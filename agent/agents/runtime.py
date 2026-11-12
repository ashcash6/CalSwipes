"""Local multi-agent runtime: a ReAct loop with hierarchical delegation.

ReAct = Reason + Act. Each step the model either
  - picks an Action (a tool call), we run it and feed back the Observation, or
  - gives the final Answer.
Hierarchical delegation = the root agent's "tools" include ask_menu_agent,
ask_policy_agent, ask_nutrition_agent. Calling one runs that sub-agent's own
ReAct loop and returns its answer to the root, which combines everything.

This mirrors what agents/adk_app.py does with Google ADK, but runs offline with
StubLLM so tests and evals need no credentials.
"""
import re
import time
from dataclasses import dataclass, field

from agents import spec
from agents.guardrails import apply_guardrails
from agents.stub_llm import StubLLM
from observability.telemetry import log_event, record_llm_call, request_scope, span

CITATION = re.compile(r"\[([a-z0-9-]+#\d+)\]")


@dataclass
class AgentResult:
    text: str
    steps: list = field(default_factory=list)


class Agent:
    def __init__(self, name, instruction, description="", tools=(), sub_agents=(), llm=None, max_steps=6):
        self.name, self.instruction, self.description = name, instruction, description
        self.tools = {t.__name__: t for t in tools}
        self.sub_agents = {a.name: a for a in sub_agents}
        self.llm = llm or StubLLM()
        self.max_steps = max_steps

    @property
    def tool_names(self):
        return list(self.tools) + [f"ask_{n}" for n in self.sub_agents]

    def run(self, request: str) -> AgentResult:
        history, steps = [], []
        with span(f"agent.{self.name}", agent=self.name):
            for step in range(self.max_steps):
                start = time.perf_counter()
                with span("llm.generate", agent=self.name, model=self.llm.model, step=step):
                    resp = self.llm.generate(self.name, self.instruction, request, history, self.tool_names)
                record_llm_call(self.name, resp.model, resp.tokens_in, resp.tokens_out,
                                (time.perf_counter() - start) * 1000)
                steps.append({"agent": self.name, "thought": resp.thought,
                              "actions": [c.name for c in resp.tool_calls]})
                if not resp.tool_calls:
                    return AgentResult(resp.text or "", steps)
                for call in resp.tool_calls:
                    if call.name.startswith("ask_") and call.name[4:] in self.sub_agents:
                        sub = self.sub_agents[call.name[4:]].run(call.args["request"])
                        steps.extend(sub.steps)
                        result = {"answer": sub.text}
                    elif call.name in self.tools:
                        result = self.tools[call.name](**call.args)
                    else:
                        result = {"error": f"unknown tool {call.name}"}
                    history.append({"type": "observation", "name": call.name, "args": call.args, "result": result})
            return AgentResult("I ran out of reasoning steps before finishing.", steps)


def build_agent(cfg: dict, llm=None) -> Agent:
    subs = [build_agent(s, llm) for s in cfg.get("sub_agents", [])]
    return Agent(cfg["name"], cfg["instruction"], cfg.get("description", ""), cfg.get("tools", []), subs, llm)


_ROOT = None


def answer_question(question: str, llm=None) -> dict:
    """Entry point used by the API, the evals and the tests."""
    global _ROOT
    root = build_agent(spec.ROOT, llm) if llm is not None else (_ROOT or build_agent(spec.ROOT))
    if llm is None:
        _ROOT = root
    with request_scope("ask", runtime="local") as metrics:
        result = root.run(question)
        text, actions = apply_guardrails(question, result.text)
    if actions:
        log_event("guardrail", request_id=metrics.request_id, actions=actions)
    return {
        "answer": text,
        "citations": sorted(set(CITATION.findall(text))),
        "agents_used": sorted({s["agent"] for s in result.steps} - {"root_planner"}),
        "steps": result.steps,
        "guardrail_actions": actions,
        "metrics": metrics.summary(),
    }
