from datetime import date, datetime
from sqlalchemy import Boolean, Date, DateTime, Float, ForeignKey, Integer, String, Text, UniqueConstraint, create_engine
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class MenuSnapshot(Base):
    __tablename__ = "menu_snapshots"
    __table_args__ = (UniqueConstraint("hall", "service_date", "meal", name="uq_menu_key"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    hall: Mapped[str] = mapped_column(String(32))
    service_date: Mapped[date] = mapped_column(Date)
    meal: Mapped[str] = mapped_column(String(32))
    content: Mapped[dict] = mapped_column(JSONB)
    revision: Mapped[str] = mapped_column(String(64))
    fetched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    source_url: Mapped[str] = mapped_column(Text)
    source_sha256: Mapped[str] = mapped_column(String(64))


class ImportRun(Base):
    __tablename__ = "import_runs"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    hall: Mapped[str] = mapped_column(String(32))
    service_date: Mapped[date] = mapped_column(Date)
    finished_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    outcome: Mapped[str] = mapped_column(String(16))
    detail: Mapped[str] = mapped_column(Text)


class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    apple_subject: Mapped[str] = mapped_column(String(255), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    is_premium: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class AuthChallenge(Base):
    __tablename__ = "auth_challenges"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    nonce_hash: Mapped[str] = mapped_column(String(64))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)


class AuthSession(Base):
    __tablename__ = "auth_sessions"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)


class AuthRateBucket(Base):
    __tablename__ = "auth_rate_buckets"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    count: Mapped[int] = mapped_column(Integer)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)


class UserDietaryProfile(Base):
    __tablename__ = "user_dietary_profiles"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    allergies: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    dietary_preferences: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class LoggedMeal(Base):
    """A food entry logged by the user (from a photo scan, a recurring item, or manual entry)."""
    __tablename__ = "logged_meals"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    service_date: Mapped[date] = mapped_column(Date, index=True)
    meal_period: Mapped[str | None] = mapped_column(String(32), nullable=True)
    hall: Mapped[str | None] = mapped_column(String(32), nullable=True)
    # "meal" counts toward plan slot consumption; "snack" only affects macro budget
    meal_type: Mapped[str] = mapped_column(String(8))
    item_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    item_name: Mapped[str] = mapped_column(String(256))
    calories_kcal: Mapped[float] = mapped_column(Float)
    protein_g: Mapped[float] = mapped_column(Float)
    carbs_g: Mapped[float] = mapped_column(Float)
    fat_g: Mapped[float] = mapped_column(Float)
    source: Mapped[str] = mapped_column(String(16))  # "scan" | "recurring" | "manual"
    logged_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class RecurringItem(Base):
    """A user-saved food item with fixed macros for quick repeated logging."""
    __tablename__ = "recurring_items"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(256))
    calories_kcal: Mapped[float] = mapped_column(Float)
    protein_g: Mapped[float] = mapped_column(Float)
    carbs_g: Mapped[float] = mapped_column(Float)
    fat_g: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class PlannedDay(Base):
    """A user's full-day meal plan for a specific date."""
    __tablename__ = "planned_days"
    __table_args__ = (UniqueConstraint("user_id", "plan_date", name="uq_planned_day_user_date"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    plan_date: Mapped[date] = mapped_column(Date)
    goal_calories: Mapped[float] = mapped_column(Float)
    goal_protein_g: Mapped[float] = mapped_column(Float)
    goal_carbs_g: Mapped[float] = mapped_column(Float)
    goal_fat_g: Mapped[float] = mapped_column(Float)
    # Timestamp of the last full regeneration; used to detect new logged entries since then
    last_regenerated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Budget snapshot from the last GET /v1/plan-day call; used by per-slot regenerate
    # so it doesn't recalculate budget from scratch on every "try again" press
    last_computed_budget: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class PlanSlot(Base):
    """A single meal slot within a planned day."""
    __tablename__ = "plan_slots"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    plan_id: Mapped[str] = mapped_column(ForeignKey("planned_days.id", ondelete="CASCADE"), index=True)
    slot_order: Mapped[int] = mapped_column(Integer)
    hall: Mapped[str] = mapped_column(String(32))
    meal_period: Mapped[str] = mapped_column(String(32))
    # "pending" | "accepted" | "consumed_externally"
    status: Mapped[str] = mapped_column(String(24))
    accepted_item_ids: Mapped[list | None] = mapped_column(JSONB, nullable=True)
    accepted_macros: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    recommendations: Mapped[list | None] = mapped_column(JSONB, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


def make_engine(url):
    return create_engine(url, pool_pre_ping=True, connect_args={"connect_timeout": 10})
