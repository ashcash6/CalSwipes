import asyncio
import base64
import json

import pytest

from agents import scanner, tools
from agents.scanner import ScanError, StubVision, load_candidates, response_schema, scan_image, validate_matches
from agents.service import make_app
from observability.telemetry import request_scope
from tests.test_service import asgi

JPEG = b"\xff\xd8\xff\xe0fake-jpeg-bytes-for-tests"
DAY = "2026-09-14"


@pytest.fixture(autouse=True)
def stub_vision():
    scanner.set_vision(StubVision())
    yield
    scanner.set_vision(None)


class OffMenuVision:
    """Pretends to be a model that hallucinates an off-menu item and repeats one."""
    model = "gemini-2.5-flash"

    def identify(self, image, mime, candidates):
        first = candidates[0]
        return ([{"menu_item_id": "does-not-exist", "name": "Lobster", "confidence": 0.99},
                 {"menu_item_id": first["menu_item_id"], "name": "WRONG NAME", "confidence": 1.7},
                 {"menu_item_id": first["menu_item_id"], "name": "dup", "confidence": 0.2},
                 "garbage"], 1200, 80)


def test_candidates_come_from_that_meal(store):
    cands = load_candidates(store, "cafe-3", "breakfast", DAY)
    names = {c["name"] for c in cands}
    assert "Scrambled Eggs" in names and len(cands) == 37  # cafe-3 breakfast has 37 items in the fixture
    assert not load_candidates(store, "cafe-3", "late-night", DAY)


def test_schema_restricts_ids_to_candidates():
    s = response_schema(["1", "2"])
    assert s["properties"]["items"]["items"]["properties"]["menu_item_id"]["enum"] == ["1", "2"]


def test_validation_drops_off_menu_and_fixes_names():
    cands = [{"menu_item_id": "556", "name": "Scrambled Eggs", "category": "x"}]
    matches, dropped = validate_matches([{"menu_item_id": "556", "name": "eggz", "confidence": 2},
                                         {"menu_item_id": "999", "name": "Steak", "confidence": 0.9}], cands)
    assert matches == [{"menu_item_id": "556", "name": "Scrambled Eggs", "confidence": 1.0}]
    assert dropped == 1


def test_scan_with_stub_only_returns_menu_items(store):
    out = scan_image(store, JPEG, "image/jpeg", "crossroads", "lunch", DAY)
    ids = {c["menu_item_id"] for c in load_candidates(store, "crossroads", "lunch", DAY)}
    assert 2 <= len(out["matches"]) <= 3 and all(m["menu_item_id"] in ids for m in out["matches"])
    assert out["model"] == "stub-vision" and out["dropped_off_menu"] == 0
    assert scan_image(store, JPEG, "image/jpeg", "crossroads", "lunch", DAY) == out  # deterministic


def test_scan_drops_hallucinations_and_logs_cost(store):
    scanner.set_vision(OffMenuVision())
    with request_scope("t") as m:
        out = scan_image(store, JPEG, "image/jpeg", "cafe-3", "breakfast", DAY)
    assert out["dropped_off_menu"] == 2  # unknown id + non-dict garbage
    assert len(out["matches"]) == 1 and out["matches"][0]["confidence"] == 1.0
    assert out["matches"][0]["name"] != "WRONG NAME"
    s = m.summary()
    assert s["tokens_in"] == 1200 and s["tokens_out"] == 80
    assert s["cost_usd"] == pytest.approx(1200 / 1e6 * 0.30 + 80 / 1e6 * 2.50)


@pytest.mark.parametrize("kwargs,code", [
    (dict(mime_type="image/gif"), "invalid_mime_type"),
    (dict(image=b""), "invalid_image"),
    (dict(image=b"x" * (10 * 1024 * 1024 + 1)), "image_too_large"),
    (dict(meal="late-night"), "menu_unavailable"),
    (dict(hall=""), "missing_field"),
])
def test_scan_errors(store, kwargs, code):
    args = dict(image=JPEG, mime_type="image/jpeg", hall="crossroads", meal="lunch", date=DAY) | kwargs
    with pytest.raises(ScanError) as e:
        scan_image(store, args["image"], args["mime_type"], args["hall"], args["meal"], args["date"])
    assert e.value.code == code


def test_scan_tray_tool_base64_and_ref(store):
    b64 = base64.b64encode(JPEG).decode()
    out = tools.scan_tray("crossroads", "lunch", DAY, image_base64=b64)
    assert out["matches"]
    ref = scanner.register_image(JPEG, "image/jpeg")
    assert tools.scan_tray("crossroads", "lunch", DAY, image_ref=ref) == out
    assert tools.scan_tray("crossroads", "lunch", DAY, image_ref="nope")["code"] == "unknown_image_ref"
    assert tools.scan_tray("crossroads", "lunch", DAY, image_base64="%%%")["code"] == "invalid_image"
    assert tools.scan_tray in tools.MENU_TOOLS  # available to the ADK menu_agent


def test_mcp_scan_tray(store):
    from mcp_server.server import server
    res = asyncio.run(server.call_tool("scan_tray", {"image_base64": base64.b64encode(JPEG).decode(),
                                                     "hall": "crossroads", "meal": "lunch", "date": DAY}))
    assert not res.is_error and json.loads(res.content[0].text)["matches"]


def _multipart(fields: dict, file_bytes: bytes, content_type="image/jpeg"):
    b = "testboundary123"
    parts = [f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n' for k, v in fields.items()]
    body = "".join(parts).encode()
    body += (f'--{b}\r\nContent-Disposition: form-data; name="image"; filename="tray.jpg"\r\n'
             f"Content-Type: {content_type}\r\n\r\n").encode() + file_bytes + f"\r\n--{b}--\r\n".encode()
    return body, f"multipart/form-data; boundary={b}"


def test_scan_endpoint(store):
    body, ctype = _multipart({"hall": "crossroads", "meal": "lunch", "date": DAY}, JPEG)
    status, out = asgi(make_app(), "POST", "/v1/scan", body, content_type=ctype)
    assert status == 200
    assert out["matches"] and out["metrics"]["llm_calls"] == 1 and out["metrics"]["tokens_in"] > 0


def test_scan_endpoint_errors(store):
    app = make_app()
    body, ctype = _multipart({"hall": "crossroads", "meal": "lunch", "date": DAY}, JPEG, "image/gif")
    assert asgi(app, "POST", "/v1/scan", body, content_type=ctype)[0] == 415
    body, ctype = _multipart({"hall": "crossroads", "meal": "late-night", "date": DAY}, JPEG)
    status, out = asgi(app, "POST", "/v1/scan", body, content_type=ctype)
    assert status == 404 and out["error"]["code"] == "menu_unavailable"
    assert asgi(app, "POST", "/v1/scan", b"{}", content_type="application/json")[0] == 400


def test_scan_scoring_math():
    from evals.scan.score_scan import score
    s = score([{"predicted": ["a", "b"], "confirmed": ["a", "c"]}, {"predicted": ["x"], "confirmed": ["x"]}])
    assert s["precision"] == pytest.approx(2 / 3) and s["recall"] == pytest.approx(2 / 3)
    assert s["exact_match"] == 0.5
