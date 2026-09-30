#!/usr/bin/env python3
"""Real-engine long-video crowding and fixed result-window checks."""
import argparse
import json
from pathlib import Path
import time
import numpy as np
from corpus import META, DIMENSIONS, normalized, documents
from opensearch_engine import Engine


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    nested = Engine(args.port, "comma-capacity-adversarial-nested")
    flat_index = "comma-capacity-adversarial-flat"
    for index in (nested.index, flat_index):
        if nested.client.indices.exists(index=index):
            nested.client.indices.delete(index=index)
    nested.create()
    nested.client.indices.create(index=flat_index, body={
        "settings": {"index.knn": True, "number_of_shards": 1, "number_of_replicas": 0},
        "mappings": {"properties": {"message_id": {"type": "long"},
            "embedding": {"type": "knn_vector", "dimension": DIMENSIONS,
                "space_type": "cosinesimil", "method": {"name": "hnsw", "engine": "lucene",
                "parameters": {"ef_construction": 100, "m": 16}}}}}})
    rng = np.random.default_rng(6139)
    query = normalized(rng.normal(size=(1, DIMENSIONS)).astype(np.float32))[0]
    video = normalized(query + rng.normal(0, .001 / 16, (500, DIMENSIONS)).astype(np.float32))
    other = normalized(query + rng.normal(0, .15 / 16, (40, DIMENSIONS)).astype(np.float32))
    matrix = np.concatenate((video, other))
    records = [(0, 0, 500, 3, 1, 1, 0, 0, 100)]
    records += [(i, 499+i, 1, 0, 1, 1, i % 100, i, 100+i) for i in range(1, 41)]
    metadata = np.array(records, dtype=META)
    nested.insert(metadata, matrix)
    bulk = []
    for doc in documents(metadata, matrix):
        for unit in doc["units"]:
            bulk.extend([{"index": {"_index": flat_index}},
                         {"message_id": doc["message_id"], "embedding": unit["embedding"]}])
    nested.client.bulk(body=bulk, refresh=True)
    nested.refresh()
    request = {"id": 0, "text": "topic_0001", "vector": query}
    started = time.perf_counter()
    flat = nested.client.search(index=flat_index, body={"size": 20,
        "_source": ["message_id"], "collapse": {"field": "message_id"},
        "query": {"knn": {"embedding": {"vector": query, "k": 200,
                    "method_parameters": {"ef_search": 200}}}}})
    flat_ms = (time.perf_counter() - started) * 1000
    nested_result = nested.search(request)
    assert len(nested_result["ids"]) == 20 and 0 in nested_result["ids"]
    window = nested.client.search(index=nested.index,
                                 body=nested.semantic_body(request, "full", size=200))
    ids = [int(h["_id"]) for h in window["hits"]["hits"]]
    assert len(ids) == len(set(ids)) == 41
    pages = [ids[i:i+20] for i in range(0, len(ids), 20)]
    # Reindex the whole immutable document: _source excludes vectors, so a
    # partial _update would not be a valid way to preserve the nested vectors.
    changed = next(documents(metadata[:1], matrix[:500]))
    changed["groups"] = ["different_group"]
    nested.client.index(index=nested.index, id="0", body=changed, refresh=True)
    after_scope_change = nested.search(request)
    assert 0 not in after_scope_change["ids"] and len(after_scope_change["ids"]) == 20
    result = {"video_units": 500, "other_messages": 40, "candidate_k": 200,
              "flat_collapse_messages": len(flat["hits"]["hits"]), "flat_latency_ms": flat_ms,
              "nested_messages": len(nested_result["ids"]),
              "nested_latency_ms": nested_result["latency_ms"],
              "window_messages": len(ids), "page_sizes": list(map(len, pages)),
              "duplicates_across_pages": 0, "scope_change_applied_after_refresh": True,
              "limitations": "Static in-memory window; refreshed index scope change, not production owner revocation protocol."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
    for index in (nested.index, flat_index):
        nested.client.indices.close(index=index)


if __name__ == "__main__":
    main()
