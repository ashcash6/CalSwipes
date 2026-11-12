# Deploying CalSwipes to Google Cloud Run

Copy-paste these blocks in order from the **repo root** (the folder containing `agent/` and `berkeley-dining-backend/`). You run them yourself; nothing here contains real credentials. Anything in `<ANGLE_BRACKETS>` is a value you fill in.

What gets created:

| Piece | Cloud Run type | Image | Notes |
|---|---|---|---|
| `calswipes-api` | service, public | `berkeley-dining-backend/Dockerfile` | The API the iOS app calls. `min-instances=1` so there's no cold start. |
| `calswipes-migrate` | job | same as API | Runs `alembic upgrade head`. |
| `calswipes-import` | job + Cloud Scheduler | same as API | Nightly menu import at 10 PM PT (replaces the APScheduler worker). |
| `calswipes-agent` | service, private | `agent/Dockerfile.agent` | `/v1/ask` multi-agent API (Gemini via Vertex AI). |
| `calswipes-agent-ingest` | job + Cloud Scheduler | same as agent | Loads menus + docs into the agent's Postgres/pgvector DB. |

> `min-instances=1` means one instance is always running and billed even with zero traffic. Check the Cloud Run pricing page / calculator before leaving it on, and set the budget alert in step 10 first.

## 0. One-time local setup

```bash
# Install the gcloud CLI first: https://cloud.google.com/sdk/docs/install
gcloud auth login
gcloud auth application-default login      # lets local scripts call Vertex AI as you
```

## 1. Variables (re-run this block in every new terminal)

```bash
export PROJECT_ID="<calswipes-something-unique>"   # lowercase, 6-30 chars, globally unique
export REGION="us-west1"                            # Cloud Run, Artifact Registry, jobs
export VERTEX_LOCATION="us-central1"                # Gemini + embeddings (widest model availability)
export REPO="calswipes"
export AR="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO"
export API_SA="calswipes-api@$PROJECT_ID.iam.gserviceaccount.com"
export AGENT_SA="calswipes-agent@$PROJECT_ID.iam.gserviceaccount.com"
export SCHED_SA="calswipes-scheduler@$PROJECT_ID.iam.gserviceaccount.com"
export TAG="$(git rev-parse --short HEAD)"
```

## 2. Create the project and link billing

```bash
gcloud projects create "$PROJECT_ID" --name="CalSwipes"
gcloud config set project "$PROJECT_ID"

gcloud billing accounts list                         # copy the ACCOUNT_ID
export BILLING_ACCOUNT="<XXXXXX-XXXXXX-XXXXXX>"
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
```

## 3. Enable APIs

```bash
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  aiplatform.googleapis.com \
  cloudtrace.googleapis.com \
  logging.googleapis.com \
  cloudscheduler.googleapis.com \
  billingbudgets.googleapis.com
```

## 4. Artifact Registry + build permissions

```bash
gcloud artifacts repositories create "$REPO" \
  --repository-format=docker --location="$REGION" --description="CalSwipes images"

# Cloud Build runs as the Compute default service account in new projects; let it push images and write logs.
for ROLE in roles/artifactregistry.writer roles/logging.logWriter roles/storage.objectViewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" --role="$ROLE"
done
```

## 5. Service accounts (least privilege)

```bash
gcloud iam service-accounts create calswipes-api --display-name="CalSwipes API"
gcloud iam service-accounts create calswipes-agent --display-name="CalSwipes Agent"
gcloud iam service-accounts create calswipes-scheduler --display-name="CalSwipes Scheduler"

# Agent: call Gemini/embeddings and write traces.
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$AGENT_SA" --role="roles/aiplatform.user"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$AGENT_SA" --role="roles/cloudtrace.agent"
# Scheduler: allowed to start Cloud Run jobs.
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SCHED_SA" --role="roles/run.invoker"
```

## 6. Secrets (Neon connection strings) in Secret Manager

Create **two databases** in your Neon project (Neon console → Databases → New database): keep the existing app database, and add one called `calswipes_agent`. The agent gets its own database so its read-only SQL tool can never see user tables.

Neon gives you a URL like `postgresql://USER:PASSWORD@ep-xxxx.us-west-2.aws.neon.tech/DBNAME?sslmode=require`.

- The **app** needs the scheme changed to `postgresql+psycopg://...` (the backend checks for it).
- The **agent** uses the plain `postgresql://...` form.

`read -s` keeps the value out of your shell history and off the screen:

```bash
read -rs -p "App DB URL (postgresql+psycopg://...): " APP_DB_URL; echo
printf '%s' "$APP_DB_URL" | gcloud secrets create DATABASE_URL --replication-policy=automatic --data-file=-

read -rs -p "Agent DB URL (postgresql://.../calswipes_agent?sslmode=require): " AGENT_DB_URL; echo
printf '%s' "$AGENT_DB_URL" | gcloud secrets create AGENT_DATABASE_URL --replication-policy=automatic --data-file=-

# Only if you use photo scanning (/v1/scan-meal). Skip otherwise.
read -rs -p "Gemini API key (or leave empty): " GEMINI_KEY; echo
[ -n "$GEMINI_KEY" ] && printf '%s' "$GEMINI_KEY" | gcloud secrets create GEMINI_API_KEY --replication-policy=automatic --data-file=-

unset APP_DB_URL AGENT_DB_URL GEMINI_KEY

gcloud secrets add-iam-policy-binding DATABASE_URL --member="serviceAccount:$API_SA" --role="roles/secretmanager.secretAccessor"
gcloud secrets add-iam-policy-binding AGENT_DATABASE_URL --member="serviceAccount:$AGENT_SA" --role="roles/secretmanager.secretAccessor"
gcloud secrets describe GEMINI_API_KEY >/dev/null 2>&1 && \
  gcloud secrets add-iam-policy-binding GEMINI_API_KEY --member="serviceAccount:$API_SA" --role="roles/secretmanager.secretAccessor"
```

To rotate a secret later: `printf '%s' "$NEW" | gcloud secrets versions add DATABASE_URL --data-file=-`, then redeploy.

## 7. Build and deploy the CalSwipes API

```bash
gcloud builds submit berkeley-dining-backend --tag "$AR/api:$TAG"

# Run database migrations once per release.
gcloud run jobs create calswipes-migrate --image "$AR/api:$TAG" --region "$REGION" \
  --service-account "$API_SA" --set-secrets "DATABASE_URL=DATABASE_URL:latest" \
  --command alembic --args upgrade,head
gcloud run jobs execute calswipes-migrate --region "$REGION" --wait

# If you created GEMINI_API_KEY, add ",GEMINI_API_KEY=GEMINI_API_KEY:latest" to --set-secrets.
gcloud run deploy calswipes-api --image "$AR/api:$TAG" --region "$REGION" \
  --service-account "$API_SA" \
  --min-instances 1 --max-instances 3 --cpu 1 --memory 512Mi --concurrency 80 \
  --set-secrets "DATABASE_URL=DATABASE_URL:latest" \
  --set-env-vars "STALE_HOURS=36,SCRAPER_USER_AGENT=CalSwipes/1.0 (public menu research)" \
  --allow-unauthenticated

export API_URL="$(gcloud run services describe calswipes-api --region "$REGION" --format='value(status.url)')"
curl -s "$API_URL/health/live"
```

Later releases: re-run `export TAG=...`, `gcloud builds submit ...`, then `gcloud run jobs update calswipes-migrate --image "$AR/api:$TAG" --region "$REGION"`, execute it, and `gcloud run deploy calswipes-api --image "$AR/api:$TAG" --region "$REGION"`.

## 8. Nightly menu import (replaces the always-on worker)

```bash
gcloud run jobs create calswipes-import --image "$AR/api:$TAG" --region "$REGION" \
  --service-account "$API_SA" --set-secrets "DATABASE_URL=DATABASE_URL:latest" \
  --set-env-vars "STALE_HOURS=36,SCRAPER_USER_AGENT=CalSwipes/1.0 (public menu research)" \
  --task-timeout 15m --max-retries 1 \
  --command python --args=-m,app.importer
gcloud run jobs execute calswipes-import --region "$REGION" --wait     # fill tomorrow's menus now

gcloud scheduler jobs create http calswipes-import-nightly --location "$REGION" \
  --schedule "0 22 * * *" --time-zone "America/Los_Angeles" \
  --uri "https://run.googleapis.com/v2/projects/$PROJECT_ID/locations/$REGION/jobs/calswipes-import:run" \
  --http-method POST --oauth-service-account-email "$SCHED_SA"
```

`app.importer` with no `--date` imports tomorrow's menus, same as the worker's 10 PM job. The worker's 15-minute freshness monitor isn't ported; the API already refuses stale menus with `menu_stale`.

## 9. Build and deploy the agent

```bash
gcloud builds submit . --config agent/deploy/cloudbuild.agent.yaml --substitutions=_IMAGE="$AR/agent:$TAG"

AGENT_ENV="GOOGLE_GENAI_USE_VERTEXAI=TRUE,GOOGLE_CLOUD_PROJECT=$PROJECT_ID,GOOGLE_CLOUD_LOCATION=global,GEMINI_MODEL=gemini-3.8-flash,PLANNER_MODEL=gemini-3.1-flash-lite,EMBEDDING_MODEL=text-embedding-005,TRACE_EXPORTER=gcp,AGENT_RUNTIME=adk"

# Load menus + docs into Postgres/pgvector (creates tables and the vector extension on first run).
gcloud run jobs create calswipes-agent-ingest --image "$AR/agent:$TAG" --region "$REGION" \
  --service-account "$AGENT_SA" --set-secrets "AGENT_DATABASE_URL=AGENT_DATABASE_URL:latest" \
  --set-env-vars "$AGENT_ENV" --task-timeout 20m --max-retries 1 \
  --command sh --args=-c,"python -m pipeline.ingest_menus --live && python -m pipeline.ingest_docs"
gcloud run jobs execute calswipes-agent-ingest --region "$REGION" --wait

gcloud scheduler jobs create http calswipes-agent-ingest-daily --location "$REGION" \
  --schedule "15 6 * * *" --time-zone "America/Los_Angeles" \
  --uri "https://run.googleapis.com/v2/projects/$PROJECT_ID/locations/$REGION/jobs/calswipes-agent-ingest:run" \
  --http-method POST --oauth-service-account-email "$SCHED_SA"

# Private service: every request costs Gemini tokens, so don't expose it publicly yet.
gcloud run deploy calswipes-agent --image "$AR/agent:$TAG" --region "$REGION" \
  --service-account "$AGENT_SA" \
  --min-instances 1 --max-instances 2 --cpu 1 --memory 1Gi --concurrency 20 --timeout 60 \
  --set-secrets "AGENT_DATABASE_URL=AGENT_DATABASE_URL:latest" \
  --set-env-vars "$AGENT_ENV" \
  --no-allow-unauthenticated

export AGENT_URL="$(gcloud run services describe calswipes-agent --region "$REGION" --format='value(status.url)')"
curl -s -H "Authorization: Bearer $(gcloud auth print-identity-token)" -H "Content-Type: application/json" \
  -d '{"question":"What vegan options are at Crossroads for lunch?"}' "$AGENT_URL/v1/ask"
```

To save money while not demoing, drop the agent to `--min-instances 0`: `gcloud run services update calswipes-agent --region "$REGION" --min-instances 0`.

Before ingesting real docs: run `cd agent && python -m pipeline.fetch_docs` locally, check `agent/pipeline/docs/fetched/`, then delete `agent/pipeline/docs/sample/` (or keep it out of the image) so answers only cite real pages. Rebuild and re-run the ingest job.

## 9b. Connect the public API to the agent (assistant proxy + cost controls)

```bash
# Let the API's service account call the private agent service.
gcloud run services add-iam-policy-binding calswipes-agent --region "$REGION" \
  --member="serviceAccount:$API_SA" --role="roles/run.invoker"

# New tables for caps/spend/cache (migration 0005). Rebuild the API image first if you haven't since pulling.
gcloud builds submit berkeley-dining-backend --tag "$AR/api:$TAG"
gcloud run jobs update calswipes-migrate --image "$AR/api:$TAG" --region "$REGION"
gcloud run jobs execute calswipes-migrate --region "$REGION" --wait

# Turn the proxy on. Pick your promo end date (or leave PROMO_FREE_UNTIL empty for none).
gcloud run deploy calswipes-api --image "$AR/api:$TAG" --region "$REGION" \
  --update-env-vars "ASSISTANT_AGENT_URL=$AGENT_URL,ASSISTANT_DAILY_SPEND_CAP_USD=1.00,PROMO_FREE_UNTIL=2026-12-31,TRUST_CLIENT_ENTITLEMENT=0"

# Model routing on the agent (these are the defaults; set explicitly so they show in the console).
gcloud run services update calswipes-agent --region "$REGION" \
  --update-env-vars "GEMINI_MODEL=gemini-2.5-flash,PLANNER_MODEL=gemini-2.5-flash-lite,SCAN_MODEL=gemini-2.5-flash"

# Smoke test through the public API (any 16+ char id works as a test device).
curl -s -X POST "$API_URL/assistant/ask" -H "Content-Type: application/json" \
  -H "X-CalSwipes-Device: test-device-000000001" \
  -d '{"question":"What vegan options are at Crossroads for lunch?","hall":"crossroads","meal":"lunch"}'
```

The spend cap counts only what the agent reports for requests that go through the proxy. Keep the Cloud Billing budget from step 10 as the real backstop, and note that `min-instances=1` costs are separate from the $1/day AI cap.

## 10. Budget alert (do this before leaving min-instances on)

```bash
gcloud billing budgets create --billing-account="$BILLING_ACCOUNT" \
  --display-name="calswipes-monthly" --budget-amount=20USD \
  --filter-projects="projects/$PROJECT_ID" \
  --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0
```

Pick an amount you're comfortable with instead of 20. Alerts go by email to billing admins (you). A budget **alerts**, it does not stop spending. In the console: Billing → Budgets & alerts → calswipes-monthly to check it, and Billing → Reports to see spend per service.

## 11. Measure before/after latency

```bash
python berkeley-dining-backend/scripts/bench.py --base-url "https://<YOUR-RENDER-URL>" --label render --date "$(date +%F)" --json-out bench-render.json
python berkeley-dining-backend/scripts/bench.py --base-url "$API_URL" --label cloudrun --date "$(date +%F)" --json-out bench-cloudrun.json
```

Run both from the same network, a few times, at similar times of day. Paste the tables into the README's results section. Only switch the iOS app's base URL to `$API_URL` after the Cloud Run numbers and `/v1/menu` responses look right.

## 12. Look at the observability data

- Logs: Cloud Run → `calswipes-agent` → Logs. Filter `jsonPayload.event="request_complete"` to see `latency_ms`, `tokens_in`, `tokens_out`, `tokens_per_sec`, `cost_usd` per question.
- Traces: Trace Explorer (console → Trace). Each `/v1/ask` shows spans for the agents, LLM calls, and tools.
- Evals against the deployed stack, locally:
  ```bash
  export GOOGLE_GENAI_USE_VERTEXAI=TRUE GOOGLE_CLOUD_PROJECT="$PROJECT_ID" GOOGLE_CLOUD_LOCATION="$VERTEX_LOCATION"
  export AGENT_DATABASE_URL="$(gcloud secrets versions access latest --secret=AGENT_DATABASE_URL)"
  (cd agent && python -m evals.run_evals --mode adk)
  unset AGENT_DATABASE_URL
  ```
  The eval set uses 2026-09-14 fixture data. For adk mode, ingest that date first: `cd agent && python -m pipeline.ingest_menus --from-dir ../berkeley-dining-backend/tests/fixtures --date 2026-09-14`.

## Clean up / stop costs

```bash
gcloud run services update calswipes-agent --region "$REGION" --min-instances 0
gcloud run services update calswipes-api --region "$REGION" --min-instances 0
# Delete everything:
# gcloud projects delete "$PROJECT_ID"
```
