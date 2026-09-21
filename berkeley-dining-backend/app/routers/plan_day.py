"""
/v1/plan-day — full-day adaptive meal planning.
"""
from datetime import date, datetime, timezone
from uuid import uuid4
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import delete, select
from sqlalchemy.orm import Session
from app.auth import make_auth_dependency
from app.db import LoggedMeal, PlannedDay, PlanSlot
from app import planning, recommendation as rec


def _now() -> datetime:
    return datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# Request / response schemas
# ---------------------------------------------------------------------------

class SlotInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    hall: str = Field(min_length=1, max_length=32)
    meal_period: str | None = Field(default=None, max_length=32)


class CreatePlanRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    date: date
    goal_calories: float = Field(gt=0)
    goal_protein_g: float = Field(ge=0)
    goal_carbs_g: float = Field(ge=0)
    goal_fat_g: float = Field(ge=0)
    slots: list[SlotInput] = Field(min_length=1, max_length=10)


class AcceptSlotRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    item_id: str = Field(min_length=1, max_length=64)
    item_name: str = Field(min_length=1, max_length=256)
    macros: dict  # {calories_kcal, protein_g, carbs_g, fat_g}


class ConfirmPlanRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    date: date


# ---------------------------------------------------------------------------
# Router factory
# ---------------------------------------------------------------------------

def router(settings, engine):
    routes = APIRouter(prefix="/v1/plan-day", tags=["Plan My Day"])
    _auth = make_auth_dependency(settings, engine)

    # ------------------------------------------------------------------
    # POST /v1/plan-day  — create (or replace) a day plan
    # ------------------------------------------------------------------
    @routes.post("", status_code=201)
    def create_plan(body: CreatePlanRequest, identity=Depends(_auth)):
        """
        Create a meal plan for a date.  If a plan already exists for this
        user+date it is replaced (all slots are discarded).

        meal_period in each slot is optional; when omitted the server auto-assigns
        it from the published menu for that hall/date (positional fallback if
        no menu data exists yet).

        Recommendations are generated client-side using the returned
        last_computed_budget and menu data already cached on device.
        """
        _, user = identity
        instant = _now()
        plan_id = str(uuid4())

        with Session(engine) as db, db.begin():
            # Delete any existing plan for this user+date (cascades to plan_slots)
            existing = db.scalar(select(PlannedDay).where(
                PlannedDay.user_id  == user.id,
                PlannedDay.plan_date == body.date,
            ))
            if existing:
                db.execute(delete(PlanSlot).where(PlanSlot.plan_id == existing.id))
                db.delete(existing)
                db.flush()

            plan = PlannedDay(
                id                  = plan_id,
                user_id             = user.id,
                plan_date           = body.date,
                goal_calories       = body.goal_calories,
                goal_protein_g      = body.goal_protein_g,
                goal_carbs_g        = body.goal_carbs_g,
                goal_fat_g          = body.goal_fat_g,
                last_regenerated_at = None,
                last_computed_budget= None,
                confirmed_at        = None,
                created_at          = instant,
            )
            db.add(plan)
            db.flush()

            slots = []
            for i, s in enumerate(body.slots):
                meal_period = s.meal_period or rec.auto_assign_meal_period(
                    s.hall, body.date, i, engine
                )
                slot = PlanSlot(
                    id          = str(uuid4()),
                    plan_id     = plan_id,
                    slot_order  = i,
                    hall        = s.hall,
                    meal_period = meal_period,
                    status      = "pending",
                    created_at  = instant,
                )
                db.add(slot)
                slots.append(slot)

            db.flush()

            # Compute budget for client-side recommendation scoring
            budget = planning.compute_remaining_budget(plan, user.id, body.date, db)
            plan.last_computed_budget = budget
            plan.last_regenerated_at  = _now()

        return JSONResponse(
            planning.plan_to_dict(plan, slots),
            status_code=201,
            headers={"Cache-Control": "no-store"},
        )

    # ------------------------------------------------------------------
    # GET /v1/plan-day?date=  — fetch plan with budget refresh
    # ------------------------------------------------------------------
    @routes.get("")
    def get_plan(plan_date: date = Query(alias="date"), identity=Depends(_auth)):
        """
        Fetch the plan for a date.

        When new logged entries exist since last_regenerated_at the budget is
        recomputed and stored so the client can re-score recommendations locally
        without another round-trip.  Accepted/consumed slots are untouched.
        """
        _, user = identity

        with Session(engine) as db, db.begin():
            plan = db.scalar(select(PlannedDay).where(
                PlannedDay.user_id  == user.id,
                PlannedDay.plan_date == plan_date,
            ))
            if plan is None:
                raise HTTPException(404, "No plan found for this date")

            # Refresh budget when new meals have been logged
            needs_refresh = True
            if plan.last_regenerated_at is not None:
                newer = db.scalar(
                    select(LoggedMeal.id).where(
                        LoggedMeal.user_id      == user.id,
                        LoggedMeal.service_date == plan_date,
                        LoggedMeal.logged_at    > plan.last_regenerated_at,
                    ).limit(1)
                )
                needs_refresh = newer is not None

            if needs_refresh:
                budget = planning.compute_remaining_budget(plan, user.id, plan_date, db)
                plan.last_computed_budget = budget
                plan.last_regenerated_at  = _now()

            slots = db.scalars(select(PlanSlot).where(
                PlanSlot.plan_id == plan.id
            ).order_by(PlanSlot.slot_order)).all()

            result = planning.plan_to_dict(plan, list(slots))

        return JSONResponse(result, headers={"Cache-Control": "no-store"})

    # ------------------------------------------------------------------
    # POST /v1/plan-day/slots/{slot_id}/accept
    # ------------------------------------------------------------------
    @routes.post("/slots/{slot_id}/accept")
    def accept_slot(slot_id: str, body: AcceptSlotRequest, identity=Depends(_auth)):
        """
        Accept a recommendation for a pending slot.
        The chosen item's macros are stored on the slot and are subtracted
        from the remaining budget on the next GET call.
        """
        _, user = identity

        with Session(engine) as db, db.begin():
            slot, _ = _require_pending_slot(slot_id, user.id, db)

            slot.status            = "accepted"
            slot.accepted_item_ids = [body.item_id]
            slot.accepted_macros   = {
                "calories_kcal": body.macros.get("calories_kcal", 0),
                "protein_g":     body.macros.get("protein_g",     0),
                "carbs_g":       body.macros.get("carbs_g",       0),
                "fat_g":         body.macros.get("fat_g",         0),
            }

        return JSONResponse(planning.slot_to_dict(slot), headers={"Cache-Control": "no-store"})

    # ------------------------------------------------------------------
    # POST /v1/plan-day/confirm
    # ------------------------------------------------------------------
    @routes.post("/confirm")
    def confirm_plan(body: ConfirmPlanRequest, identity=Depends(_auth)):
        """Lock in the plan for a date."""
        _, user = identity
        instant = _now()

        with Session(engine) as db, db.begin():
            plan = db.scalar(select(PlannedDay).where(
                PlannedDay.user_id  == user.id,
                PlannedDay.plan_date == body.date,
            ))
            if plan is None:
                raise HTTPException(404, "No plan found for this date")
            if plan.confirmed_at is not None:
                raise HTTPException(409, "Plan for this date is already confirmed")

            plan.confirmed_at = instant

        return JSONResponse(
            {"confirmed_at": instant.isoformat()},
            headers={"Cache-Control": "no-store"},
        )

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _require_pending_slot(slot_id: str, user_id: str, db: Session):
        slot = db.get(PlanSlot, slot_id)
        if slot is None:
            raise HTTPException(404, "Slot not found")
        plan = db.get(PlannedDay, slot.plan_id)
        if plan is None or plan.user_id != user_id:
            raise HTTPException(404, "Slot not found")
        if slot.status != "pending":
            raise HTTPException(409, f"Slot is already '{slot.status}' and cannot be modified")
        return slot, plan

    return routes
