"""Text -> vector. Vertex AI in production, a fake deterministic embedder offline.

The fake embedder is a "hashing trick" bag of words: each word (and word pair)
is hashed into one of 768 slots. Two texts that share words end up with similar
vectors, so retrieval tests behave sensibly without any API call. It is NOT a
semantic model ("hours" and "open" don't match unless they share words).
"""
import hashlib
import math
import re
import time

from config import Settings, offline
from observability.telemetry import record_llm_call, span

_WORD = re.compile(r"[a-z0-9]+")
_STOP = frozenset("a an and are as at be by for from has have i in is it its of on or that the this to was what when where which who will with you your can do does".split())


def _stem(w: str) -> str:
    # Crude plural/verb folding so "menus"/"menu" and "updates"/"update" share a slot.
    if len(w) > 4 and w.endswith("ing"):
        return w[:-3]
    if len(w) > 3 and w.endswith("s") and not w.endswith("ss"):
        return w[:-1]
    return w


def tokenize(text: str) -> list[str]:
    return [_stem(w) for w in _WORD.findall(text.lower()) if w not in _STOP]


def _normalize(vec):
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec]


class FakeEmbedder:
    model = "fake-embedder"

    def __init__(self, dim: int = 768):
        self.dim = dim

    def _embed(self, text: str) -> list[float]:
        vec = [0.0] * self.dim
        words = tokenize(text)
        feats = words + [f"{a}_{b}" for a, b in zip(words, words[1:])]
        for f in feats:
            h = int.from_bytes(hashlib.sha256(f.encode()).digest()[:8], "big")
            vec[h % self.dim] += 1.0 if (h >> 63) & 1 == 0 else -1.0
        return _normalize(vec)

    def embed_documents(self, texts):
        return [self._embed(t) for t in texts]

    def embed_query(self, text):
        return self._embed(text)


class VertexEmbedder:
    """Vertex AI text embeddings through the google-genai SDK.

    Auth: Application Default Credentials (on Cloud Run: the service account;
    locally: `gcloud auth application-default login`).
    """

    def __init__(self, settings: Settings):
        from google import genai  # imported lazily so OFFLINE mode never needs it
        from google.genai import types

        self._types = types
        self.model = settings.embedding_model
        self.dim = settings.embedding_dim
        self.client = genai.Client(vertexai=True, project=settings.gcp_project, location=settings.gcp_location)

    def _call(self, texts, task_type):
        out = []
        for i in range(0, len(texts), 100):  # stay well under per-request limits
            batch = texts[i:i + 100]
            start = time.perf_counter()
            with span("embed", model=self.model, batch=len(batch), task_type=task_type):
                resp = self.client.models.embed_content(
                    model=self.model, contents=batch,
                    config=self._types.EmbedContentConfig(task_type=task_type, output_dimensionality=self.dim))
            # Embedding APIs bill input tokens; approximate with ~4 chars/token for the cost log.
            approx_tokens = sum(len(t) for t in batch) // 4
            record_llm_call("embedder", self.model, approx_tokens, 0, (time.perf_counter() - start) * 1000)
            out.extend(e.values for e in resp.embeddings)
        return out

    def embed_documents(self, texts):
        return self._call(list(texts), "RETRIEVAL_DOCUMENT")

    def embed_query(self, text):
        return self._call([text], "RETRIEVAL_QUERY")[0]


def get_embedder(settings: Settings | None = None):
    settings = settings or Settings.from_env()
    if offline():
        return FakeEmbedder(settings.embedding_dim)
    return VertexEmbedder(settings)
