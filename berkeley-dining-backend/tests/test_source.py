from datetime import date
import httpx
import pytest
from app.parser import SourceError
from app.schemas import Hall
from app.source import BerkeleySource


def source(handler):
    return BerkeleySource("BerkeleyPlate", httpx.Client(transport=httpx.MockTransport(handler)), sleep=lambda _: None)


def test_robots_denial_blocks_feed():
    urls = []
    def handler(request):
        urls.append(str(request.url))
        return httpx.Response(200, text="User-agent: *\nDisallow: /wp-content/")
    with pytest.raises(SourceError):
        source(handler).fetch(Hall.foothill, date(2026,9,14))
    assert len(urls) == 1


def test_robots_outage_fails_closed():
    with pytest.raises(SourceError):
        source(lambda r: httpx.Response(503)).fetch(Hall.foothill, date(2026,9,14))


def test_empty_robots_allows_feed():
    s = source(lambda r: httpx.Response(200, content=b"" if r.url.path == "/robots.txt" else b"xml"))
    assert s.fetch(Hall.foothill, date(2026,9,14))[1] == b"xml"


def test_transient_retry():
    calls = []
    def handler(r):
        calls.append(r)
        return httpx.Response(503 if len(calls) < 3 else 200, content=b"ok")
    assert source(handler).get("https://dining.berkeley.edu/test") == b"ok"
    assert len(calls) == 3


def test_redirect_is_not_followed():
    with pytest.raises(httpx.HTTPStatusError):
        source(lambda r: httpx.Response(302, headers={"Location":"https://other.example"})).get("https://dining.berkeley.edu/test")
