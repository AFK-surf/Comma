"""Runnable group-scoped mixed-message retrieval prototype using the official SDK."""
import time
import orjson
from opensearchpy import OpenSearch, helpers
from opensearchpy.serializer import JSONSerializer
from corpus import DIMENSIONS, documents


class NumpySerializer(JSONSerializer):
    def dumps(self, value):
        if isinstance(value, str):
            return value
        return orjson.dumps(value, option=orjson.OPT_SERIALIZE_NUMPY).decode()


class Engine:
    name = "opensearch_nested"

    def __init__(self, port, index, ef=200):
        self.index, self.ef = index, ef
        self.client = OpenSearch([{"host": "127.0.0.1", "port": port}],
                                 serializer=NumpySerializer(), http_compress=False,
                                 timeout=30, max_retries=0, retry_on_timeout=False, pool_maxsize=20)

    def create(self):
        self.client.indices.create(index=self.index, body={
            "settings": {"index": {"knn": True, "number_of_shards": 1,
                                     "number_of_replicas": 0, "refresh_interval": "-1"}},
            "mappings": {"dynamic": "strict", "_source": {"excludes": ["units.embedding", "search_text"]},
                "properties": {
                    "message_id": {"type": "long"}, "tenant_id": {"type": "integer"},
                    "groups": {"type": "keyword"}, "connect_id": {"type": "integer"},
                    "channel_id": {"type": "integer"}, "day": {"type": "integer"},
                    "kind": {"type": "keyword"}, "topic": {"type": "integer"},
                    "search_text": {"type": "text"},
                    "units": {"type": "nested", "properties": {
                        "embedding": {"type": "knn_vector", "dimension": DIMENSIONS,
                                      "space_type": "cosinesimil", "method": {"name": "hnsw",
                                      "engine": "lucene", "parameters": {"ef_construction": 100, "m": 16}}},
                        "ordinal": {"type": "integer"}, "kind": {"type": "keyword"},
                        "text": {"type": "text", "index": False},
                        "start_ms": {"type": "integer"}, "end_ms": {"type": "integer"}}}}}})

    def insert(self, metadata, matrix):
        actions = ({"_index": self.index, "_id": str(doc["message_id"]), "_source": doc}
                   for doc in documents(metadata, matrix))
        successful, errors = helpers.bulk(self.client, actions, chunk_size=300,
                                           max_chunk_bytes=8 * 1024 * 1024,
                                           request_timeout=120, raise_on_error=True)
        if errors or successful != len(metadata):
            raise RuntimeError(f"incomplete bulk: {successful}/{len(metadata)}")

    def refresh(self):
        self.client.indices.refresh(index=self.index, request_timeout=180)

    def count(self):
        return self.client.count(index=self.index)["count"]

    def stats(self):
        stats = self.client.indices.stats(index=self.index)
        total = stats["_all"]["primaries"]
        nodes = self.client.nodes.stats(metric="jvm,process,os")
        node = next(iter(nodes["nodes"].values()))
        return {"store_bytes": total["store"]["size_in_bytes"],
                "lucene_documents": total["docs"]["count"],
                "segments": total["segments"]["count"],
                "heap_used_bytes": node["jvm"]["mem"]["heap_used_in_bytes"],
                "heap_max_bytes": node["jvm"]["mem"]["heap_max_in_bytes"],
                "gc_ms": sum(v["collection_time_in_millis"] for v in node["jvm"]["gc"]["collectors"].values()),
                "cpu_percent": node["process"]["cpu"]["percent"]}

    @staticmethod
    def filters(scope, oldest=0):
        return [{"term": {"tenant_id": 1}}, {"term": {"groups": scope}}, {"range": {"day": {"gte": oldest}}}]

    def semantic_body(self, request, scope, oldest=0, size=20):
        return {"size": size, "track_total_hits": False, "timeout": "10s",
            "_source": {"excludes": ["units"]},
            "query": {"nested": {"path": "units", "score_mode": "max",
                "query": {"knn": {"units.embedding": {"vector": request["vector"],
                    "k": max(size, self.ef), "method_parameters": {"ef_search": max(size, self.ef)},
                    "filter": {"bool": {"filter": self.filters(scope, oldest)}}}}},
                "inner_hits": {"size": 1, "_source": {"includes": ["units.ordinal", "units.kind", "units.text", "units.start_ms", "units.end_ms"]}}}}}

    def keyword_body(self, request, scope, oldest=0, size=20):
        return {"size": size, "track_total_hits": False, "timeout": "10s",
                "_source": {"excludes": ["units"]}, "query": {"bool": {
                    "filter": self.filters(scope, oldest),
                    "must": {"match": {"search_text": request["text"]}}}}}

    @staticmethod
    def hits(response):
        if response.get("timed_out") or response.get("_shards", {}).get("failed", 0):
            raise RuntimeError("search timeout or failed shard")
        return response["hits"]["hits"]

    def search(self, request, scope="full", mode="semantic", oldest=0):
        started = time.perf_counter()
        if mode == "hybrid":
            # Explicit rank fusion of 100 lexical + 100 semantic roots (200 total).
            response = self.client.msearch(body=[{"index": self.index}, self.keyword_body(request, scope, oldest, 100),
                {"index": self.index}, self.semantic_body(request, scope, oldest, 100)])
            pages = [self.hits(page) for page in response["responses"]]
            scored, by_id = {}, {}
            for page in pages:
                for rank, hit in enumerate(page, 1):
                    mid = hit["_id"]
                    scored[mid] = scored.get(mid, 0) + 1.0 / (60 + rank)
                    by_id[mid] = hit
            hits = [by_id[mid] for mid in sorted(scored, key=lambda mid: (-scored[mid], int(mid)))[:20]]
            server_ms = max(page.get("took", 0) for page in response["responses"])
        else:
            body = self.semantic_body(request, scope, oldest) if mode == "semantic" else self.keyword_body(request, scope, oldest)
            response = self.client.search(index=self.index, body=body)
            hits, server_ms = self.hits(response), response.get("took", 0)
        ids = [int(hit["_id"]) for hit in hits]
        if len(ids) != len(set(ids)):
            raise RuntimeError("duplicate message in one result page")
        for hit in hits:
            source = hit["_source"]
            if source["tenant_id"] != 1 or scope not in source["groups"] or source["day"] < oldest:
                raise RuntimeError("out-of-scope result")
        return {"latency_ms": (time.perf_counter() - started) * 1000,
                "server_ms": server_ms, "ids": ids,
                "channels": list({hit["_source"]["channel_id"] for hit in hits}),
                "oldest_day": min((hit["_source"]["day"] for hit in hits), default=None),
                "locators": sum(bool(hit.get("inner_hits")) for hit in hits)}
