"""Recommendation engine: given a per-slot macro target, score and rank menu items."""
from datetime import date
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.db import MenuSnapshot, UserDietaryProfile

# Canonical ordering used to sort available meal periods
_MEAL_ORDER = ["breakfast", "brunch", "lunch", "all-day", "dinner", "late-night"]


def _meal_rank(meal_period: str) -> int:
    try:
        return _MEAL_ORDER.index(meal_period)
    except ValueError:
        return len(_MEAL_ORDER)


def _score(item: dict, target: dict, preferred_tags: set[str]) -> float:
    """
    Score how well an item fits a macro target.
    - Calorie match (60%) and protein match (40%) form the base score.
    - Items matching at least one dietary preference tag get a 10% boost.
    Both dimensions are penalised linearly by the percentage deviation from
    the target value; a perfect match scores 1.0 on that dimension.
    """
    m = item["macros"]
    target_cal = target.get("calories_kcal") or 1.0
    target_pro = target.get("protein_g") or 1.0

    cal_diff = abs(m["calories_kcal"] - target["calories_kcal"]) / target_cal
    pro_diff = abs(m["protein_g"] - target["protein_g"]) / target_pro

    cal_score = max(0.0, 1.0 - cal_diff)
    pro_score = max(0.0, 1.0 - pro_diff)

    base = cal_score * 0.6 + pro_score * 0.4
    boost = 1.1 if preferred_tags and preferred_tags.intersection(item.get("dietary_tags", [])) else 1.0
    return round(base * boost, 4)


def recommend(
    hall: str,
    meal_period: str,
    service_date: date,
    target: dict,
    user_id: str,
    engine,
    *,
    exclude_ids: list[str] | None = None,
    top_n: int = 3,
) -> list[dict]:
    """
    Return up to *top_n* recommended menu items for a slot.

    Args:
        hall: dining hall identifier (e.g. "crossroads")
        meal_period: meal period (e.g. "lunch")
        service_date: the calendar date of the meal
        target: per-slot macro budget dict with keys
                calories_kcal, protein_g, carbs_g, fat_g
        user_id: requesting user's id (used for allergen/preference lookup)
        engine: SQLAlchemy engine
        exclude_ids: item ids to exclude (user has already rejected these)
        top_n: number of recommendations to return (default 3)

    Returns:
        List of dicts, each with item_id, item_name, macros, categories, score.
        Empty list if the hall/date/meal has no published menu or no suitable items.
    """
    exclude = set(exclude_ids or [])

    with Session(engine) as db:
        snapshot = db.scalar(select(MenuSnapshot).where(
            MenuSnapshot.hall == hall,
            MenuSnapshot.service_date == service_date,
            MenuSnapshot.meal == meal_period,
        ))
        profile = db.get(UserDietaryProfile, user_id)

    if snapshot is None:
        return []

    blocked_allergens: set[str] = set(profile.allergies) if profile else set()
    preferred_tags: set[str] = set(profile.dietary_preferences) if profile else set()

    candidates = []
    for item in snapshot.content.get("items", []):
        if not item.get("macros"):
            continue
        if item["id"] in exclude:
            continue
        # Hard-exclude items containing any of the user's blocked allergens
        if blocked_allergens and blocked_allergens.intersection(item.get("allergens", [])):
            continue
        candidates.append(item)

    if not candidates:
        return []

    ranked = sorted(candidates, key=lambda i: _score(i, target, preferred_tags), reverse=True)

    return [
        {
            "item_id": i["id"],
            "item_name": i["name"],
            "macros": i["macros"],
            "categories": i.get("categories", []),
            "score": _score(i, target, preferred_tags),
        }
        for i in ranked[:top_n]
    ]


def auto_assign_meal_period(hall: str, plan_date: date, slot_index: int, engine) -> str:
    """
    Pick a meal period for a slot that has none specified.
    Looks up available published menus for the hall/date and returns the
    Nth available period (by canonical meal ordering).  Falls back to a
    positional default when no menu data exists.
    """
    fallback = ["breakfast", "lunch", "dinner"]

    with Session(engine) as db:
        available = db.execute(
            select(MenuSnapshot.meal).where(
                MenuSnapshot.hall == hall,
                MenuSnapshot.service_date == plan_date,
                MenuSnapshot.content["status"].as_string() == "published",
            )
        ).scalars().all()

    if available:
        sorted_meals = sorted(available, key=_meal_rank)
        return sorted_meals[min(slot_index, len(sorted_meals) - 1)]

    return fallback[min(slot_index, len(fallback) - 1)]
