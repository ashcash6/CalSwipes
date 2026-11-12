"""assistant usage caps, spend tracking and response cache

Revision ID: 0005
Revises: 0004
"""
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "assistant_usage",
        sa.Column("subject", sa.String(96), primary_key=True),  # 'user:<device>' or 'ip:<addr>'
        sa.Column("day", sa.Date, primary_key=True),
        sa.Column("kind", sa.String(8), primary_key=True),       # 'ask' | 'scan'
        sa.Column("count", sa.Integer, nullable=False),
    )
    op.create_table(
        "assistant_spend",
        sa.Column("day", sa.Date, primary_key=True),
        sa.Column("cost_usd", sa.Float, nullable=False),
    )
    op.create_table(
        "assistant_cache",
        sa.Column("key", sa.String(64), primary_key=True),
        sa.Column("response", JSONB, nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False, index=True),
    )


def downgrade():
    op.drop_table("assistant_cache")
    op.drop_table("assistant_spend")
    op.drop_table("assistant_usage")
