import base64
import json
import logging
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
import httpx
from fastapi import FastAPI, Query, Request, Response
from fastapi.responses import JSONResponse
from sqlalchemy import select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session
from app.config import Settings
from app.db import MenuSnapshot, make_engine
from app.importer import canonical_hash
from app.schemas import ALLOWED_SCAN_MIME_TYPES, MAX_PHOTO_BYTES, Hall, Meal, MenuResponse, ScanMealRequest, ScanMealResponse
from app import vision


def create_app(settings=None, engine=None):
    settings = settings or Settings.from_env()
    owned = engine is None
    engine = engine or make_engine(settings.database_url)

    @asynccontextmanager
    async def lifespan(app):
        yield
        if owned:
            engine.dispose()

    app = FastAPI(title="Berkeley Dining Menu API", version="1.2.0", lifespan=lifespan)

    def error(code, message, status):
        return JSONResponse({"error": {"code": code, "message": message}}, status_code=status,
                            headers={"Cache-Control": "no-store", "Retry-After": "300"} if status == 503 else {"Cache-Control": "no-store"})

    @app.exception_handler(SQLAlchemyError)
    async def database_error(request, exc):
        logging.getLogger("berkeley.api").error("database_unavailable")
        return error("database_unavailable", "Database temporarily unavailable", 503)

    @app.get("/health/live")
    def live():
        return {"status": "ok"}

    @app.get("/health/ready")
    def ready():
        with engine.connect() as connection:
            connection.execute(text("SELECT 1 FROM menu_snapshots LIMIT 1"))
        return {"status": "ok"}

    @app.get("/v1/available-meals")
    def available_meals(hall: Hall, date: date = Query()):
        with Session(engine) as session:
            meals = session.execute(
                select(MenuSnapshot.meal).where(
                    MenuSnapshot.hall == hall.value,
                    MenuSnapshot.service_date == date,
                    MenuSnapshot.content["status"].as_string() == "published",
                )
            ).scalars().all()
        return JSONResponse(
            {"hall": hall.value, "date": str(date), "available": sorted(meals)},
            headers={"Cache-Control": "public, max-age=300"},
        )

    @app.get("/menu", response_model=MenuResponse)
    @app.get("/v1/menu", response_model=MenuResponse)
    def menu(request: Request, hall: Hall, date: date = Query(), meal: Meal = Query()):
        with Session(engine) as session:
            snapshot = session.scalar(select(MenuSnapshot).where(MenuSnapshot.hall == hall.value,
                                      MenuSnapshot.service_date == date, MenuSnapshot.meal == meal.value))
            if snapshot is None:
                return error("menu_unavailable", "No verified menu for this hall/date/meal", 404)
            expires = snapshot.fetched_at + timedelta(hours=settings.stale_hours)
            now = datetime.now(timezone.utc)
            if now >= expires:
                return error("menu_stale", "Menu exceeds the freshness limit; refresh is required", 503)
            result = MenuResponse(**snapshot.content, revision=snapshot.revision, fetched_at=snapshot.fetched_at,
                                  expires_at=expires, source_url=snapshot.source_url, source_sha256=snapshot.source_sha256)
            payload = result.model_dump(mode="json")
            etag = '"' + canonical_hash(payload) + '"'
            headers = {"ETag": etag, "Cache-Control": "public, max-age=0, must-revalidate",
                       "X-Menu-Schema-Version": "1"}
            tags = [t.strip().removeprefix("W/") for t in request.headers.get("if-none-match", "").split(",")]
            if etag in tags or "*" in tags:
                return Response(status_code=304, headers=headers)
            return JSONResponse(payload, headers=headers)

    @app.post("/v1/scan-meal", response_model=ScanMealResponse)
    def scan_meal(body: ScanMealRequest):
        if not settings.gemini_api_key:
            return error("vision_unavailable", "Food photo recognition is not configured on this server", 503)

        if body.mime_type not in ALLOWED_SCAN_MIME_TYPES:
            return error("invalid_mime_type", f"Supported types: {', '.join(sorted(ALLOWED_SCAN_MIME_TYPES))}", 400)

        try:
            photo_bytes = base64.b64decode(body.photo, validate=True)
        except Exception:
            return error("invalid_photo", "photo must be valid base64", 400)

        if len(photo_bytes) > MAX_PHOTO_BYTES:
            return error("photo_too_large", "Photo must be under 10 MB", 413)

        with Session(engine) as session:
            snapshot = session.scalar(select(MenuSnapshot).where(
                MenuSnapshot.hall == body.hall.value,
                MenuSnapshot.service_date == body.date,
                MenuSnapshot.meal == body.meal.value,
            ))

        if snapshot is None:
            return error("menu_unavailable", "No menu found for this hall/date/meal", 404)

        all_items = snapshot.content.get("items", [])
        scannable = [{"id": i["id"], "name": i["name"]} for i in all_items if i.get("macros")]
        if not scannable:
            return error("no_scannable_items", "No items with nutrition data available for this meal", 422)

        item_map = {i["id"]: i for i in all_items}

        log = logging.getLogger("berkeley.api")
        try:
            result = vision.identify_items(photo_bytes, body.mime_type, scannable, settings.gemini_api_key)
        except httpx.HTTPStatusError as exc:
            log.error("gemini_http_error status=%s body=%s", exc.response.status_code, exc.response.text[:500])
            return error("vision_error", "Photo recognition service returned an error", 502)
        except httpx.TransportError as exc:
            log.error("gemini_transport_error %s", exc)
            return error("vision_error", "Photo recognition service is temporarily unavailable", 503)
        except (json.JSONDecodeError, KeyError, ValueError) as exc:
            log.error("gemini_parse_error %s", exc)
            return error("vision_error", "Unexpected response from photo recognition service", 502)

        matched = []
        for m in result.get("matched", []):
            item = item_map.get(m["item_id"])
            if item is None:
                continue
            base_macros = item.get("macros")
            adjusted = None
            if base_macros:
                mult = m["portion_multiplier"]
                adjusted = {k: round(v * mult, 1) for k, v in base_macros.items()}
            matched.append({
                "item_id": m["item_id"],
                "item_name": m["item_name"],
                "confidence": m["confidence"],
                "portion_multiplier": m["portion_multiplier"],
                "adjusted_macros": adjusted,
            })

        return JSONResponse(
            {"matched": matched, "no_match_reason": result.get("no_match_reason")},
            headers={"Cache-Control": "no-store"},
        )

    return app
