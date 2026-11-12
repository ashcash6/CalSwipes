"""Load Berkeley Dining Eatec XML menus into the structured tables.

    OFFLINE=1 python -m pipeline.ingest_menus --from-dir ../berkeley-dining-backend/tests/fixtures --date 2026-09-14
    python -m pipeline.ingest_menus --live --date 2026-11-12      # fetches dining.berkeley.edu

XML parsing imports the CalSwipes backend parser directly (pipeline/backend_parser.py), so
the same validation rules apply: no guessed nutrition, strict hall/date checks.
"""
import argparse
import time
import urllib.request
from datetime import date, datetime
from zoneinfo import ZoneInfo
from pathlib import Path
from urllib.robotparser import RobotFileParser

from defusedxml import ElementTree

from config import Settings
from observability.telemetry import log_event, setup_logging, span
from pipeline.store import BaseStore, open_store
from pipeline.backend_parser import HALLS, Hall, meal_name, parse_xml

ORIGIN = "https://dining.berkeley.edu"
USER_AGENT = "CalSwipesAgent/0.1 (student project; menu research)"


def meal_times(raw: bytes) -> dict:
    """{meal_period: (source_name, start 'HH:MM', end 'HH:MM')} straight from the feed's <menu> attributes."""
    out = {}
    for menu in ElementTree.fromstring(raw).findall("menu"):
        label = menu.get("mealperiodname", "")
        out[meal_name(label).value] = (label, menu.get("mealstarttime"), menu.get("mealendtime"))
    return out


def load_hall(store: BaseStore, raw: bytes, hall: Hall, day: date) -> int:
    with span("ingest.hall", hall=hall.value, date=day.isoformat()):
        menus = parse_xml(raw, hall, day)
        times = meal_times(raw)
        location_id = store.upsert_location(hall.value, HALLS[hall][1])
        store.upsert_date(day)
        count = 0
        for menu in menus:
            if menu.status != "published":
                continue
            source_name, start, end = times.get(menu.meal.value, (None, None, None))
            meal_id = store.upsert_meal(location_id, day, menu.meal.value, source_name, start, end)
            for it in menu.items:
                item_id = store.upsert_item({
                    "recipe_id": it.id, "name": it.name, "category": ", ".join(c for c in it.categories if c),
                    "allergens": it.allergens, "dietary_tags": it.dietary_tags,
                    "nutrition_status": it.nutrition_status,
                    "serving_qty": it.serving.quantity, "serving_unit": it.serving.unit,
                    "serving_weight_g": it.serving.weight_g,
                    "macros": it.macros.model_dump() if it.macros else None,
                })
                store.add_menu_entry(meal_id, item_id)
                count += 1
        store.commit()
    log_event("ingest_hall", hall=hall.value, date=day.isoformat(), menu_entries=count)
    return count


def hall_from_filename(path: Path) -> Hall:
    stem = path.stem.lower().replace("_", "-")
    for hall in Hall:
        if stem == hall.value or stem.startswith(hall.value + "-") or stem.startswith(HALLS[hall][0].lower()):
            return hall
    raise ValueError(f"cannot tell which hall {path.name} is")


def ingest_dir(store: BaseStore, folder: Path, day: date) -> int:
    return sum(load_hall(store, p.read_bytes(), hall_from_filename(p), day) for p in sorted(folder.glob("*.xml")))


def ingest_live(store: BaseStore, day: date, halls=tuple(Hall)) -> int:
    robots = RobotFileParser(ORIGIN + "/robots.txt")
    robots.read()
    total = 0
    for hall in halls:
        url = f"{ORIGIN}/wp-content/uploads/menus-exportimport/{HALLS[hall][0]}_{day:%Y%m%d}.xml"
        if not robots.can_fetch(USER_AGENT, url):
            log_event("ingest_skipped_robots", hall=hall.value)
            continue
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=30) as r:
                raw = r.read(8 * 1024 * 1024)
            total += load_hall(store, raw, hall, day)
        except Exception as exc:  # one bad hall shouldn't stop the others
            log_event("ingest_hall_failed", hall=hall.value, error=type(exc).__name__)
        time.sleep(max(1, robots.crawl_delay(USER_AGENT) or 0))
    return total


def main(argv=None):
    setup_logging()
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--from-dir", type=Path)
    src.add_argument("--live", action="store_true")
    p.add_argument("--date", type=date.fromisoformat, default=None,
                   help="YYYY-MM-DD; default: today in Berkeley (America/Los_Angeles)")
    a = p.parse_args(argv)
    day = a.date or datetime.now(ZoneInfo("America/Los_Angeles")).date()
    store = open_store(Settings.from_env())
    n = ingest_dir(store, a.from_dir, day) if a.from_dir else ingest_live(store, day)
    log_event("ingest_menus_done", menu_entries=n)


if __name__ == "__main__":
    main()
