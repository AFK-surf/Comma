#!/usr/bin/env python3
"""Refine a measured capacity bracket by indexing the exact same corpus prefix."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import time
import numpy as np
from corpus import Corpus, queries, exact_oracle
from opensearch_engine import Engine
from run import case, emit


class Prefix:
    def __init__(self, corpus, count):
        self.base, self.count, self.profile, self.path = corpus, count, corpus.profile, corpus.path
        last = corpus.metadata()[count-1]
        self.units = int(last["offset"] + last["units"])
    def metadata(self):
        return self.base.metadata()[:self.count]
    def vectors(self):
        return self.base.vectors()
    def summary(self):
        return Corpus.summary(self)


parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port',type=int,required=True)
parser.add_argument('--directory',type=Path,required=True)
parser.add_argument('--profiles',default='chat,balanced,media')
parser.add_argument('--stages',default='1000000,2000000')
parser.add_argument('--query-count',type=int,default=64)
args=parser.parse_args()
for profile in args.profiles.split(','):
    corpus=Corpus(args.directory,profile)
    metadata,matrix=corpus.metadata(),corpus.vectors()
    engine=Engine(args.port,f'comma-capacity-prefix-{profile}')
    if not engine.client.indices.exists(index=engine.index):
        engine.create()
    else:
        engine.client.indices.open(index=engine.index,request_timeout=180)
    loaded=engine.count()
    for target in map(int,args.stages.split(',')):
        end=min(corpus.count,int(np.searchsorted(metadata['offset']+metadata['units'],target))+1)
        prefix=Prefix(corpus,end)
        path=corpus.path/f'results-{prefix.units}-ef200-prefix-fresh64.json'
        if path.exists():continue
        if loaded>end:raise RuntimeError('Existing index is larger than requested prefix')
        start_time=last_progress=time.perf_counter()
        while loaded<end:
            batches=[]
            next_start=loaded
            for _ in range(4):
                if next_start>=end:break
                start_unit=int(metadata[next_start]['offset'])
                next_end=min(end,int(np.searchsorted(metadata['offset'],start_unit+8000)))
                next_end=max(next_start+1,next_end)
                batch=metadata[next_start:next_end]
                last_unit=int(batch[-1]['offset']+batch[-1]['units'])
                batches.append((batch,matrix[start_unit:last_unit]))
                next_start=next_end
            with ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(lambda pair:engine.insert(*pair),batches))
            loaded=next_start
            if time.perf_counter()-last_progress>15:
                emit('prefix_ingest',profile=profile,target=target,messages=loaded,
                     units=int(metadata[loaded-1]['offset']+metadata[loaded-1]['units']))
                last_progress=time.perf_counter()
        engine.refresh()
        if engine.count()!=end:raise RuntimeError('Unexpected parent message count')
        record={**prefix.summary(),'engine':engine.name,'ef_search':200,'label':'prefix-fresh64',
                'query_count':args.query_count,'repeats':1,'stats':engine.stats(),
                'ingest_seconds':time.perf_counter()-start_time,'cases':[]}
        emit('prefix_loaded',**{k:v for k,v in record.items() if k!='cases'})
        specs=[('semantic','ten',4,0),('semantic','full',8,0),('semantic','full',4,0),
               ('semantic','full',1,0),('semantic','one',4,0),('semantic','full',4,716),
               ('keyword','full',4,0),('hybrid','full',4,0)]
        for index,(mode,scope,concurrency,oldest) in enumerate(specs):
            seed=117893+index*1009
            requests=queries(args.query_count,seed)
            oracle=exact_oracle(prefix,requests,scopes=(scope,),oldest=oldest) if mode=='semantic' else {}
            measured=case(engine,requests,oracle,mode,scope,concurrency,1,oldest)
            measured['query_seed']=seed
            record['cases'].append(measured)
            emit('prefix_case',profile=profile,units=prefix.units,
                 **{k:v for k,v in measured.items() if k!='raw'})
            path.write_text(json.dumps(record,indent=2))
        record['stats_after']=engine.stats()
        path.write_text(json.dumps(record,indent=2))
    engine.client.indices.close(index=engine.index,request_timeout=180)
