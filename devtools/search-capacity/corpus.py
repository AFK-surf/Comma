"""Deterministic mixed-message index corpus; synthetic vectors, not a WeMM eval."""
from pathlib import Path
import json
import numpy as np

DIMENSIONS = 256
TOPICS = 1024
PROFILES = {
    "chat": [0.90, 0.05, 0.04, 0.01],
    "balanced": [0.60, 0.20, 0.15, 0.05],
    "media": [0.20, 0.20, 0.30, 0.30],
    "diffuse": [0.60, 0.20, 0.15, 0.05],
}
KINDS = ["text", "image", "audio", "video"]
UNIT_COUNTS = [1, 2, 12, 60]
META = np.dtype([
    ("id", "<u8"), ("offset", "<u8"), ("units", "<u4"),
    ("kind", "u1"), ("topic", "<u2"), ("tenant", "u1"),
    ("connect", "<u2"), ("channel", "<u2"), ("day", "<u2"),
])
PHRASES = [
    "发布回滚 deployment rollback release checklist and incident response",
    "身份认证 authentication token permissions group connect access",
    "数据库迁移 database schema online migration and stored data safety",
    "移动客户端 mobile client UI rendering scroll keyboard and message sync",
    "视频会议 video meeting transcript design decisions follow up actions",
    "监控告警 observability metrics latency saturation tracing and recovery",
    "媒体处理 image OCR audio transcription video frame extraction",
    "产品讨论 product roadmap user feedback priorities and implementation",
]


def normalized(values):
    return (values / np.linalg.norm(values, axis=-1, keepdims=True)).astype(np.float32)


def centers():
    rng = np.random.default_rng(91721)
    return normalized(rng.normal(size=(TOPICS, DIMENSIONS)).astype(np.float32))


def groups(connect):
    return ["full"] + (["ten"] if connect < 10 else []) + (["one"] if connect == 0 else [])


class Corpus:
    def __init__(self, directory, profile):
        self.path = Path(directory) / profile
        self.path.mkdir(parents=True, exist_ok=True)
        self.profile = profile
        self.meta_path = self.path / "messages.bin"
        self.vector_path = self.path / "vectors.f32"
        self.count = self.meta_path.stat().st_size // META.itemsize if self.meta_path.exists() else 0
        self.units = self.vector_path.stat().st_size // (4 * DIMENSIONS) if self.vector_path.exists() else 0
        self.centers = centers()
        self.rng = np.random.default_rng(53197 + list(PROFILES).index(profile))
        state_path = self.path / "generator.json"
        if state_path.exists():
            self.rng.bit_generator.state = json.loads(state_path.read_text())
        elif self.count:
            raise RuntimeError("Corpus generator checkpoint is missing")

    def generate(self, target_units, batch_units=4000):
        stop = min(target_units, self.units + batch_units)
        records, vectors = [], []
        offset = self.units
        while offset < stop:
            mid = self.count + len(records)
            kind = int(self.rng.choice(4, p=PROFILES[self.profile]))
            count = UNIT_COUNTS[kind]
            # Persistent long tail: ~0.1% of balanced messages are 500-unit video.
            if self.profile == "balanced" and mid % 997 == 996:
                kind, count = 3, 500
            topic = int(self.rng.integers(TOPICS))
            tenant = 2 if mid % 20 == 19 else 1
            connect = mid % 100
            day = int(self.rng.integers(730))
            records.append((mid, offset, count, kind, topic, tenant, connect, mid % 10000, day))
            center = self.centers[topic]
            if self.profile == "diffuse":
                center = normalized(self.rng.normal(size=(1, DIMENSIONS)).astype(np.float32))[0]
            base = center + self.rng.normal(0, .30 / 16, DIMENSIONS).astype(np.float32)
            block = base + self.rng.normal(0, .20 / 16, (count, DIMENSIONS)).astype(np.float32)
            vectors.append(normalized(block))
            offset += count
        metadata = np.array(records, dtype=META)
        matrix = np.concatenate(vectors)
        with self.meta_path.open("ab") as stream:
            metadata.tofile(stream)
        with self.vector_path.open("ab") as stream:
            matrix.tofile(stream)
        self.count += len(metadata)
        self.units += len(matrix)
        (self.path / "generator.json").write_text(json.dumps(self.rng.bit_generator.state))
        return metadata, matrix

    def metadata(self):
        return np.memmap(self.meta_path, dtype=META, mode="r")

    def vectors(self):
        return np.memmap(self.vector_path, dtype="<f4", mode="r", shape=(self.units, DIMENSIONS))

    def batches(self, first_message=0, messages_per_batch=300):
        meta, vectors = self.metadata(), self.vectors()
        for start in range(first_message, self.count, messages_per_batch):
            batch = meta[start:start + messages_per_batch]
            offset = int(batch[0]["offset"])
            end = int(batch[-1]["offset"] + batch[-1]["units"])
            yield batch, vectors[offset:end]

    def summary(self):
        meta = self.metadata()
        return {
            "profile": self.profile, "messages": self.count, "units": self.units,
            "units_per_message": self.units / self.count,
            "messages_by_kind": {kind: int(np.count_nonzero(meta["kind"] == i)) for i, kind in enumerate(KINDS)},
            "units_by_kind": {kind: int(meta["units"][meta["kind"] == i].sum()) for i, kind in enumerate(KINDS)},
            "channels": int(len(np.unique(meta["channel"]))), "days": 730,
        }


def unit_text(record, ordinal):
    topic = int(record["topic"])
    prefix = f"topic_{topic:04d} {PHRASES[topic % len(PHRASES)]} "
    return (prefix + f"message {int(record['id'])} segment {ordinal}. " + PHRASES[(topic + 1) % len(PHRASES)])


def unit_kind(kind, ordinal):
    return ["message_text", "image_visual" if ordinal % 2 == 0 else "ocr", "asr",
            ["video_frame", "video_ocr", "asr"][ordinal % 3]][kind]


def documents(metadata, matrix):
    base = int(metadata[0]["offset"])
    for rec in metadata:
        start = int(rec["offset"]) - base
        units = []
        for ordinal in range(int(rec["units"])):
            units.append({"embedding": np.asarray(matrix[start + ordinal]), "ordinal": ordinal,
                          "kind": unit_kind(int(rec["kind"]), ordinal),
                          "text": unit_text(rec, ordinal),
                          "start_ms": ordinal * 3000, "end_ms": (ordinal + 1) * 3000})
        yield {"message_id": int(rec["id"]), "tenant_id": int(rec["tenant"]),
               "groups": groups(int(rec["connect"])), "connect_id": int(rec["connect"]),
               "channel_id": int(rec["channel"]), "day": int(rec["day"]),
               "kind": KINDS[int(rec["kind"])], "topic": int(rec["topic"]),
               "search_text": " ".join(unit["text"] for unit in units), "units": units}


def queries(count=24, seed=89131):
    rng = np.random.default_rng(seed)
    topics = rng.choice(TOPICS, count, replace=False)
    matrix = centers()[topics] + rng.normal(0, .10 / 16, (count, DIMENSIONS)).astype(np.float32)
    return [{"id": i, "topic": int(topic), "text": f"topic_{int(topic):04d}", "vector": vector}
            for i, (topic, vector) in enumerate(zip(topics, normalized(matrix)))]


def eligible(metadata, scope="full", oldest=0):
    mask = (metadata["tenant"] == 1) & (metadata["day"] >= oldest)
    if scope == "ten":
        mask &= metadata["connect"] < 10
    elif scope == "one":
        mask &= metadata["connect"] == 0
    return mask


def exact_oracle(corpus, requests, scopes=("full", "ten", "one"), oldest=0, k=20):
    """Exact float32 cosine, max over ALL units per message; no topic shortcut."""
    q = np.array([r["vector"] for r in requests], dtype=np.float32)
    metadata, matrix = corpus.metadata(), corpus.vectors()
    best = {scope: [([], []) for _ in requests] for scope in scopes}
    for begin in range(0, corpus.count, 3000):
        batch = metadata[begin:begin + 3000]
        offset = int(batch[0]["offset"])
        stop = int(batch[-1]["offset"] + batch[-1]["units"])
        block = np.asarray(matrix[offset:stop])
        scores = (q @ block.T) / np.linalg.norm(block, axis=1)
        message_scores = np.maximum.reduceat(scores, (batch["offset"] - offset).astype(np.int64), axis=1)
        for scope in scopes:
            mask = eligible(batch, scope, oldest)
            ids = batch["id"][mask]
            selected = message_scores[:, mask]
            for qi in range(len(requests)):
                old_ids, old_scores = best[scope][qi]
                combined_scores = np.concatenate((old_scores, selected[qi]))
                combined_ids = np.concatenate((old_ids, ids)).astype(np.int64)
                keep = np.argsort(-combined_scores, kind="stable")[:k]
                best[scope][qi] = (combined_ids[keep], combined_scores[keep])
    return {scope: {r["id"]: [int(x) for x in best[scope][i][0]]
                    for i, r in enumerate(requests)} for scope in scopes}
