import logging
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from fastapi import FastAPI, Query, Request, Response
from fastapi.responses import JSONResponse
from sqlalchemy import select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session
from app.config import Settings
from app.db import MenuSnapshot, make_engine
from app.importer import canonical_hash
from app.schemas import Hall, Meal, MenuResponse
from app.auth import router as auth_router


def create_app(settings=None, engine=None, apple_verifier=None):
    settings = settings or Settings.from_env()
    owned = engine is None
    engine = engine or make_engine(settings.database_url)

    @asynccontextmanager
    async def lifespan(app):
        yield
        if owned:
            engine.dispose()

    app = FastAPI(title="Berkeley Dining Menu API", version="1.1.0", lifespan=lifespan)
    app.include_router(auth_router(settings, engine, apple_verifier))

    @app.middleware("http")
    async def private_auth_responses(request, call_next):
        response = await call_next(request)
        if request.url.path.startswith("/v1/auth/"):
            response.headers["Cache-Control"] = "no-store"
        return response

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

    return app
