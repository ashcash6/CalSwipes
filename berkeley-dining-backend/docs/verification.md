# Phase 1 verification — 2026-09-14

Executed locally on Windows with Python 3.12 and a disposable PostgreSQL 17.11 instance bound to localhost. All temporary runtime/database files were kept outside the deliverable directory. No system PostgreSQL service was installed.

## Results

- **23 tests passed, none skipped** when `TEST_DATABASE_URL` was configured.
- Fresh database migration: `alembic upgrade head` succeeded.
- Migration/model drift: `alembic check` reported no new upgrade operations.
- Live importer fetched robots.txt and all four Berkeley XML feeds over HTTPS and persisted them into PostgreSQL.
- Stored 20 hall/date/meal snapshots: 12 published menus and 8 explicitly not-published periods (brunch and late-night).
- Deduplicated item totals: Crossroads 158, Café 3 147, Foothill 90, Clark Kerr 141; total **536**.
- Started the actual Uvicorn server and verified HTTP readiness 200, a real menu response 200, ETag conditional GET 304, and OpenAPI 200.
- Captured the real HTTP response in `example-menu.json` and generated `openapi.json`.

## Coverage

Tests cover all four real feeds; ounce-to-gram conversion; unknown/fluid-volume units; absent/unapproved nutrition; negative and nonfinite nutrients; unknown meal labels; wrong hall/date; missing nutrient headers; empty/invalid/unsafe XML; robots denial/outage; retries; refusal to follow redirects; exact sample recipe macros through PostgreSQL and API; idempotent imports; ETag/revision semantics; freshness expiration before conditional responses; partial source failure preserving previous data; parameter validation; unpublished periods; and concurrent-import locking.

## Limits

Docker/Compose was not available here, so the container stack and hosted CI workflow are provided but were not executed locally. The same application, importer, migrations and PostgreSQL queries were executed directly. The worker schedule was implemented but not observed across an overnight clock boundary. Tests emitted upstream HTTPX/Starlette deprecation warnings; the Windows sandbox also produced a non-fatal pytest cache-permission warning during one run. These did not skip or fail tests.

Public deployment, external log-alert routing, Berkeley feed redistribution agreement, iOS device testing and all later app/model phases are outstanding. The supplied code is a verified Phase 1 backend, not a claim that the entire app is App-Store-ready.
