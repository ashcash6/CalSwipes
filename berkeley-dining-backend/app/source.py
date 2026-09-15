import time
from datetime import date
from urllib.robotparser import RobotFileParser
import httpx
from app.parser import HALLS, SourceError
from app.schemas import Hall

ORIGIN = "https://dining.berkeley.edu"
MAX_BYTES = 8 * 1024 * 1024


def feed_url(hall: Hall, day: date):
    return f"{ORIGIN}/wp-content/uploads/menus-exportimport/{HALLS[hall][0]}_{day:%Y%m%d}.xml"


class BerkeleySource:
    def __init__(self, user_agent: str, client=None, sleep=time.sleep):
        self.user_agent = user_agent
        self.client = client or httpx.Client(timeout=30, follow_redirects=False,
                                            headers={"User-Agent": user_agent})
        self.sleep = sleep
        self.robots = None

    def close(self):
        self.client.close()

    def get(self, url):
        for attempt in range(3):
            try:
                with self.client.stream("GET", url) as response:
                    if response.status_code in (429, 500, 502, 503, 504):
                        if attempt < 2:
                            retry = response.headers.get("Retry-After", "")
                            delay = min(60, int(retry)) if retry.isdigit() else 2 ** (attempt + 1)
                            self.sleep(delay)
                            continue
                    response.raise_for_status()
                    data = bytearray()
                    for chunk in response.iter_bytes():
                        data.extend(chunk)
                        if len(data) > MAX_BYTES:
                            raise SourceError("Source exceeds size limit")
                    return bytes(data)
            except httpx.TransportError:
                if attempt == 2:
                    raise
                self.sleep(2 ** (attempt + 1))
        raise SourceError("Upstream retries exhausted")

    def check_robots(self):
        url = ORIGIN + "/robots.txt"
        try:
            raw = self.get(url)
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code not in (404, 410):
                raise SourceError("Cannot establish robots policy") from exc
            raw = b""
        text = raw.decode("utf-8-sig")
        if "<html" in text.lower() or "<!doctype" in text.lower():
            raise SourceError("robots.txt returned HTML")
        self.robots = RobotFileParser()
        self.robots.parse(text.splitlines())

    def fetch(self, hall: Hall, day: date):
        if self.robots is None:
            self.check_robots()
        url = feed_url(hall, day)
        if not self.robots.can_fetch(self.user_agent, url):
            raise SourceError("robots.txt disallows menu feed")
        self.sleep(max(1, self.robots.crawl_delay(self.user_agent) or 0))
        return url, self.get(url)
