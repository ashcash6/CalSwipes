"""Structured logs + OpenTelemetry traces + LLM-native metrics.

Three ideas, in plain words:
1. Every request gets a RequestMetrics object (kept in a contextvar, so nested
   agents/tools all add to the same one without passing it around).
2. Every LLM call records tokens in/out and how long it took. From that we get
   tokens/sec and cost (using config/pricing.json).
3. Every step (agent, tool, LLM call) is wrapped in an OpenTelemetry span, so in
   Cloud Trace you see a waterfall: root agent -> menu_agent -> search_menu tool.

If the OpenTelemetry SDK isn't installed, the API package gives no-op spans, so
code still runs; you just don't export traces.
"""
import contextlib
import contextvars
import json
import logging
import sys
import time
import uuid
from dataclasses import asdict, dataclass, field

from config import load_pricing

try:
    from opentelemetry import trace as _otel_trace
except ImportError:  # pragma: no cover - opentelemetry-api is a pinned dependency
    _otel_trace = None

_PRICING = load_pricing()["models"]
_current: contextvars.ContextVar["RequestMetrics | None"] = contextvars.ContextVar("request_metrics", default=None)


# ---------- cost ----------

def cost_usd(model: str, tokens_in: int, tokens_out: int) -> float:
    price = _PRICING.get(model)
    if price is None:
        logging.getLogger("calswipes.telemetry").warning(json.dumps({"event": "unknown_model_price", "model": model}))
        return 0.0
    return tokens_in / 1e6 * price["input_per_million"] + tokens_out / 1e6 * price["output_per_million"]


# ---------- per-request metrics ----------

@dataclass
class LLMCall:
    agent: str
    model: str
    tokens_in: int
    tokens_out: int
    latency_ms: float
    cost_usd: float

    @property
    def tokens_per_sec(self) -> float:
        return self.tokens_out / (self.latency_ms / 1000) if self.latency_ms > 0 else 0.0


@dataclass
class RequestMetrics:
    request_id: str = field(default_factory=lambda: uuid.uuid4().hex[:16])
    started: float = field(default_factory=time.perf_counter)
    llm_calls: list = field(default_factory=list)
    tool_calls: list = field(default_factory=list)
    latency_ms: float = 0.0

    @property
    def tokens_in(self):
        return sum(c.tokens_in for c in self.llm_calls)

    @property
    def tokens_out(self):
        return sum(c.tokens_out for c in self.llm_calls)

    @property
    def cost_usd(self):
        return sum(c.cost_usd for c in self.llm_calls)

    @property
    def llm_latency_ms(self):
        return sum(c.latency_ms for c in self.llm_calls)

    @property
    def tokens_per_sec(self):
        # Output tokens per second of LLM time (generation speed), not wall-clock.
        return self.tokens_out / (self.llm_latency_ms / 1000) if self.llm_latency_ms > 0 else 0.0

    def summary(self) -> dict:
        return {
            "request_id": self.request_id,
            "latency_ms": round(self.latency_ms, 2),
            "llm_calls": len(self.llm_calls),
            "tool_calls": len(self.tool_calls),
            "tokens_in": self.tokens_in,
            "tokens_out": self.tokens_out,
            "tokens_per_sec": round(self.tokens_per_sec, 2),
            "cost_usd": round(self.cost_usd, 8),
            "agents": sorted({c.agent for c in self.llm_calls}),
        }


def current() -> "RequestMetrics | None":
    return _current.get()


@contextlib.contextmanager
def request_scope(name: str = "request", **attrs):
    """Wrap one user question. Emits one structured log line with the totals at the end."""
    metrics = RequestMetrics()
    token = _current.set(metrics)
    try:
        with span(name, request_id=metrics.request_id, **attrs) as s:
            yield metrics
            metrics.latency_ms = (time.perf_counter() - metrics.started) * 1000
            for k, v in metrics.summary().items():
                if isinstance(v, (int, float, str)):
                    s.set_attribute(f"calswipes.{k}", v)
    finally:
        if not metrics.latency_ms:
            metrics.latency_ms = (time.perf_counter() - metrics.started) * 1000
        _current.reset(token)
        log_event("request_complete", **metrics.summary())


def record_llm_call(agent: str, model: str, tokens_in: int, tokens_out: int, latency_ms: float) -> LLMCall:
    call = LLMCall(agent, model, int(tokens_in), int(tokens_out), latency_ms, cost_usd(model, tokens_in, tokens_out))
    m = current()
    if m is not None:
        m.llm_calls.append(call)
    log_event("llm_call", **asdict(call), tokens_per_sec=round(call.tokens_per_sec, 2))
    return call


def record_tool_call(agent: str, tool: str, latency_ms: float, ok: bool):
    m = current()
    if m is not None:
        m.tool_calls.append({"agent": agent, "tool": tool, "latency_ms": round(latency_ms, 2), "ok": ok})
    log_event("tool_call", agent=agent, tool=tool, latency_ms=round(latency_ms, 2), ok=ok)


# ---------- tracing ----------

class _NoopSpan:
    def set_attribute(self, *_):
        pass

    def record_exception(self, *_):
        pass


@contextlib.contextmanager
def span(name: str, **attrs):
    if _otel_trace is None:
        yield _NoopSpan()
        return
    tracer = _otel_trace.get_tracer("calswipes-agent")
    with tracer.start_as_current_span(name) as s:
        for k, v in attrs.items():
            if isinstance(v, (str, int, float, bool)):
                s.set_attribute(k, v)
        yield s


def setup_tracing(exporter: str = "none", service_name: str = "calswipes-agent"):
    """exporter: 'none' (no-op), 'console' (print spans), 'gcp' (Cloud Trace).

    Needs opentelemetry-sdk; 'gcp' also needs opentelemetry-exporter-gcp-trace.
    Returns True if a real tracer provider was installed.
    """
    if exporter == "none":
        return False
    try:
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter, SimpleSpanProcessor
    except ImportError:
        log_event("tracing_disabled", reason="opentelemetry-sdk not installed")
        return False
    provider = TracerProvider(resource=Resource.create({"service.name": service_name}))
    if exporter == "console":
        provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter(out=sys.stderr)))
    elif exporter == "gcp":
        from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter
        provider.add_span_processor(BatchSpanProcessor(CloudTraceSpanExporter()))
    else:
        raise ValueError(f"unknown TRACE_EXPORTER {exporter!r}")
    _otel_trace.set_tracer_provider(provider)
    return True


# ---------- structured logging ----------

class JsonFormatter(logging.Formatter):
    """One JSON object per line. Cloud Logging parses 'severity' and 'message' automatically."""

    def format(self, record):
        try:
            payload = json.loads(record.getMessage())
            if not isinstance(payload, dict):
                payload = {"message": record.getMessage()}
        except (ValueError, TypeError):
            payload = {"message": record.getMessage()}
        payload.setdefault("severity", record.levelname)
        payload.setdefault("logger", record.name)
        if _otel_trace is not None:
            ctx = _otel_trace.get_current_span().get_span_context()
            if ctx.is_valid:
                payload["trace_id"] = format(ctx.trace_id, "032x")
                payload["span_id"] = format(ctx.span_id, "016x")
        return json.dumps(payload, default=str)


def setup_logging(level=logging.INFO, stream=None):
    # stdout by default (Cloud Run collects it); the MCP stdio server passes stderr because stdout is the protocol.
    handler = logging.StreamHandler(stream or sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)


def log_event(event: str, level=logging.INFO, **fields):
    logging.getLogger("calswipes").log(level, json.dumps({"event": event, **fields}, default=str))
