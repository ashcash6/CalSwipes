"""One storage interface, two backends.

- PostgresStore: production (Neon). Structured tables + a `chunks` table whose
  `embedding` column is a pgvector `vector(768)`. Similarity search runs inside
  Postgres with the `<=>` (cosine distance) operator and an HNSW index.
- SQLiteStore: offline dev and tests. Same tables; embeddings stored as JSON and
  compared in Python with numpy. Same results, just not scalable.

All SQL in this file is written with `?` placeholders; the Postgres store swaps
them to `%s` for psycopg. Keep `?` and `%` out of string literals here.
"""
import json
import re
import sqlite3
from pathlib import Path

import numpy as np

from config import Settings

SCHEMA = [
    """CREATE TABLE IF NOT EXISTS locations (
        id {pk}, slug TEXT UNIQUE NOT NULL, name TEXT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS dates (
        service_date {date} PRIMARY KEY, weekday TEXT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS meals (
        id {pk},
        location_id INTEGER NOT NULL REFERENCES locations(id),
        service_date {date} NOT NULL REFERENCES dates(service_date),
        period TEXT NOT NULL,              -- breakfast | lunch | dinner | ...
        source_name TEXT,                  -- e.g. 'Fall - Lunch'
        start_time TEXT, end_time TEXT,    -- 'HH:MM' local time, from the feed
        UNIQUE (location_id, service_date, period))""",
    # Eatec recipe ids are shared across halls; if two halls disagree, the last import wins.
    """CREATE TABLE IF NOT EXISTS items (
        id {pk}, recipe_id TEXT UNIQUE NOT NULL, name TEXT NOT NULL, category TEXT,
        allergens TEXT NOT NULL DEFAULT ',',     -- ',Milk,Egg,' so LIKE '%,Milk,%' works
        dietary_tags TEXT NOT NULL DEFAULT ',')""",
    """CREATE TABLE IF NOT EXISTS nutrition (
        item_id INTEGER PRIMARY KEY REFERENCES items(id),
        status TEXT NOT NULL,                  -- published | unapproved | missing
        serving_qty REAL, serving_unit TEXT, serving_weight_g REAL,
        calories_kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL)""",
    """CREATE TABLE IF NOT EXISTS menu_entries (
        meal_id INTEGER NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
        item_id INTEGER NOT NULL REFERENCES items(id),
        PRIMARY KEY (meal_id, item_id))""",
    """CREATE TABLE IF NOT EXISTS docs (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, source_url TEXT,
        is_sample {bool} NOT NULL, fetched_at TEXT)""",
    """CREATE TABLE IF NOT EXISTS chunks (
        id TEXT PRIMARY KEY, doc_id TEXT NOT NULL REFERENCES docs(id) ON DELETE CASCADE,
        idx INTEGER NOT NULL, text TEXT NOT NULL, embedding {vector} NOT NULL)""",
]

# Tables the read-only SQL tool may touch. Docs/chunks are reachable only through RAG.
READABLE_TABLES = {"locations", "dates", "meals", "items", "nutrition", "menu_entries"}
_FORBIDDEN = re.compile(r"\b(insert|update|delete|drop|alter|create|attach|detach|pragma|grant|revoke|"
                        r"truncate|copy|vacuum|replace|call|do|set|reset|load|lock|listen|notify)\b", re.I)


class UnsafeQuery(ValueError):
    pass


def validate_readonly_sql(sql: str, max_rows: int = 50) -> str:
    """Allow exactly one SELECT over the structured tables, with a row cap.

    Defence in depth: this check AND a read-only connection/transaction.
    """
    s = sql.strip().rstrip(";").strip()
    if ";" in s:
        raise UnsafeQuery("only one statement allowed")
    if not re.match(r"^(select|with)\b", s, re.I):
        raise UnsafeQuery("only SELECT queries are allowed")
    if _FORBIDDEN.search(s):
        raise UnsafeQuery("query contains a forbidden keyword")
    if "--" in s or "/*" in s:
        raise UnsafeQuery("comments are not allowed")
    if re.search(r"\b(docs|chunks|sqlite_\w+|pg_\w+|information_schema|users|auth_\w+|menu_snapshots|import_runs|"
                 r"user_dietary_profiles|logged_meals|recurring_items|planned_days|plan_slots)\b", s, re.I):
        raise UnsafeQuery("query references a non-menu table")
    names = {n.lower() for n in re.findall(r"\b(?:from|join)\s+([a-z_][a-z0-9_]*)", s, re.I)}
    ctes = {n.lower() for n in re.findall(r"\b([a-z_][a-z0-9_]*)\s+as\s*\(", s, re.I)}
    bad = names - READABLE_TABLES - ctes
    if bad:
        raise UnsafeQuery(f"table(s) not allowed: {sorted(bad)}")
    return f"SELECT * FROM ({s}) AS q LIMIT {int(max_rows)}"


class BaseStore:
    dialect = "base"

    # --- low level, implemented by subclasses ---
    def execute(self, sql, params=()):
        raise NotImplementedError

    def query(self, sql, params=()) -> list[dict]:
        raise NotImplementedError

    def readonly_query(self, sql: str, max_rows: int = 50) -> list[dict]:
        raise NotImplementedError

    def vector_search(self, embedding, k=4) -> list[dict]:
        raise NotImplementedError

    def commit(self):
        raise NotImplementedError

    # --- shared helpers ---
    def scalar(self, sql, params=()):
        rows = self.query(sql, params)
        return next(iter(rows[0].values())) if rows else None

    def upsert_location(self, slug, name):
        return self.scalar("INSERT INTO locations (slug, name) VALUES (?, ?) "
                           "ON CONFLICT (slug) DO UPDATE SET name = excluded.name RETURNING id", (slug, name))

    def upsert_date(self, day):
        self.execute("INSERT INTO dates (service_date, weekday) VALUES (?, ?) ON CONFLICT (service_date) DO NOTHING",
                     (day.isoformat(), day.strftime("%A")))

    def upsert_meal(self, location_id, day, period, source_name, start, end):
        meal_id = self.scalar(
            "INSERT INTO meals (location_id, service_date, period, source_name, start_time, end_time) "
            "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (location_id, service_date, period) DO UPDATE SET "
            "source_name = excluded.source_name, start_time = excluded.start_time, end_time = excluded.end_time "
            "RETURNING id", (location_id, day.isoformat(), period, source_name, start, end))
        self.execute("DELETE FROM menu_entries WHERE meal_id = ?", (meal_id,))  # re-import replaces the menu
        return meal_id

    def upsert_item(self, item: dict):
        item_id = self.scalar(
            "INSERT INTO items (recipe_id, name, category, allergens, dietary_tags) VALUES (?, ?, ?, ?, ?) "
            "ON CONFLICT (recipe_id) DO UPDATE SET name = excluded.name, category = excluded.category, "
            "allergens = excluded.allergens, dietary_tags = excluded.dietary_tags RETURNING id",
            (item["recipe_id"], item["name"], item["category"],
             "," + ",".join(item["allergens"]) + ",", "," + ",".join(item["dietary_tags"]) + ","))
        m = item.get("macros") or {}
        self.execute(
            "INSERT INTO nutrition (item_id, status, serving_qty, serving_unit, serving_weight_g, calories_kcal, "
            "protein_g, carbs_g, fat_g) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (item_id) DO UPDATE SET "
            "status = excluded.status, serving_qty = excluded.serving_qty, serving_unit = excluded.serving_unit, "
            "serving_weight_g = excluded.serving_weight_g, calories_kcal = excluded.calories_kcal, "
            "protein_g = excluded.protein_g, carbs_g = excluded.carbs_g, fat_g = excluded.fat_g",
            (item_id, item["nutrition_status"], item["serving_qty"], item["serving_unit"], item["serving_weight_g"],
             m.get("calories_kcal"), m.get("protein_g"), m.get("carbs_g"), m.get("fat_g")))
        return item_id

    def add_menu_entry(self, meal_id, item_id):
        self.execute("INSERT INTO menu_entries (meal_id, item_id) VALUES (?, ?) ON CONFLICT DO NOTHING",
                     (meal_id, item_id))

    def upsert_doc(self, doc_id, title, source_url, is_sample, fetched_at):
        self.execute("DELETE FROM chunks WHERE doc_id = ?", (doc_id,))
        self.execute("INSERT INTO docs (id, title, source_url, is_sample, fetched_at) VALUES (?, ?, ?, ?, ?) "
                     "ON CONFLICT (id) DO UPDATE SET title = excluded.title, source_url = excluded.source_url, "
                     "is_sample = excluded.is_sample, fetched_at = excluded.fetched_at",
                     (doc_id, title, source_url, bool(is_sample), fetched_at))

    def add_chunk(self, chunk_id, doc_id, idx, text, embedding):
        raise NotImplementedError


class SQLiteStore(BaseStore):
    dialect = "sqlite"

    def __init__(self, path: str = ":memory:"):
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys = ON")

    def init_schema(self):
        for ddl in SCHEMA:
            self.conn.execute(ddl.format(pk="INTEGER PRIMARY KEY", date="TEXT", bool="INTEGER", vector="TEXT"))
        self.conn.commit()

    def execute(self, sql, params=()):
        self.conn.execute(sql, params)

    def query(self, sql, params=()):
        return [dict(r) for r in self.conn.execute(sql, params).fetchall()]

    def commit(self):
        self.conn.commit()

    def readonly_query(self, sql, max_rows=50):
        safe = validate_readonly_sql(sql, max_rows)
        self.conn.commit()
        # query_only makes SQLite itself reject writes, even if validation missed something.
        self.conn.execute("PRAGMA query_only = ON")
        try:
            return self.query(safe)
        finally:
            self.conn.execute("PRAGMA query_only = OFF")

    def add_chunk(self, chunk_id, doc_id, idx, text, embedding):
        self.execute("INSERT INTO chunks (id, doc_id, idx, text, embedding) VALUES (?, ?, ?, ?, ?)",
                     (chunk_id, doc_id, idx, text, json.dumps(list(embedding))))

    def vector_search(self, embedding, k=4):
        rows = self.query("SELECT c.id, c.doc_id, c.idx, c.text, c.embedding, d.title, d.source_url, d.is_sample "
                          "FROM chunks c JOIN docs d ON d.id = c.doc_id")
        if not rows:
            return []
        mat = np.array([json.loads(r.pop("embedding")) for r in rows], dtype=float)
        q = np.asarray(embedding, dtype=float)
        sims = mat @ q / (np.linalg.norm(mat, axis=1) * (np.linalg.norm(q) or 1.0) + 1e-12)
        order = np.argsort(-sims)[:k]
        return [{**rows[i], "is_sample": bool(rows[i]["is_sample"]), "score": float(sims[i])} for i in order]


class PostgresStore(BaseStore):
    """Neon / Cloud SQL Postgres with the pgvector extension. Requires psycopg + pgvector packages."""
    dialect = "postgres"

    def __init__(self, url: str, dim: int = 768):
        import psycopg
        from psycopg.rows import dict_row

        self.dim = dim
        # Accept SQLAlchemy-style URLs from the backend config too.
        self.conn = psycopg.connect(url.replace("postgresql+psycopg://", "postgresql://"), row_factory=dict_row,
                                    connect_timeout=10)

    @staticmethod
    def _pg(sql):
        return sql.replace("?", "%s")

    def init_schema(self):
        # Vectors are sent as '[0.1,...]'::vector text, so the pgvector Python package isn't needed.
        with self.conn.cursor() as cur:
            cur.execute("CREATE EXTENSION IF NOT EXISTS vector")
            for ddl in SCHEMA:
                cur.execute(ddl.format(pk="SERIAL PRIMARY KEY", date="DATE", bool="BOOLEAN",
                                       vector=f"vector({self.dim})"))
            cur.execute("CREATE INDEX IF NOT EXISTS chunks_embedding_hnsw ON chunks "
                        "USING hnsw (embedding vector_cosine_ops)")
        self.conn.commit()

    def execute(self, sql, params=()):
        with self.conn.cursor() as cur:
            cur.execute(self._pg(sql), params)

    def query(self, sql, params=()):
        with self.conn.cursor() as cur:
            cur.execute(self._pg(sql), params)
            rows = cur.fetchall() if cur.description else []
        return [{k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in r.items()} for r in rows]

    def commit(self):
        self.conn.commit()

    def readonly_query(self, sql, max_rows=50):
        safe = validate_readonly_sql(sql, max_rows)
        self.conn.commit()
        with self.conn.cursor() as cur:
            cur.execute("BEGIN READ ONLY")
            try:
                cur.execute("SET LOCAL statement_timeout = '3s'")
                cur.execute(safe)
                rows = cur.fetchall()
            finally:
                cur.execute("ROLLBACK")
        return [{k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in r.items()} for r in rows]

    def add_chunk(self, chunk_id, doc_id, idx, text, embedding):
        self.execute("INSERT INTO chunks (id, doc_id, idx, text, embedding) VALUES (?, ?, ?, ?, ?::vector)",
                     (chunk_id, doc_id, idx, text, "[" + ",".join(f"{x:.7f}" for x in embedding) + "]"))

    def vector_search(self, embedding, k=4):
        vec = "[" + ",".join(f"{x:.7f}" for x in embedding) + "]"
        return self.query(
            "SELECT c.id, c.doc_id, c.idx, c.text, d.title, d.source_url, d.is_sample, "
            "1 - (c.embedding <=> ?::vector) AS score FROM chunks c JOIN docs d ON d.id = c.doc_id "
            "ORDER BY c.embedding <=> ?::vector LIMIT ?", (vec, vec, k))


def open_store(settings: Settings | None = None) -> BaseStore:
    settings = settings or Settings.from_env()
    if settings.database_url:
        store = PostgresStore(settings.database_url, settings.embedding_dim)
    else:
        store = SQLiteStore(settings.sqlite_path)
    store.init_schema()
    return store
