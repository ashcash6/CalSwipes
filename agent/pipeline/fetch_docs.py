"""Download Berkeley Dining info pages and save them as plain-text docs for RAG.

    python -m pipeline.fetch_docs              # writes pipeline/docs/fetched/*.md
    python -m pipeline.ingest_docs             # then embed them

The sandbox this repo was built in could not reach dining.berkeley.edu, so the
repo ships hand-written SAMPLE docs (pipeline/docs/sample, marked `sample: true`).
Run this on your own machine to replace them with real page text. Check each URL
still exists in a browser first; edit PAGES if the site was reorganised.
After fetching real pages, delete or move the sample folder so answers only cite real text.
"""
import re
import sys
import time
import urllib.request
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.robotparser import RobotFileParser

ORIGIN = "https://dining.berkeley.edu"
USER_AGENT = "CalSwipesAgent/0.1 (student project; menu research)"
OUT = Path(__file__).parent / "docs" / "fetched"

# doc_id -> (title, url). Verify these in a browser; they are best guesses at the site layout.
PAGES = {
    "hours": ("Berkeley Dining hours", ORIGIN + "/locations/hours-of-operation/"),
    "locations": ("Berkeley Dining locations", ORIGIN + "/locations/"),
    "allergens": ("Berkeley Dining allergen and special diet information", ORIGIN + "/nutrition/special-diets/"),
    "meal-plans": ("Berkeley Dining meal plans", ORIGIN + "/meal-plans/"),
}


class _TextExtractor(HTMLParser):
    SKIP = {"script", "style", "nav", "footer", "header", "noscript", "svg", "form"}
    BLOCK = {"p", "div", "li", "h1", "h2", "h3", "h4", "tr", "br", "section", "article"}

    def __init__(self):
        super().__init__()
        self.parts, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        elif tag in self.BLOCK:
            self.parts.append("\n\n")

    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skip:
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def html_to_text(html: str) -> str:
    p = _TextExtractor()
    p.feed(html)
    text = "".join(p.parts)
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    return re.sub(r"\n\s*\n+", "\n\n", text).strip()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    robots = RobotFileParser(ORIGIN + "/robots.txt")
    robots.read()
    ok = 0
    for doc_id, (title, url) in PAGES.items():
        if not robots.can_fetch(USER_AGENT, url):
            print(f"skip {url}: disallowed by robots.txt")
            continue
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=30) as r:
                text = html_to_text(r.read(4 * 1024 * 1024).decode("utf-8", "replace"))
        except Exception as exc:
            print(f"fail {url}: {exc}")
            continue
        stamp = datetime.now(timezone.utc).isoformat()
        (OUT / f"{doc_id}.md").write_text(
            f"title: {title}\nsource_url: {url}\nsample: false\nfetched_at: {stamp}\n---\n{text}\n", encoding="utf-8")
        print(f"ok   {url} -> {doc_id}.md ({len(text)} chars)")
        ok += 1
        time.sleep(max(1, robots.crawl_delay(USER_AGENT) or 0))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
