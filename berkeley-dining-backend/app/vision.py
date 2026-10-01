"""Gemini vision module: classify dining-hall food items from a photo."""
import base64
import json
import httpx

GEMINI_URL = "https://generativelanguage.googleapis.com/v1/models/gemini-3.6-flash:generateContent"

# Matches with confidence < MIN_THRESHOLD are dropped entirely.
# ≥ AUTO_THRESHOLD → auto-accept on the client.
# ≥ CONFIRM_THRESHOLD → present to user for confirmation.
# < CONFIRM_THRESHOLD (but ≥ MIN_THRESHOLD) → ask user to pick.
AUTO_THRESHOLD = 0.90
CONFIRM_THRESHOLD = 0.70
MIN_THRESHOLD = 0.50


def _confidence_tier(confidence: float) -> str:
    if confidence >= AUTO_THRESHOLD:
        return "auto"
    if confidence >= CONFIRM_THRESHOLD:
        return "confirm"
    return "ask"


def _prompt(menu_items: list[dict]) -> str:
    lines = "\n".join(f"- id={item['id']}: {item['name']}" for item in menu_items)
    return f"""You are a food classifier for Berkeley university dining halls.
Your ONLY job: identify which item(s) from the provided menu list appear in this photo.
Do NOT estimate portion sizes. Do NOT estimate nutrition. Classify only.

Available menu items:
{lines}

For each distinct food component visible in the photo, output one entry with:
  • item_id   — the id from the menu above
  • item_name — the exact name from the menu above
  • confidence — your confidence 0.0–1.0 that this is the correct classification
  • alternatives — up to 2 other menu items that could also be correct,
                   each with item_id, item_name, and confidence

Reply ONLY with this JSON — no markdown fences, no prose:
{{
  "matches": [
    {{
      "item_id": "<id>",
      "item_name": "<name>",
      "confidence": <0.0–1.0>,
      "alternatives": [
        {{"item_id": "<id>", "item_name": "<name>", "confidence": <0.0–1.0>}}
      ]
    }}
  ],
  "no_match_reason": null
}}

If you cannot identify food with confidence ≥ {MIN_THRESHOLD}, set "matches" to [] and
explain in "no_match_reason" why (not on menu, photo unclear, etc.)."""


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
    """Call Gemini to classify food in a photo against known menu items.

    Returns a dict with keys:
      matches         – list of {item_id, item_name, confidence, confidence_tier, alternatives}
                        filtered to confidence ≥ MIN_THRESHOLD and validated against menu IDs
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
        "generationConfig": {"temperature": 0.1, "maxOutputTokens": 768},
    }

    with httpx.Client(timeout=30) as client:
        resp = client.post(f"{GEMINI_URL}?key={api_key}", json=payload)
        resp.raise_for_status()

    raw = _strip_fences(resp.json()["candidates"][0]["content"]["parts"][0]["text"])
    result = json.loads(raw)

    valid_ids = {item["id"] for item in menu_items}
    processed = []
    for m in result.get("matches", []):
        conf = float(m.get("confidence", 0))
        if conf < MIN_THRESHOLD:
            continue
        item_id = m.get("item_id", "")
        if item_id not in valid_ids:
            continue
        alternatives = []
        for alt in m.get("alternatives", [])[:2]:
            alt_id = alt.get("item_id", "")
            alt_conf = float(alt.get("confidence", 0))
            if alt_id in valid_ids and alt_id != item_id and alt_conf > 0:
                alternatives.append({
                    "item_id": alt_id,
                    "item_name": alt.get("item_name", ""),
                    "confidence": round(alt_conf, 3),
                })
        processed.append({
            "item_id": item_id,
            "item_name": m.get("item_name", ""),
            "confidence": round(conf, 3),
            "confidence_tier": _confidence_tier(conf),
            "alternatives": alternatives,
        })

    no_match = result.get("no_match_reason")
    if not processed and not no_match:
        no_match = "No menu items identified with sufficient confidence"

    return {"matches": processed, "no_match_reason": no_match}
