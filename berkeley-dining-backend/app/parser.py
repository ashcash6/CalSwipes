"""Adapter for Berkeley's public EatecExchange XML; never infer absent nutrition."""
import logging
import re
from datetime import date
from decimal import Decimal, InvalidOperation
from defusedxml import ElementTree
from app.schemas import Hall, Item, Macros, Meal, MenuContent, Serving

log = logging.getLogger("berkeley.parser")

HALLS = {
    Hall.crossroads:     ("Crossroads",       "Crossroads"),
    Hall.cafe_3:         ("Cafe_3",            "Cafe 3"),
    Hall.foothill:       ("Foothill",          "Foothill"),
    Hall.clark_kerr:     ("Clark_Kerr_Campus", "Clark Kerr Campus"),
    Hall.golden_bear:    ("Golden_Bear_Cafe",  "Golden Bear Café"),
    Hall.bear_market:    ("Bear_Market",       "Bear Market"),
    Hall.cub_market:     ("Cub_Market",        "Cub Market"),
    Hall.local_x_design: ("Local_x_Design",    "Local x Design"),
    Hall.the_den:        ("Den",               "Den"),
    Hall.qualcomm_cafe:  ("Qualcomm_Cafe",     "Qualcomm Café"),
    Hall.gateway_cafe:   ("Gateway_Cafe",      "Gateway Café"),
}
NUTRIENTS = {
    "Calories (kcal)": "calories_kcal", "Protein (g)": "protein_g",
    "Carbohydrate (g)": "carbs_g", "Total Lipid/Fat (g)": "fat_g",
}
MASS_FACTORS = {"g": Decimal(1), "gram": Decimal(1), "grams": Decimal(1),
                "oz": Decimal("28.349523125"), "lb": Decimal("453.59237"),
                "kg": Decimal(1000)}


class SourceError(ValueError):
    pass


def number(value: str, label: str, positive=False) -> float:
    try:
        n = Decimal(value)
        if not n.is_finite() or n < 0 or (positive and n == 0):
            raise InvalidOperation
        return float(n)
    except (InvalidOperation, ValueError):
        raise SourceError(f"Invalid {label}: {value!r}") from None


def meal_name(label: str) -> Meal:
    normalized = re.sub(r"[-_]+", " ", label.lower())
    matches = [m for m in Meal if re.search(r"\b" + m.value.replace("-", r"\s+") + r"\b", normalized)]
    if len(matches) != 1:
        raise SourceError(f"Unrecognized meal period: {label!r}")
    return matches[0]


def parse_xml(raw: bytes, hall: Hall, day: date) -> list[MenuContent]:
    try:
        root = ElementTree.fromstring(raw)
    except Exception as exc:
        raise SourceError("Invalid or unsafe XML") from exc
    if root.tag != "EatecExchange" or not root.findall("menu"):
        raise SourceError("Expected nonempty EatecExchange; empty feed is not a closure")
    groups = {m: {} for m in Meal}
    labels = {m: [] for m in Meal}
    for menu in root.findall("menu"):
        if menu.get("location") != HALLS[hall][1] or menu.get("servedate") != day.strftime("%Y%m%d"):
            raise SourceError("Feed hall/date does not match requested hall/date")
        label = menu.get("mealperiodname", "")
        meal = meal_name(label)
        labels[meal].append(label)
        headers = (menu.findtext("nutrients") or "").strip("|").split("|")
        if len(headers) != len(set(headers)) or not set(NUTRIENTS).issubset(headers):
            raise SourceError("Required nutrient headers missing or duplicated")
        recipes = menu.findall("./recipes/recipe")
        if not recipes:
            raise SourceError("Empty published meal; cannot distinguish closure from source failure")
        for recipe in recipes:
            a = recipe.attrib
            rid, name = a.get("id"), (a.get("shortName") or a.get("description", "")).strip()
            if not rid or not name:
                raise SourceError("Recipe ID/name missing")
            quantity = number(a.get("servingSize", ""), "serving size", positive=True)
            unit = a.get("servingSizeUnit", "").strip()
            if not unit:
                raise SourceError("Serving unit missing")
            factor = MASS_FACTORS.get(unit.lower())
            weight = float(Decimal(a["servingSize"]) * factor) if factor else None
            values = a.get("nutrients", "").strip("|").split("|")
            if len(values) != len(headers):
                raise SourceError("Nutrient/value column count changed")
            selected = {target: values[headers.index(source)].strip() for source, target in NUTRIENTS.items()}
            approved = a.get("approvedNutrition", "").lower() == "yes"
            status = "unapproved" if not approved else "missing" if not all(selected.values()) else "published"
            macros = Macros(**{k: number(v, k) for k, v in selected.items()}) if status == "published" else None
            warnings = [] if weight is not None else ["serving_weight_unknown"]
            if status != "published":
                warnings.append("nutrition_unavailable")
            item = Item(id=rid, name=name, categories=[a.get("category", "").strip()],
                        serving=Serving(quantity=quantity, unit=unit, description=a.get("servingDescription"),
                                        weight_g=weight, weight_basis="source_mass_unit" if factor else "unknown"),
                        macros=macros, nutrition_status=status, warnings=warnings)
            existing = groups[meal].get(rid)
            if existing:
                all_categories = sorted(set(existing.categories + item.categories))
                if existing.model_dump(exclude={"categories"}) != item.model_dump(exclude={"categories"}):
                    log.warning("duplicate_recipe_conflict hall=%s meal=%s id=%s name=%r; keeping last occurrence",
                                hall.value, meal.value, rid, name)
                    item.categories = all_categories
                    groups[meal][rid] = item
                else:
                    existing.categories = all_categories
            else:
                groups[meal][rid] = item
    return [MenuContent(hall=hall, date=day, meal=m,
                        status="published" if labels[m] else "not_published",
                        source_meal_names=sorted(set(labels[m])),
                        items=sorted(groups[m].values(), key=lambda i: i.id)) for m in Meal]
