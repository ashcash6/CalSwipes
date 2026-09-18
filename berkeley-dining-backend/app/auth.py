"""Native Sign in with Apple: one-time nonce, verified identity, revocable JWT."""
import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4
import jwt
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session
from app.db import AuthChallenge, AuthRateBucket, AuthSession, User, UserDietaryProfile
from app.schemas import DietaryProfile, DietaryProfileResponse

APPLE_ISSUER = "https://appleid.apple.com"
SESSION_ISSUER = "berkeley-plate-api"
SESSION_AUDIENCE = "berkeley-plate-ios"


def now():
    return datetime.now(timezone.utc)


class ExchangeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    challenge_id: UUID
    identity_token: str = Field(min_length=20, max_length=16384)


class ChallengeResponse(BaseModel):
    challenge_id: str
    nonce: str
    expires_at: datetime


class AccountResponse(BaseModel):
    id: str
    created_at: datetime


class SessionResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_at: datetime
    user: AccountResponse


class AppleVerifier:
    def __init__(self, audience, jwks=None):
        self.audience = audience
        self.jwks = jwks or jwt.PyJWKClient(APPLE_ISSUER + "/auth/keys", timeout=10, lifespan=3600)

    def verify(self, token):
        try:
            header = jwt.get_unverified_header(token)
            if header.get("alg") not in ("RS256", "ES256") or not header.get("kid"):
                raise jwt.InvalidTokenError("Unsupported algorithm")
            key = self.jwks.get_signing_key_from_jwt(token)
            if key.algorithm_name != header["alg"]:
                raise jwt.InvalidTokenError("Key algorithm mismatch")
            claims = jwt.decode(token, key.key, algorithms=[header["alg"]], audience=self.audience,
                                issuer=APPLE_ISSUER, leeway=10,
                                options={"require": ["iss", "aud", "sub", "exp", "iat", "nonce"]})
            if not isinstance(claims["sub"], str) or not 1 <= len(claims["sub"]) <= 255:
                raise jwt.InvalidTokenError("Invalid subject")
            if not isinstance(claims["nonce"], str) or len(claims["nonce"]) > 256:
                raise jwt.InvalidTokenError("Invalid nonce")
            return claims
        except jwt.PyJWKClientConnectionError:
            raise HTTPException(503, "Apple verification temporarily unavailable") from None
        except (jwt.PyJWTError, ValueError, TypeError, KeyError):
            raise HTTPException(401, "Apple identity could not be verified") from None


def router(settings, engine, verifier=None):
    routes = APIRouter(prefix="/v1/auth", tags=["Authentication"])
    profile = APIRouter(prefix="/v1/profile", tags=["Profile"])
    verifier = verifier or AppleVerifier(settings.apple_bundle_id)
    bearer = HTTPBearer(auto_error=False)

    def configured():
        if not settings.apple_bundle_id or len(settings.session_secret) < 32:
            raise HTTPException(503, "Sign in with Apple is not configured on this server")

    def limited(request: Request):
        configured()
        instant = now()
        # Shared database budget; no raw IP is persisted. Do not trust arbitrary forwarded headers.
        peer = request.client.host if request.client else "unknown"
        bucket = f"{peer}:{int(instant.timestamp()) // 60}"
        key = hmac.new(settings.session_secret.encode(), bucket.encode(), hashlib.sha256).hexdigest()
        with engine.begin() as c:
            stmt = insert(AuthRateBucket).values(key=key, count=1, expires_at=instant+timedelta(minutes=2))
            count = c.execute(stmt.on_conflict_do_update(index_elements=[AuthRateBucket.key],
                              set_={"count": AuthRateBucket.count+1}).returning(AuthRateBucket.count)).scalar_one()
        if count > 30:
            raise HTTPException(429, "Too many sign-in attempts; try again shortly", headers={"Retry-After":"60"})

    @routes.post("/challenge", response_model=ChallengeResponse, dependencies=[Depends(limited)])
    def challenge(response: Response):
        instant, nonce = now(), secrets.token_urlsafe(32)
        challenge_id = str(uuid4())
        expires = instant + timedelta(minutes=5)
        with engine.begin() as c:
            c.execute(delete(AuthChallenge).where(AuthChallenge.expires_at <= instant))
            c.execute(delete(AuthRateBucket).where(AuthRateBucket.expires_at <= instant))
            c.execute(delete(AuthSession).where(AuthSession.expires_at <= instant))
            c.execute(insert(AuthChallenge).values(id=challenge_id,
                      nonce_hash=hashlib.sha256(nonce.encode()).hexdigest(), expires_at=expires))
        response.headers["Cache-Control"] = "no-store"
        return ChallengeResponse(challenge_id=challenge_id, nonce=nonce, expires_at=expires)

    @routes.post("/apple", response_model=SessionResponse, dependencies=[Depends(limited)])
    def exchange(body: ExchangeRequest, response: Response):
        cid = str(body.challenge_id)
        with Session(engine) as db:
            valid = db.get(AuthChallenge, cid)
            if valid is None or valid.expires_at <= now():
                raise HTTPException(401, "Sign-in request expired; start again")
        claims = verifier.verify(body.identity_token)
        # Serialize the consume with account/session creation. A concurrent replay loses this lock.
        with Session(engine) as db, db.begin():
            valid = db.scalar(select(AuthChallenge).where(AuthChallenge.id == cid).with_for_update())
            if valid is None or valid.expires_at <= now():
                raise HTTPException(401, "Sign-in request expired; start again")
            digest = hashlib.sha256(claims["nonce"].encode()).hexdigest()
            if not hmac.compare_digest(digest, valid.nonce_hash):
                raise HTTPException(401, "Sign-in request does not match")
            instant = now()
            stmt = insert(User).values(id=str(uuid4()), apple_subject=claims["sub"], created_at=instant)
            db.execute(stmt.on_conflict_do_nothing(index_elements=[User.apple_subject]))
            user = db.scalar(select(User).where(User.apple_subject == claims["sub"]))
            sid, expires = str(uuid4()), instant + timedelta(days=7)
            db.add(AuthSession(id=sid, user_id=user.id, expires_at=expires))
            db.delete(valid)
            token = jwt.encode({"iss":SESSION_ISSUER, "aud":SESSION_AUDIENCE, "sub":user.id,
                                "jti":sid, "iat":instant, "exp":expires}, settings.session_secret, algorithm="HS256")
            result = SessionResponse(access_token=token, expires_at=expires,
                                     user=AccountResponse(id=user.id, created_at=user.created_at))
        response.headers["Cache-Control"] = "no-store"
        return result

    def authenticated(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        configured()
        if not credentials or len(credentials.credentials) > 4096:
            raise HTTPException(401, "Sign in required", headers={"WWW-Authenticate":"Bearer"})
        try:
            claims = jwt.decode(credentials.credentials, settings.session_secret, algorithms=["HS256"],
                issuer=SESSION_ISSUER, audience=SESSION_AUDIENCE,
                options={"require":["iss","aud","sub","jti","iat","exp"]})
        except jwt.PyJWTError:
            raise HTTPException(401, "Session expired; sign in again") from None
        with Session(engine) as db:
            session = db.get(AuthSession, claims["jti"])
            if not session or session.expires_at <= now() or session.user_id != claims["sub"]:
                raise HTTPException(401, "Session is no longer valid")
            user = db.get(User, session.user_id)
            if not user:
                raise HTTPException(401, "Account is unavailable")
            return session.id, AccountResponse(id=user.id, created_at=user.created_at)

    @routes.get("/me", response_model=AccountResponse)
    def me(response: Response, identity=Depends(authenticated)):
        response.headers["Cache-Control"] = "no-store"
        return identity[1]

    @routes.post("/logout", status_code=204)
    def logout(identity=Depends(authenticated)):
        with engine.begin() as c:
            c.execute(delete(AuthSession).where(AuthSession.id == identity[0]))
        return Response(status_code=204, headers={"Cache-Control":"no-store"})

    @profile.get("/dietary", response_model=DietaryProfileResponse)
    def get_dietary(response: Response, identity=Depends(authenticated)):
        _, account = identity
        with Session(engine) as db:
            row = db.get(UserDietaryProfile, account.id)
        response.headers["Cache-Control"] = "no-store"
        if row is None:
            return DietaryProfileResponse()
        return DietaryProfileResponse(
            allergies=row.allergies or [],
            dietary_preferences=row.dietary_preferences or [],
            updated_at=row.updated_at,
        )

    @profile.put("/dietary", response_model=DietaryProfileResponse)
    def put_dietary(body: DietaryProfile, response: Response, identity=Depends(authenticated)):
        _, account = identity
        instant = now()
        with engine.begin() as c:
            stmt = insert(UserDietaryProfile).values(
                user_id=account.id,
                allergies=body.allergies,
                dietary_preferences=body.dietary_preferences,
                updated_at=instant,
            ).on_conflict_do_update(
                index_elements=["user_id"],
                set_=dict(allergies=body.allergies, dietary_preferences=body.dietary_preferences, updated_at=instant),
            )
            c.execute(stmt)
        response.headers["Cache-Control"] = "no-store"
        return DietaryProfileResponse(
            allergies=body.allergies,
            dietary_preferences=body.dietary_preferences,
            updated_at=instant,
        )

    combined = APIRouter()
    combined.include_router(routes)
    combined.include_router(profile)
    return combined
