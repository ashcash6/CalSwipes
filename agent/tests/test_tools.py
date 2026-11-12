import pytest

from agents import tools


def test_search_menu_excludes_allergens(store):
    out = tools.search_menu(hall="crossroads", meal="lunch", exclude_allergens=["Sesame", "soy"], limit=500)
    assert out["count"] > 0
    assert all("Sesame" not in i["allergens"] and "Soybeans" not in i["allergens"] for i in out["items"])


def test_search_menu_dietary_and_query(store):
    out = tools.search_menu(hall="crossroads", meal="lunch", query="tofu", dietary_tag="Vegan Option")
    assert {i["item"] for i in out["items"]} == {"Paprika Rosemary Tofu", "Fried Sweet and Sour Tofu",
                                                 "Baked Lemongrass Tofu"}


def test_get_nutrition_exact_values(store):
    m = tools.get_nutrition("Scrambled Eggs", hall="cafe-3")["matches"][0]
    assert m["item"] == "Scrambled Eggs"
    assert m["protein_g"] == pytest.approx(13.92)
    assert m["allergens"] == ["Egg"]


def test_get_nutrition_missing_item(store):
    assert tools.get_nutrition("Unicorn Steak")["matches"] == []


def test_meal_hours(store):
    meals = tools.get_meal_hours("foothill")["meals"]
    assert {(m["period"], m["start_time"], m["end_time"]) for m in meals} >= {("dinner", "16:30", "21:00")}


def test_plan_meal_hits_target_and_respects_allergens(store):
    out = tools.plan_meal("crossroads", 700, 40, meal="lunch", exclude_allergens=["Milk"])
    assert out["combos"]
    best = out["combos"][0]
    assert abs(best["totals"]["calories_kcal"] - 700) <= 0.15 * 700
    assert all("Milk" not in i["allergens"] for c in out["combos"] for i in c["items"])
    assert 1 <= len(best["items"]) <= 3


def test_plan_meal_totals_are_sums(store):
    c = tools.plan_meal("cafe-3", 600, 30, meal="dinner")["combos"][0]
    assert c["totals"]["calories_kcal"] == pytest.approx(sum(i["calories_kcal"] for i in c["items"]), abs=0.1)


def test_search_dining_info_returns_citations(store):
    res = tools.search_dining_info("cross-contact shared kitchens allergen")["results"]
    assert res[0]["doc_id"] == "allergen-policy"
    assert res[0]["citation"].startswith("[allergen-policy#")
    assert res[0]["is_sample"] is True


def test_tools_have_docstrings_for_adk():
    for fn in tools.MENU_TOOLS + tools.POLICY_TOOLS + tools.NUTRITION_TOOLS:
        assert fn.__doc__ and "Args" in fn.__doc__ or fn is tools.run_menu_sql
        assert fn.__wrapped__  # functools.wraps keeps the real signature for schema generation
