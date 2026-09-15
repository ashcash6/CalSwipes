import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    database_url: str
    stale_hours: int = 36
    user_agent: str = "BerkeleyPlate/0.1 (public menu research)"
    apple_bundle_id: str = ""
    session_secret: str = ""

    @classmethod
    def from_env(cls):
        url = os.environ.get("DATABASE_URL", "")
        if not url.startswith("postgresql+psycopg://"):
            raise ValueError("DATABASE_URL must use postgresql+psycopg://")
        hours = int(os.environ.get("STALE_HOURS", "36"))
        if not 1 <= hours <= 36:
            raise ValueError("STALE_HOURS must be between 1 and 36")
        bundle = os.environ.get("APPLE_BUNDLE_ID", "")
        secret = os.environ.get("SESSION_SECRET", "")
        if bool(bundle) != bool(secret) or (secret and len(secret) < 32):
            raise ValueError("Set both APPLE_BUNDLE_ID and a random SESSION_SECRET of at least 32 characters")
        return cls(url, hours, os.environ.get("SCRAPER_USER_AGENT", cls.user_agent), bundle, secret)
