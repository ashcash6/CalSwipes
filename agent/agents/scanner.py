"""Tray scanner: photo of a dining tray -> which menu items are on it.

How it works:
1. Load the candidate list: every item served at that hall/meal/date, from the
   structured tables (menu_item_id = the Eatec recipe id the iOS app already uses).
2. Send the photo + candidate list to Gemini with a constrained JSON schema. The
   schema's `enum` lists only candidate ids, so the model is steered to pick from the menu.
3. Validate server-side anyway: anything whose id isn't a candidate is dropped,
   names are replaced with the canonical menu name, confidence is clamped to 0..1.

Servings are a rough estimate (0.5-3, snapped to halves); the client shows them as editable steppers.
OFFLINE=1 uses StubVision (deterministic, does not look at the image).
"""
import base64
import hashlib
import json
import os
import time
import uuid
from datetime import datetime
from zoneinfo import ZoneInfo

from config import Settings, offline
from observability.telemetry import log_event, record_llm_call, span

ALLOWED_MIME_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_IMAGE_BYTES = 10 * 1024 * 1024
MAX_MATCHES = 12

PROMPT = """You identify food on a UC Berkeley dining hall tray.
Only choose items from this menu (JSON list of {{menu_item_id, name, category, serving}}):
{candidates}
Return every menu item you can see on the tray with a confidence from 0 to 1.
If you can't tell between two similar items, return both with lower confidence.
For each item, estimate how many of its listed servings are on the tray (0.5, 1, 1.5, 2, 2.5 or 3).
A standard plate scoop of a side is about 1 serving; a full plate of one item is about 2.
If nothing on the tray matches the menu, return an empty list."""


class ScanError(ValueError):
    def __init__(self, code: str, message: str, status: int):
        super().__init__(message)
        self.code, self.status = code, status


def today_berkeley() -> str:
    return datetime.now(ZoneInfo("America/Los_Angeles")).date().isoformat()


def load_candidates(store, hall: str, meal: str, date: str) -> list[dict]:
    return store.query(
        "SELECT DISTINCT i.recipe_id AS menu_item_id, i.name, i.category, n.serving_qty, n.serving_unit, "
        "n.calories_kcal, n.protein_g, n.carbs_g, n.fat_g FROM menu_entries e "
        "JOIN meals m ON m.id = e.meal_id JOIN locations l ON l.id = m.location_id JOIN items i ON i.id = e.item_id "
        "LEFT JOIN nutrition n ON n.item_id = i.id "
        "WHERE l.slug = ? AND m.period = ? AND m.service_date = ? ORDER BY i.name",
        (hall.strip().lower(), meal.strip().lower(), date))


def serving_label(c: dict) -> str | None:
    q, u = c.get("serving_qty"), c.get("serving_unit")
    if q is None or not u:
        return None
    return f"{q:g} {u}"


def prompt_candidates(candidates: list[dict]) -> list[dict]:
    """What the model sees: id, name, category, serving. Nutrition stays server-side."""
    return [{"menu_item_id": c["menu_item_id"], "name": c["name"], "category": c.get("category"),
             "serving": serving_label(c)} for c in candidates]


def snap_servings(value) -> float:
    try:
        v = float(value)
    except (TypeError, ValueError):
        return 1.0
    return min(3.0, max(0.5, round(v * 2) / 2))


def response_schema(candidate_ids: list[str]) -> dict:
    return {
        "type": "OBJECT",
        "properties": {"items": {"type": "ARRAY", "items": {
            "type": "OBJECT",
            "properties": {"menu_item_id": {"type": "STRING", "enum": candidate_ids},
                           "name": {"type": "STRING"},
                           "confidence": {"type": "NUMBER"},
                           "servings": {"type": "NUMBER"}},
            "required": ["menu_item_id", "name", "confidence", "servings"]}}},
        "required": ["items"],
    }


def validate_matches(raw_items, candidates: list[dict]) -> tuple[list[dict], int]:
    """Keep only candidate ids; canonical names; clamp confidence; dedupe; sort. Returns (matches, dropped)."""
    by_id = {c["menu_item_id"]: c for c in candidates}
    best, dropped = {}, 0
    for it in raw_items if isinstance(raw_items, list) else []:
        mid = str(it.get("menu_item_id", "")) if isinstance(it, dict) else ""
        if mid not in by_id:
            dropped += 1
            continue
        try:
            conf = min(1.0, max(0.0, float(it.get("confidence", 0))))
        except (TypeError, ValueError):
            conf = 0.0
        if mid not in best or conf > best[mid]["confidence"]:
            c = by_id[mid]
            m = {"menu_item_id": mid, "name": c["name"], "confidence": round(conf, 3),
                 "servings": snap_servings(it.get("servings", 1)), "serving": serving_label(c)}
            if c.get("calories_kcal") is not None:
                m["macros"] = {k: round(float(c.get(k) or 0), 2)
                               for k in ("calories_kcal", "protein_g", "carbs_g", "fat_g")}
            best[mid] = m
    matches = sorted(best.values(), key=lambda m: (-m["confidence"], m["name"]))[:MAX_MATCHES]
    return matches, dropped


class StubVision:
    """Offline stand-in. Deterministically 'sees' 2-3 candidates chosen by hashing the image bytes.
    It never looks at the picture, so its output means nothing about accuracy."""
    model = "stub-vision"

    def identify(self, image: bytes, mime_type: str, candidates: list[dict]) -> tuple[list, int, int]:
        ranked = sorted(candidates, key=lambda c: hashlib.sha256(image + c["menu_item_id"].encode()).hexdigest())
        n = 2 + (image[0] % 2 if image else 0)
        items = [{"menu_item_id": c["menu_item_id"], "name": c["name"], "confidence": round(0.9 - 0.2 * i, 2),
                  "servings": 1}
                 for i, c in enumerate(ranked[:n])]
        return items, 258 + len(json.dumps(candidates)) // 4, len(json.dumps(items)) // 4


class GeminiVision:
    """Gemini on Vertex AI with structured JSON output. Auth = Application Default Credentials."""

    def __init__(self, settings: Settings):
        from google import genai
        from google.genai import types

        self.types = types
        self.model = os.environ.get("SCAN_MODEL", "gemini-3.8-flash")
        self.client = genai.Client(vertexai=True, project=settings.gcp_project, location=settings.gcp_location)

    def identify(self, image: bytes, mime_type: str, candidates: list[dict]) -> tuple[list, int, int]:
        t = self.types
        resp = self.client.models.generate_content(
            model=self.model,
            contents=[t.Part.from_bytes(data=image, mime_type=mime_type),
                      PROMPT.format(candidates=json.dumps(prompt_candidates(candidates), ensure_ascii=False))],
            config=t.GenerateContentConfig(
                temperature=0, response_mime_type="application/json",
                response_schema=response_schema([c["menu_item_id"] for c in candidates])),
        )
        usage = resp.usage_metadata
        items = json.loads(resp.text or "{}").get("items", [])
        return items, (usage.prompt_token_count or 0) if usage else 0, (usage.candidates_token_count or 0) if usage else 0


_vision = {"client": None}


def get_vision():
    if _vision["client"] is None:
        _vision["client"] = StubVision() if offline() else GeminiVision(Settings.from_env())
    return _vision["client"]


def set_vision(client):
    """Tests swap in a fake client (e.g. one that returns off-menu ids)."""
    _vision["client"] = client


def scan_image(store, image: bytes, mime_type: str, hall: str, meal: str, date: str = "") -> dict:
    if mime_type not in ALLOWED_MIME_TYPES:
        raise ScanError("invalid_mime_type", f"Supported types: {', '.join(sorted(ALLOWED_MIME_TYPES))}", 415)
    if not image:
        raise ScanError("invalid_image", "image is empty", 400)
    if len(image) > MAX_IMAGE_BYTES:
        raise ScanError("image_too_large", "Image must be under 10 MB", 413)
    if not hall or not meal:
        raise ScanError("missing_field", "hall and meal are required", 400)
    date = date or today_berkeley()
    candidates = load_candidates(store, hall, meal, date)
    if not candidates:
        raise ScanError("menu_unavailable", f"No menu for {hall} {meal} on {date}", 404)
    vision = get_vision()
    start = time.perf_counter()
    with span("scan.vision", model=vision.model, candidates=len(candidates), hall=hall, meal=meal):
        raw, tokens_in, tokens_out = vision.identify(image, mime_type, candidates)
    record_llm_call("scanner", vision.model, tokens_in, tokens_out, (time.perf_counter() - start) * 1000)
    matches, dropped = validate_matches(raw, candidates)
    if dropped:
        log_event("scan_dropped_off_menu", count=dropped, hall=hall, meal=meal, date=date)
    return {"hall": hall, "meal": meal, "date": date, "matches": matches, "dropped_off_menu": dropped,
            "candidates_count": len(candidates), "model": vision.model}


# ---- images uploaded to the service, referenced by id from the ADK tool ----
_IMAGES: dict[str, tuple[bytes, str]] = {}


def register_image(image: bytes, mime_type: str) -> str:
    ref = uuid.uuid4().hex
    if len(_IMAGES) > 100:  # bounded in-memory cache; Cloud Run instances are short-lived anyway
        _IMAGES.pop(next(iter(_IMAGES)))
    _IMAGES[ref] = (image, mime_type)
    return ref


def resolve_image(image_ref: str = "", image_base64: str = "", mime_type: str = "image/jpeg") -> tuple[bytes, str]:
    if image_ref:
        if image_ref not in _IMAGES:
            raise ScanError("unknown_image_ref", "image_ref not found (upload via POST /v1/scan)", 404)
        return _IMAGES[image_ref]
    try:
        return base64.b64decode(image_base64, validate=True), mime_type
    except Exception:
        raise ScanError("invalid_image", "image_base64 must be valid base64", 400) from None
