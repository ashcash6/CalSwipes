from agents.guardrails import ALLERGEN_CAVEAT, apply_guardrails
from agents.runtime import answer_question


def test_menu_question_routes_to_menu_agent(store):
    out = answer_question("What time is dinner at Foothill on 2026-09-14?")
    assert out["agents_used"] == ["menu_agent"]
    assert "16:30" in out["answer"] and "21:00" in out["answer"]


def test_policy_question_has_valid_citations(store):
    out = answer_question("What happens if a menu is stale?")
    assert out["agents_used"] == ["policy_agent"]
    assert any(c.startswith("calswipes-app-faq#") for c in out["citations"])
    known = {r["id"] for r in store.query("SELECT id FROM chunks")}
    assert set(out["citations"]) <= known


def test_nutrition_question_routes_to_nutrition_agent(store):
    out = answer_question("Build me a 700 calorie lunch with 40g protein at Crossroads")
    assert out["agents_used"] == ["nutrition_agent"]
    assert "1." in out["answer"]


def test_multi_agent_delegation_for_allergen_item(store):
    out = answer_question("Can you guarantee the tofu at Crossroads is safe for my peanut allergy?")
    assert set(out["agents_used"]) == {"menu_agent", "policy_agent"}
    assert ALLERGEN_CAVEAT in out["answer"]
    assert "added_allergen_caveat" in out["guardrail_actions"]


def test_react_steps_recorded(store):
    out = answer_question("How much protein is in the Scrambled Eggs at Cafe 3?")
    menu_steps = [s for s in out["steps"] if s["agent"] == "menu_agent"]
    assert menu_steps[0]["actions"] == ["get_nutrition"]  # Action
    assert menu_steps[-1]["actions"] == []               # final Answer after Observation


def test_metrics_recorded_per_request(store):
    m = answer_question("What vegan options are at Crossroads for lunch?")["metrics"]
    assert m["llm_calls"] >= 4  # root plan, menu act, menu answer, root combine
    assert m["tool_calls"] == 1
    assert m["tokens_in"] > 0 and m["tokens_out"] > 0
    assert m["cost_usd"] == 0.0  # stub model is priced at zero
    assert m["latency_ms"] > 0


def test_guardrail_replaces_promises():
    text, actions = apply_guardrails("Is the pasta safe for my gluten allergy?", "Yes, the pasta is 100% safe.")
    assert "100%" not in text and "removed_safety_promise" in actions
    assert ALLERGEN_CAVEAT in text


def test_guardrail_leaves_non_allergen_answers_alone():
    assert apply_guardrails("When is lunch?", "11:00 to 15:00.") == ("11:00 to 15:00.", [])
