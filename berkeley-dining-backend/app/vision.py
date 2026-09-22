"""Gemini vision module: identify dining-hall food items from a photo."""
import base64
import json
import httpx

GEMINI_URL = "https://generativelanguage.googleapis.com/v1/models/gemini-3.6-flash:generateContent"
CONFIDENCE_THRESHOLD = 0.6


def _prompt(menu_items: list[dict]) -> str:
    lines = "\n".join(f"- id={item['id']}: {item['name']}" for item in menu_items)
    return f"""You are analyzing a food photo taken at a university dining hall.

Menu items available for this meal:
{lines}

Identify which item(s) from the menu are visible in the photo.
For each identifiable item:
  • Match it to exactly one menu item by its id and name.
  • Estimate the portion size relative to a standard serving: 0.5, 1.0, 1.5, or 2.0.
  • Rate your confidence from 0.0 to 1.0.

Reply ONLY with a JSON object — no markdown fences, no prose:
{{
  "matched": [
    {{
      "item_id": "<id from the menu>",
      "item_name": "<name from the menu>",
      "portion_multiplier": <0.5|1.0|1.5|2.0>,
      "confidence": <0.0-1.0>
    }}
  ],
  "no_match_reason": null
}}

If you cannot match any item with confidence ≥ {CONFIDENCE_THRESHOLD}
(the food is not on the menu, the photo is unclear, etc.),
set "matched" to [] and "no_match_reason" to a brief explanation."""


def _generic_prompt() -> str:
    return """You are a nutrition expert analyzing a food photo.

Identify the food(s) visible and estimate their combined nutritional content for the portion shown.

Reply ONLY with a JSON object — no markdown fences, no prose:
{
  "description": "<brief description, e.g. 'grilled chicken sandwich with fries'>",
  "calories_kcal": <number>,
  "protein_g": <number>,
  "carbs_g": <number>,
  "fat_g": <number>,
  "confidence": <0.0-1.0>
}

If the image is unclear or you cannot identify food, set confidence to 0.0 and all macros to 0."""


def _strip_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        parts = text.split("```", 2)
        inner = parts[1]
        if inner.startswith("json"):
            inner = inner[4:]
        return inner.strip()
    return text


def identify_items(
    photo_bytes: bytes,
    mime_type: str,
    menu_items: list[dict],
    api_key: str,
) -> dict:
    """Call Gemini 2.0 Flash to match food in a photo against known menu items.

    Returns a dict with keys:
      matched        – list of {item_id, item_name, portion_multiplier, confidence}
                       already filtered to confidence ≥ CONFIDENCE_THRESHOLD
      no_match_reason – str | None
    """
    photo_b64 = base64.b64encode(photo_bytes).decode()
    payload = {
        "contents": [{
            "parts": [
                {"text": _prompt(menu_items)},
                {"inline_data": {"mime_type": mime_type, "data": photo_b64}},
            ]
        }],
        "generationConfig": {"temperature": 0.1, "maxOutputTokens": 512},
    }

    with httpx.Client(timeout=30) as client:
        resp = client.post(f"{GEMINI_URL}?key={api_key}", json=payload)
        resp.raise_for_status()

    raw = _strip_fences(resp.json()["candidates"][0]["content"]["parts"][0]["text"])
    result = json.loads(raw)

    # Drop low-confidence matches and clamp values defensively
    valid_multipliers = {0.5, 1.0, 1.5, 2.0}
    filtered = []
    for m in result.get("matched", []):
        conf = float(m.get("confidence", 0))
        mult = float(m.get("portion_multiplier", 1.0))
        if mult not in valid_multipliers:
            # Round to nearest allowed value
            mult = min(valid_multipliers, key=lambda v: abs(v - mult))
        if conf >= CONFIDENCE_THRESHOLD:
            filtered.append({**m, "confidence": conf, "portion_multiplier": mult})

    result["matched"] = filtered
    if not filtered and not result.get("no_match_reason"):
        result["no_match_reason"] = "No menu items identified with sufficient confidence"

    return result


def identify_food_generic(
    photo_bytes: bytes,
    mime_type: str,
    api_key: str,
) -> dict:
    """Estimate macros for any food photo without a menu constraint.

    Returns a dict with keys: description, calories_kcal, protein_g, carbs_g, fat_g, confidence.
    """
    photo_b64 = base64.b64encode(photo_bytes).decode()
    payload = {
        "contents": [{
            "parts": [
                {"text": _generic_prompt()},
                {"inline_data": {"mime_type": mime_type, "data": photo_b64}},
            ]
        }],
        "generationConfig": {"temperature": 0.1, "maxOutputTokens": 256},
    }

    with httpx.Client(timeout=30) as client:
        resp = client.post(f"{GEMINI_URL}?key={api_key}", json=payload)
        resp.raise_for_status()

    raw = _strip_fences(resp.json()["candidates"][0]["content"]["parts"][0]["text"])
    result = json.loads(raw)

    return {
        "description": str(result.get("description", "Unknown food")),
        "calories_kcal": max(0.0, float(result.get("calories_kcal", 0))),
        "protein_g": max(0.0, float(result.get("protein_g", 0))),
        "carbs_g": max(0.0, float(result.get("carbs_g", 0))),
        "fat_g": max(0.0, float(result.get("fat_g", 0))),
        "confidence": min(1.0, max(0.0, float(result.get("confidence", 0)))),
    }
