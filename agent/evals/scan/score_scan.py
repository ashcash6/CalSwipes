"""Score the tray scanner against user-confirmed labels (see README.md in this folder)."""
import argparse
import json
import mimetypes
import sys
import time
from pathlib import Path


def prf(pred: set, gold: set):
    tp = len(pred & gold)
    return tp, len(pred - gold), len(gold - pred)


def score(records) -> dict:
    tp = fp = fn = exact = 0
    for r in records:
        a, b, c = prf(set(r["predicted"]), set(r["confirmed"]))
        tp, fp, fn = tp + a, fp + b, fn + c
        exact += set(r["predicted"]) == set(r["confirmed"])
    p = tp / (tp + fp) if tp + fp else 0.0
    rc = tp / (tp + fn) if tp + fn else 0.0
    return {"n": len(records), "precision": p, "recall": rc, "f1": 2 * p * rc / (p + rc) if p + rc else 0.0,
            "exact_match": exact / len(records) if records else 0.0}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--labels", required=True)
    ap.add_argument("--use-logged", action="store_true", help="score stored predictions instead of re-scanning")
    ap.add_argument("--min-confidence", type=float, default=0.5)
    ap.add_argument("--out", default="scan-report.md")
    a = ap.parse_args(argv)
    records = [json.loads(l) for l in Path(a.labels).read_text().splitlines() if l.strip()]
    latencies, dropped = [], 0
    if not a.use_logged:
        from agents import tools
        from agents.scanner import scan_image
        for r in records:
            img = Path(r["photo"]).read_bytes()
            start = time.perf_counter()
            out = scan_image(tools._store(), img, mimetypes.guess_type(r["photo"])[0] or "image/jpeg",
                             r["hall"], r["meal"], r["date"])
            latencies.append((time.perf_counter() - start) * 1000)
            dropped += out["dropped_off_menu"]
            r["predicted"] = [m["menu_item_id"] for m in out["matches"] if m["confidence"] >= a.min_confidence]
    s = score(records)
    lat = sorted(latencies)
    pct = lambda q: lat[min(len(lat) - 1, max(0, round(q / 100 * len(lat)) - 1))] if lat else None
    lines = ["# Tray scanner eval", "", f"Records: {s['n']}", "",
             f"- precision {s['precision']:.3f} / recall {s['recall']:.3f} / F1 {s['f1']:.3f}",
             f"- exact tray match {s['exact_match']:.1%}", f"- off-menu ids dropped: {dropped}",
             f"- latency p50/p95 ms: {pct(50)} / {pct(95)}"]
    Path(a.out).write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
