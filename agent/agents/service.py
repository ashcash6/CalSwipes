"""HTTP API for the assistant (deploys as its own Cloud Run service).

    POST /v1/ask   {"question": "..."}  ->  {"answer", "citations", "agents_used", "metrics"}
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
        if runtime == "adk":
            if "adk" not in state:
                from agents.adk_app import ADKAssistant
                state["adk"] = ADKAssistant(settings)
            out = await state["adk"].ask(question)
        else:
            from agents.runtime import answer_question
            out = await asyncio.to_thread(answer_question, question)
            out.pop("steps", None)
        return JSONResponse(out)

    async def health(_):
        return JSONResponse({"status": "ok", "runtime": runtime})

    return Starlette(routes=[Route("/v1/ask", ask, methods=["POST"]), Route("/health", health)])


app = make_app() if os.environ.get("CALSWIPES_AGENT_AUTOAPP", "1") == "1" else None
