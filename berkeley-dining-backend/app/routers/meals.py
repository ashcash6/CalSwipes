"""POST /v1/meals — log a food entry (from a confirmed scan, manual input, or any other source)."""
from datetime import date, datetime, timezone
from uuid import uuid4
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.orm import Session
from app.auth import make_auth_dependency
from app.db import LoggedMeal
from app import planning


def _now() -> datetime:
    return datetime.now(timezone.utc)


class LogMealRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    service_date: date
    meal_type: str = Field(pattern=r"^(meal|snack)$")
    item_name: str = Field(min_length=1, max_length=256)
    calories_kcal: float = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)
    source: str = Field(pattern=r"^(scan|recurring|manual)$")
    # Optional context
    hall: str | None = Field(default=None, max_length=32)
    meal_period: str | None = Field(default=None, max_length=32)
    item_id: str | None = Field(default=None, max_length=64)


def router(settings, engine):
    routes = APIRouter(prefix="/v1/meals", tags=["Meals"])
    _auth = make_auth_dependency(settings, engine)

    @routes.post("", status_code=201)
    def log_meal(body: LogMealRequest, identity=Depends(_auth)):
        """
        Log a food entry for the authenticated user.

        meal_type="meal" counts as filling one pending plan slot (if a plan exists
        for this date). meal_type="snack" only affects the macro budget.
        """
        _, user = identity
        instant = _now()
        entry_id = str(uuid4())

        with Session(engine) as db, db.begin():
            entry = LoggedMeal(
                id           = entry_id,
                user_id      = user.id,
                service_date = body.service_date,
                meal_period  = body.meal_period,
                hall         = body.hall,
                meal_type    = body.meal_type,
                item_id      = body.item_id,
                item_name    = body.item_name,
                calories_kcal= body.calories_kcal,
                protein_g    = body.protein_g,
                carbs_g      = body.carbs_g,
                fat_g        = body.fat_g,
                source       = body.source,
                logged_at    = instant,
            )
            db.add(entry)

            if body.meal_type == "meal":
                planning.consume_next_pending_slot(user.id, body.service_date, db)

        return JSONResponse(
            {"id": entry_id, "logged_at": instant.isoformat()},
            status_code=201,
            headers={"Cache-Control": "no-store"},
        )

    return routes
