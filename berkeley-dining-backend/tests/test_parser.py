from datetime import date
from pathlib import Path
import pytest
from app.parser import SourceError, parse_xml
from app.schemas import Hall, Meal

DAY = date(2026, 9, 14)
FIXTURES = Path(__file__).parent / "fixtures"


@pytest.mark.parametrize("hall,expected", [(Hall.crossroads,158),(Hall.cafe_3,147),(Hall.foothill,90),(Hall.clark_kerr,141)])
def test_real_feed(hall, expected):
    menus = parse_xml((FIXTURES / f"{hall.value}.xml").read_bytes(), hall, DAY)
    assert sum(len(m.items) for m in menus) == expected
    assert next(m for m in menus if m.meal == Meal.late_night).status == "not_published"
    assert all(i.serving.weight_g > 0 for m in menus for i in m.items)


def raw():
    return (FIXTURES / "foothill.xml").read_bytes()


@pytest.mark.parametrize("data", [b"<html>Down</html>", b"<EatecExchange/>",
    b'<!DOCTYPE a [<!ENTITY x SYSTEM "file:///etc/passwd">]><EatecExchange>&x;</EatecExchange>'])
def test_invalid_feed(data):
    with pytest.raises(SourceError):
        parse_xml(data, Hall.foothill, DAY)


def test_wrong_date_and_hall():
    with pytest.raises(SourceError):
        parse_xml(raw(), Hall.foothill, date(2026,9,15))
    with pytest.raises(SourceError):
        parse_xml(raw(), Hall.cafe_3, DAY)


def test_unknown_units_never_become_mass():
    menus = parse_xml(raw().replace(b'servingSizeUnit="oz"', b'servingSizeUnit="fl oz"'), Hall.foothill, DAY)
    assert all(i.serving.weight_g is None for m in menus for i in m.items)


def test_known_conversion():
    item = parse_xml(raw(), Hall.foothill, DAY)[0].items[0]
    assert item.serving.weight_g == pytest.approx(item.serving.quantity * 28.349523125)


def test_missing_header_rejects_whole_hall():
    with pytest.raises(SourceError):
        parse_xml(raw().replace(b'Protein (g)', b'Protein changed'), Hall.foothill, DAY)


def test_unapproved_nutrition_is_not_zero():
    menus = parse_xml(raw().replace(b'approvedNutrition="Yes"', b'approvedNutrition="No"'), Hall.foothill, DAY)
    assert all(i.macros is None and i.nutrition_status == "unapproved" for m in menus for i in m.items)


def test_unknown_period_rejected():
    with pytest.raises(SourceError):
        parse_xml(raw().replace(b'Fall - Breakfast', b'Fall - Snack'), Hall.foothill, DAY)


def test_negative_and_nonfinite_macros_rejected():
    for value in (b'-1', b'NaN', b'Infinity'):
        with pytest.raises(SourceError):
            parse_xml(raw().replace(b'nutrients="173.18|', b'nutrients="'+value+b'|'), Hall.foothill, DAY)
