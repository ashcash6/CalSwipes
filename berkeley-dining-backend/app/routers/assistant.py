"""Public assistant proxy: the iOS app calls these; they forward to the PRIVATE agent service.

    POST /assistant/ask   JSON {question, hall?, meal?, date?}
    POST /assistant/scan  multipart: image, hall, meal, date?

Who is the user? The backend's Sign in with Apple routes (app/auth.py) aren't wired into
app/main.py yet, so for now the user is identified by an app-generated device id in the
`X-CalSwipes-Device` header (a UUID kept in the iOS Keychain).
TODO(Ash): replace with App Attest (DeviceCheck) assertions or the existing Apple auth sessions;
a device id alone can be rotated by a determined client. The per-IP cap and the global spend cap
bound the damage until then.

Premium: the app sends `X-CalSwipes-Entitlement: premium` plus (optionally) the StoreKit 2
signed transaction in `X-CalSwipes-Transaction`. The claim is ignored unless
TRUST_CLIENT_ENTITLEMENT=1. TODO(Ash): verify the JWS server-side (App Store Server API /
app-store-server-library) and pass premium_verified=True.

Service-to-service auth: the agent runs with --no-allow-unauthenticated; this service fetches a
Google-signed ID token for audience=ASSISTANT_AGENT_URL from the Cloud Run metadata server.
"""
import logging
import re
import time
from datetime import datetime, timezone

import httpx
from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.assistant_limits import ASK, SCAN, AssistantConfig, AssistantGate, SqlUsageStore, berkeley_today

log = logging.getLogger("berkeley.assistant")
METADATA_TOKEN_URL = ("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/"
                      "identity?audience={audience}")
_DEVICE_RE = re.compile(r"^[A-Za-z0-9-]{16,64}$")
MAX_IMAGE_BYTES = 10 * 1024 * 1024


class AskBody(BaseModel):
    question: str = Field(min_length=1, max_length=1000)
    hall: str = Field(default="", max_length=32)
    meal: str = Field(default="", max_length=32)
    date: str = Field(default="", max_length=10)


class AgentForwarder:
    """Calls the private agent service with a Cloud Run ID token (cached ~50 min)."""

    def __init__(self, agent_url: str, client: httpx.Client | None = None):
        self.agent_url = agent_url
        self.client = client or httpx.Client(timeout=60)
        self._token, self._token_expiry = "", 0.0

    def _id_token(self) -> str:
        if self._token and time.time() < self._token_expiry:
            return self._token
        r = self.client.get(METADATA_TOKEN_URL.format(audience=self.agent_url), headers={"Metadata-Flavor": "Google"},
                            timeout=5)
        r.raise_for_status()
        self._token, self._token_expiry = r.text.strip(), time.time() + 50 * 60
        return self._token

    def ask(self, payload: dict) -> dict:
        r = self.client.post(f"{self.agent_url}/v1/ask", json=payload,
                             headers={"Authorization": f"Bearer {self._id_token()}"})
        r.raise_for_status()
        return r.json()

    def scan(self, image: bytes, mime: str, fields: dict) -> tuple[int, dict]:
        r = self.client.post(f"{self.agent_url}/v1/scan", data=fields, files={"image": ("tray", image, mime)},
                             headers={"Authorization": f"Bearer {self._id_token()}"})
        return r.status_code, r.json()


def _identity(request: Request):
    device = request.headers.get("x-calswipes-device", "")
    if not _DEVICE_RE.match(device):
        return None
    ip = (request.headers.get("x-forwarded-for", "").split(",")[0].strip()
          or (request.client.host if request.client else "unknown"))
    premium = request.headers.get("x-calswipes-entitlement", "").lower() == "premium"
    return device, ip, premium


def _deny(decision):
    return JSONResponse({"error": {"code": decision.reason, "message": decision.message},
                         "quota": {"tier": decision.tier, "limit": decision.limit, "remaining": decision.remaining}},
                        status_code=decision.status, headers={"Cache-Control": "no-store"})


def _err(code, message, status):
    return JSONResponse({"error": {"code": code, "message": message}}, status_code=status,
                        headers={"Cache-Control": "no-store"})


def make_router(gate: AssistantGate, forwarder) -> APIRouter:
    router = APIRouter(prefix="/assistant")

    @router.post("/ask")
    def ask(body: AskBody, request: Request):
        who = _identity(request)
        if who is None:
            return _err("missing_device", "X-CalSwipes-Device header is required", 401)
        device, ip, premium = who
        day = body.date or berkeley_today().isoformat()
        hit = gate.cached(body.question, body.hall, body.meal, day)
        if hit is not None:
            return JSONResponse({**hit, "cached": True}, headers={"Cache-Control": "no-store"})
        decision = gate.reserve(ASK, device, ip, premium)
        if not decision.allowed:
            return _deny(decision)
        try:
            out = forwarder.ask({"question": body.question, "hall": body.hall, "meal": body.meal, "date": day})
        except Exception as exc:
            gate.release(ASK, device, ip)
            log.error("assistant_upstream_error kind=ask err=%s", type(exc).__name__)
            return _err("assistant_unavailable", "The assistant is temporarily unavailable. Please try again.", 503)
        cost = float(out.get("metrics", {}).get("cost_usd", 0.0))
        gate.record_cost(cost)
        public = {k: out[k] for k in ("answer", "citations", "agents_used") if k in out}
        gate.remember(body.question, body.hall, body.meal, day, public)
        log.info("assistant_ask tier=%s cost_usd=%.6f remaining=%d", decision.tier, cost, decision.remaining)
        return JSONResponse({**public, "cached": False,
                             "quota": {"tier": decision.tier, "limit": decision.limit, "remaining": decision.remaining}},
                            headers={"Cache-Control": "no-store"})

    @router.post("/scan")
    async def scan(request: Request, image: UploadFile = File(...), hall: str = Form(...), meal: str = Form(...),
                   date: str = Form("")):
        who = _identity(request)
        if who is None:
            return _err("missing_device", "X-CalSwipes-Device header is required", 401)
        device, ip, premium = who
        data = await image.read(MAX_IMAGE_BYTES + 1)
        if len(data) > MAX_IMAGE_BYTES:
            return _err("image_too_large", "Image must be under 10 MB", 413)
        decision = gate.reserve(SCAN, device, ip, premium)
        if not decision.allowed:
            return _deny(decision)
        try:
            status, out = forwarder.scan(data, image.content_type or "image/jpeg",
                                         {"hall": hall, "meal": meal, "date": date})
        except Exception as exc:
            gate.release(SCAN, device, ip)
            log.error("assistant_upstream_error kind=scan err=%s", type(exc).__name__)
            return _err("assistant_unavailable", "Scanning is temporarily unavailable. Please try again.", 503)
        if status != 200:
            gate.release(SCAN, device, ip)  # bad photo / no menu shouldn't burn the user's scan
            return JSONResponse(out, status_code=status, headers={"Cache-Control": "no-store"})
        gate.record_cost(float(out.get("metrics", {}).get("cost_usd", 0.0)))
        out.pop("metrics", None)
        out["quota"] = {"tier": decision.tier, "limit": decision.limit, "remaining": decision.remaining}
        return JSONResponse(out, headers={"Cache-Control": "no-store"})

    return router


def build_assistant_router(engine, cfg: AssistantConfig | None = None):
    """Returns the router, or None when ASSISTANT_AGENT_URL isn't set (feature off, API unchanged)."""
    cfg = cfg or AssistantConfig.from_env()
    if not cfg.agent_url:
        return None
    return make_router(AssistantGate(cfg, SqlUsageStore(engine)), AgentForwarder(cfg.agent_url))
