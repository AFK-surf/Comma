#!/usr/bin/env python3
"""Replay identical corpus prefixes through exact and bounded-candidate CH reads."""
import argparse
import json
from pathlib import Path
import time
import numpy as np
from corpus import Corpus, queries, exact_oracle
from clickhouse_engine import Engine
from run import case, emit


class Prefix:
    def __init__(self, corpus, count):
        self.corpus, self.count = corpus, count
        last = corpus.metadata()[count-1]
        self.units = int(last["offset"] + last["units"])
    def metadata(self):
        return self.corpus.metadata()[:self.count]
    def vectors(self):
        return self.corpus.vectors()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--profiles", default="chat,balanced,media")
    parser.add_argument("--stages", default="100000,300000,1000000")
    parser.add_argument("--query-count", type=int, default=24)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    output = args.directory / "clickhouse"
    output.mkdir(exist_ok=True)
    requests = queries(args.query_count)
    for profile in args.profiles.split(","):
        corpus = Corpus(args.directory, profile)
        engine = Engine(args.port, f"comma_capacity_{profile}")
        engine.create()
        loaded = 0
        meta, matrix = corpus.metadata(), corpus.vectors()
        existing = engine.client.query(f"SELECT count(),max(message_id) FROM {engine.database}.units").result_rows[0]
        if existing[0]:
            loaded = existing[1]+1
        for target in map(int,args.stages.split(",")):
            end = min(corpus.count, int(np.searchsorted(meta["offset"]+meta["units"], target))+1)
            prefix = Prefix(corpus, end)
            path = output / f"{profile}-{target}.json"
            if path.exists():
                continue
            started = time.perf_counter()
            last_progress = started
            for start in range(loaded, end, 1000):
                batch = meta[start:min(start+1000,end)]
                first_unit = int(batch[0]["offset"])
                last_unit = int(batch[-1]["offset"] + batch[-1]["units"])
                engine.insert(batch,matrix[first_unit:last_unit])
                if time.perf_counter()-last_progress>15:
                    emit("ch_ingest",profile=profile,units=last_unit,target=target)
                    last_progress=time.perf_counter()
            loaded=end
            stored=engine.client.query(f"SELECT count() FROM {engine.database}.units").result_rows[0][0]
            if stored != prefix.units:
                raise RuntimeError(f"prefix count mismatch {stored} != {prefix.units}")
            record={"profile":profile,"messages":end,"units":prefix.units,
                    "query_count":args.query_count,"repeats":args.repeats,
                    "ingest_seconds":time.perf_counter()-started,"cases":[],"warmup_failures":[]}
            emit("ch_loaded",**record)
            oracle=exact_oracle(prefix,requests)
            for ann in (False,True):
                engine.ann=ann
                name="ann200" if ann else "exact"
                sql,params=engine.query(requests[0],ann=ann)
                plan=engine.client.query("EXPLAIN indexes=1 "+sql,parameters=params,
                                        settings=engine.query_settings()).result_rows
                (output/f"{profile}-{target}-{name}-plan.txt").write_text("\n".join(str(row[0]) for row in plan))
                try:
                    for request in requests[:2]:
                        engine.search(request)
                except Exception as error:
                    failure={"algorithm":name,"query_id":request['id'],"error":str(error)[:1500]}
                    record['warmup_failures'].append(failure)
                    path.write_text(json.dumps(record,indent=2))
                    emit('ch_warmup_failure',profile=profile,units=prefix.units,**failure)
                    continue
                for scope, concurrency in [("full",1),("full",4),("full",8),("ten",4),("one",4)]:
                    measured=case(engine,requests,oracle,"semantic",scope,concurrency,args.repeats)
                    measured["algorithm"]=name
                    record["cases"].append(measured)
                    emit("ch_case",profile=profile,units=prefix.units,**{k:v for k,v in measured.items() if k!='raw'})
                    path.write_text(json.dumps(record,indent=2))
            record["parts"]=engine.client.query("SELECT count(),sum(rows),sum(bytes_on_disk) FROM system.parts "
                "WHERE active AND database={db:String} AND table='units'",parameters={"db":engine.database}).result_rows[0]
            path.write_text(json.dumps(record,indent=2))


if __name__=='__main__':
    main()
