# Berkeley Dining backend — Phases 1–2

Runnable FastAPI + PostgreSQL backend using Berkeley's public Eatec XML exports. It imports the four dining commons, normalizes nutrition and serving units, and serves versioned daily menu snapshots. Phase 2 adds native Apple identity verification and revocable account sessions. No images or user health data are uploaded. Meal-history endpoints remain a later phase. See [authentication setup](docs/auth.md) and [Phase 2 verification](docs/phase2-verification.md).

## Start with Docker

Requires Docker Engine with Compose. From this project directory:

```sh
cp .env.example .env
# Edit .env: set a random URL-safe POSTGRES_PASSWORD and your scraper contact.
docker compose up --build -d
docker compose logs -f worker
```

PowerShell uses `Copy-Item .env.example .env` for the first step. The migration job runs before the API and worker. The worker imports the current Berkeley date immediately, then refreshes at 00:15 and every three hours in America/Los_Angeles. It checks freshness every 15 minutes. Only one worker replica is needed; PostgreSQL advisory locking also prevents overlapping import processes.

Open http://localhost:8000/docs for interactive API documentation. The API binds to localhost; PostgreSQL has no host port in Compose. For an iPhone in a later phase, deploy behind HTTPS and configure its reachable API base URL.

```sh
curl 'http://localhost:8000/menu?hall=foothill&date=2026-09-14&meal=breakfast'
# Use the current date for a fresh installation. Import a specific source date:
docker compose run --rm worker python -m app.importer --date 2026-09-14
```

Historical URLs depend on Berkeley continuing to host those exports. Missing feeds do not become empty menus.

## Local Python setup

Requires Python 3.12+ and PostgreSQL 17. Create a database and set its URL (with URL-encoded credentials).

```sh
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.lock
export DATABASE_URL='postgresql+psycopg://USER:PASSWORD@localhost:5432/berkeley'
alembic upgrade head
python -m app.importer
uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
# In a separate terminal with the same environment:
python -m app.worker
```

On PowerShell, activate `.venv\Scripts\Activate.ps1` and set `$env:DATABASE_URL = 'postgresql+psycopg://...'`. `.env` is consumed by Compose; local Python expects real environment variables.

## Files and dependencies

```text
app/
  schemas.py       Version 1 menu, serving and nutrition contract
  parser.py        Eatec XML adapter, validation and deduplication
  source.py        Bounded HTTP fetching, retries, robots checks
  db.py            PostgreSQL snapshot and import-audit tables
  importer.py      Atomic per-hall import and command-line entrypoint
  main.py          Menu API, conditional GET, readiness and liveness
  worker.py        Berkeley-time refresh schedule and freshness alerts
  config.py        Validated environment configuration
  auth.py          Apple verification, one-time challenges and session JWTs
migrations/        Alembic database schema revisions
tests/             Parser, HTTP policy and real PostgreSQL tests
tests/fixtures/    Actual Berkeley XML fetched 2026-09-14
docs/              Source review, API contract, verification evidence
.github/workflows/ PostgreSQL CI tests
compose.yaml       Database, migrations, API and worker
```

Runtime dependencies: FastAPI/Uvicorn, SQLAlchemy/psycopg, Alembic, HTTPX, defusedxml, APScheduler, tzdata and PyJWT with cryptography. pytest is the test dependency. `pyproject.toml` pins direct dependencies; `requirements.lock` pins the tested dependency set, including test tooling.

## Verify

Unit/source tests need no network. Integration tests require an **isolated, disposable, migrated database**: the suite truncates its menu and audit tables.

```sh
export DATABASE_URL='postgresql+psycopg://USER:PASSWORD@localhost:5432/berkeley_test'
export TEST_DATABASE_URL="$DATABASE_URL"
alembic upgrade head
pytest -q
alembic check
```

Without `TEST_DATABASE_URL`, PostgreSQL tests are explicitly skipped. CI provides PostgreSQL and runs them. See [verification](docs/verification.md) for what was actually run here.

## Operational behavior

- One request per hall per refresh, plus robots.txt. A minimum one-second delay separates feed requests; longer robots crawl delays are honored. Transient failures retry at most three times.
- A failed or malformed hall feed leaves its previous snapshots and freshness timestamps unchanged. Other halls can still update. Each successful hall's five meal keys update in one database transaction.
- Import events go to logs and `import_runs`; freshness failures produce ERROR logs every 15 minutes. Configure your hosting log monitor to page on `import_failure`, `refresh_failed`, `menu_freshness_alert` and worker-process failure. No Slack webhook is configured or sent.
- `/health/live` confirms API process liveness; `/health/ready` checks database/schema access. Readiness does not imply fresh menus. Monitor the worker and menu availability separately.
- A source outage never extends cache validity. Menus older than 36 hours return 503, including conditional requests. `STALE_HOURS` may shorten that limit, not increase it.
- Deploy only the API publicly, behind TLS and gateway rate limits. Keep worker/migration access private, configure PostgreSQL backups and secrets, and use a limited API database role for a public deployment. The included Compose stack is a local deployment baseline, not managed production hosting.

## Phase boundary

Phase 1 implements the real-data importer, storage, menu API and operational tests. Phase 2 adds Apple/session authentication and an accompanying SwiftUI shell in the sibling iOS directory. Meal logging/history, camera capture, CoreML, HealthKit and TestFlight remain subsequent phases. No pretrained model is needed or converted for these phases. See [source and feasibility findings](docs/source-review.md) before designing device support and portion estimation.
