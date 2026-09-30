"""Independent narrow ClickHouse exact/ANN reference, using clickhouse-connect."""
import time
import clickhouse_connect
from corpus import DIMENSIONS, unit_text, unit_kind


class Engine:
    name = "clickhouse_units"

    def __init__(self, port, database, ann=False):
        self.port, self.database, self.ann = port, database, ann
        self.client = self.new_client()

    def new_client(self):
        return clickhouse_connect.get_client(host="127.0.0.1", port=self.port,
            username="default", password="", autogenerate_session_id=False,
            connect_timeout=5, send_receive_timeout=120)

    def create(self):
        self.client.command(f"CREATE DATABASE IF NOT EXISTS {self.database}")
        self.client.command(f"""CREATE TABLE IF NOT EXISTS {self.database}.units (
          message_id UInt64, unit_ordinal UInt16, tenant_id UInt16, connect_id UInt16,
          channel_id UInt16, day UInt16, kind LowCardinality(String), text String,
          vector Array(Float32) CODEC(NONE),
          INDEX vector_idx vector TYPE vector_similarity('hnsw','cosineDistance',256,'f32',16,100)
        ) ENGINE=MergeTree PARTITION BY tenant_id
        ORDER BY (tenant_id,connect_id,message_id,unit_ordinal)
        SETTINGS min_bytes_for_wide_part=0,min_rows_for_wide_part=0""")

    def insert(self, metadata, matrix):
        values = [[] for _ in range(9)]
        base = int(metadata[0]["offset"])
        for rec in metadata:
            offset = int(rec["offset"]) - base
            for unit in range(int(rec["units"])):
                row = [int(rec["id"]), unit, int(rec["tenant"]), int(rec["connect"]),
                       int(rec["channel"]), int(rec["day"]), unit_kind(int(rec["kind"]), unit),
                       unit_text(rec, unit), matrix[offset+unit].tolist()]
                for column, value in zip(values, row):
                    column.append(value)
        self.client.insert(f"{self.database}.units", values, column_oriented=True)

    def query(self, request, scope="full", ann=False, oldest=0):
        filters = "tenant_id=1 AND day >= {oldest:UInt16}"
        if scope == "ten":
            filters += " AND connect_id < 10"
        elif scope == "one":
            filters += " AND connect_id = 0"
        if ann:
            source = f"""SELECT message_id,channel_id,day,connect_id,unit_ordinal,
                cosineDistance(vector,{{q:Array(Float32)}}) AS distance
                FROM {self.database}.units WHERE {filters}
                ORDER BY distance LIMIT 200"""
            query = f"""SELECT message_id, argMin(tuple(channel_id,day,unit_ordinal,connect_id),distance),
                min(distance)
                FROM ({source}) GROUP BY message_id ORDER BY min(distance) LIMIT 20"""
        else:
            query = f"""SELECT message_id,argMin(tuple(channel_id,day,unit_ordinal,connect_id),distance),
                min(distance)
                FROM (SELECT message_id,channel_id,day,connect_id,unit_ordinal,
                             cosineDistance(vector,{{q:Array(Float32)}}) AS distance
                      FROM {self.database}.units WHERE {filters})
                GROUP BY message_id ORDER BY min(distance) LIMIT 20"""
        return query, {"q": request["vector"].tolist(), "oldest": oldest}

    def search(self, request, scope="full", mode="semantic", oldest=0):
        started = time.perf_counter()
        query, parameters = self.query(request, scope, ann=self.ann, oldest=oldest)
        result = self.client.query(query, parameters=parameters, settings=self.query_settings())
        rows = result.result_rows
        locators = [(row[1][3], row[0], row[1][2]) for row in rows]
        excerpts = self.client.query(f"""SELECT message_id,unit_ordinal,kind,text
              FROM {self.database}.units
              WHERE tenant_id=1 AND (connect_id,message_id,unit_ordinal)
                IN {{hits:Array(Tuple(UInt16,UInt64,UInt16))}} LIMIT 20""",
              parameters={"hits": locators}, settings={"max_threads":4,"max_execution_time":10}) if locators else None
        return {"latency_ms": (time.perf_counter()-started)*1000,
                "ids": [row[0] for row in rows], "channels": list({row[1][0] for row in rows}),
                "oldest_day": min((row[1][1] for row in rows),default=None),
                "locators": len(excerpts.result_rows) if excerpts else 0,
                "server_ms": int(result.summary.get("elapsed_ns",0))/1e6,
                "read_bytes": int(result.summary.get("read_bytes",0)) + (int(excerpts.summary.get("read_bytes",0)) if excerpts else 0),
                "read_rows": int(result.summary.get("read_rows",0)) + (int(excerpts.summary.get("read_rows",0)) if excerpts else 0)}

    @staticmethod
    def query_settings():
        return {"max_threads": 4, "max_execution_time": 10,
                "max_memory_usage": 2 * 1024**3,
                "vector_search_with_rescoring": 1,
                "hnsw_candidate_list_size_for_search": 200}
