"""Backend container + bench script checks that run without Docker or FastAPI."""
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from tests.conftest import BACKEND


def test_dockerfile_listens_on_port_env():
    text = (BACKEND / "Dockerfile").read_text()
    assert "--port ${PORT}" in text and "CMD exec" in text
    assert "ENV" in text and "PORT=8080" in text


def test_dockerignore_excludes_secrets():
    lines = (BACKEND / ".dockerignore").read_text().splitlines()
    assert ".env" in lines and ".git" in lines


def test_backend_routes_unchanged():
    """The iOS app depends on these paths; the copied backend must still serve them."""
    main = (BACKEND / "app" / "main.py").read_text()
    for route in ['"/health/live"', '"/health/ready"', '"/v1/available-meals"', '"/v1/menu"', '"/menu"',
                  '"/v1/scan-meal"', '"/v1/log-correction"']:
        assert route in main


def test_backend_api_imports_when_deps_installed():
    pytest.importorskip("fastapi")
    pytest.importorskip("sqlalchemy")
    import sys
    sys.path.insert(0, str(BACKEND))
    from app.main import create_app  # noqa: F401


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"ok": True}).encode()
        self.send_response(200 if not self.path.startswith("/v1/menu") else 404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def test_bench_against_local_server():
    import importlib.util
    spec = importlib.util.spec_from_file_location("bench", BACKEND / "scripts" / "bench.py")
    bench = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bench)

    srv = HTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        res = bench.bench(f"http://127.0.0.1:{srv.server_port}", n=10, concurrency=2, warmup=1, day="2026-09-14")
    finally:
        srv.shutdown()
    assert res["health_live"]["ok"] == 10 and res["health_live"]["p95_ms"] >= res["health_live"]["p50_ms"]
    assert res["menu"]["ok"] == 0 and res["menu"]["status_codes"] == {"404": 10}
    assert "| health_live |" in bench.to_markdown("local", "x", res)


def test_percentile_nearest_rank():
    import importlib.util
    spec = importlib.util.spec_from_file_location("bench", BACKEND / "scripts" / "bench.py")
    bench = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bench)
    assert bench.percentile(list(range(1, 101)), 50) == 50
    assert bench.percentile(list(range(1, 101)), 95) == 95
