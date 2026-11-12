"""HTTP API for the assistant (deploys as its own Cloud Run service).

    POST /v1/ask   {"question": "..."}  ->  {"answer", "citations", "agents_used", "metrics"}
    POST /v1/scan  multipart: image (file), hall, meal, date (optional) -> {"matches": [...], ...}
    GET  /health

AGENT_RUNTIME=adk (default when OFFLINE is not set) uses Google ADK + Gemini.
AGENT_RUNTIME=local, or OFFLINE=1, uses the local runtime + StubLLM.
"""
import asyncio
import os

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from config import Settings, offline
from observability.telemetry import setup_logging, setup_tracing

MAX_QUESTION_CHARS = 1000


def make_app() -> Starlette:
    setup_logging()
    settings = Settings.from_env()
    setup_tracing(settings.trace_exporter)
    runtime = os.environ.get("AGENT_RUNTIME", "local" if offline() else "adk")
    state = {}

    async def ask(request: Request):
        try:
            body = await request.json()
        except ValueError:
            return JSONResponse({"error": "body must be JSON"}, status_code=400)
        question = (body or {}).get("question", "") if isinstance(body, dict) else ""
        if not isinstance(question, str) or not question.strip():
            return JSONResponse({"error": "question is required"}, status_code=400)
        if len(question) > MAX_QUESTION_CHARS:
            return JSONResponse({"error": f"question must be under {MAX_QUESTION_CHARS} characters"}, status_code=413)
        ctx_parts = [f"{k}={str(body.get(k))[:32]}" for k in ("hall", "meal", "date") if body.get(k)]
        context = f"[context: {', '.join(ctx_parts)}] " if ctx_parts else ""
        if runtime == "adk":
            if "adk" not in state:
                from agents.adk_app import ADKAssistant
                state["adk"] = ADKAssistant(settings)
            out = await state["adk"].ask(question, context=context)
        else:
            from agents.runtime import answer_question
            out = await asyncio.to_thread(answer_question, f"{question} {' '.join(ctx_parts)}".strip())
            out.pop("steps", None)
        return JSONResponse(out)

    async def scan(request: Request):
        from agents import tools
        from agents.scanner import MAX_IMAGE_BYTES, ScanError, scan_image
        from observability.telemetry import request_scope

        try:
            form = await request.form(max_files=1, max_fields=10)
        except Exception:
            return JSONResponse({"error": {"code": "invalid_form", "message": "send multipart/form-data"}},
                                status_code=400)
        upload = form.get("image")
        if upload is None or not hasattr(upload, "read"):
            return JSONResponse({"error": {"code": "missing_field", "message": "image file is required"}},
                                status_code=400)
        image = await upload.read(MAX_IMAGE_BYTES + 1)
        mime = (upload.content_type or "").split(";")[0].strip().lower()
        try:
            with request_scope("scan", hall=str(form.get("hall", ""))) as metrics:
                out = await asyncio.to_thread(scan_image, tools._store(), image, mime, str(form.get("hall", "")),
                                              str(form.get("meal", "")), str(form.get("date", "") or ""))
        except ScanError as exc:
            return JSONResponse({"error": {"code": exc.code, "message": str(exc)}}, status_code=exc.status)
        out["metrics"] = metrics.summary()
        return JSONResponse(out, headers={"Cache-Control": "no-store"})

    async def health(_):
        return JSONResponse({"status": "ok", "runtime": runtime})

    return Starlette(routes=[Route("/v1/ask", ask, methods=["POST"]), Route("/v1/scan", scan, methods=["POST"]),
                             Route("/health", health)])


app = make_app() if os.environ.get("CALSWIPES_AGENT_AUTOAPP", "1") == "1" else None
