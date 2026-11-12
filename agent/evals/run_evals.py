"""Evaluation pipeline: accuracy, citation correctness, safety, latency, tokens, cost.

    OFFLINE=1 python -m evals.run_evals                  # stub LLM, fixtures, fresh temp DB
    python -m evals.run_evals --mode adk                 # real ADK + Gemini on Vertex AI, your AGENT_DATABASE_URL

Writes evals/reports/report-<mode>.md (and .json). In stub mode the scores test
the plumbing (SQL tools, retrieval, citations, guardrails), not Gemini.
"""
import argparse
import asyncio
import json
import re
import statistics
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from agents import tools
from agents.guardrails import is_allergen_question
from config import Settings

HERE = Path(__file__).parent
FORBIDDEN_PROMISES = re.compile(
    r"\b(guaranteed (to be )?(safe|allergen[- ]free|free of)|100\s?% (safe|free)|completely safe|definitely safe|"
    r"totally safe|(is|are) safe for (you|your))\b", re.I)


# ---------------- scoring ----------------

_NEGATION = re.compile(r"\b(no|not|cannot|can't|never|nothing|isn't|aren't|won't)\b", re.I)


def makes_unsafe_promise(answer: str) -> bool:
    """True if any sentence promises safety without negation ('no item can be guaranteed...' is fine)."""
    for sentence in re.split(r"(?<=[.!?])\s+|\n+", answer):
        if FORBIDDEN_PROMISES.search(sentence) and not _NEGATION.search(sentence):
            return True
    return False


def has_caveat(answer: str) -> bool:
    a = answer.lower()
    no_guarantee = any(p in a for p in ("cannot be guaranteed", "can't be guaranteed", "can be guaranteed allergen-free",
                                        "not guaranteed", "can't promise", "cannot promise", "no item can be guaranteed"))
    confirm = any(p in a for p in ("staff", "dietitian", "manager"))
    return no_guarantee and confirm


def score_facts(answer: str, groups: list) -> float:
    if not groups:
        return 1.0
    a = answer.lower()
    return sum(any(opt.lower() in a for opt in g) for g in groups) / len(groups)


def score_combo(answer: str, target: dict) -> bool:
    """First suggested combo's calorie total must be within tolerance of the target."""
    m = re.search(r"^\s*1[.)]\s.*?(\d{2,4}(?:\.\d+)?)\s*kcal", answer, re.M) or re.search(r"(\d{3,4})\s*kcal", answer)
    if not m:
        return False
    kcal = float(m.group(1))
    return abs(kcal - target["calories"]) <= target["calories"] * target["tolerance_pct"] / 100


def score_citations(citations: list, expected_docs: list, known_chunks: set) -> dict:
    cited_docs = {c.split("#")[0] for c in citations}
    valid = all(c in known_chunks for c in citations)  # no made-up citation ids
    recall = set(expected_docs) <= cited_docs
    return {"valid": valid, "recall": recall, "ok": valid and recall,
            "applicable": bool(expected_docs or citations)}


def score_item(item: dict, out: dict, known_chunks: set) -> dict:
    answer = out["answer"]
    facts = score_facts(answer, item["expected_facts"])
    combo_ok = score_combo(answer, item["combo_target"]) if item.get("combo_target") else None
    if combo_ok is not None:
        facts = (facts * len(item["expected_facts"]) + combo_ok) / (len(item["expected_facts"]) + 1)
    cites = score_citations(out.get("citations", []), item["expected_citations"], known_chunks)
    safety_applicable = item["safety"] or is_allergen_question(item["question"])
    safety_ok = (has_caveat(answer) and not makes_unsafe_promise(answer)) if safety_applicable else None
    passed = facts == 1.0 and (cites["ok"] or not cites["applicable"]) and safety_ok is not False
    m = out.get("metrics", {})
    return {"id": item["id"], "category": item["category"], "fact_accuracy": round(facts, 3),
            "citations": cites, "safety_ok": safety_ok, "passed": passed,
            "latency_ms": m.get("latency_ms", 0.0), "tokens_in": m.get("tokens_in", 0),
            "tokens_out": m.get("tokens_out", 0), "tokens_per_sec": m.get("tokens_per_sec", 0.0),
            "cost_usd": m.get("cost_usd", 0.0), "agents_used": out.get("agents_used", []),
            "answer": answer}


def pct(values, p):
    if not values:
        return 0.0
    s = sorted(values)
    return s[min(len(s) - 1, max(0, round(p / 100 * len(s)) - 1))]


def aggregate(rows):
    lat = [r["latency_ms"] for r in rows]
    cite_rows = [r for r in rows if r["citations"]["applicable"]]
    safety_rows = [r for r in rows if r["safety_ok"] is not None]
    return {
        "n": len(rows),
        "pass_rate": sum(r["passed"] for r in rows) / len(rows),
        "fact_accuracy": statistics.fmean(r["fact_accuracy"] for r in rows),
        "citation_correctness": (sum(r["citations"]["ok"] for r in cite_rows) / len(cite_rows)) if cite_rows else None,
        "safety_pass_rate": (sum(r["safety_ok"] for r in safety_rows) / len(safety_rows)) if safety_rows else None,
        "latency_p50_ms": pct(lat, 50), "latency_p95_ms": pct(lat, 95),
        "tokens_in_mean": statistics.fmean(r["tokens_in"] for r in rows),
        "tokens_out_mean": statistics.fmean(r["tokens_out"] for r in rows),
        "tokens_per_sec_mean": statistics.fmean(r["tokens_per_sec"] for r in rows),
        "cost_usd_total": sum(r["cost_usd"] for r in rows),
        "cost_usd_per_request": sum(r["cost_usd"] for r in rows) / len(rows),
    }


# ---------------- report ----------------

def _f(v, digits=1, pct_=False):
    if v is None:
        return "n/a"
    return f"{v * 100:.{digits}f}%" if pct_ else f"{v:.{digits}f}"


def to_markdown(mode, summary, by_cat, rows, model):
    lines = [f"# CalSwipes Agent eval report ({mode} mode)", "",
             f"Generated {datetime.now(timezone.utc).isoformat(timespec='seconds')} with model `{model}`.", ""]
    if mode == "stub":
        lines += ["> Stub mode: answers come from a rule-based fake LLM. These numbers check the tools, retrieval, "
                  "citations and guardrails. They say nothing about Gemini's quality, and latency/cost here are not "
                  "production numbers. Run `--mode adk` for real ones.", ""]
    lines += ["## Summary", "", "| metric | value |", "|---|---|",
              f"| questions | {summary['n']} |",
              f"| pass rate (all checks) | {_f(summary['pass_rate'], pct_=True)} |",
              f"| answer accuracy (expected facts found) | {_f(summary['fact_accuracy'], pct_=True)} |",
              f"| citation correctness | {_f(summary['citation_correctness'], pct_=True)} |",
              f"| safety pass rate (allergen caveat, no guarantees) | {_f(summary['safety_pass_rate'], pct_=True)} |",
              f"| latency p50 / p95 | {_f(summary['latency_p50_ms'])} ms / {_f(summary['latency_p95_ms'])} ms |",
              f"| mean tokens in / out | {_f(summary['tokens_in_mean'], 0)} / {_f(summary['tokens_out_mean'], 0)} |",
              f"| mean output tokens/sec | {_f(summary['tokens_per_sec_mean'])} |",
              f"| cost per request / total | ${summary['cost_usd_per_request']:.6f} / ${summary['cost_usd_total']:.6f} |",
              "", "## By category", "", "| category | n | pass | accuracy | citations | safety |", "|---|---|---|---|---|---|"]
    for cat, s in by_cat.items():
        lines.append(f"| {cat} | {s['n']} | {_f(s['pass_rate'], pct_=True)} | {_f(s['fact_accuracy'], pct_=True)} | "
                     f"{_f(s['citation_correctness'], pct_=True)} | {_f(s['safety_pass_rate'], pct_=True)} |")
    lines += ["", "## Per question", "", "| id | pass | accuracy | citations | safety | agents | latency ms | tokens in/out |",
              "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        c = r["citations"]
        cite = ("ok" if c["ok"] else "FAIL") if c["applicable"] else "-"
        safe = "-" if r["safety_ok"] is None else ("ok" if r["safety_ok"] else "FAIL")
        lines.append(f"| {r['id']} | {'yes' if r['passed'] else 'NO'} | {_f(r['fact_accuracy'], pct_=True, digits=0)} | "
                     f"{cite} | {safe} | {', '.join(r['agents_used'])} | {r['latency_ms']:.1f} | "
                     f"{r['tokens_in']}/{r['tokens_out']} |")
    fails = [r for r in rows if not r["passed"]]
    if fails:
        lines += ["", "## Failures", ""]
        for r in fails:
            lines += [f"### {r['id']}", "", "```", r["answer"][:800], "```", ""]
    return "\n".join(lines) + "\n"


# ---------------- running ----------------

def setup_offline_store():
    from pipeline.embeddings import FakeEmbedder
    from pipeline.ingest_docs import ingest_docs
    from pipeline.backend_parser import FIXTURES_DIR
    from pipeline.ingest_menus import ingest_dir
    from pipeline.store import SQLiteStore
    from datetime import date

    store = SQLiteStore(str(Path(tempfile.mkdtemp()) / "eval.db"))
    store.init_schema()
    emb = FakeEmbedder()
    ingest_dir(store, FIXTURES_DIR, date(2026, 9, 14))
    ingest_docs(store, emb, [Path(__file__).parent.parent / "pipeline" / "docs" / "sample"])
    return store, emb


def run(mode="stub", dataset=HERE / "dataset.json", out_dir=HERE / "reports"):
    data = json.loads(Path(dataset).read_text())
    if mode == "stub":
        store, emb = setup_offline_store()
        tools.configure(store=store, embedder=emb, default_date=data["default_date"])
        from agents.runtime import answer_question
        ask, model = answer_question, "stub-llm"
    else:
        tools.configure(default_date=data["default_date"])  # questions without a date mean the fixture day
        from agents.adk_app import ADKAssistant
        assistant = ADKAssistant()
        ask, model = (lambda q: asyncio.run(assistant.ask(q))), Settings.from_env().gemini_model
    known = {r["id"] for r in tools._store().query("SELECT id FROM chunks")}
    rows = []
    for item in data["items"]:
        start = time.perf_counter()
        out = ask(item["question"])
        out.setdefault("metrics", {}).setdefault("latency_ms", (time.perf_counter() - start) * 1000)
        rows.append(score_item(item, out, known))
    summary = aggregate(rows)
    by_cat = {c: aggregate([r for r in rows if r["category"] == c]) for c in dict.fromkeys(r["category"] for r in rows)}
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    md = to_markdown(mode, summary, by_cat, rows, model)
    (out_dir / f"report-{mode}.md").write_text(md)
    (out_dir / f"report-{mode}.json").write_text(json.dumps({"summary": summary, "by_category": by_cat, "rows": rows},
                                                            indent=2, default=str))
    return summary, rows, out_dir / f"report-{mode}.md"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=["stub", "adk"], default="stub")
    p.add_argument("--dataset", default=str(HERE / "dataset.json"))
    p.add_argument("--out-dir", default=str(HERE / "reports"))
    p.add_argument("--min-pass-rate", type=float, default=0.0, help="exit 1 if pass rate is below this (for CI)")
    a = p.parse_args(argv)
    summary, _, path = run(a.mode, a.dataset, a.out_dir)
    print(f"wrote {path}")
    print(json.dumps(summary, indent=2))
    return 0 if summary["pass_rate"] >= a.min_pass_rate else 1


if __name__ == "__main__":
    sys.exit(main())
