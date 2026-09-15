import argparse
import hashlib
import json
import logging
from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo
from sqlalchemy import text
from sqlalchemy.dialects.postgresql import insert
from app.config import Settings
from app.db import ImportRun, MenuSnapshot, make_engine
from app.parser import SourceError, parse_xml
from app.schemas import Hall
from app.source import BerkeleySource

log = logging.getLogger("berkeley.import")


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def today():
    return datetime.now(ZoneInfo("America/Los_Angeles")).date()


def persist(connection, menus, fetched_at, url, raw):
    for menu in menus:
        content = menu.model_dump(mode="json")
        values = dict(hall=menu.hall.value, service_date=menu.date, meal=menu.meal.value,
                      content=content, revision=canonical_hash(content), fetched_at=fetched_at,
                      source_url=url, source_sha256=hashlib.sha256(raw).hexdigest())
        stmt = insert(MenuSnapshot).values(**values)
        connection.execute(stmt.on_conflict_do_update(constraint="uq_menu_key", set_=values))


def import_day(engine, day: date, source: BerkeleySource):
    failures = 0
    # Dedicated connection holds a session lock while separate transactions publish each hall.
    with engine.connect() as lock:
        acquired = lock.execute(text("SELECT pg_try_advisory_lock(72819041)")).scalar()
        lock.commit()
        if not acquired:
            raise RuntimeError("Another importer is running")
        try:
            for hall in Hall:
                try:
                    url, raw = source.fetch(hall, day)
                    menus = parse_xml(raw, hall, day)
                    now = datetime.now(timezone.utc)
                    count = sum(len(m.items) for m in menus)
                    with engine.begin() as connection:
                        persist(connection, menus, now, url, raw)
                        connection.execute(insert(ImportRun).values(hall=hall.value, service_date=day,
                            finished_at=now, outcome="success", detail=f"{count} unique menu items"))
                    log.info(json.dumps({"event": "import_success", "hall": hall.value, "date": str(day), "items": count}))
                except Exception as exc:
                    failures += 1
                    # Do not log connection strings, response bodies or credentials.
                    reason = str(exc)[:250] if isinstance(exc, SourceError) else "source import failed"
                    detail = f"{type(exc).__name__}: {reason}; previous snapshot retained"
                    log.error(json.dumps({"event": "import_failure", "hall": hall.value, "date": str(day), "error": detail}))
                    with engine.begin() as connection:
                        connection.execute(insert(ImportRun).values(hall=hall.value, service_date=day,
                            finished_at=datetime.now(timezone.utc), outcome="failure", detail=detail))
        finally:
            lock.execute(text("SELECT pg_advisory_unlock(72819041)"))
            lock.commit()
    return failures


def run(day=None):
    settings = Settings.from_env()
    engine = make_engine(settings.database_url)
    source = BerkeleySource(settings.user_agent)
    try:
        return import_day(engine, day or today(), source)
    finally:
        source.close()
        engine.dispose()


def main():
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    parser = argparse.ArgumentParser(description="Import all four Berkeley halls atomically per hall")
    parser.add_argument("--date", type=date.fromisoformat, default=None)
    args = parser.parse_args()
    raise SystemExit(1 if run(args.date) else 0)


if __name__ == "__main__":
    main()
