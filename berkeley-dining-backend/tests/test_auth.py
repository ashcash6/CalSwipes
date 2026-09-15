import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from sqlalchemy import func, select, text, update
from app.auth import APPLE_ISSUER, AppleVerifier
from app.config import Settings
from app.db import AuthChallenge, AuthSession, User, make_engine
from app.main import create_app

BUNDLE = "edu.example.BerkeleyPlate"
SECRET = "a-test-only-session-secret-with-48-randomish-chars"


@pytest.fixture(scope="module")
def key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture
def auth(key):
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL required for authentication tests")
    engine = make_engine(url)
    with engine.begin() as c:
        c.execute(text("TRUNCATE users, auth_sessions, auth_challenges, auth_rate_buckets CASCADE"))
    class Keys:
        def get_signing_key_from_jwt(self, token):
            return SimpleNamespace(key=key.public_key(), algorithm_name="RS256")
    verifier = AppleVerifier(BUNDLE, Keys())
    settings = Settings(url, apple_bundle_id=BUNDLE, session_secret=SECRET)
    with TestClient(create_app(settings, engine, verifier)) as client:
        yield client, engine
    engine.dispose()


def token(key, nonce, **overrides):
    instant = datetime.now(timezone.utc)
    claims = {"iss": APPLE_ISSUER, "aud": BUNDLE, "sub": "apple-user-123", "iat": instant,
              "exp": instant+timedelta(minutes=5), "nonce": nonce}
    claims.update(overrides)
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid":"test-key"})


def login(client, key):
    challenge = client.post("/v1/auth/challenge").json()
    body = {"challenge_id":challenge["challenge_id"],"identity_token":token(key, challenge["nonce"])}
    return client.post("/v1/auth/apple", json=body), body


def test_verified_login_replay_and_logout(auth, key):
    client, engine = auth
    response, body = login(client, key)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    headers = {"Authorization":"Bearer "+response.json()["access_token"]}
    me = client.get("/v1/auth/me", headers=headers)
    assert me.status_code == 200 and me.json()["id"] == response.json()["user"]["id"]
    assert client.post("/v1/auth/apple", json=body).status_code == 401
    assert client.post("/v1/auth/logout", headers=headers).status_code == 204
    assert client.get("/v1/auth/me", headers=headers).status_code == 401
    with engine.connect() as c:
        assert c.scalar(select(func.count()).select_from(AuthSession)) == 0


@pytest.mark.parametrize("overrides", [{"iss":"https://attacker.example"}, {"aud":"wrong-app"},
    {"exp":1}, {"iat":4102444800}, {"nonce":"wrong"}, {"sub":""}, {"nonce":42}])
def test_invalid_claims_rejected(auth, key, overrides):
    client, engine = auth
    challenge = client.post("/v1/auth/challenge").json()
    claims = dict(overrides)
    nonce = claims.pop("nonce", challenge["nonce"])
    result = client.post("/v1/auth/apple", json={"challenge_id":challenge["challenge_id"], "identity_token":token(key, nonce, **claims)})
    assert result.status_code == 401
    assert result.headers["cache-control"] == "no-store"
    with engine.connect() as c:
        assert c.scalar(select(func.count()).select_from(User)) == 0


def test_bad_signature_and_symmetric_algorithm(auth, key):
    client, _ = auth
    challenge = client.post("/v1/auth/challenge").json()
    wrong = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    for encoded in (token(wrong, challenge["nonce"]), jwt.encode({"sub":"bad"}, SECRET, algorithm="HS256", headers={"kid":"test-key"})):
        assert client.post("/v1/auth/apple", json={"challenge_id":challenge["challenge_id"], "identity_token":encoded}).status_code == 401


def test_expired_challenge(auth, key):
    client, engine = auth
    challenge = client.post("/v1/auth/challenge").json()
    with engine.begin() as c:
        c.execute(update(AuthChallenge).values(expires_at=datetime.now(timezone.utc)-timedelta(seconds=1)))
    assert client.post("/v1/auth/apple", json={"challenge_id":challenge["challenge_id"],"identity_token":token(key, challenge["nonce"])}).status_code == 401


def test_same_user_reuses_account(auth, key):
    client, engine = auth
    first, _ = login(client, key)
    second, _ = login(client, key)
    assert first.json()["user"]["id"] == second.json()["user"]["id"]
    with engine.connect() as c:
        assert c.scalar(select(func.count()).select_from(User)) == 1
        assert c.scalar(select(func.count()).select_from(AuthSession)) == 2


def test_concurrent_replay_one_winner(auth, key):
    client, _ = auth
    challenge = client.post("/v1/auth/challenge").json()
    body = {"challenge_id":challenge["challenge_id"],"identity_token":token(key, challenge["nonce"])}
    with ThreadPoolExecutor(2) as pool:
        codes = list(pool.map(lambda _: client.post("/v1/auth/apple", json=body).status_code, range(2)))
    assert sorted(codes) == [200, 401]


def test_database_session_expiry(auth, key):
    client, engine = auth
    response, _ = login(client, key)
    with engine.begin() as c:
        c.execute(update(AuthSession).values(expires_at=datetime.now(timezone.utc)-timedelta(seconds=1)))
    assert client.get("/v1/auth/me", headers={"Authorization":"Bearer "+response.json()["access_token"]}).status_code == 401


def test_missing_session_and_rate_limit(auth):
    client, _ = auth
    assert client.get("/v1/auth/me").status_code == 401
    assert client.get("/v1/auth/me", headers={"Authorization":"Bearer broken"}).status_code == 401
    for _ in range(30):
        assert client.post("/v1/auth/challenge").status_code == 200
    assert client.post("/v1/auth/challenge").status_code == 429


def test_auth_configuration_is_explicit(auth):
    _, engine = auth
    with TestClient(create_app(Settings(str(engine.url)), engine)) as client:
        assert client.post("/v1/auth/challenge").status_code == 503
        assert client.get("/health/live").status_code == 200
