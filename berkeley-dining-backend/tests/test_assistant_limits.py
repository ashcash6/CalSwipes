"""Offline tests for assistant cost controls (no FastAPI/Postgres needed)."""
from datetime import date, datetime, timedelta, timezone

import pytest

from app.assistant_limits import (ASK, FREE, PREMIUM, SCAN, AssistantConfig, AssistantGate, MemoryUsageStore,
                                  berkeley_today, cache_key, normalize_question, tier_for)

DAY = date(2026, 11, 20)


def gate(**cfg):
    return AssistantGate(AssistantConfig(**cfg), MemoryUsageStore())


def take(g, kind, n, user="device-aaaaaaaaaaaaaaaa", ip="1.2.3.4", premium=False, day=DAY):
    return [g.reserve(kind, user, ip, premium, today=day) for _ in range(n)]


def test_free_caps():
    g = gate()
    asks = take(g, ASK, 4)
    assert [d.allowed for d in asks] == [True, True, True, False]
    assert asks[-1].status == 429 and asks[-1].reason == "user_cap" and "CalSwipes+" in asks[-1].message
    assert [d.allowed for d in take(g, SCAN, 2)] == [True, False]


def test_caps_are_per_user_and_reset_daily():
    g = gate()
    take(g, ASK, 3)
    assert take(g, ASK, 1, user="device-bbbbbbbbbbbbbbbb")[0].allowed
    assert take(g, ASK, 1, day=DAY + timedelta(days=1))[0].allowed


def test_premium_claim_ignored_unless_trusted():
    assert tier_for(AssistantConfig(), DAY, premium_claimed=True) == ("free", FREE)
    assert tier_for(AssistantConfig(trust_client_entitlement=True), DAY, True) == ("premium", PREMIUM)
    assert tier_for(AssistantConfig(), DAY, False, premium_verified=True) == ("premium", PREMIUM)


def test_premium_caps():
    g = gate(trust_client_entitlement=True)
    assert sum(d.allowed for d in take(g, ASK, 31, premium=True)) == 30
    assert sum(d.allowed for d in take(g, SCAN, 6, premium=True)) == 5


def test_promo_gives_everyone_premium_through_the_end_date():
    cfg = AssistantConfig(promo_free_until=DAY)
    assert tier_for(cfg, DAY, False) == ("promo", PREMIUM)
    assert tier_for(cfg, DAY + timedelta(days=1), False) == ("free", FREE)
    g = AssistantGate(cfg, MemoryUsageStore())
    assert sum(d.allowed for d in take(g, ASK, 31)) == 30


def test_promo_from_env():
    cfg = AssistantConfig.from_env({"PROMO_FREE_UNTIL": "2026-12-31", "ASSISTANT_AGENT_URL": "https://a.run.app/"})
    assert cfg.promo_free_until == date(2026, 12, 31) and cfg.agent_url == "https://a.run.app"


def test_default_spend_cap_is_one_dollar():
    assert AssistantConfig().daily_spend_cap_usd == 1.0
    assert AssistantConfig.from_env({}).daily_spend_cap_usd == 1.0


def test_spend_cap_kill_switch():
    g = gate(daily_spend_cap_usd=1.0)
    g.record_cost(0.6, today=DAY)
    assert take(g, ASK, 1)[0].allowed
    g.record_cost(0.4, today=DAY)
    d = take(g, ASK, 1, user="device-cccccccccccccccc")[0]
    assert not d.allowed and d.status == 503 and d.reason == "spend_cap" and "tomorrow" in d.message
    assert take(g, ASK, 1, day=DAY + timedelta(days=1))[0].allowed  # new day, new budget


def test_release_refunds_failed_upstream_call():
    g = gate()
    take(g, SCAN, 1)
    g.release(SCAN, "device-aaaaaaaaaaaaaaaa", "1.2.3.4", today=DAY)
    assert take(g, SCAN, 1)[0].allowed


def test_ip_cap_stops_device_id_rotation():
    g = gate(ip_daily_cap=5)
    allowed = [g.reserve(ASK, f"device-{i:016d}", "9.9.9.9", False, today=DAY).allowed for i in range(7)]
    assert allowed == [True] * 5 + [False] * 2


def test_cache_key_normalization():
    assert normalize_question("  What's for LUNCH at Crossroads?? ") == "whats for lunch at crossroads"
    a = cache_key("What's for lunch?", "crossroads", "lunch", "2026-11-20")
    assert a == cache_key("whats   for LUNCH", "Crossroads", "LUNCH", "2026-11-20")
    assert a != cache_key("What's for lunch?", "crossroads", "lunch", "2026-11-21")
    assert a != cache_key("What's for lunch?", "foothill", "lunch", "2026-11-20")


def test_cache_roundtrip_and_expiry():
    g = gate(cache_ttl_hours=1)
    now = datetime(2026, 11, 20, 18, tzinfo=timezone.utc)
    g.remember("Q?", "crossroads", "lunch", "2026-11-20", {"answer": "A"}, now=now)
    assert g.cached("q", "crossroads", "lunch", "2026-11-20", now=now) == {"answer": "A"}
    assert g.cached("q", "crossroads", "lunch", "2026-11-20", now=now + timedelta(hours=2)) is None


def test_berkeley_day_rollover():
    # 07:30 UTC on Nov 21 is still Nov 20 in Berkeley (PST, UTC-8).
    assert berkeley_today(datetime(2026, 11, 21, 7, 30, tzinfo=timezone.utc)) == date(2026, 11, 20)
