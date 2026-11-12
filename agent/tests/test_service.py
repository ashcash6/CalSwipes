"""Call the Starlette app over raw ASGI (no httpx needed)."""
import asyncio
import json

from agents.service import make_app


def asgi(app, method, path, body=b"", content_type="application/json"):
    sent, msgs = [], [{"type": "http.request", "body": body, "more_body": False}]

    async def receive():
        return msgs.pop(0) if msgs else {"type": "http.disconnect"}

    async def send(m):
        sent.append(m)

    scope = {"type": "http", "method": method, "path": path, "headers": [(b"content-type", content_type.encode()), (b"content-length", str(len(body)).encode())],
             "query_string": b"", "http_version": "1.1", "scheme": "http", "server": ("t", 80), "client": ("c", 1),
             "root_path": ""}
    asyncio.run(app(scope, receive, send))
    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    data = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    return status, json.loads(data)


def test_health():
    assert asgi(make_app(), "GET", "/health") == (200, {"status": "ok", "runtime": "local"})


def test_ask(store):
    status, out = asgi(make_app(), "POST", "/v1/ask", json.dumps({"question": "What time is lunch at Cafe 3?"}).encode())
    assert status == 200
    assert "11:00" in out["answer"] and "metrics" in out and "steps" not in out


def test_ask_validation():
    app = make_app()
    assert asgi(app, "POST", "/v1/ask", b"{}")[0] == 400
    assert asgi(app, "POST", "/v1/ask", json.dumps({"question": "x" * 2000}).encode())[0] == 413


def test_ask_with_context(store):
    status, out = asgi(make_app(), "POST", "/v1/ask",
                       json.dumps({"question": "What time is dinner?", "hall": "foothill", "date": "2026-09-14"}).encode())
    assert status == 200 and "16:30" in out["answer"]
