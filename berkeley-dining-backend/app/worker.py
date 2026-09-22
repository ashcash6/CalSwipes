import logging
from datetime import datetime, timedelta, timezone
from apscheduler.schedulers.blocking import BlockingScheduler
from sqlalchemy import select
from app.config import Settings
from app.db import MenuSnapshot, make_engine
from app.importer import run, today
from app.schemas import Hall, Meal

log = logging.getLogger("berkeley.worker")


def refresh():
    try:
        if run():
            log.error("refresh_incomplete: one or more dining halls failed")
    except Exception:
        log.error("refresh_failed: inspect database and source connectivity")


def monitor():
    settings = Settings.from_env()
    engine = make_engine(settings.database_url)
    try:
        with engine.connect() as connection:
            rows = connection.execute(select(MenuSnapshot.hall, MenuSnapshot.meal, MenuSnapshot.fetched_at)
                                      .where(MenuSnapshot.service_date == today())).all()
        current = {(r.hall, r.meal): r.fetched_at for r in rows}
        threshold = datetime.now(timezone.utc) - timedelta(hours=settings.stale_hours)
        missing = [f"{h.value}/{m.value}" for h in Hall for m in Meal
                   if current.get((h.value, m.value), datetime.min.replace(tzinfo=timezone.utc)) <= threshold]
        if missing:
            log.error("menu_freshness_alert date=%s keys=%s", today(), ",".join(missing))
    except Exception:
        log.error("freshness_monitor_failed: database unavailable")
    finally:
        engine.dispose()


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    scheduler = BlockingScheduler(timezone="America/Los_Angeles", job_defaults={"coalesce": True, "max_instances": 1, "misfire_grace_time": 3600})
    # Runs at 10:00 PM PT to import the next day's menus before the app rolls over at 10 PM.
    scheduler.add_job(refresh, "cron", hour=22, minute=0, id="refresh")
    scheduler.add_job(monitor, "interval", minutes=15, id="freshness")
    refresh()
    monitor()
    try:
        scheduler.start()
    except (KeyboardInterrupt, SystemExit):
        pass


if __name__ == "__main__":
    main()
