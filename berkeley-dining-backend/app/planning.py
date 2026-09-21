"""
Planning utilities: macro budget calculation, slot bookkeeping, and plan regeneration.
These functions are called by multiple routers and share no FastAPI-specific state.
"""
from datetime import date, datetime, timezone
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.db import LoggedMeal, PlannedDay, PlanSlot
from app import recommendation as rec


def _now() -> datetime:
    return datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# Budget helpers
# ---------------------------------------------------------------------------

def compute_remaining_budget(plan: PlannedDay, user_id: str, plan_date: date, db: Session) -> dict:
    """
    remaining = goals
                – sum(all logged_meals for user/date)
                – sum(accepted_macros on accepted plan slots)

    Both meal and snack entries count toward macro consumption.
    Accepted slot macros are subtracted to avoid double-counting plan picks
    that will be eaten but haven't been scanned/logged yet.
    Values are clamped to 0 so the budget never goes negative.
    """
    meals = db.scalars(select(LoggedMeal).where(
        LoggedMeal.user_id == user_id,
        LoggedMeal.service_date == plan_date,
    )).all()

    logged_cal  = sum(m.calories_kcal for m in meals)
    logged_pro  = sum(m.protein_g     for m in meals)
    logged_carb = sum(m.carbs_g       for m in meals)
    logged_fat  = sum(m.fat_g         for m in meals)

    accepted = db.scalars(select(PlanSlot).where(
        PlanSlot.plan_id == plan.id,
        PlanSlot.status  == "accepted",
    )).all()

    acc_cal  = sum((s.accepted_macros or {}).get("calories_kcal", 0) for s in accepted)
    acc_pro  = sum((s.accepted_macros or {}).get("protein_g",     0) for s in accepted)
    acc_carb = sum((s.accepted_macros or {}).get("carbs_g",       0) for s in accepted)
    acc_fat  = sum((s.accepted_macros or {}).get("fat_g",         0) for s in accepted)

    return {
        "calories_kcal": max(0.0, plan.goal_calories  - logged_cal  - acc_cal),
        "protein_g":     max(0.0, plan.goal_protein_g - logged_pro  - acc_pro),
        "carbs_g":       max(0.0, plan.goal_carbs_g   - logged_carb - acc_carb),
        "fat_g":         max(0.0, plan.goal_fat_g     - logged_fat  - acc_fat),
    }


def per_slot_target(budget: dict, pending_count: int) -> dict:
    """Divide remaining budget evenly across pending slots."""
    n = max(pending_count, 1)
    return {k: round(v / n, 2) for k, v in budget.items()}


# ---------------------------------------------------------------------------
# Slot bookkeeping
# ---------------------------------------------------------------------------

def consume_next_pending_slot(user_id: str, service_date: date, db: Session) -> None:
    """
    Called whenever a logged entry with meal_type="meal" is created.
    Finds the first pending plan slot (lowest slot_order) for the user's plan
    on that date and marks it "consumed_externally".

    Logged snacks never call this function — they affect only macro budget.
    If there is no plan or no pending slots, this is a no-op.
    """
    plan = db.scalar(select(PlannedDay).where(
        PlannedDay.user_id  == user_id,
        PlannedDay.plan_date == service_date,
    ))
    if plan is None:
        return

    slot = db.scalar(
        select(PlanSlot)
        .where(PlanSlot.plan_id == plan.id, PlanSlot.status == "pending")
        .order_by(PlanSlot.slot_order)
        .limit(1)
    )
    if slot is None:
        return

    slot.status = "consumed_externally"
    # No commit here — caller is responsible for committing the transaction


# ---------------------------------------------------------------------------
# Full plan regeneration
# ---------------------------------------------------------------------------

def regenerate_plan(plan: PlannedDay, user_id: str, plan_date: date, db: Session, engine) -> None:
    """
    Recalculates remaining macro budget and regenerates recommendations for every
    PENDING slot.  Accepted and consumed_externally slots are left untouched.
    Stores the computed budget on the plan for use by single-slot regeneration.
    Updates last_regenerated_at.
    """
    budget = compute_remaining_budget(plan, user_id, plan_date, db)
    plan.last_computed_budget = budget

    pending_slots = db.scalars(select(PlanSlot).where(
        PlanSlot.plan_id == plan.id,
        PlanSlot.status  == "pending",
    ).order_by(PlanSlot.slot_order)).all()

    pending_count = len(pending_slots)
    target = per_slot_target(budget, pending_count)

    for slot in pending_slots:
        slot.recommendations = rec.recommend(
            hall         = slot.hall,
            meal_period  = slot.meal_period,
            service_date = plan_date,
            target       = target,
            user_id      = user_id,
            engine       = engine,
        )

    plan.last_regenerated_at = _now()
    # No commit — caller owns the transaction


# ---------------------------------------------------------------------------
# Response serialisation
# ---------------------------------------------------------------------------

def slot_to_dict(slot: PlanSlot) -> dict:
    return {
        "id":                 slot.id,
        "slot_order":         slot.slot_order,
        "hall":               slot.hall,
        "meal_period":        slot.meal_period,
        "status":             slot.status,
        "recommendations":    slot.recommendations or [],
        "accepted_item_ids":  slot.accepted_item_ids,
        "accepted_macros":    slot.accepted_macros,
    }


def plan_to_dict(plan: PlannedDay, slots: list[PlanSlot]) -> dict:
    return {
        "id":                   plan.id,
        "plan_date":            str(plan.plan_date),
        "goal_calories":        plan.goal_calories,
        "goal_protein_g":       plan.goal_protein_g,
        "goal_carbs_g":         plan.goal_carbs_g,
        "goal_fat_g":           plan.goal_fat_g,
        "last_regenerated_at":  plan.last_regenerated_at,
        "last_computed_budget": plan.last_computed_budget,
        "confirmed_at":         plan.confirmed_at,
        "slots":                [slot_to_dict(s) for s in sorted(slots, key=lambda s: s.slot_order)],
    }
