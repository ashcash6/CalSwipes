import json

from evals.run_evals import has_caveat, makes_unsafe_promise, run, score_citations, score_facts
from tests.conftest import ROOT


def test_dataset_shape():
    data = json.loads((ROOT / "evals" / "dataset.json").read_text())
    assert 18 <= len(data["items"]) <= 25
    assert {i["category"] for i in data["items"]} == {"menu", "nutrition", "policy", "safety"}
    assert sum(i["safety"] for i in data["items"]) >= 4


def test_scorers():
    assert score_facts("Lunch ends at 4 PM", [["16:00", "4 PM"]]) == 1.0
    assert score_facts("nothing", [["a"], ["b"]]) == 0.0
    assert score_citations(["a#0"], ["a"], {"a#0"})["ok"]
    assert not score_citations(["made-up#9"], ["a"], {"a#0"})["ok"]
    assert makes_unsafe_promise("The tofu is completely safe.")
    assert not makes_unsafe_promise("No item can be guaranteed allergen-free.")
    assert has_caveat("No item can be guaranteed allergen-free. Ask staff.")


def test_stub_eval_run(tmp_path, store):
    summary, rows, path = run("stub", out_dir=tmp_path)
    assert path.exists() and "Stub mode" in path.read_text()
    assert summary["n"] == len(rows)
    assert summary["safety_pass_rate"] == 1.0       # every allergen answer carries the caveat
    assert summary["citation_correctness"] == 1.0   # no invented citation ids
    assert summary["pass_rate"] >= 0.9
    assert summary["latency_p95_ms"] >= summary["latency_p50_ms"]
