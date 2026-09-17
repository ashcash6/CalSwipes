"""Generate static menu JSON files for GitHub Pages / Cloudflare Pages hosting."""
import hashlib
import json
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from app.importer import canonical_hash, today
from app.parser import parse_xml
from app.schemas import Hall
from app.source import BerkeleySource

STALE_HOURS = 36
log = logging.getLogger("berkeley.export")


def export(output_dir: Path, day=None):
    day = day or today()
    source = BerkeleySource("BerkeleyPlate/0.1 (public menu research)")
    failures = 0
    try:
        for hall in Hall:
            try:
                url, raw = source.fetch(hall, day)
                menus = parse_xml(raw, hall, day)
                now = datetime.now(timezone.utc)
                sha256 = hashlib.sha256(raw).hexdigest()
                for menu in menus:
                    content = menu.model_dump(mode="json")
                    payload = {
                        **content,
                        "revision": canonical_hash(content),
                        "fetched_at": now.isoformat(),
                        "expires_at": (now + timedelta(hours=STALE_HOURS)).isoformat(),
                        "source_url": url,
                        "source_sha256": sha256,
                    }
                    out = output_dir / menu.hall.value / str(menu.date) / f"{menu.meal.value}.json"
                    out.parent.mkdir(parents=True, exist_ok=True)
                    out.write_text(json.dumps(payload, separators=(",", ":"), ensure_ascii=False))
                    log.info("exported %s/%s/%s (%d items)", menu.hall.value, menu.date, menu.meal.value, len(menu.items))
            except Exception as exc:
                failures += 1
                log.error("failed hall=%s: %s", hall.value, exc)
    finally:
        source.close()
    return failures


if __name__ == "__main__":
    import argparse
    from datetime import date
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    p = argparse.ArgumentParser(description="Export Berkeley dining menus to static JSON files")
    p.add_argument("--output", default="menus", type=Path)
    p.add_argument("--date", type=date.fromisoformat, default=None)
    args = p.parse_args()
    raise SystemExit(1 if export(args.output, args.date) else 0)
