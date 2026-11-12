"""Proxy endpoint tests with a fake agent. Need FastAPI + httpx (backend requirements.lock)."""
import pytest

pytest.importorskip("fastapi")
pytest.importorskip("httpx")
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.assistant_limits import AssistantConfig, AssistantGate, MemoryUsageStore  # noqa: E402
from app.routers.assistant import make_router  # noqa: E402

H = {"X-CalSwipes-Device": "device-aaaaaaaaaaaaaaaa"}


class FakeAgent:
    def __init__(self):
        self.asks = 0

    def ask(self, payload):
        self.asks += 1
        return {"answer": f"answer to {payload['question']}", "citations": [], "agents_used": ["menu_agent"],
                "metrics": {"cost_usd": 0.01}}

    def scan(self, image, mime, fields):
        return 200, {"matches": [{"menu_item_id": "1", "name": "Tofu", "confidence": 0.9}],
                     "metrics": {"cost_usd": 0.002}}


def client(**cfg):
    agent = FakeAgent()
    app = FastAPI()
    app.include_router(make_router(AssistantGate(AssistantConfig(agent_url="x", **cfg), MemoryUsageStore()), agent))
    return TestClient(app), agent


def test_ask_cache_and_caps():
    c, agent = client()
    body = {"question": "What's for lunch?", "hall": "crossroads", "meal": "lunch", "date": "2026-11-20"}
    r = c.post("/assistant/ask", json=body, headers=H)
    assert r.status_code == 200 and r.json()["quota"]["remaining"] == 2 and not r.json()["cached"]
    r = c.post("/assistant/ask", json={**body, "question": "whats for LUNCH"}, headers=H)
    assert r.json()["cached"] and agent.asks == 1
    for q in ("a", "b"):
        assert c.post("/assistant/ask", json={**body, "question": q}, headers=H).status_code == 200
    assert c.post("/assistant/ask", json={**body, "question": "c"}, headers=H).status_code == 429


def test_requires_device_header():
    c, _ = client()
    assert c.post("/assistant/ask", json={"question": "hi"}).status_code == 401


def test_scan_proxy():
    c, _ = client()
    files = {"image": ("t.jpg", b"\xff\xd8xx", "image/jpeg")}
    r = c.post("/assistant/scan", data={"hall": "crossroads", "meal": "lunch"}, files=files, headers=H)
    assert r.status_code == 200 and "metrics" not in r.json() and r.json()["quota"]["remaining"] == 0
    assert c.post("/assistant/scan", data={"hall": "crossroads", "meal": "lunch"}, files=files,
                  headers=H).status_code == 429
