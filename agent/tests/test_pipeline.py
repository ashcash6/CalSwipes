from pathlib import Path

from pipeline.chunking import chunk_text
from pipeline.embeddings import FakeEmbedder, get_embedder
from pipeline.ingest_docs import clean_body, read_doc
from pipeline.ingest_menus import ingest_dir
from pipeline.backend_parser import FIXTURES_DIR
from tests.conftest import BACKEND, DAY, ROOT


def test_structured_counts_match_backend_parser(store):
    # 158 + 147 + 90 + 141 unique items per hall, same numbers as the backend's test_parser.py
    assert store.scalar("SELECT COUNT(*) FROM menu_entries") == 536
    assert store.scalar("SELECT COUNT(*) FROM locations") == 4
    assert store.scalar("SELECT COUNT(*) FROM dates") == 1
    assert store.scalar("SELECT COUNT(*) FROM meals") == 12  # 4 halls x breakfast/lunch/dinner
    assert store.scalar("SELECT COUNT(*) FROM nutrition") == store.scalar("SELECT COUNT(*) FROM items")


def test_meal_times_come_from_feed(store):
    rows = store.query("SELECT m.start_time, m.end_time FROM meals m JOIN locations l ON l.id = m.location_id "
                       "WHERE l.slug = 'crossroads' AND m.period = 'lunch'")
    assert rows == [{"start_time": "11:00", "end_time": "16:00"}]


def test_reingest_is_idempotent(store):
    before = store.scalar("SELECT COUNT(*) FROM menu_entries")
    ingest_dir(store, FIXTURES_DIR, DAY)
    assert store.scalar("SELECT COUNT(*) FROM menu_entries") == before


def test_allergens_stored_delimited(store):
    row = store.query("SELECT allergens FROM items WHERE name = 'Cheddar Eggs Scramble'")[0]
    assert row["allergens"] == ",Egg,Milk,"


def test_chunking_overlap_and_limits():
    text = "\n\n".join(" ".join(f"w{p}_{i}" for i in range(50)) for p in range(6))
    chunks = chunk_text(text, max_words=120, overlap_words=30)
    assert len(chunks) > 1
    assert all(len(c.split()) <= 150 for c in chunks)
    assert chunks[0].split()[-30:] == chunks[1].split()[:30]  # overlap carried forward


def test_fake_embedder_deterministic_and_normalized():
    e = FakeEmbedder()
    a, b = e.embed_query("peanut allergy"), e.embed_query("peanut allergy")
    assert a == b and len(a) == 768
    assert abs(sum(x * x for x in a) - 1.0) < 1e-9


def test_offline_picks_fake_embedder():
    assert isinstance(get_embedder(), FakeEmbedder)


def test_sample_docs_are_labeled():
    for path in (ROOT / "pipeline" / "docs" / "sample").glob("*.md"):
        assert read_doc(path)["is_sample"] is True
        assert "SAMPLE TEXT" in path.read_text()


def test_clean_body_strips_banner():
    assert clean_body("> SAMPLE banner\n## Hours\nOpen late.") == "Hours:\nOpen late."


def test_doc_chunks_stored_with_embeddings(store):
    assert store.scalar("SELECT COUNT(*) FROM chunks") >= 6
    assert store.scalar("SELECT COUNT(*) FROM docs WHERE is_sample = 1") == 6


def test_parser_is_the_real_backend_module():
    """No vendored copy: the pipeline must import the backend's own parser."""
    import pipeline.backend_parser as bp
    assert Path(bp.parse_xml.__code__.co_filename).resolve() == (BACKEND / "app" / "parser.py").resolve()
