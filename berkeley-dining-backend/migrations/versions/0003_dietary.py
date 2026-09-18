"""User dietary profile: allergy exclusions and dietary preference tags."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "user_dietary_profiles",
        sa.Column("user_id", sa.String(36),
                  sa.ForeignKey("users.id", ondelete="CASCADE"),
                  primary_key=True),
        sa.Column("allergies", JSONB, nullable=False, server_default="'[]'::jsonb"),
        sa.Column("dietary_preferences", JSONB, nullable=False, server_default="'[]'::jsonb"),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade():
    op.drop_table("user_dietary_profiles")
