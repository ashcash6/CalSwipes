"""Safety rules applied to every final answer, regardless of what the LLM wrote.

The LLM is asked to follow these in its instructions, but prompts are not a
guarantee. So the final answer also passes through this deterministic check:
if the question is about allergies, the caveat is added, and any sentence that
promises an item is "guaranteed"/"100%" safe is replaced.
"""
import re

ALLERGEN_CAVEAT = (
    "Allergen caveat: allergen flags come from Berkeley Dining's menu data and describe recipes, not your plate. "
    "Shared kitchens mean cross-contact is possible, so no item can be guaranteed allergen-free. "
    "If you have a serious allergy, confirm with dining hall staff before eating."
)

_ALLERGY_WORDS = re.compile(
    r"\b(allerg\w*|anaphyla\w*|epipen|celiac|intoleran\w*|cross[- ]contact|nut[- ]free|peanut\w*|tree nuts?|"
    r"gluten|dairy[- ]free|lactose|shellfish|sesame|soy|egg[- ]free|safe (for|to eat))\b", re.I)
_UNSAFE_PROMISE = re.compile(
    r"[^.!?\n]*\b(guarantee[ds]?|100\s?%|completely safe|totally safe|definitely safe|"
    r"(is|are) (?:\w+ ){0,2}(safe|free of)\b(?! to assume))[^.!?\n]*[.!?]?", re.I)


def is_allergen_question(text: str) -> bool:
    return bool(_ALLERGY_WORDS.search(text or ""))


def apply_guardrails(question: str, answer: str) -> tuple[str, list[str]]:
    """Returns (safe_answer, list_of_actions_taken)."""
    actions = []
    if is_allergen_question(question):
        def _swap(m):
            s = m.group(0)
            if re.search(r"\b(no|not|cannot|can't|never|nothing|isn't|aren't)\b", s, re.I):
                return s  # negated ("no item can be guaranteed ...") is the correct caveat, keep it
            actions.append("removed_safety_promise")
            return "I can't promise any item is safe for an allergy."
        answer = _UNSAFE_PROMISE.sub(_swap, answer)
        if ALLERGEN_CAVEAT not in answer:
            answer = answer.rstrip() + "\n\n" + ALLERGEN_CAVEAT
            actions.append("added_allergen_caveat")
    return answer, actions
