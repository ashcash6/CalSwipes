"""The production agent tree on Google ADK (Agent Development Kit), using Gemini on Vertex AI.

Same tree, instructions and tool functions as agents/spec.py. ADK reads each
tool's signature + docstring to build the function schema Gemini sees, runs the
ReAct loop (model -> tool call -> result -> model ...), and handles delegation:
declaring `sub_agents` on the root auto-injects one delegation tool per
sub-agent (named after it), so the root can call several and combine answers.

Environment (see deploy/README.md):
    GOOGLE_GENAI_USE_VERTEXAI=TRUE
    GOOGLE_CLOUD_PROJECT=<your project id>
    GOOGLE_CLOUD_LOCATION=us-central1
    GEMINI_MODEL=gemini-2.5-flash          # root planner (final answer) + tray scanner
    PLANNER_MODEL=gemini-2.5-flash-lite    # specialist agents (tool routing)

Try it locally (after `gcloud auth application-default login`):
    python -m agents.adk_app "What vegan options are at Crossroads for lunch?"

NOTE: written against google-adk 2.13 docs; it could not be executed in the
sandbox this repo was built in (no PyPI access). If an import path moved, check
https://adk.dev/api-reference/python/ .
"""
import asyncio
import sys
import time
import uuid

from agents import spec
from agents.guardrails import apply_guardrails
from agents.runtime import CITATION
from config import Settings, model_for_agent
from observability.telemetry import record_llm_call, request_scope, setup_logging, setup_tracing

APP_NAME = "calswipes_agent"


def build_adk_agent(settings: Settings | None = None):
    from google.adk import Agent

    settings = settings or Settings.from_env()

    def make(cfg, is_root=False):
        kwargs = dict(name=cfg["name"], model=model_for_agent(cfg["name"], settings), description=cfg["description"],
                      instruction=cfg["instruction"], tools=list(cfg.get("tools", [])))
        if cfg.get("sub_agents"):
            kwargs["sub_agents"] = [make(s) for s in cfg["sub_agents"]]
        if not is_root:
            kwargs["mode"] = "single_turn"  # specialists answer and hand back; they don't chat with the user
        return Agent(**kwargs)

    return make(spec.ROOT, is_root=True)


class ADKAssistant:
    def __init__(self, settings: Settings | None = None):
        from google.adk.runners import Runner
        from google.adk.sessions import InMemorySessionService

        self.settings = settings or Settings.from_env()
        self.sessions = InMemorySessionService()
        self.runner = Runner(agent=build_adk_agent(self.settings), app_name=APP_NAME, session_service=self.sessions)

    async def ask(self, question: str, user_id: str = "anon", context: str = "") -> dict:
        from google.genai import types

        with request_scope("ask", runtime="adk") as metrics:
            session = await self.sessions.create_session(app_name=APP_NAME, user_id=user_id,
                                                         session_id=uuid.uuid4().hex)
            message = types.Content(role="user", parts=[types.Part(text=(context + question) if context else question)])
            final, agents, last = "", set(), time.perf_counter()
            async for event in self.runner.run_async(user_id=user_id, session_id=session.id, new_message=message):
                now = time.perf_counter()
                usage = getattr(event, "usage_metadata", None)
                if usage is not None:
                    # Latency per LLM call ~= time since the previous event (ADK streams one event per model turn).
                    record_llm_call(event.author, model_for_agent(event.author, self.settings),
                                    usage.prompt_token_count or 0,
                                    usage.candidates_token_count or 0, (now - last) * 1000)
                last = now
                if event.author:
                    agents.add(event.author)
                if event.is_final_response() and event.content and event.content.parts:
                    text = "".join(p.text or "" for p in event.content.parts)
                    if text.strip():
                        final = text
            answer, actions = apply_guardrails(question, final)
        return {"answer": answer, "citations": sorted(set(CITATION.findall(answer))),
                "agents_used": sorted(agents - {spec.ROOT["name"], "user"}), "guardrail_actions": actions,
                "metrics": metrics.summary()}


def main():
    setup_logging()
    settings = Settings.from_env()
    setup_tracing(settings.trace_exporter)
    question = " ".join(sys.argv[1:]) or "What's for lunch at Crossroads?"
    out = asyncio.run(ADKAssistant(settings).ask(question))
    print(out["answer"])
    print(out["metrics"])


if __name__ == "__main__":
    main()
