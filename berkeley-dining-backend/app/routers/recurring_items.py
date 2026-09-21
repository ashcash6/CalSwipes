"""
/v1/recurring-items — user-saved food items with fixed macros for quick repeated logging.
All endpoints require a premium account.
"""
from datetime import date, datetime, timezone
from uuid import uuid4
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.auth import make_auth_dependency
from app.db import LoggedMeal, RecurringItem
from app import planning


def _now() -> datetime:
    return datetime.now(timezone.utc)


class RecurringItemBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=256)
    calories_kcal: float = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)


class LogRecurringRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    meal_type: str = Field(pattern=r"^(meal|snack)$")
    service_date: date | None = None  # defaults to today (UTC) when omitted


def _item_dict(item: RecurringItem) -> dict:
    return {
        "id":            item.id,
        "name":          item.name,
        "calories_kcal": item.calories_kcal,
        "protein_g":     item.protein_g,
        "carbs_g":       item.carbs_g,
        "fat_g":         item.fat_g,
        "created_at":    item.created_at.isoformat(),
    }


def router(settings, engine):
    routes = APIRouter(prefix="/v1/recurring-items", tags=["Recurring Items"])
    _auth = make_auth_dependency(settings, engine)

    def _premium(identity=Depends(_auth)):
        _, user = identity
        if not user.is_premium:
            raise HTTPException(402, "Recurring items require a Berkeley Plate Premium subscription")
        return identity

    @routes.get("")
    def list_items(identity=Depends(_premium)):
        """List all recurring items saved by the authenticated user."""
        _, user = identity
        with Session(engine) as db:
            items = db.scalars(
                select(RecurringItem)
                .where(RecurringItem.user_id == user.id)
                .order_by(RecurringItem.created_at)
            ).all()
        return JSONResponse(
            [_item_dict(i) for i in items],
            headers={"Cache-Control": "no-store"},
        )

    @routes.post("", status_code=201)
    def create_item(body: RecurringItemBody, identity=Depends(_premium)):
        """Save a new recurring item with fixed macros."""
        _, user = identity
        item_id = str(uuid4())
        instant = _now()
        with Session(engine) as db, db.begin():
            db.add(RecurringItem(
                id           = item_id,
                user_id      = user.id,
                name         = body.name,
                calories_kcal= body.calories_kcal,
                protein_g    = body.protein_g,
                carbs_g      = body.carbs_g,
                fat_g        = body.fat_g,
                created_at   = instant,
            ))
        return JSONResponse(
            {
                "id":            item_id,
                "name":          body.name,
                "calories_kcal": body.calories_kcal,
                "protein_g":     body.protein_g,
                "carbs_g":       body.carbs_g,
                "fat_g":         body.fat_g,
                "created_at":    instant.isoformat(),
            },
            status_code=201,
            headers={"Cache-Control": "no-store"},
        )

    @routes.delete("/{item_id}", status_code=204)
    def delete_item(item_id: str, identity=Depends(_premium)):
        """Delete a recurring item owned by the authenticated user."""
        _, user = identity
        with Session(engine) as db, db.begin():
            item = db.get(RecurringItem, item_id)
            if item is None or item.user_id != user.id:
                raise HTTPException(404, "Recurring item not found")
            db.delete(item)
        from fastapi.responses import Response
        return Response(status_code=204, headers={"Cache-Control": "no-store"})

    @routes.post("/{item_id}/log", status_code=201)
    def log_item(item_id: str, body: LogRecurringRequest, identity=Depends(_premium)):
        """
        Log a recurring item as a food entry.
        meal_type="meal" fills the next pending plan slot (if a plan exists for that date).
        meal_type="snack" only affects the macro budget.
        service_date defaults to today (UTC) when omitted.
        """
        _, user = identity
        instant = _now()
        service_date = body.service_date or instant.date()
        entry_id = str(uuid4())

        with Session(engine) as db, db.begin():
            item = db.get(RecurringItem, item_id)
            if item is None or item.user_id != user.id:
                raise HTTPException(404, "Recurring item not found")

            db.add(LoggedMeal(
                id           = entry_id,
                user_id      = user.id,
                service_date = service_date,
                meal_period  = None,
                hall         = None,
                meal_type    = body.meal_type,
                item_id      = item.id,
                item_name    = item.name,
                calories_kcal= item.calories_kcal,
                protein_g    = item.protein_g,
                carbs_g      = item.carbs_g,
                fat_g        = item.fat_g,
                source       = "recurring",
                logged_at    = instant,
            ))

            if body.meal_type == "meal":
                planning.consume_next_pending_slot(user.id, service_date, db)

        return JSONResponse(
            {"id": entry_id, "logged_at": instant.isoformat()},
            status_code=201,
            headers={"Cache-Control": "no-store"},
        )

    return routes
