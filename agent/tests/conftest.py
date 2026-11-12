import os
import sys
from datetime import date
from pathlib import Path

import pytest

os.environ["OFFLINE"] = "1"
os.environ.pop("DATABASE_URL", None)
os.environ.pop("AGENT_DATABASE_URL", None)
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

BACKEND = ROOT.parent / "berkeley-dining-backend"
DAY = date(2026, 9, 14)

from pipeline.backend_parser import FIXTURES_DIR  # noqa: E402


@pytest.fixture(scope="session")
def store():
    from agents import tools
    from pipeline.embeddings import FakeEmbedder
    from pipeline.ingest_docs import ingest_docs
    from pipeline.ingest_menus import ingest_dir
    from pipeline.store import SQLiteStore

    s = SQLiteStore(":memory:")
    s.init_schema()
    emb = FakeEmbedder()
    ingest_dir(s, FIXTURES_DIR, DAY)
    ingest_docs(s, emb, [ROOT / "pipeline" / "docs" / "sample"])
    tools.configure(store=s, embedder=emb, default_date=DAY.isoformat())
    return s
