"""Central settings, read from environment variables (never hard-code credentials)."""
import json
import os
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def offline() -> bool:
    """OFFLINE=1 means: no Google Cloud calls. Fake embedder + stub LLM + local SQLite."""
    return os.environ.get("OFFLINE", "0").lower() in ("1", "true", "yes")


@dataclass(frozen=True)
class Settings:
    # Postgres+pgvector in prod: a SEPARATE Neon database from the app's (AGENT_DATABASE_URL), so the
    # agent's read-only SQL tool can never see user tables. e.g. postgresql://user:pass@host/db?sslmode=require
    # Empty -> local SQLite file (offline dev/tests).
    database_url: str = ""
    sqlite_path: str = str(ROOT / ".local" / "calswipes_agent.db")
    gcp_project: str = ""
    gcp_location: str = "us-central1"  # Vertex AI region (Cloud Run itself is us-west1)
    gemini_model: str = "gemini-3.8-flash"           # final answers + vision
    planner_model: str = "gemini-3.1-flash-lite"     # cheap model for tool routing in specialist agents
    embedding_model: str = "text-embedding-005"
    embedding_dim: int = 768
    trace_exporter: str = "none"  # none | console | gcp
    pricing: dict = field(default_factory=dict)

    @classmethod
    def from_env(cls):
        return cls(
            database_url=os.environ.get("AGENT_DATABASE_URL", ""),  # deliberately NOT the app DATABASE_URL
            sqlite_path=os.environ.get("SQLITE_PATH", cls.sqlite_path),
            gcp_project=os.environ.get("GOOGLE_CLOUD_PROJECT", ""),
            gcp_location=os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1"),
            gemini_model=os.environ.get("GEMINI_MODEL", cls.gemini_model),
            planner_model=os.environ.get("PLANNER_MODEL", cls.planner_model),
            embedding_model=os.environ.get("EMBEDDING_MODEL", cls.embedding_model),
            embedding_dim=int(os.environ.get("EMBEDDING_DIM", "768")),
            trace_exporter=os.environ.get("TRACE_EXPORTER", "none"),
            pricing=load_pricing(),
        )


def model_for_agent(agent_name: str, settings: "Settings") -> str:
    """Model routing: specialists mostly pick tools and pass data back, so they run on Flash-Lite.
    The root planner writes the answer the user reads, so it runs on Flash (as does the tray scanner)."""
    return settings.gemini_model if agent_name in ("root_planner", "scanner") else settings.planner_model


def load_pricing() -> dict:
    with open(ROOT / "config" / "pricing.json") as f:
        return json.load(f)
