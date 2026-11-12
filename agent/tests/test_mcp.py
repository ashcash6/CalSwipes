import asyncio
import json
import os
import sys

import pytest

from tests.conftest import ROOT


def test_tools_listed_and_callable(store):
    from mcp_server.server import server

    async def go():
        names = {t.name for t in await server.list_tools()}
        res = await server.call_tool("get_nutrition", {"item_name": "Scrambled Eggs", "hall": "cafe-3"})
        return names, res

    names, res = asyncio.run(go())
    assert names == {"search_menu", "get_nutrition", "search_dining_info"}
    assert not res.is_error
    assert json.loads(res.content[0].text)["matches"][0]["protein_g"] == pytest.approx(13.92)


def test_stdio_round_trip(tmp_path):
    """Spawn the real server over stdio and talk MCP to it, like a desktop client would."""
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
    from pipeline.embeddings import FakeEmbedder
    from pipeline.ingest_docs import ingest_docs
    from pipeline.store import SQLiteStore

    db = tmp_path / "mcp.db"
    s = SQLiteStore(str(db))
    s.init_schema()
    ingest_docs(s, FakeEmbedder(), [ROOT / "pipeline" / "docs" / "sample"])

    async def go():
        params = StdioServerParameters(command=sys.executable, args=["-m", "mcp_server.server"], cwd=str(ROOT),
                                       env={**os.environ, "OFFLINE": "1", "SQLITE_PATH": str(db)})
        async with stdio_client(params) as (r, w):
            async with ClientSession(r, w) as session:
                await session.initialize()
                res = await session.call_tool("search_dining_info", {"query": "cross-contact allergen"})
                return json.loads(res.content[0].text)

    out = asyncio.run(asyncio.wait_for(go(), 60))
    assert out["results"][0]["doc_id"] == "allergen-policy"
