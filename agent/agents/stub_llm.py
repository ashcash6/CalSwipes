"""A fake, rule-based "LLM" so the whole agent system runs offline and deterministically.

It follows the same ReAct contract as a real model: given the conversation so
far, it either asks for a tool call (Action) or returns final text (Answer).
It is deliberately simple keyword logic. Eval scores in stub mode measure the
plumbing (tools, retrieval, citations, guardrails), NOT Gemini's reasoning.
Run the evals with --mode adk to measure the real model.
"""
import json
import re
from dataclasses import dataclass, field

from agents.tools import KNOWN_ALLERGENS

HALL_PATTERNS = [
    ("crossroads", r"cross\s*roads"), ("cafe-3", r"caf[eé][\s-]*3|cafe three"),
    ("foothill", r"foothill"), ("clark-kerr", r"clark[\s-]*kerr|\bckc\b"),
]
MEALS = ["breakfast", "brunch", "lunch", "dinner", "late-night"]
FOODS = ["tofu", "chicken", "beef", "pork", "pizza", "pasta", "eggs", "egg", "salad", "soup", "rice", "fish",
         "salmon", "tuna", "bagel", "oatmeal", "beans", "curry", "noodle", "burger", "fries", "waffle", "pancake"]
DIETARY = {"vegan": "Vegan Option", "vegetarian": "Vegetarian Option", "halal": "Halal", "kosher": "Kosher"}
ALLERGEN_WORDS = {
    "milk": ["Milk"], "dairy": ["Milk"], "lactose": ["Milk"], "egg": ["Egg"], "eggs": ["Egg"],
    "fish": ["Fish"], "shellfish": ["Shellfish"], "tree nut": ["Tree Nuts"], "tree nuts": ["Tree Nuts"],
    "nut": ["Tree Nuts", "Peanuts"], "nuts": ["Tree Nuts", "Peanuts"], "peanut": ["Peanuts"],
    "peanuts": ["Peanuts"], "wheat": ["Wheat"], "gluten": ["Gluten", "Wheat"], "celiac": ["Gluten", "Wheat"],
    "soy": ["Soybeans"], "sesame": ["Sesame"], "pork": ["Pork"], "alcohol": ["Alcohol"],
}


@dataclass
class ToolCall:
    name: str
    args: dict


@dataclass
class LLMResponse:
    text: str | None = None
    tool_calls: list = field(default_factory=list)
    thought: str = ""
    tokens_in: int = 0
    tokens_out: int = 0
    model: str = "stub-llm"


# ---------------- tiny parsers ----------------

def find_hall(q):
    for slug, pat in HALL_PATTERNS:
        if re.search(pat, q, re.I):
            return slug
    return ""


def find_meal(q):
    ql = q.lower().replace("late night", "late-night")
    return next((m for m in MEALS if re.search(r"\b" + m + r"\b", ql)), "")


def find_date(q):
    m = re.search(r"\b(20\d\d-\d\d-\d\d)\b", q)
    return m.group(1) if m else ""


def find_allergens(q):
    """Allergens the user wants to AVOID ('nut allergy', 'no dairy', 'gluten-free', 'without egg')."""
    ql = q.lower()
    out = set()
    for word, names in sorted(ALLERGEN_WORDS.items(), key=lambda kv: -len(kv[0])):
        w = re.escape(word)
        avoid = (rf"\b{w}[- ]?(free|allerg\w*|intoleran\w*)", rf"\b(no|without|avoid\w*|allergic to)\s+(any\s+)?{w}\b",
                 rf"\b{w}\b[^.?]*\ballerg", rf"\ballerg\w*[^.?]*\b{w}\b")
        if any(re.search(p, ql) for p in avoid):
            if word == "fish" and re.search(r"shellfish", ql) and not re.search(r"(?<!shell)fish", ql):
                continue
            out.update(names)
    return sorted(a for a in out if a in KNOWN_ALLERGENS)


def find_dietary(q):
    return next((tag for word, tag in DIETARY.items() if re.search(r"\b" + word + r"\b", q, re.I)), "")


def find_food(q):
    ql = q.lower()
    return next((f for f in FOODS if re.search(r"\b" + f + r"\b", ql)), "")


def find_item_phrase(q):
    pats = [r"(?:protein|calories|carbs|fat|macros|nutrition|allergens?)\s+(?:is |are )?(?:in|for|of)\s+(?:the\s+)?(.+?)(?:\s+at\s+|\s+on\s+|\s+for\s+|\?|$)",
            r"(?:is|does|do|are)\s+(?:the\s+)?(.+?)\s+(?:safe|contain|have|vegan|vegetarian|halal|kosher)\b"]
    for p in pats:
        m = re.search(p, q, re.I)
        if m:
            phrase = re.sub(r"\b(at|in)\s+(crossroads|cafe 3|foothill|clark kerr)\b.*", "", m.group(1), flags=re.I)
            phrase = phrase.strip(" ?.,")
            if len(phrase) > 3 and phrase.lower() not in {"the", "this", "that", "food", "item", "anything"}:
                return phrase
    return ""


def find_number(q, unit_pat):
    m = re.search(r"(\d{2,4})\s*" + unit_pat, q, re.I)
    return float(m.group(1)) if m else 0.0


def _tokens(*parts):
    return max(1, sum(len(p if isinstance(p, str) else json.dumps(p, default=str)) for p in parts) // 4)


def _sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]


# ---------------- per-agent policies ----------------

class StubLLM:
    model = "stub-llm"

    def generate(self, agent_name: str, instruction: str, request: str, history: list, tool_names: list) -> LLMResponse:
        policy = getattr(self, "_" + agent_name)
        resp = policy(request, history)
        resp.tokens_in = _tokens(instruction, request, history, tool_names)
        resp.tokens_out = _tokens(resp.text or "", [c.__dict__ for c in resp.tool_calls], resp.thought)
        return resp

    # root: plan + delegate, then combine
    def _root_planner(self, q, history):
        if history:
            answers = [h["result"]["answer"] for h in history if h["type"] == "observation"]
            return LLMResponse(text="\n\n".join(a for a in answers if a), thought="All delegated parts answered; combine.")
        ql = q.lower()
        targets = []
        wants_plan = bool(find_number(q, r"(k?cal|calories)") or re.search(r"\b(combo|meal plan|plan a|build (me )?a)\b", ql))
        policy_words = re.search(r"\b(cross[- ]contact|guarantee\w*|policy|polic(y|ies)|label\w*|mean|update\w*|"
                                 r"refresh\w*|stale|accurate|accuracy|come from|source|which halls|locations?|"
                                 r"serious allergy|severe|ounces|convert|track\w*|how often|cross|estimat\w*|approv\w*)\b", ql)
        menu_words = re.search(r"\b(serv\w*|menu|what'?s for|protein|calories|carbs|macros|nutrition|hours?|"
                               r"open|time|close\w*|contain\w*|items?|options?|have|available|safe)\b", ql)
        allergen_q = re.search(r"allerg|nut|gluten|celiac|dairy|sesame|shellfish|soy", ql)
        if wants_plan:
            targets.append("nutrition_agent")
        if menu_words and not wants_plan and not (policy_words and not find_hall(q) and not find_item_phrase(q)):
            targets.append("menu_agent")
        if policy_words or (allergen_q and ("menu_agent" in targets or "nutrition_agent" in targets) and
                            re.search(r"\bsafe\b", ql)):
            targets.append("policy_agent")
        if not targets:
            targets = ["menu_agent"]
        return LLMResponse(tool_calls=[ToolCall(f"ask_{t}", {"request": q}) for t in targets],
                           thought=f"Plan: delegate to {', '.join(targets)}.")

    def _menu_agent(self, q, history):
        if history:
            return LLMResponse(text=self._menu_answer(q, history[-1]), thought="Summarize tool result.")
        hall, meal, date = find_hall(q), find_meal(q), find_date(q)
        ql = q.lower()
        if re.search(r"\b(hours?|open|what time|when (is|does|do)|close\w*|start\w*|end\w*)\b", ql):
            return LLMResponse(tool_calls=[ToolCall("get_meal_hours", {"hall": hall, "date": date})],
                               thought="Hours question -> get_meal_hours.")
        item = find_item_phrase(q)
        if item and not find_dietary(item):
            return LLMResponse(tool_calls=[ToolCall("get_nutrition", {"item_name": item, "hall": hall, "date": date})],
                               thought=f"Specific item '{item}' -> get_nutrition.")
        args = {"hall": hall, "meal": meal, "date": date, "query": find_food(q),
                "exclude_allergens": find_allergens(q), "dietary_tag": find_dietary(q),
                "min_protein_g": 20.0 if re.search(r"high[- ]protein", ql) else 0.0, "limit": 25}
        return LLMResponse(tool_calls=[ToolCall("search_menu", args)], thought="Menu listing -> search_menu.")

    def _menu_answer(self, q, obs):
        name, r, args = obs["name"], obs["result"], obs["args"]
        if "error" in r and not r.get("matches"):
            return f"I couldn't find that: {r['error']}."
        if name == "get_meal_hours":
            if not r["meals"]:
                return "I don't have meal times for that hall and date."
            meal = find_meal(q)
            rows = [m for m in r["meals"] if not meal or m["period"] == meal] or r["meals"]
            return "Meal times from the menu feed: " + "; ".join(
                f"{m['hall_name']} {m['period']} {m['start_time']} to {m['end_time']} on {m['date']}" for m in rows) + "."
        if name == "get_nutrition":
            m = r["matches"][0]
            allergens = ", ".join(m["allergens"]) or "none flagged"
            tags = ", ".join(m["dietary_tags"]) or "none"
            if m["nutrition_status"] != "published":
                return f"{m['item']} at {m['hall']} has no published nutrition. Allergen flags: {allergens}."
            return (f"{m['item']} at {m['hall']} ({m['meal']}, {m['date']}), per {m['serving']} serving: "
                    f"{m['calories_kcal']:.0f} kcal, {m['protein_g']:.1f} g protein, {m['carbs_g']:.1f} g carbs, "
                    f"{m['fat_g']:.1f} g fat. Allergen flags: {allergens}. Dietary tags: {tags}.")
        if name == "search_menu":
            if not r["items"]:
                return f"No matching items on {r['date']}."
            where = " ".join(x for x in [args.get("hall"), args.get("meal")] if x) or "all halls"
            filt = []
            if args.get("exclude_allergens"):
                filt.append("without the " + ", ".join(args["exclude_allergens"]) + " flag")
            if args.get("dietary_tag"):
                filt.append("tagged " + args["dietary_tag"])
            items = "; ".join(f"{i['item']} ({i['hall']} {i['meal']}, {i['calories_kcal']:.0f} kcal, "
                              f"{i['protein_g']:.1f} g protein)" for i in r["items"][:8])
            return (f"{r['count']} items for {where} on {r['date']}" + (" " + ", ".join(filt) if filt else "")
                    + f". Top by protein: {items}.")
        return json.dumps(r)[:500]

    def _policy_agent(self, q, history):
        if not history:
            return LLMResponse(tool_calls=[ToolCall("search_dining_info", {"query": q, "k": 4})],
                               thought="Policy question -> retrieve passages.")
        results = history[-1]["result"]["results"]
        if not results:
            return LLMResponse(text="I couldn't find anything about that in the dining docs.")
        qwords = set(re.findall(r"[a-z]+", q.lower())) - {"the", "a", "is", "are", "what", "how", "do", "does", "i", "if", "to", "of"}
        top = results[0]["score"]
        results = [r for r in results if r["score"] >= 0.6 * top]  # drop weakly related passages
        scored = []
        for rank, r in enumerate(results):
            for s in _sentences(r["text"]):
                if s.startswith(">") or "SAMPLE TEXT" in s or s.startswith("#"):
                    continue
                overlap = len(qwords & set(re.findall(r"[a-z]+", s.lower())))
                scored.append((overlap + r["score"] * 2 - rank * 0.1, s.lstrip("# "), r))
        scored.sort(key=lambda x: -x[0])
        picked = scored[:2]
        sample = any(r["is_sample"] for _, _, r in picked)
        body = " ".join(f"{s} {r['citation']}" for _, s, r in picked)
        prefix = "From the dining docs (sample text, not official): " if sample else "From the dining docs: "
        return LLMResponse(text=prefix + body, thought="Answer with the two most relevant cited sentences.")

    def _nutrition_agent(self, q, history):
        if not history:
            hall = find_hall(q)
            if not hall:
                return LLMResponse(text="Which dining hall should I plan from? (Crossroads, Cafe 3, Foothill, or Clark Kerr)")
            args = {"hall": hall, "target_calories": find_number(q, r"(k?cal|calories)") or 700.0,
                    "target_protein_g": find_number(q, r"g(rams)?\s*(of\s*)?protein"), "meal": find_meal(q),
                    "date": find_date(q), "exclude_allergens": find_allergens(q), "dietary_tag": find_dietary(q),
                    "max_items": 3}
            return LLMResponse(tool_calls=[ToolCall("plan_meal", args)], thought="Extract targets -> plan_meal.")
        r = history[-1]["result"]
        if not r.get("combos"):
            return LLMResponse(text="I couldn't build a combo with those filters: " + r.get("error", "no items") + ".")
        lines = []
        for i, c in enumerate(r["combos"], 1):
            items = " + ".join(f"{x['item']} ({x['serving']})" for x in c["items"])
            t = c["totals"]
            lines.append(f"{i}. {items}: {t['calories_kcal']:.0f} kcal, {t['protein_g']:.1f} g protein, "
                         f"{t['carbs_g']:.1f} g carbs, {t['fat_g']:.1f} g fat")
        tgt = r["target"]
        head = (f"Combos at {r['hall']} {r['meal']} on {r['date']} for about {tgt['calories_kcal']:.0f} kcal"
                + (f" and {tgt['protein_g']:.0f} g protein" if tgt["protein_g"] else "") + ":")
        return LLMResponse(text=head + "\n" + "\n".join(lines), thought="Format combos.")
