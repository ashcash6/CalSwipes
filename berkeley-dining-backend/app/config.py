import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    database_url: str
    stale_hours: int = 36
    user_agent: str = "BerkeleyPlate/0.1 (public menu research)"
    gemini_api_key: str = ""

    @classmethod
    def from_env(cls):
        url = os.environ.get("DATABASE_URL", "")
        if not url.startswith("postgresql+psycopg://"):
            raise ValueError("DATABASE_URL must use postgresql+psycopg://")
        hours = int(os.environ.get("STALE_HOURS", "36"))
        if not 1 <= hours <= 36:
            raise ValueError("STALE_HOURS must be between 1 and 36")
        return cls(url, hours, os.environ.get("SCRAPER_USER_AGENT", cls.user_agent),
                   os.environ.get("GEMINI_API_KEY", ""))
