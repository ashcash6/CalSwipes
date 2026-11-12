"""MCP server: exposes the CalSwipes tools to any MCP client (Claude Desktop, ADK's MCPToolset, IDEs).

MCP (Model Context Protocol) is a standard way for an AI app to discover and call
tools on a separate server. Same functions as the agents use, so behaviour matches.

    OFFLINE=1 python -m mcp_server.server                 # stdio (for desktop clients)
    python -m mcp_server.server --http --port 8765        # streamable HTTP

Built for the `mcp` Python SDK v2 (MCPServer, formerly FastMCP).
"""
import argparse
import sys

from mcp.server.mcpserver import MCPServer

from agents import tools
from observability.telemetry import setup_logging

server = MCPServer(name="calswipes", instructions=(
    "Berkeley dining hall menus, nutrition and dining info. Allergen flags come from the menu feed and are "
    "not a safety guarantee; always tell users to confirm with dining staff."))


@server.tool()
def search_menu(hall: str = "", date: str = "", meal: str = "", query: str = "",
                exclude_allergens: list[str] | None = None, dietary_tag: str = "", min_protein_g: float = 0.0,
                limit: int = 25) -> dict:
    """Search items served at Berkeley dining halls. hall: crossroads | cafe-3 | foothill | clark-kerr;
    date: YYYY-MM-DD (empty = today/latest); meal: breakfast | lunch | dinner; query: name substring;
    exclude_allergens: e.g. ["Peanuts"]; dietary_tag: Vegan Option | Vegetarian Option | Halal | Kosher."""
    return tools.search_menu(hall, date, meal, query, exclude_allergens, dietary_tag, min_protein_g, limit)


@server.tool()
def get_nutrition(item_name: str, hall: str = "", date: str = "") -> dict:
    """Calories, protein, carbs, fat, serving size, allergen flags and dietary tags for a menu item."""
    return tools.get_nutrition(item_name, hall, date)


@server.tool()
def search_dining_info(query: str, k: int = 4) -> dict:
    """Retrieve cited passages about dining hours, allergen policy, dietary labels and the CalSwipes app."""
    return tools.search_dining_info(query, k)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--http", action="store_true", help="serve streamable HTTP instead of stdio")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    a = p.parse_args()
    setup_logging(stream=sys.stderr)
    if a.http:
        server.run("streamable-http", host=a.host, port=a.port)
    else:
        server.run("stdio")


if __name__ == "__main__":
    main()
