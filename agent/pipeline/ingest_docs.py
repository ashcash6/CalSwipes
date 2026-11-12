"""Chunk + embed dining info documents into the vector table (RAG source).

    OFFLINE=1 python -m pipeline.ingest_docs            # fake embedder, local SQLite
    python -m pipeline.ingest_docs                      # Vertex AI embeddings, AGENT_DATABASE_URL Postgres

Each doc is a .md/.txt file with a small header:

    title: Crossroads hours
    source_url: https://dining.berkeley.edu/...
    sample: true            # true = written for this demo, NOT official text
    ---
    body text...
"""
import argparse
import re
from datetime import datetime, timezone
from pathlib import Path

from config import Settings
from observability.telemetry import log_event, setup_logging, span
from pipeline.chunking import chunk_text
from pipeline.embeddings import get_embedder
from pipeline.store import BaseStore, open_store

DOCS_DIR = Path(__file__).parent / "docs"


def read_doc(path: Path) -> dict:
    raw = path.read_text(encoding="utf-8")
    header, sep, body = raw.partition("\n---\n")
    if not sep:
        raise ValueError(f"{path.name}: missing '---' header separator")
    meta = {}
    for line in header.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            meta[k.strip().lower()] = v.strip()
    return {"id": path.stem, "title": meta.get("title", path.stem), "source_url": meta.get("source_url", ""),
            "is_sample": meta.get("sample", "true").lower() == "true", "fetched_at": meta.get("fetched_at"),
            "body": clean_body(body)}


def clean_body(body: str) -> str:
    """Drop '>' banner lines (sample status lives in metadata) and turn '## Heading' into 'Heading:'."""
    lines = []
    for line in body.splitlines():
        if line.lstrip().startswith(">"):
            continue
        m = re.match(r"^#+\s*(.+)$", line.strip())
        lines.append(m.group(1).rstrip(":") + ":" if m else line)
    return "\n".join(lines).strip()


def ingest_docs(store: BaseStore, embedder, folders=None) -> int:
    folders = folders or [DOCS_DIR / "sample", DOCS_DIR / "fetched"]
    total = 0
    for folder in folders:
        for path in sorted(list(folder.glob("*.md")) + list(folder.glob("*.txt"))):
            doc = read_doc(path)
            with span("ingest.doc", doc_id=doc["id"]):
                chunks = chunk_text(doc["body"])
                # Prefix the title so a chunk like "Open 7am-10am" still knows which hall it is about.
                vectors = embedder.embed_documents([f"{doc['title']}\n{c}" for c in chunks])
                store.upsert_doc(doc["id"], doc["title"], doc["source_url"], doc["is_sample"],
                                 doc["fetched_at"] or datetime.now(timezone.utc).isoformat())
                for i, (text, vec) in enumerate(zip(chunks, vectors)):
                    store.add_chunk(f"{doc['id']}#{i}", doc["id"], i, text, vec)
                store.commit()
            total += len(chunks)
            log_event("ingest_doc", doc_id=doc["id"], chunks=len(chunks), sample=doc["is_sample"])
    return total


def main(argv=None):
    setup_logging()
    argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter).parse_args(argv)
    settings = Settings.from_env()
    n = ingest_docs(open_store(settings), get_embedder(settings))
    log_event("ingest_docs_done", chunks=n)


if __name__ == "__main__":
    main()
