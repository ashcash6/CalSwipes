"""Versioned menu snapshots and import audit trail."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("menu_snapshots",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("hall", sa.String(32), nullable=False),
        sa.Column("service_date", sa.Date(), nullable=False),
        sa.Column("meal", sa.String(32), nullable=False),
        sa.Column("content", postgresql.JSONB(), nullable=False),
        sa.Column("revision", sa.String(64), nullable=False),
        sa.Column("fetched_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("source_url", sa.Text(), nullable=False),
        sa.Column("source_sha256", sa.String(64), nullable=False),
        sa.UniqueConstraint("hall", "service_date", "meal", name="uq_menu_key"))
    op.create_table("import_runs",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("hall", sa.String(32), nullable=False),
        sa.Column("service_date", sa.Date(), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("outcome", sa.String(16), nullable=False),
        sa.Column("detail", sa.Text(), nullable=False))
    op.create_index("ix_import_runs_finished_at", "import_runs", ["finished_at"])


def downgrade():
    op.drop_table("import_runs")
    op.drop_table("menu_snapshots")
