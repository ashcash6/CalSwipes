"""Only runs where google-adk is installed (pip install -r requirements.txt). No network needed."""
import pytest

pytest.importorskip("google.adk")


def test_adk_tree_matches_spec():
    from agents import spec
    from agents.adk_app import build_adk_agent

    root = build_adk_agent()
    assert root.name == spec.ROOT["name"]
    assert {a.name for a in root.sub_agents} == {"menu_agent", "policy_agent", "nutrition_agent"}
