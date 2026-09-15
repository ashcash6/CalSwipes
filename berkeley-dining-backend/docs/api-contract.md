# Menu API contract, schema version 1

`GET /menu?hall=&date=&meal=` and `GET /v1/menu?...` return the same representation. `/openapi.json` and `/docs` expose the runtime schema. A generated copy is in `openapi.json`; `example-menu.json` is an actual live API response captured during verification, not a seed menu.

Hall IDs: `crossroads`, `cafe-3`, `foothill`, `clark-kerr`.
Meal IDs: `breakfast`, `lunch`, `dinner`, `late-night`, `brunch`.
Dates are ISO `YYYY-MM-DD`, interpreted as Berkeley service dates. The importer computes today's date in America/Los_Angeles, independent of server UTC or client timezone.

Every response identifies its hall/date/meal, `schema_version`, `revision`, `fetched_at`, `expires_at`, source URL and source SHA-256. `revision` hashes normalized menu content; unchanged content keeps its revision. ETag hashes the entire response, including the refresh timestamps, so revalidation communicates an extended validity window even when the recipes did not change.

Each item has its source recipe ID, name, station categories, serving quantity/unit/description, weight in grams when safely convertible, per-serving calories/protein/carbs/fat, nutrition status and warnings. IDs are source recipe IDs scoped to the menu snapshot; consumers should retain hall/date/meal/revision when logging meals. Future logging must snapshot the actual macros used, not re-read a mutable menu later.

Missing or unapproved nutrition is `macros: null`, never zero. `weight_g: null` means the source serving cannot be converted to mass without more information. Such items cannot support automatic volume-to-serving calculations. Image URLs are null because the inspected XML has no food reference photos; dietary/allergen icons are not food photographs.

`published` means that this meal period and its recipes appear in a validated feed. `not_published` means the hall/day feed exists but omits this meal period. It does **not** mean the hall is closed. Brunch remains its own period rather than being silently assigned to lunch. An entirely empty feed is treated as an import failure because it cannot reliably establish a closure.

HTTP behavior:

| Code | Meaning |
| --- | --- |
| 200 | Fresh published or explicitly not-published menu snapshot |
| 304 | ETag matches a still-fresh representation |
| 404 | No snapshot exists for the requested valid key |
| 422 | Invalid/missing hall, date or meal |
| 503 | Snapshot exceeded freshness limit, or database unavailable |

Domain errors use `{"error":{"code":"menu_stale","message":"..."}}`; FastAPI validation errors use its standard `detail` array. 503 responses include `Retry-After: 300` and `Cache-Control: no-store`.

## iOS caching policy for the next phase

Persist the entire response under `(schema_version, hall, date, meal)`. Reuse it offline until `expires_at`, with a visible downloaded-time label. After expiration, show unavailable or explicitly stale historical information and prevent a new supposedly-current scan. Preserve past meal logs separately.

While online, revalidate on selection/app foreground using `If-None-Match`; avoid repeated requests during one session. Switching date/hall/meal chooses a new key. The spec's literal "only re-fetch when date/hall/meal changes" cannot also detect same-day substitutions or enforce source freshness, so this design adds lightweight conditional revalidation. `Cache-Control: public, max-age=0, must-revalidate` prevents intermediary caches from silently extending freshness; offline storage is an explicit application feature.

## Storage

`menu_snapshots` stores one typed, normalized JSONB menu document per unique hall/service-date/meal, alongside indexed lookup columns and provenance. This is intentional snapshot storage: menu-serving macros can change over time, so a global mutable recipe row would lose context. JSONB payloads are validated with strict Pydantic models before writes and reads. `import_runs` records success/failure independently of menu payloads. Schema upgrades use Alembic; API schema versioning is separate from migration revision numbering.
