"""Measure p50/p95 latency of the CalSwipes API's key endpoints.

Run it against the old host and the new host, then compare:

    python backend/scripts/bench.py --base-url https://YOUR-RENDER-URL --label render
    python backend/scripts/bench.py --base-url https://YOUR-CLOUD-RUN-URL --label cloudrun

Standard library only, so it runs anywhere with Python 3.10+.
"""
import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date


def endpoints(day: str, hall: str, meal: str):
    q = urllib.parse.urlencode
    return {
        "health_live": "/health/live",
        "available_meals": "/v1/available-meals?" + q({"hall": hall, "date": day}),
        "menu": "/v1/menu?" + q({"hall": hall, "date": day, "meal": meal}),
    }


def percentile(values, pct):
    """Nearest-rank percentile (no interpolation), so p95 is a latency someone really saw."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, round(pct / 100 * len(ordered)))
    return ordered[min(rank, len(ordered)) - 1]


def timed_get(url, timeout):
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "calswipes-bench"}),
                                    timeout=timeout) as resp:
            resp.read()
            status = resp.status
    except urllib.error.HTTPError as exc:
        status = exc.code
    except (urllib.error.URLError, TimeoutError, OSError):
        status = 0
    return (time.perf_counter() - start) * 1000, status


def bench(base_url, n=50, concurrency=4, warmup=3, timeout=15.0, day=None, hall="crossroads", meal="lunch"):
    base = base_url.rstrip("/")
    results = {}
    for name, path in endpoints(day or date.today().isoformat(), hall, meal).items():
        url = base + path
        for _ in range(warmup):  # warm caches / wake a cold instance; not counted
            timed_get(url, timeout)
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            samples = list(pool.map(lambda _: timed_get(url, timeout), range(n)))
        ok = [ms for ms, status in samples if 200 <= status < 400]
        codes = {}
        for _, status in samples:
            codes[str(status)] = codes.get(str(status), 0) + 1
        results[name] = {
            "n": n, "ok": len(ok), "status_codes": codes,
            "p50_ms": round(percentile(ok, 50), 1) if ok else None,
            "p95_ms": round(percentile(ok, 95), 1) if ok else None,
            "mean_ms": round(statistics.fmean(ok), 1) if ok else None,
        }
    return results


def to_markdown(label, base_url, results):
    lines = [f"### {label} ({base_url})", "", "| endpoint | ok/n | p50 ms | p95 ms | mean ms | status codes |",
             "|---|---|---|---|---|---|"]
    for name, r in results.items():
        lines.append(f"| {name} | {r['ok']}/{r['n']} | {r['p50_ms']} | {r['p95_ms']} | {r['mean_ms']} | {r['status_codes']} |")
    return "\n".join(lines)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", required=True)
    p.add_argument("--label", default="target")
    p.add_argument("-n", type=int, default=50, help="requests per endpoint")
    p.add_argument("--concurrency", type=int, default=4)
    p.add_argument("--warmup", type=int, default=3)
    p.add_argument("--date", default=None, help="YYYY-MM-DD; defaults to today")
    p.add_argument("--hall", default="crossroads")
    p.add_argument("--meal", default="lunch")
    p.add_argument("--json-out", default=None, help="also write raw results to this JSON file")
    a = p.parse_args(argv)
    results = bench(a.base_url, a.n, a.concurrency, a.warmup, day=a.date, hall=a.hall, meal=a.meal)
    print(to_markdown(a.label, a.base_url, results))
    if a.json_out:
        with open(a.json_out, "w") as f:
            json.dump({"label": a.label, "base_url": a.base_url, "results": results}, f, indent=2)
    return 0 if all(r["ok"] for r in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
