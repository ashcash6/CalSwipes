"""The agent tree, defined once and used by both runtimes.

    root_planner  (decides who should answer; combines their answers)
      |- menu_agent       what is served, item nutrition, meal hours  (SQL over structured tables)
      |- policy_agent     hours/allergen/dietary/app policies           (RAG over embedded docs)
      |- nutrition_agent  meal combos that hit calorie/protein goals    (combo math)

agents/adk_app.py builds these as Google ADK agents (Gemini on Vertex AI).
agents/runtime.py builds them with a local ReAct loop + StubLLM for offline tests.
"""
from agents import tools
from agents.guardrails import ALLERGEN_CAVEAT

COMMON = (
    "Only state facts that come from your tool results. If the tools return nothing, say you don't know. "
    "Never invent menu items, numbers, or hours. Dates are YYYY-MM-DD."
)

MENU = dict(
    name="menu_agent",
    description="Answers what food is served at Berkeley dining halls, item nutrition facts, and meal times.",
    instruction=(
        "You answer questions about Berkeley Dining menus. Use search_menu to list items (filters for hall, "
        "meal, date, allergens, dietary tags), get_nutrition for one item's macros and allergens, "
        "get_meal_hours for meal start/end times, scan_tray when the user provides a tray photo (image_ref), and run_menu_sql only when the others can't express the "
        "question. Think step by step: decide the tool, call it, read the result, then answer. "
        "Report macros per serving with units. " + COMMON + "\n" + tools.SCHEMA_DOC
    ),
    tools=tools.MENU_TOOLS,
)

POLICY = dict(
    name="policy_agent",
    description="Answers questions about dining policies: allergens and cross-contact, dietary labels, "
                "nutrition data rules, locations, and how the CalSwipes app updates menus.",
    instruction=(
        "You answer policy and general-information questions using search_dining_info. Every sentence that "
        "uses a passage must end with that passage's citation tag exactly as given, e.g. [allergen-policy#1]. "
        "If a passage is marked is_sample=true, say the source is sample text. " + COMMON
    ),
    tools=tools.POLICY_TOOLS,
)

NUTRITION = dict(
    name="nutrition_agent",
    description="Builds meal combinations from a hall's menu that hit calorie and protein targets.",
    instruction=(
        "You plan meals. Extract the hall, meal, calorie target, protein target, allergens to avoid and "
        "dietary tag from the request, then call plan_meal. Present up to 3 combos with item names, "
        "servings and totals. Do the arithmetic from tool output only. " + COMMON
    ),
    tools=tools.NUTRITION_TOOLS,
)

ROOT = dict(
    name="root_planner",
    description="CalSwipes dining assistant that routes questions to specialist agents.",
    instruction=(
        "You are the CalSwipes dining assistant for UC Berkeley students. Plan first: break the question "
        "into parts and delegate each part to the right specialist: menu_agent (what's served, item "
        "nutrition, hours, tray photo scans), policy_agent (allergen/cross-contact policy, dietary labels, app FAQ; returns "
        "citations), nutrition_agent (meal combos for calorie/protein goals). You may call several. Combine "
        "their answers into one short reply and keep their citation tags. The reply shows on a phone: at most 5 items, "
        "best first, one per line as '- Item: 520 kcal, 32g protein', no headers, no bold, no duplicate items, skip toppings "
        "and condiments unless asked, leave out desserts, breads and drinks unless asked, then one short line offering more. If the question involves food "
        f"allergies, always include this caveat: \"{ALLERGEN_CAVEAT}\" Never say an item is guaranteed safe. "
        + COMMON
    ),
    sub_agents=[MENU, POLICY, NUTRITION],
)


# Fast lane: simple "what's being served" questions skip the planner and go straight to a
# menu agent that also knows the phone answer format. One agent instead of planner -> specialist
# -> planner cuts most of the model round trips.
PHONE_FORMAT = (
    "The reply shows on a phone: at most 5 items, best first, one per line as "
    "'- Item: 520 kcal, 32g protein', no headers, no bold, no duplicate items, skip toppings and "
    "condiments unless asked, then one short line offering more. Lead with real dishes (entrees, mains, "
    "protein); leave out desserts, breads and drinks unless the user asks for them."
)

MENU_FAST = dict(
    name="menu_fast",
    description="Answers simple menu questions directly.",
    instruction=MENU["instruction"] + "\n" + PHONE_FORMAT,
    tools=MENU["tools"],
)

import re as _re

# Whole-word patterns (so "cross-contact" is slow but "Crossroads" isn't).
_SLOW = _re.compile(
    r"\b(allerg\w*|gluten|celiac|cross[- ]contact\w*|contaminat\w*|safe|peanuts?|tree nuts?|nuts?|shellfish|"
    r"policy|polic\w+|swipes?|meal plans?|flex|refunds?|how do i|app|"
    r"plan|planning|combos?|combin\w*|goals?|budget|whole day|build|under \d+)\b"
)
_MENU = _re.compile(
    r"\b(menu|serving|served|options?|what'?s|what is|what are|anything|vegan|vegetarian|protein|"
    r"dessert|breakfast|brunch|lunch|dinner|crossroads|cafe 3|foothill|clark kerr|calories|macros|best|"
    r"dishes|food)\b"
)


def is_fast_lane(question: str) -> bool:
    """Conservative: only plain menu lookups. Anything about allergies, policy or planning goes
    through the full planner."""
    q = question.lower()
    if _SLOW.search(q):
        return False
    return bool(_MENU.search(q))
