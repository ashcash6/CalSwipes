"""Run against a disposable migrated Postgres DB using TEST_DATABASE_URL."""
import os
from datetime import datetime, timedelta, timezone
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import func, select, text, update
from app.config import Settings
from app.db import ImportRun, MenuSnapshot, make_engine
from app.importer import import_day
from app.main import create_app
from app.schemas import Hall
from tests.test_parser import DAY, FIXTURES


class FixtureSource:
    def fetch(self, hall, day):
        return f"https://dining.berkeley.edu/{hall}.xml", (FIXTURES / f"{hall.value}.xml").read_bytes()


@pytest.fixture
def engine():
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL not set; use a disposable migrated PostgreSQL database")
    db = make_engine(url)
    with db.begin() as connection:
        connection.execute(text("TRUNCATE menu_snapshots, import_runs RESTART IDENTITY"))
    yield db
    db.dispose()


def test_import_api_and_freshness(engine):
    assert import_day(engine, DAY, FixtureSource()) == 0
    client = TestClient(create_app(Settings(str(engine.url)), engine))
    path = "/menu?hall=foothill&date=2026-09-14&meal=breakfast"
    first = client.get(path)
    assert first.status_code == 200
    assert len(first.json()["items"]) == 17
    croissant = next(i for i in first.json()["items"] if i["id"] == "1542")
    assert croissant["macros"] == {"calories_kcal":173.18,"protein_g":4.25,"carbs_g":19.09,"fat_g":8.55}
    assert croissant["serving"]["weight_g"] == pytest.approx(42.5242846875)
    assert client.get(path, headers={"If-None-Match": first.headers["etag"]}).status_code == 304
    assert client.get(path, headers={"If-None-Match": "W/"+first.headers["etag"]}).status_code == 304
    assert import_day(engine, DAY, FixtureSource()) == 0
    second = client.get(path)
    assert second.json()["revision"] == first.json()["revision"]
    assert second.headers["etag"] != first.headers["etag"]  # refreshed validity window
    with engine.begin() as c:
        assert c.scalar(select(func.count()).select_from(MenuSnapshot)) == 20
        assert c.scalar(select(func.count()).select_from(ImportRun)) == 8
        c.execute(update(MenuSnapshot).values(fetched_at=datetime.now(timezone.utc)-timedelta(hours=37)))
    stale = client.get(path, headers={"If-None-Match": second.headers["etag"]})
    assert stale.status_code == 503
    assert stale.json()["error"]["code"] == "menu_stale"
    assert stale.headers["cache-control"] == "no-store"


def test_failure_preserves_snapshot_and_other_halls_update(engine):
    import_day(engine, DAY, FixtureSource())
    with engine.connect() as c:
        before = c.scalar(select(MenuSnapshot.fetched_at).where(MenuSnapshot.hall == "foothill"))
    class Broken(FixtureSource):
        def fetch(self, hall, day):
            if hall == Hall.foothill:
                return "https://dining.berkeley.edu/fail", b"<html/>"
            return super().fetch(hall, day)
    assert import_day(engine, DAY, Broken()) == 1
    with engine.connect() as c:
        after = c.scalar(select(MenuSnapshot.fetched_at).where(MenuSnapshot.hall == "foothill"))
        assert before == after
        assert c.scalar(select(func.count()).select_from(ImportRun).where(ImportRun.outcome=="failure")) == 1


def test_api_validation_and_unpublished(engine):
    import_day(engine, DAY, FixtureSource())
    client = TestClient(create_app(Settings(str(engine.url)), engine))
    assert client.get("/menu?hall=other&date=2026-09-14&meal=lunch").status_code == 422
    assert client.get("/menu?hall=foothill&date=bad&meal=lunch").status_code == 422
    assert client.get("/menu?hall=foothill&date=2026-09-15&meal=lunch").status_code == 404
    assert client.get("/v1/menu?hall=foothill&date=2026-09-14&meal=late-night").json()["status"] == "not_published"
    assert client.get("/health/ready").status_code == 200


def test_import_lock(engine):
    with engine.connect() as c:
        c.execute(text("SELECT pg_advisory_lock(72819041)"))
        try:
            with pytest.raises(RuntimeError, match="Another importer"):
                import_day(engine, DAY, FixtureSource())
        finally:
            c.execute(text("SELECT pg_advisory_unlock(72819041)"))
