"""Cost controls for the public assistant proxy (POST /assistant/ask, /assistant/scan).

Pure Python (no FastAPI) so the rules are unit-testable on their own:

- Per-user daily caps: free 3 asks + 1 scan, premium 30 asks + 5 scans.
- PROMO_FREE_UNTIL=YYYY-MM-DD: until (and including) that date everyone gets premium caps.
- Per-IP daily cap: backstop against someone rotating device ids.
- Global daily spend cap (ASSISTANT_DAILY_SPEND_CAP_USD, default 1.00): once today's recorded
  Gemini spend reaches it, every new request gets a friendly "try again tomorrow".
- Response cache keyed by normalized question + hall + meal + date. Menus are the same
  for everyone on a given day, so a cached answer is correct for everyone. Cache hits are free:
  they don't count against caps and are served even when the spend cap is hit.

Days roll over at midnight America/Los_Angeles.
"""
import hashlib
import json
import os
import re
import threading
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

BERKELEY = ZoneInfo("America/Los_Angeles")
ASK, SCAN = "ask", "scan"


@dataclass(frozen=True)
class Limits:
    asks: int
    scans: int

    def for_kind(self, kind: str) -> int:
        return self.asks if kind == ASK else self.scans


FREE = Limits(asks=3, scans=1)
PREMIUM = Limits(asks=30, scans=5)

MESSAGES = {
    "spend_cap": "CalSwipes' AI assistant has hit its budget for today. Try again tomorrow! "
                 "Quick actions and meal plans still work offline.",
    "user_cap_free": "You've used today's free AI {kind}s. CalSwipes+ gets you more, or try again tomorrow.",
    "user_cap_premium": "You've used today's AI {kind}s. Your limit resets tomorrow.",
    "ip_cap": "Too many AI requests from this network today. Try again tomorrow.",
}


def berkeley_today(now: datetime | None = None) -> date:
    return (now or datetime.now(timezone.utc)).astimezone(BERKELEY).date()


@dataclass(frozen=True)
class AssistantConfig:
    agent_url: str = ""
    daily_spend_cap_usd: float = 1.0
    promo_free_until: date | None = None
    # Until StoreKit receipts are verified server-side, a client saying "I'm premium" is NOT trusted.
    trust_client_entitlement: bool = False
    cache_ttl_hours: int = 24
    ip_daily_cap: int = 200

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        promo = env.get("PROMO_FREE_UNTIL", "").strip()
        return cls(
            agent_url=env.get("ASSISTANT_AGENT_URL", "").rstrip("/"),
            daily_spend_cap_usd=float(env.get("ASSISTANT_DAILY_SPEND_CAP_USD", "1.0")),
            promo_free_until=date.fromisoformat(promo) if promo else None,
            trust_client_entitlement=env.get("TRUST_CLIENT_ENTITLEMENT", "0").lower() in ("1", "true", "yes"),
            cache_ttl_hours=int(env.get("ASSISTANT_CACHE_TTL_HOURS", "24")),
            ip_daily_cap=int(env.get("ASSISTANT_IP_DAILY_CAP", "200")),
        )


def promo_active(cfg: AssistantConfig, today: date) -> bool:
    return cfg.promo_free_until is not None and today <= cfg.promo_free_until


def tier_for(cfg: AssistantConfig, today: date, premium_claimed: bool, premium_verified: bool = False):
    """Returns ('promo' | 'premium' | 'free', Limits)."""
    if promo_active(cfg, today):
        return "promo", PREMIUM
    if premium_verified or (premium_claimed and cfg.trust_client_entitlement):
        return "premium", PREMIUM
    return "free", FREE


_PUNCT = re.compile(r"[^\w\s-]")
_SPACE = re.compile(r"\s+")


def normalize_question(q: str) -> str:
    """'  What's for LUNCH at Crossroads?? ' -> 'whats for lunch at crossroads'."""
    return _SPACE.sub(" ", _PUNCT.sub("", (q or "").lower().replace("’", "'"))).strip()


def cache_key(question: str, hall: str = "", meal: str = "", day: str = "") -> str:
    raw = "|".join([normalize_question(question), (hall or "").lower(), (meal or "").lower(), day or ""])
    return hashlib.sha256(raw.encode()).hexdigest()


# ------------------------------------------------------------------ stores

class MemoryUsageStore:
    """Single-process store for tests and local dev. Production uses SqlUsageStore."""

    def __init__(self):
        self._lock = threading.Lock()
        self.counts: dict = {}
        self.spend: dict = {}
        self.cache: dict = {}

    def increment_if_below(self, subject: str, day: date, kind: str, limit: int) -> int | None:
        with self._lock:
            k = (subject, day.isoformat(), kind)
            if self.counts.get(k, 0) >= limit:
                return None
            self.counts[k] = self.counts.get(k, 0) + 1
            return self.counts[k]

    def decrement(self, subject: str, day: date, kind: str):
        with self._lock:
            k = (subject, day.isoformat(), kind)
            self.counts[k] = max(0, self.counts.get(k, 0) - 1)

    def used(self, subject: str, day: date, kind: str) -> int:
        return self.counts.get((subject, day.isoformat(), kind), 0)

    def get_spend(self, day: date) -> float:
        return self.spend.get(day.isoformat(), 0.0)

    def add_spend(self, day: date, usd: float):
        with self._lock:
            self.spend[day.isoformat()] = self.spend.get(day.isoformat(), 0.0) + max(0.0, usd)

    def cache_get(self, key: str, now: datetime):
        hit = self.cache.get(key)
        return hit[1] if hit and hit[0] > now else None

    def cache_put(self, key: str, value: dict, expires: datetime):
        self.cache[key] = (expires, value)


class SqlUsageStore:
    """Postgres-backed store (tables from migration 0005_assistant). Works across Cloud Run instances."""

    def __init__(self, engine):
        from sqlalchemy import text  # imported lazily so this module stays importable without SQLAlchemy
        self.engine, self.text = engine, text

    def increment_if_below(self, subject, day, kind, limit):
        # Atomic: the conditional upsert only bumps the counter if it is still under the limit.
        with self.engine.begin() as c:
            row = c.execute(self.text(
                "INSERT INTO assistant_usage (subject, day, kind, count) VALUES (:s, :d, :k, 1) "
                "ON CONFLICT (subject, day, kind) DO UPDATE SET count = assistant_usage.count + 1 "
                "WHERE assistant_usage.count < :limit RETURNING count"),
                {"s": subject, "d": day, "k": kind, "limit": limit}).first()
        if row is None or row[0] > limit:
            return None
        return row[0]

    def decrement(self, subject, day, kind):
        with self.engine.begin() as c:
            c.execute(self.text("UPDATE assistant_usage SET count = GREATEST(count - 1, 0) "
                                "WHERE subject = :s AND day = :d AND kind = :k"), {"s": subject, "d": day, "k": kind})

    def used(self, subject, day, kind):
        with self.engine.connect() as c:
            v = c.execute(self.text("SELECT count FROM assistant_usage WHERE subject = :s AND day = :d AND kind = :k"),
                          {"s": subject, "d": day, "k": kind}).scalar()
        return v or 0

    def get_spend(self, day):
        with self.engine.connect() as c:
            v = c.execute(self.text("SELECT cost_usd FROM assistant_spend WHERE day = :d"), {"d": day}).scalar()
        return float(v or 0.0)

    def add_spend(self, day, usd):
        with self.engine.begin() as c:
            c.execute(self.text("INSERT INTO assistant_spend (day, cost_usd) VALUES (:d, :u) ON CONFLICT (day) "
                                "DO UPDATE SET cost_usd = assistant_spend.cost_usd + :u"), {"d": day, "u": max(0.0, usd)})

    def cache_get(self, key, now):
        with self.engine.connect() as c:
            v = c.execute(self.text("SELECT response FROM assistant_cache WHERE key = :k AND expires_at > :n"),
                          {"k": key, "n": now}).scalar()
        if v is None:
            return None
        return v if isinstance(v, dict) else json.loads(v)

    def cache_put(self, key, value, expires):
        with self.engine.begin() as c:
            c.execute(self.text("INSERT INTO assistant_cache (key, response, expires_at) VALUES (:k, CAST(:v AS JSONB), :e) "
                                "ON CONFLICT (key) DO UPDATE SET response = excluded.response, expires_at = excluded.expires_at"),
                      {"k": key, "v": json.dumps(value), "e": expires})


# ------------------------------------------------------------------ gate

@dataclass
class Decision:
    allowed: bool
    tier: str
    limit: int
    used: int
    reason: str = ""
    message: str = ""
    status: int = 200

    @property
    def remaining(self) -> int:
        return max(0, self.limit - self.used)


class AssistantGate:
    def __init__(self, cfg: AssistantConfig, store):
        self.cfg, self.store = cfg, store

    def spend_cap_reached(self, today: date) -> bool:
        return self.store.get_spend(today) >= self.cfg.daily_spend_cap_usd

    def reserve(self, kind: str, user: str, ip: str, premium_claimed: bool, today: date | None = None,
                premium_verified: bool = False) -> Decision:
        """Check caps and, if allowed, count this request. Call release() if the upstream call fails."""
        today = today or berkeley_today()
        tier, limits = tier_for(self.cfg, today, premium_claimed, premium_verified)
        limit = limits.for_kind(kind)
        if self.spend_cap_reached(today):
            return Decision(False, tier, limit, self.store.used(f"user:{user}", today, kind), "spend_cap",
                            MESSAGES["spend_cap"], 503)
        if self.store.increment_if_below(f"ip:{ip}", today, kind, self.cfg.ip_daily_cap) is None:
            return Decision(False, tier, limit, self.store.used(f"user:{user}", today, kind), "ip_cap",
                            MESSAGES["ip_cap"], 429)
        used = self.store.increment_if_below(f"user:{user}", today, kind, limit)
        if used is None:
            self.store.decrement(f"ip:{ip}", today, kind)
            key = "user_cap_free" if tier == "free" else "user_cap_premium"
            return Decision(False, tier, limit, limit, "user_cap", MESSAGES[key].format(kind=kind), 429)
        return Decision(True, tier, limit, used)

    def release(self, kind: str, user: str, ip: str, today: date | None = None):
        today = today or berkeley_today()
        self.store.decrement(f"user:{user}", today, kind)
        self.store.decrement(f"ip:{ip}", today, kind)

    def record_cost(self, usd: float, today: date | None = None):
        self.store.add_spend(today or berkeley_today(), float(usd or 0.0))

    # cache (asks only; scans are per-photo so never cached)
    def cached(self, question, hall, meal, day, now: datetime | None = None):
        return self.store.cache_get(cache_key(question, hall, meal, day), now or datetime.now(timezone.utc))

    def remember(self, question, hall, meal, day, response: dict, now: datetime | None = None):
        now = now or datetime.now(timezone.utc)
        self.store.cache_put(cache_key(question, hall, meal, day), response,
                             now + timedelta(hours=self.cfg.cache_ttl_hours))
