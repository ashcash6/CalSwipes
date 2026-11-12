"""Split long text into overlapping chunks for embedding.

Why chunk? Embedding a whole page blurs many topics into one vector. Small
chunks (about a paragraph) let retrieval return just the relevant part, and the
overlap keeps a sentence that straddles a boundary findable from either side.
"""
import re


def chunk_text(text: str, max_words: int = 120, overlap_words: int = 30) -> list[str]:
    if overlap_words >= max_words:
        raise ValueError("overlap must be smaller than max_words")
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chunks, current = [], []
    for para in paragraphs:
        words = para.split()
        # A heading line sticks to the paragraph after it.
        if current and len(current) + len(words) > max_words:
            chunks.append(" ".join(current))
            current = current[-overlap_words:] if overlap_words else []
        while len(words) > max_words:  # a single giant paragraph gets a sliding window
            take = max_words - len(current)
            current.extend(words[:take])
            words = words[take:]
            chunks.append(" ".join(current))
            current = current[-overlap_words:] if overlap_words else []
        current.extend(words)
    if current:
        chunks.append(" ".join(current))
    return chunks
