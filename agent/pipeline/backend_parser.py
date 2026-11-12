"""Reuse the CalSwipes backend's Eatec XML parser directly (no copy).

The backend lives at ../berkeley-dining-backend (package `app`). In the agent
Docker image only app/parser.py and app/schemas.py are copied in, at the path
given by CALSWIPES_BACKEND_DIR. The parser only needs pydantic + defusedxml.
"""
import os
import sys
from pathlib import Path

BACKEND_DIR = Path(os.environ.get("CALSWIPES_BACKEND_DIR",
                                  Path(__file__).resolve().parents[2] / "berkeley-dining-backend"))
FIXTURES_DIR = BACKEND_DIR / "tests" / "fixtures"

if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from app.parser import HALLS, SourceError, meal_name, parse_xml  # noqa: E402
from app.schemas import Hall, Meal  # noqa: E402

__all__ = ["HALLS", "SourceError", "meal_name", "parse_xml", "Hall", "Meal", "BACKEND_DIR", "FIXTURES_DIR"]
