#!/usr/bin/env python3
"""Load and measure a real, isolated search engine with mixed indexed messages."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import time
import threading
import numpy as np
from corpus import Corpus, PROFILES, queries, exact_oracle
from opensearch_engine import Engine


def emit(event, **values):
    print(json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%S"), "event": event, **values}), flush=True)


def case(engine, requests, oracle, mode, scope, concurrency, repeats=3, oldest=0):
    jobs = requests * repeats
    results = []
    stop = threading.Event()
    error_lock = threading.Lock()
    error_count = 0
    case_started = time.perf_counter()

    def one(request):
        nonlocal error_count
        if stop.is_set() or time.perf_counter() - case_started > 120:
            return {"skipped": True}
        started = time.perf_counter()
        try:
            result = engine.search(request, scope, mode, oldest)
            expected = oracle.get(scope, {}).get(request["id"])
            if mode == "semantic" and expected is not None:
                result["recall"] = len(set(result["ids"]) & set(expected)) / len(expected) if expected else float(not result["ids"])
                result["filled"] = len(result["ids"]) == len(expected)
            result["query_id"] = request["id"]
            return result
        except Exception as error:
            with error_lock:
                error_count += 1
                if error_count >= 3:
                    stop.set()
            return {"query_id": request["id"], "latency_ms": (time.perf_counter() - started) * 1000,
                    "error": str(error)[:800]}

    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        results = list(pool.map(one, jobs))
    wall = time.perf_counter() - started
    skipped = sum(bool(r.get("skipped")) for r in results)
    results = [r for r in results if not r.get("skipped")]
    elapsed = np.array([r["latency_ms"] for r in results])
    good = [r for r in results if "error" not in r]
    recall = [r["recall"] for r in good if "recall" in r]
    filled = [r["filled"] for r in good if "filled" in r]
    summary = {"mode": mode, "scope": scope, "concurrency": concurrency, "oldest_day": oldest,
        "requests": len(results), "skipped_after_failure_or_case_deadline": skipped,
        "wall_seconds": wall, "qps": len(results) / wall,
        "p50_ms": float(np.percentile(elapsed, 50)), "p95_ms": float(np.percentile(elapsed, 95)),
        "p99_ms": float(np.percentile(elapsed, 99)), "max_ms": float(elapsed.max()),
        "errors": len(results) - len(good),
        "error_examples": list(dict.fromkeys(r["error"] for r in results if "error" in r))[:2],
        "mean_recall_at_20": float(np.mean(recall)) if recall else None,
        "min_recall_at_20": float(np.min(recall)) if recall else None,
        "full_page_rate": float(np.mean(filled)) if filled else None,
        "mean_channels": float(np.mean([len(r["channels"]) for r in good])) if good else None,
        "raw": results}
    return summary


def checkpoint(path, value):
    path.write_text(json.dumps(value, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--prefix", default="comma-capacity")
    parser.add_argument("--profiles", default="chat,balanced,media")
    parser.add_argument("--stages", default="100000,300000,1000000,3000000,10000000")
    parser.add_argument("--query-count", type=int, default=24)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--ef", type=int, default=200)
    parser.add_argument("--ingest-workers", type=int, default=4)
    parser.add_argument("--label", default="")
    parser.add_argument("--slo-ms", type=float, default=2000)
    parser.add_argument("--benchmark-current", action="store_true")
    parser.add_argument("--ingest-only", action="store_true")
    parser.add_argument("--keep-going", action="store_true")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    requests = queries(args.query_count)
    all_records = []
    for profile in args.profiles.split(","):
        if profile not in PROFILES:
            raise ValueError(profile)
        corpus = Corpus(args.directory, profile)
        engine = Engine(args.port, f"{args.prefix}-{profile}", ef=args.ef)
        commit_path = corpus.path / "loaded.json"
        if not engine.client.indices.exists(index=engine.index):
            engine.create()
            checkpoint(commit_path, {"messages": 0, "units": 0})
        else:
            engine.client.indices.open(index=engine.index, request_timeout=180)
        committed = json.loads(commit_path.read_text())
        for batch, vectors in corpus.batches(committed["messages"]) if corpus.count > committed["messages"] else []:
            engine.insert(batch, vectors)
            committed = {"messages": int(batch[-1]["id"]) + 1,
                         "units": int(batch[-1]["offset"] + batch[-1]["units"])}
            checkpoint(commit_path, committed)
        stages = [corpus.units] if args.benchmark_current else [int(s) for s in args.stages.split(",")]
        for target in stages:
            label = "-" + args.label if args.label else ""
            result_path = corpus.path / f"results-{target}-ef{args.ef}{label}.json"
            if result_path.exists() and not args.benchmark_current:
                all_records.append(json.loads(result_path.read_text()))
                continue
            if target < corpus.units and not args.benchmark_current:
                continue
            started, previous_units = time.perf_counter(), corpus.units
            last_progress = started
            try:
                while corpus.units < target:
                    if shutil.disk_usage(args.directory).free < 35 * 1024**3:
                        raise RuntimeError("benchmark disk floor: retain 35 GiB free")
                    batches = []
                    for _ in range(args.ingest_workers):
                        if corpus.units < target:
                            batches.append(corpus.generate(target))
                    with ThreadPoolExecutor(max_workers=args.ingest_workers) as pool:
                        list(pool.map(lambda pair: engine.insert(*pair), batches))
                    checkpoint(commit_path, {"messages": corpus.count, "units": corpus.units})
                    if time.perf_counter() - last_progress > 15:
                        emit("ingest", profile=profile, target=target, messages=corpus.count,
                             units=corpus.units, elapsed_seconds=time.perf_counter() - started)
                        last_progress = time.perf_counter()
                engine.refresh()
                if engine.count() != corpus.count:
                    raise RuntimeError(f"message count mismatch: {engine.count()} != {corpus.count}")
            except Exception as error:
                failure = {**corpus.summary(), "target": target, "phase": "ingest",
                           "error": str(error)[:3000], "elapsed_seconds": time.perf_counter() - started}
                checkpoint(corpus.path / f"failure-{target}.json", failure)
                emit("ingest_failure", **failure)
                raise
            load_seconds = time.perf_counter() - started
            record = {**corpus.summary(), "engine": engine.name, "ef_search": args.ef,
                      "query_count": args.query_count, "repeats": args.repeats, "label": args.label,
                      "target": target, "ingest_seconds": load_seconds,
                      "new_units_per_second": (corpus.units - previous_units) / load_seconds,
                      "stats": engine.stats(), "cases": []}
            emit("loaded", **{k: v for k, v in record.items() if k != "cases"})
            if args.ingest_only:
                continue
            oracle_started = time.perf_counter()
            oracle = exact_oracle(corpus, requests)
            checkpoint(corpus.path / f"oracle-{corpus.units}-q{args.query_count}.json", oracle)
            emit("oracle", profile=profile, units=corpus.units, seconds=time.perf_counter() - oracle_started)
            for request in requests[:4]:
                engine.search(request)
            # Closed-loop independent clients. Wall time includes queueing and HTTP.
            configurations = [("semantic", "full", c) for c in (1, 4, 8)]
            configurations += [("semantic", scope, 4) for scope in ("ten", "one")]
            configurations += [(mode, "full", 4) for mode in ("keyword", "hybrid")]
            for mode, scope, concurrency in configurations:
                measured = case(engine, requests, oracle, mode, scope, concurrency, args.repeats)
                record["cases"].append(measured)
                emit("case", profile=profile, units=corpus.units,
                     **{k: v for k, v in measured.items() if k != "raw"})
                checkpoint(result_path, record)
            record["stats_after"] = engine.stats()
            checkpoint(result_path, record)
            all_records.append(record)
            baseline = record["cases"][0]
            # At a failed single-client latency boundary, larger data cannot be
            # called supported without further evidence. Quality is reported
            # independently; it never gets silently relaxed to declare success.
            if not args.keep_going and (baseline["errors"] or baseline["p95_ms"] > args.slo_ms * 2):
                emit("scale_stop", profile=profile, units=corpus.units,
                     reason="single-client p95 exceeds twice the SLO or queries fail")
                break
        # Keep data for reproducibility but release this index's open readers.
        engine.client.indices.close(index=engine.index, request_timeout=180)
    checkpoint(args.directory / "summary.json", all_records)


if __name__ == "__main__":
    main()
