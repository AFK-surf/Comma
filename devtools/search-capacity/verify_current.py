#!/usr/bin/env python3
"""Fresh-query verification of a loaded index; different seed for every case."""
import argparse
import json
from pathlib import Path
import time
from corpus import Corpus, queries, exact_oracle
from opensearch_engine import Engine
from run import case, emit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--directory", type=Path, required=True)
parser.add_argument("--profiles", default="chat,balanced,media")
parser.add_argument("--prefix", default="comma-capacity-main")
parser.add_argument("--query-count", type=int, default=64)
parser.add_argument("--ef", type=int, default=200)
parser.add_argument("--label", default="fresh")
args = parser.parse_args()
for profile in args.profiles.split(","):
    corpus = Corpus(args.directory, profile)
    engine = Engine(args.port, f"{args.prefix}-{profile}", args.ef)
    engine.client.indices.open(index=engine.index, request_timeout=180)
    record = {**corpus.summary(), "engine": engine.name, "label": args.label,
              "ef_search": args.ef, "query_count": args.query_count, "repeats": 1,
              "stats": engine.stats(), "cases": [],
              "method": "No explicit warmup. Every case uses a distinct seed and fresh query vectors. OS page cache is not forcibly cleared."}
    path = corpus.path / f"results-{corpus.units}-ef{args.ef}-{args.label}.json"
    # Begin with the previously slow scope. Other cases have independent query
    # topics/noise, so the single-client run cannot prime the C8 query set.
    specs = [("semantic", "ten", 4, 0), ("semantic", "full", 8, 0),
             ("semantic", "full", 4, 0), ("semantic", "full", 1, 0),
             ("semantic", "one", 4, 0), ("semantic", "full", 4, 716),
             ("keyword", "full", 4, 0), ("hybrid", "full", 4, 0)]
    for index, (mode, scope, concurrency, oldest) in enumerate(specs):
        seed = 117893 + index * 1009
        requests = queries(args.query_count, seed)
        oracle = {}
        if mode == "semantic":
            started = time.perf_counter()
            oracle = exact_oracle(corpus, requests, scopes=(scope,), oldest=oldest)
            emit("fresh_oracle", profile=profile, units=corpus.units, scope=scope,
                 concurrency=concurrency, seconds=time.perf_counter()-started)
        measured = case(engine,requests,oracle,mode,scope,concurrency,1,oldest)
        measured["query_seed"] = seed
        record["cases"].append(measured)
        emit("fresh_case",profile=profile,units=corpus.units,
             **{key:value for key,value in measured.items() if key!='raw'})
        path.write_text(json.dumps(record,indent=2))
    record["stats_after"] = engine.stats()
    path.write_text(json.dumps(record,indent=2))
    engine.client.indices.close(index=engine.index,request_timeout=180)
