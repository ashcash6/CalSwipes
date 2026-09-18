from datetime import date, datetime
from enum import StrEnum
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, field_validator


# Canonical allergen and dietary tag names as they appear in Berkeley's XML feed.
KNOWN_ALLERGENS: frozenset[str] = frozenset({
    "Milk", "Egg", "Fish", "Shellfish", "Tree Nuts",
    "Wheat", "Peanuts", "Soybeans", "Gluten", "Alcohol", "Sesame", "Pork",
})
KNOWN_DIETARY: frozenset[str] = frozenset({
    "Vegan Option", "Vegetarian Option", "Halal", "Kosher",
})


class Hall(StrEnum):
    crossroads = "crossroads"
    cafe_3 = "cafe-3"
    foothill = "foothill"
    clark_kerr = "clark-kerr"
    golden_bear = "golden-bear"
    bear_market = "bear-market"
    cub_market = "cub-market"
    local_x_design = "local-x-design"
    the_den = "the-den"
    qualcomm_cafe = "qualcomm-cafe"
    gateway_cafe = "gateway-cafe"


class Meal(StrEnum):
    breakfast = "breakfast"
    lunch = "lunch"
    dinner = "dinner"
    late_night = "late-night"
    brunch = "brunch"
    all_day = "all-day"


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class Macros(StrictModel):
    calories_kcal: float = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)


class Serving(StrictModel):
    quantity: float = Field(gt=0)
    unit: str
    description: str | None = None
    weight_g: float | None = Field(default=None, gt=0)
    weight_basis: Literal["source_mass_unit", "unknown"]


class Item(StrictModel):
    id: str
    name: str
    categories: list[str]
    serving: Serving
    macros: Macros | None
    nutrition_status: Literal["published", "unapproved", "missing"]
    reference_image_url: str | None = None
    warnings: list[str] = Field(default_factory=list)
    allergens: list[str] = Field(default_factory=list)
    dietary_tags: list[str] = Field(default_factory=list)


class MenuContent(StrictModel):
    schema_version: Literal[1] = 1
    hall: Hall
    date: date
    meal: Meal
    status: Literal["published", "not_published"]
    source_meal_names: list[str]
    items: list[Item]


class MenuResponse(MenuContent):
    revision: str
    fetched_at: datetime
    expires_at: datetime
    source_url: str
    source_sha256: str


class ErrorDetail(BaseModel):
    code: str
    message: str


class DietaryProfile(BaseModel):
    model_config = ConfigDict(extra="forbid")
    allergies: list[str] = Field(default_factory=list)
    dietary_preferences: list[str] = Field(default_factory=list)

    @field_validator("allergies")
    @classmethod
    def validate_allergies(cls, v: list[str]) -> list[str]:
        for a in v:
            if a not in KNOWN_ALLERGENS:
                raise ValueError(f"Unknown allergen: {a!r}")
        return sorted(set(v))

    @field_validator("dietary_preferences")
    @classmethod
    def validate_dietary(cls, v: list[str]) -> list[str]:
        for d in v:
            if d not in KNOWN_DIETARY:
                raise ValueError(f"Unknown dietary preference: {d!r}")
        return sorted(set(v))


class DietaryProfileResponse(DietaryProfile):
    updated_at: datetime | None = None
