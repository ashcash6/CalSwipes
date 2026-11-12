import sqlite3

import pytest

from pipeline.store import UnsafeQuery, validate_readonly_sql


@pytest.mark.parametrize("sql", [
    "DELETE FROM items", "select 1; drop table items", "UPDATE items SET name = 'x'",
    "select * from chunks", "select * from items, docs", "select * from sqlite_master",
    "select * from items -- sneaky", "WITH x AS (DELETE FROM items RETURNING *) SELECT * FROM x",
    "select * from users", "PRAGMA table_info(items)",
])
def test_rejects_unsafe(sql):
    with pytest.raises(UnsafeQuery):
        validate_readonly_sql(sql)


def test_allows_select_and_caps_rows(store):
    rows = store.readonly_query("SELECT name FROM items ORDER BY name")
    assert 0 < len(rows) <= 50


def test_allows_cte(store):
    rows = store.readonly_query("WITH p AS (SELECT item_id, protein_g FROM nutrition) "
                                "SELECT COUNT(*) AS n FROM p WHERE protein_g > 20")
    assert rows[0]["n"] > 0


def test_query_only_blocks_writes_even_if_validation_missed(store):
    store.conn.execute("PRAGMA query_only = ON")
    try:
        with pytest.raises(sqlite3.OperationalError):
            store.conn.execute("DELETE FROM items")
    finally:
        store.conn.execute("PRAGMA query_only = OFF")


def test_tool_returns_error_not_exception(store):
    from agents.tools import run_menu_sql
    assert "error" in run_menu_sql("DROP TABLE items")
    assert "error" in run_menu_sql("SELECT nope FROM items")
    assert store.scalar("SELECT COUNT(*) FROM items") > 0
