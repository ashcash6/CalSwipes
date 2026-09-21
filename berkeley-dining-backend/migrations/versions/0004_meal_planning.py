"""Meal planning: is_premium on users, logged_meals, recurring_items, planned_days, plan_slots."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    # Premium flag on existing users table; server_default ensures existing rows get FALSE
    op.add_column("users", sa.Column(
        "is_premium", sa.Boolean(), nullable=False, server_default="false"
    ))

    op.create_table(
        "logged_meals",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("service_date", sa.Date(), nullable=False),
        sa.Column("meal_period", sa.String(32), nullable=True),
        sa.Column("hall", sa.String(32), nullable=True),
        sa.Column("meal_type", sa.String(8), nullable=False),   # "meal" | "snack"
        sa.Column("item_id", sa.String(64), nullable=True),
        sa.Column("item_name", sa.String(256), nullable=False),
        sa.Column("calories_kcal", sa.Float(), nullable=False),
        sa.Column("protein_g", sa.Float(), nullable=False),
        sa.Column("carbs_g", sa.Float(), nullable=False),
        sa.Column("fat_g", sa.Float(), nullable=False),
        sa.Column("source", sa.String(16), nullable=False),     # "scan" | "recurring" | "manual"
        sa.Column("logged_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_logged_meals_user_id", "logged_meals", ["user_id"])
    op.create_index("ix_logged_meals_service_date", "logged_meals", ["service_date"])
    # Compound index covers the dominant query pattern: all entries for a user on a date
    op.create_index("ix_logged_meals_user_date", "logged_meals", ["user_id", "service_date"])

    op.create_table(
        "recurring_items",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(256), nullable=False),
        sa.Column("calories_kcal", sa.Float(), nullable=False),
        sa.Column("protein_g", sa.Float(), nullable=False),
        sa.Column("carbs_g", sa.Float(), nullable=False),
        sa.Column("fat_g", sa.Float(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_recurring_items_user_id", "recurring_items", ["user_id"])

    op.create_table(
        "planned_days",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("plan_date", sa.Date(), nullable=False),
        sa.Column("goal_calories", sa.Float(), nullable=False),
        sa.Column("goal_protein_g", sa.Float(), nullable=False),
        sa.Column("goal_carbs_g", sa.Float(), nullable=False),
        sa.Column("goal_fat_g", sa.Float(), nullable=False),
        sa.Column("last_regenerated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_computed_budget", JSONB, nullable=True),
        sa.Column("confirmed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "plan_date", name="uq_planned_day_user_date"),
    )
    op.create_index("ix_planned_days_user_id", "planned_days", ["user_id"])

    op.create_table(
        "plan_slots",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("plan_id", sa.String(36),
                  sa.ForeignKey("planned_days.id", ondelete="CASCADE"), nullable=False),
        sa.Column("slot_order", sa.Integer(), nullable=False),
        sa.Column("hall", sa.String(32), nullable=False),
        sa.Column("meal_period", sa.String(32), nullable=False),
        sa.Column("status", sa.String(24), nullable=False),     # "pending" | "accepted" | "consumed_externally"
        sa.Column("accepted_item_ids", JSONB, nullable=True),
        sa.Column("accepted_macros", JSONB, nullable=True),
        sa.Column("recommendations", JSONB, nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_plan_slots_plan_id", "plan_slots", ["plan_id"])


def downgrade():
    op.drop_table("plan_slots")
    op.drop_table("planned_days")
    op.drop_table("recurring_items")
    op.drop_table("logged_meals")
    op.drop_column("users", "is_premium")
