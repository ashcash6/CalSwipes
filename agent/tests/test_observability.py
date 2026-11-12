import json
import logging

import pytest

from observability import telemetry as t


def test_cost_from_pricing_table():
    # gemini-2.5-flash in config/pricing.json: $0.30 / 1M in, $2.50 / 1M out
    assert t.cost_usd("gemini-2.5-flash", 1_000_000, 0) == pytest.approx(0.30)
    assert t.cost_usd("gemini-2.5-flash", 1000, 2000) == pytest.approx(0.0003 + 0.005)
    assert t.cost_usd("unknown-model", 10, 10) == 0.0


def test_request_scope_aggregates():
    with t.request_scope("unit") as m:
        t.record_llm_call("a", "gemini-2.5-flash", 1000, 500, 250.0)
        t.record_llm_call("b", "gemini-2.5-flash", 2000, 500, 250.0)
        t.record_tool_call("a", "search_menu", 5.0, True)
    s = m.summary()
    assert s["tokens_in"] == 3000 and s["tokens_out"] == 1000
    assert s["tokens_per_sec"] == pytest.approx(1000 / 0.5)
    assert s["cost_usd"] == pytest.approx(3000 / 1e6 * 0.30 + 1000 / 1e6 * 2.50)
    assert s["llm_calls"] == 2 and s["tool_calls"] == 1 and s["agents"] == ["a", "b"]


def test_calls_outside_request_dont_crash():
    assert t.record_llm_call("x", "stub-llm", 1, 1, 1.0).cost_usd == 0.0


def test_json_formatter_emits_severity():
    rec = logging.LogRecord("calswipes", logging.INFO, __file__, 1, json.dumps({"event": "e", "k": 1}), None, None)
    out = json.loads(t.JsonFormatter().format(rec))
    assert out == {"event": "e", "k": 1, "severity": "INFO", "logger": "calswipes"}


def test_span_works_without_sdk():
    with t.span("x", a=1) as s:
        s.set_attribute("b", 2)


def test_setup_tracing_none_is_noop():
    assert t.setup_tracing("none") is False
