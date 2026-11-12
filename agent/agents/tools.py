"""Tools the agents can call. Plain Python functions with type hints + docstrings.

Google ADK turns a function like this into a tool automatically: the function
name becomes the tool name, the docstring becomes the description the LLM reads,
and the type hints become the JSON schema for arguments. The MCP server exposes
the same functions, so there is exactly one implementation of each tool.
"""
import functools
import itertools
import time
from datetime import date as _date

from config import Settings
from observability.telemetry import record_tool_call, span
from pipeline.embeddings import get_embedder
from pipeline.store import BaseStore, UnsafeQuery, open_store

KNOWN_ALLERGENS = ["Milk", "Egg", "Fish", "Shellfish", "Tree Nuts", "Wheat", "Peanuts", "Soybeans",
                   "Gluten", "Alcohol", "Sesame", "Pork"]
KNOWN_DIETARY = ["Vegan Option", "Vegetarian Option", "Halal", "Kosher"]
HALLS = ["crossroads", "cafe-3", "foothill", "clark-kerr", "golden-bear", "bear-market", "cub-market",
         "local-x-design", "the-den", "qualcomm-cafe", "gateway-cafe"]

SCHEMA_DOC = """Tables (SQLite/Postgres):
locations(id, slug, name)            slug e.g. 'crossroads', 'cafe-3', 'foothill', 'clark-kerr'
dates(service_date, weekday)         service_date 'YYYY-MM-DD'
meals(id, location_id, service_date, period, source_name, start_time, end_time)  period: breakfast|lunch|dinner|...
items(id, recipe_id, name, category, allergens, dietary_tags)   allergens like ',Milk,Egg,' (use LIKE '%,Milk,%')
nutrition(item_id, status, serving_qty, serving_unit, serving_weight_g, calories_kcal, protein_g, carbs_g, fat_g)
menu_entries(meal_id, item_id)       which items are served at which meal"""

_ctx = {"store": None, "embedder": None, "default_date": None}


def configure(store: BaseStore | None = None, embedder=None, default_date: str | None = None):
    """Point the tools at a store/embedder (tests use an in-memory SQLite store)."""
    if store is not None:
        _ctx["store"] = store
    if embedder is not None:
        _ctx["embedder"] = embedder
    if default_date is not None:
        _ctx["default_date"] = default_date


def _store() -> BaseStore:
    if _ctx["store"] is None:
        _ctx["store"] = open_store(Settings.from_env())
    return _ctx["store"]


def _embedder():
    if _ctx["embedder"] is None:
        _ctx["embedder"] = get_embedder()
    return _ctx["embedder"]


def _default_date() -> str:
    """Today, unless configured. Falls back to the latest date that has data."""
    if _ctx["default_date"]:
        return _ctx["default_date"]
    today = _date.today().isoformat()
    if _store().scalar("SELECT COUNT(*) FROM meals WHERE service_date = ?", (today,)):
        return today
    return _store().scalar("SELECT MAX(service_date) FROM meals") or today


def _traced(agent: str):
    def deco(fn):
        @functools.wraps(fn)  # keeps name, docstring and signature so ADK/MCP build the right schema
        def wrapper(*args, **kwargs):
            start, ok = time.perf_counter(), True
            with span(f"tool.{fn.__name__}", agent=agent):
                try:
                    out = fn(*args, **kwargs)
                    ok = "error" not in out
                    return out
                except Exception:
                    ok = False
                    raise
                finally:
                    record_tool_call(agent, fn.__name__, (time.perf_counter() - start) * 1000, ok)
        return wrapper
    return deco


def _norm_allergens(values) -> list[str]:
    lookup = {a.lower(): a for a in KNOWN_ALLERGENS}
    lookup.update({"nuts": "Tree Nuts", "tree nut": "Tree Nuts", "peanut": "Peanuts", "soy": "Soybeans",
                   "dairy": "Milk", "eggs": "Egg", "sesame seeds": "Sesame"})
    return sorted({lookup[v.strip().lower()] for v in (values or []) if v and v.strip().lower() in lookup})


def _item_row(r: dict) -> dict:
    return {
        "item": r["name"], "hall": r["hall"], "date": r["service_date"], "meal": r["period"],
        "category": r["category"],
        "allergens": [a for a in r["allergens"].strip(",").split(",") if a],
        "dietary_tags": [t for t in r["dietary_tags"].strip(",").split(",") if t],
        "nutrition_status": r["status"],
        "serving": f"{r['serving_qty']:g} {r['serving_unit']}",
        "calories_kcal": r["calories_kcal"], "protein_g": r["protein_g"],
        "carbs_g": r["carbs_g"], "fat_g": r["fat_g"],
    }


_BASE_SELECT = """SELECT i.name, i.category, i.allergens, i.dietary_tags, l.slug AS hall, m.service_date, m.period,
       n.status, n.serving_qty, n.serving_unit, n.calories_kcal, n.protein_g, n.carbs_g, n.fat_g
FROM menu_entries e JOIN meals m ON m.id = e.meal_id JOIN locations l ON l.id = m.location_id
JOIN items i ON i.id = e.item_id JOIN nutrition n ON n.item_id = i.id"""


def _menu_rows(hall="", date="", meal="", query="", exclude_allergens=None, dietary_tag="", min_protein_g=0.0,
               limit=25):
    where, params = ["m.service_date = ?"], [date or _default_date()]
    if hall:
        where.append("l.slug = ?")
        params.append(hall.strip().lower())
    if meal:
        where.append("m.period = ?")
        params.append(meal.strip().lower())
    if query:
        where.append("LOWER(i.name) LIKE ?")
        params.append(f"%{query.strip().lower()}%")
    for a in _norm_allergens(exclude_allergens):
        where.append("i.allergens NOT LIKE ?")
        params.append(f"%,{a},%")
    if dietary_tag:
        where.append("i.dietary_tags LIKE ?")
        params.append(f"%,{dietary_tag.strip()},%")
    if min_protein_g:
        where.append("n.protein_g >= ?")
        params.append(float(min_protein_g))
    sql = _BASE_SELECT + " WHERE " + " AND ".join(where) + " ORDER BY n.protein_g DESC, i.name LIMIT ?"
    return _store().query(sql, (*params, int(limit)))


# ----------------------------- menu_agent tools -----------------------------

@_traced("menu_agent")
def search_menu(hall: str = "", date: str = "", meal: str = "", query: str = "",
                exclude_allergens: list[str] | None = None, dietary_tag: str = "",
                min_protein_g: float = 0.0, limit: int = 25) -> dict:
    """Search what is being served in Berkeley dining halls.

    Args:
        hall: hall slug such as 'crossroads', 'cafe-3', 'foothill', 'clark-kerr'. Empty = all halls.
        date: 'YYYY-MM-DD'. Empty = today (or the latest date with data).
        meal: 'breakfast', 'lunch', 'dinner', 'brunch', 'late-night'. Empty = all meals.
        query: case-insensitive substring of the item name, e.g. 'tofu'.
        exclude_allergens: allergen names to filter out, e.g. ['Peanuts', 'Milk'].
            Filtering uses the feed's allergen flags and does NOT guarantee safety.
        dietary_tag: one of 'Vegan Option', 'Vegetarian Option', 'Halal', 'Kosher'.
        min_protein_g: only items with at least this much protein per serving.
        limit: max rows to return (default 25).

    Returns:
        {"items": [...], "count": int, "date": str}. Each item has hall, meal, allergens,
        dietary_tags and macros per one serving.
    """
    rows = _menu_rows(hall, date, meal, query, exclude_allergens, dietary_tag, min_protein_g, limit)
    return {"items": [_item_row(r) for r in rows], "count": len(rows), "date": date or _default_date()}


@_traced("menu_agent")
def get_nutrition(item_name: str, hall: str = "", date: str = "") -> dict:
    """Look up the nutrition facts, serving size, allergens and dietary tags for one menu item.

    Args:
        item_name: full or partial item name, e.g. 'Scrambled Eggs'.
        hall: optional hall slug to narrow the match.
        date: optional 'YYYY-MM-DD'; empty = today (or the latest date with data).

    Returns:
        {"matches": [...]} with at most 5 matching items, exact-name matches first.
    """
    rows = _menu_rows(hall=hall, date=date, query=item_name, limit=50)
    seen, out = set(), []
    for r in sorted(rows, key=lambda r: (r["name"].lower() != item_name.strip().lower(), len(r["name"]))):
        if (r["name"], r["hall"]) in seen:
            continue
        seen.add((r["name"], r["hall"]))
        out.append(_item_row(r))
    if not out:
        return {"matches": [], "error": f"no item matching {item_name!r}"}
    return {"matches": out[:5]}


@_traced("menu_agent")
def get_meal_hours(hall: str = "", date: str = "") -> dict:
    """Meal periods and their start/end times for a hall on a date, taken from the menu feed.

    Args:
        hall: hall slug, e.g. 'crossroads'. Empty = all halls.
        date: 'YYYY-MM-DD'. Empty = today (or the latest date with data).
    """
    where, params = ["m.service_date = ?"], [date or _default_date()]
    if hall:
        where.append("l.slug = ?")
        params.append(hall.strip().lower())
    rows = _store().query(
        "SELECT l.slug AS hall, l.name AS hall_name, m.service_date AS date, m.period, m.start_time, m.end_time "
        "FROM meals m JOIN locations l ON l.id = m.location_id WHERE " + " AND ".join(where) +
        " ORDER BY l.slug, m.start_time", tuple(params))
    return {"meals": rows, "count": len(rows)}


@_traced("menu_agent")
def run_menu_sql(sql: str) -> dict:
    """Run ONE read-only SELECT over the menu tables when the other tools can't answer.

    Only SELECT/WITH over locations, dates, meals, items, nutrition, menu_entries is allowed.
    Results are capped at 50 rows. Schema is appended below.
    """
    try:
        rows = _store().readonly_query(sql)
    except UnsafeQuery as exc:
        return {"error": f"query rejected: {exc}"}
    except Exception as exc:  # syntax errors etc. go back to the model so it can retry
        return {"error": f"query failed: {type(exc).__name__}: {str(exc)[:200]}"}
    return {"rows": rows, "count": len(rows)}


run_menu_sql.__doc__ += "\n" + SCHEMA_DOC


# ----------------------------- policy_agent tools -----------------------------

@_traced("policy_agent")
def search_dining_info(query: str, k: int = 4) -> dict:
    """Retrieve passages from dining info documents (hours, allergen policy, dietary labels, app FAQ).

    Args:
        query: the user's question or keywords.
        k: number of passages (default 4).

    Returns:
        {"results": [{"citation": "[doc_id#n]", "title", "text", "score", "is_sample", "source_url"}]}.
        Quote the citation tag after any sentence that uses a passage.
    """
    vec = _embedder().embed_query(query)
    hits = _store().vector_search(vec, k=int(k))
    return {"results": [{"citation": f"[{h['id']}]", "doc_id": h["doc_id"], "title": h["title"],
                         "text": h["text"], "score": round(float(h["score"]), 4),
                         "is_sample": bool(h["is_sample"]), "source_url": h["source_url"]} for h in hits]}


# ----------------------------- nutrition_agent tools -----------------------------

_SKIP_CATEGORIES = ("condiment", "dessert", "soft serve", "beverage", "bread & pastries", "pastry")


def _role(it: dict) -> str:
    cal, p, c = it["calories_kcal"] or 0, it["protein_g"] or 0, it["carbs_g"] or 0
    if p >= 10 and p * 4 >= 0.25 * max(cal, 1):
        return "protein"
    if c * 4 >= 0.45 * max(cal, 1) and cal >= 80:
        return "carb"
    if cal < 150:
        return "side"
    return "other"


def _combo_error(totals, target_cal, target_pro):
    # Same idea as the iOS LocalRecommender: weighted relative miss on calories and protein.
    cal_err = abs(totals["calories_kcal"] - target_cal) / max(target_cal, 1)
    pro_err = abs(totals["protein_g"] - target_pro) / max(target_pro, 1) if target_pro else 0
    return 0.6 * cal_err + 0.4 * pro_err


@_traced("nutrition_agent")
def plan_meal(hall: str, target_calories: float, target_protein_g: float = 0.0, meal: str = "",
              date: str = "", exclude_allergens: list[str] | None = None, dietary_tag: str = "",
              max_items: int = 3) -> dict:
    """Build up to 3 meal combinations (1-3 items) from one hall's menu that best hit a calorie/protein target.

    Args:
        hall: hall slug, e.g. 'crossroads'.
        target_calories: calories for this meal, e.g. 700.
        target_protein_g: protein target in grams, e.g. 40. 0 = ignore protein.
        meal: 'breakfast' | 'lunch' | 'dinner'. Empty = any.
        date: 'YYYY-MM-DD'. Empty = today (or the latest date with data).
        exclude_allergens: allergens to filter out using the feed's flags (not a safety guarantee).
        dietary_tag: optional 'Vegan Option' | 'Vegetarian Option' | 'Halal' | 'Kosher'.
        max_items: 1-3 items per combo.

    Returns:
        {"combos": [{"items": [...], "totals": {...}, "error_pct": float}], "target": {...}}
    """
    rows = _menu_rows(hall, date, meal, "", exclude_allergens, dietary_tag, 0, 500)
    items, seen = [], set()
    for r in rows:
        if r["status"] != "published" or r["calories_kcal"] is None or r["name"] in seen:
            continue
        if any(s in (r["category"] or "").lower() for s in _SKIP_CATEGORIES) or r["calories_kcal"] < 20:
            continue
        seen.add(r["name"])
        it = _item_row(r)
        it["role"] = _role(it)
        items.append(it)
    if not items:
        return {"combos": [], "error": "no items with published nutrition match these filters"}

    # Candidate pool: best protein sources + best carbs + some produce, so search stays small.
    by_role = {}
    for it in items:
        by_role.setdefault(it["role"], []).append(it)
    pool = (sorted(by_role.get("protein", []), key=lambda i: -i["protein_g"])[:6]
            + sorted(by_role.get("carb", []), key=lambda i: -i["calories_kcal"])[:4]
            + sorted(by_role.get("side", []), key=lambda i: -i["protein_g"])[:3]
            + by_role.get("other", [])[:2])
    keys = ("calories_kcal", "protein_g", "carbs_g", "fat_g")
    scored = []
    for n in range(1, max(1, min(int(max_items), 3)) + 1):
        for combo in itertools.combinations(pool, n):
            if n > 1 and len({c["role"] for c in combo}) < n:
                continue  # one item per role keeps combos balanced (protein + carb + side)
            totals = {k: round(sum(c[k] or 0 for c in combo), 1) for k in keys}
            scored.append((_combo_error(totals, target_calories, target_protein_g), combo, totals))
    scored.sort(key=lambda s: s[0])
    picked, used = [], []
    for err, combo, totals in scored:
        names = {c["item"] for c in combo}
        if any(len(names & u) > 1 for u in used):
            continue  # diversity: two suggestions share at most one item
        used.append(names)
        picked.append({"items": [{"item": c["item"], "role": c["role"], "serving": c["serving"],
                                  "calories_kcal": c["calories_kcal"], "protein_g": c["protein_g"],
                                  "allergens": c["allergens"]} for c in combo],
                       "totals": totals, "error_pct": round(err * 100, 1)})
        if len(picked) == 3:
            break
    return {"combos": picked, "hall": hall, "meal": meal or "any", "date": date or _default_date(),
            "target": {"calories_kcal": target_calories, "protein_g": target_protein_g}}


# ----------------------------- tray scanner -----------------------------

@_traced("menu_agent")
def scan_tray(hall: str, meal: str, date: str = "", image_ref: str = "", image_base64: str = "",
              mime_type: str = "image/jpeg") -> dict:
    """Identify which menu items are on a photo of a dining tray.

    Only items on that hall/meal/date's menu can be returned. Does not estimate portions;
    ask the user how many servings they took.

    Args:
        hall: hall slug, e.g. 'crossroads'.
        meal: 'breakfast' | 'lunch' | 'dinner' | ...
        date: 'YYYY-MM-DD'. Empty = today in Berkeley.
        image_ref: id of an image uploaded through POST /v1/scan (given to you in the user message).
        image_base64: alternatively, the image bytes as base64 (for MCP clients).
        mime_type: 'image/jpeg' | 'image/png' | 'image/webp' (only used with image_base64).

    Returns:
        {"matches": [{"menu_item_id", "name", "confidence"}], "dropped_off_menu": int, ...} or {"error": ...}.
    """
    from agents.scanner import ScanError, resolve_image, scan_image
    try:
        image, mime = resolve_image(image_ref, image_base64, mime_type)
        return scan_image(_store(), image, mime, hall, meal, date)
    except ScanError as exc:
        return {"error": str(exc), "code": exc.code}


MENU_TOOLS = [search_menu, get_nutrition, get_meal_hours, run_menu_sql, scan_tray]
POLICY_TOOLS = [search_dining_info]
NUTRITION_TOOLS = [plan_meal, get_nutrition]
