#!/usr/bin/env python3
"""Disposable local fixture for the shipped message-search code; no provider data bodies."""
import argparse, csv, gzip, hashlib, json, re, time, uuid
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
import clickhouse_connect
import numpy as np

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--port', type=int, required=True)
p.add_argument('--daily', type=Path, required=True)
p.add_argument('--directory', type=Path, required=True)
p.add_argument('--database', default='message_search_runtime_0906')
a = p.parse_args()
assert re.fullmatch(r'message_search_runtime_[a-z0-9_]+', a.database), 'Use a disposable benchmark database'
a.directory.mkdir(parents=True, exist_ok=True)
manifest = json.loads((a.daily/'manifest.json').read_text())
tables = ('slack_messages', 'slack_message_payloads', 'slack_semantic_documents', 'slack_semantic_files')
daily = {}
for table in tables:
    with gzip.open(a.daily/(table+'.json.gz'), 'rt') as f:
        daily[table] = [json.loads(line) for line in f]
source_counts = {tuple(r[:4]): (r[4], r[5]) for r in daily[tables[0]]}
payload_counts = {tuple(r[:4]): r[4] for r in daily[tables[1]]}
doc_units, file_units = defaultdict(list), defaultdict(list)
for r in daily[tables[2]]: doc_units[tuple(r[:4])].extend([r[4]]*r[5])
for r in daily[tables[3]]: file_units[tuple(r[:4])].extend([r[4]]*r[5])
data = {t: [] for t in tables}
for key in sorted(set(source_counts) | set(payload_counts) | set(doc_units) | set(file_units)):
    tenant, workspace, channel, date = key
    n, deleted = source_counts.get(key, (0, 0))
    payloads = payload_counts.get(key, 0)
    units = doc_units[key]
    total = max(n, payloads, len(units), 1)
    start = int(datetime.strptime(date, '%Y-%m-%d').replace(tzinfo=timezone.utc).timestamp()*1e6)
    span = min(start+86400000000, manifest['reference_end_us'])-start
    stamps = [start+(i+1)*span//(total+1) for i in range(total)]
    for i in range(n): data[tables[0]].append([tenant, workspace, channel, stamps[i], 1, i >= n-deleted])
    for i in range(payloads): data[tables[1]].append([tenant, workspace, channel, stamps[i], 1])
    for i, count in enumerate(units):
        position = i*max(n, len(units))//max(len(units), 1)
        data[tables[2]].append([tenant, workspace, channel, stamps[position], 1, int(position < payloads), count])
    for i, count in enumerate(file_units[key]):
        position = i*7919%max(n, 1)
        data[tables[3]].append([tenant, workspace, channel, stamps[position], 1, int(position < payloads), f'F{start}{i:06d}', count])

# Anonymized, valid Salix IDs. One synthetic group per original tenant; every
# workspace/channel in that tenant is assigned to its group for this test.
# This is an upper-scope load fixture, NOT a reconstruction of real group ACLs.
tenants = {v:i for i,v in enumerate(sorted({r[0] for r in data[tables[0]]}))}
workspaces = {v:i for i,v in enumerate(sorted({r[1] for r in data[tables[0]]}))}
channels = {v:i for i,v in enumerate(sorted({tuple(r[:3]) for r in data[tables[0]]}))}
def scope(row):
    ti, wi = tenants[row[0]], workspaces[row[1]]
    body = str(1000000000000000100+ti)
    return {'tenant_id': 'ten1_'+body, 'group_id': 'grp1_'+body+'_1000000000000000200',
            'connect_id': f'imc1_{1000000000000000300+wi}', 'connect_generation':'',
            'workspace_id':f'TBENCH{wi}', 'channel_id':f'CBENCH{channels[tuple(row[:3])]:03d}'}

def ident(key):
    # Deterministic fixture identities only; runtime uses frozen random UUIDs.
    return str(uuid.uuid5(uuid.NAMESPACE_URL, json.dumps(key)))

def day(ts): return datetime.fromtimestamp(ts/1e6, timezone.utc).date()
def stamp(ts): return f'{ts//1000000}.{ts%1000000:06d}'
units_by_key = {tuple(r[:4]):r[6] for r in data[tables[2]]}
payload_keys = {tuple(r[:4]) for r in data[tables[1]]}
files_by_key = defaultdict(list)
for r in data[tables[3]]: files_by_key[tuple(r[:4])].append({'id': r[6]})
def body(key):
    marker = int(hashlib.sha256(json.dumps(key).encode()).hexdigest()[:8],16)%97
    return (f'marker_{marker:02d} synthetic retained message '+('x'*325))*max(units_by_key.get(key, 1), 1)

client = clickhouse_connect.get_client(host='127.0.0.1', port=a.port, autogenerate_session_id=False)
client.command(f'CREATE DATABASE {a.database}')
root = Path(__file__).resolve().parents[2]
for migration in sorted((root/'systems/apps/salix_analytics/priv/clickhouse/migrations').glob('*slack_*.sql')):
    sql = re.sub(r'^\s*--.*$', '', migration.read_text(), flags=re.M).replace('{{database}}', a.database)
    for statement in sql.split(';'):
        if statement.strip(): client.command(statement)

vectors = np.random.default_rng(20260906).normal(size=(4096,256)).astype(np.float32)
vectors /= np.linalg.norm(vectors,axis=1)[:,None]
vectors = vectors.tolist()

pub_file = (a.directory/'publications.csv').open('w')
source_file = (a.directory/'sources.csv').open('w')
file_file = (a.directory/'files.csv').open('w')
pub_csv, source_csv, file_csv = csv.writer(pub_file), csv.writer(source_file), csv.writer(file_file)
sequence = 0

def reference(row, component, file_id='', unit_count=1):
    global sequence
    sequence += 1
    key = tuple(row[:4]); s = scope(row); ts = row[3]
    result = dict(s, event_date=day(ts), message_ts_us=ts, message_ts=stamp(ts), thread_ts='',
                  actor_id='UBENCH', actor_kind='user', change_epoch=1,
                  message_identity=ident(key), payload_identity=ident(key) if key in payload_keys else 'absent',
                  source_version=1, payload_version=int(key in payload_keys), build_id=str(uuid.uuid4()),
                  build_sequence=sequence)
    pub_csv.writerow([*[s[k] for k in ('tenant_id','group_id','connect_id','connect_generation','workspace_id','channel_id')],
                      ts,component,1,result['build_id'],sequence,result['message_identity'],result['payload_identity'],
                      file_id,0,unit_count,'2026-09-06 00:00:00'])
    return result

loaded = {}
def insert(table, rows):
    count, batch, started = 0, [], time.perf_counter()
    for row in rows:
        batch.append(row)
        if len(batch) == 5000:
            client.insert(f'{a.database}.{table}', [list(r.values()) for r in batch], column_names=list(batch[0]), settings={'max_threads':2})
            count += len(batch); batch = []
    if batch:
        client.insert(f'{a.database}.{table}', [list(r.values()) for r in batch], column_names=list(batch[0]), settings={'max_threads':2})
        count += len(batch)
    loaded[table] = {'rows':count, 'insert_ms':(time.perf_counter()-started)*1000}
    print(json.dumps({'loaded':table, **loaded[table]}), flush=True)

for table in tables[:2]:
    def source_rows(table=table):
        for row in sorted(data[table],key=lambda r:(day(r[3]).replace(day=1),r[:4])):
            key=tuple(row[:4]); s=scope(row)
            result={k:s[k] for k in ('tenant_id','workspace_id','channel_id')}
            result.update(event_date=day(row[3]),message_ts_us=row[3],version=1,text=body(key),body_text='',
                          payload=json.dumps({'files':files_by_key[key],'padding':str(row[3])*110}),source_write_id=ident(key))
            if table==tables[0]:
                result.update(message_ts=stamp(row[3]),thread_ts='',deleted=row[5],actor_id='UBENCH',actor_kind='user')
                source_csv.writerow([s['tenant_id'],s['workspace_id'],s['channel_id'],row[3],1])
            yield result
    insert(table, source_rows())

def documents():
    for row in data[tables[0]]:
        result=reference(row,'lexical',unit_count=int(not row[5]))
        result.update(deleted=row[5],search_text='' if row[5] else body(tuple(row[:4]))+'\n')
        yield result
insert('slack_message_search_documents',documents())

def components():
    for row in data[tables[2]]:
        key=tuple(row[:4]); text=body(key)
        for unit in range(row[6]):
            result=reference(row,f'text:{unit*360}')
            result.update(component=f'text:{unit*360}',file_id='',file_epoch=0,chunks=[text[unit*360:unit*360+400]],
                          embeddings=[vectors[(row[3]+unit)%4096]],kinds=['message_text'],pages=[0],starts=[0],ends=[0])
            yield result
    seen_files=set()
    for row in data[tables[3]]:
        s=scope(row); file_key=(s['tenant_id'],s['workspace_id'],row[6]); count=row[7]
        if file_key not in seen_files:
            file_csv.writerow([*file_key,0,False]);seen_files.add(file_key)
        result=reference(row,'file:'+row[6],file_id=row[6],unit_count=count)
        result.update(component='file:'+row[6],file_id=row[6],file_epoch=0,
                      chunks=[f'marker_{i%97:02d} synthetic file segment {i}' for i in range(count)],
                      embeddings=[vectors[(row[3]+i)%4096] for i in range(count)],kinds=['document_text']*count,
                      pages=list(range(count)),starts=[0]*count,ends=[0]*count)
        yield result
insert('slack_message_search_components',components())
for f in (pub_file,source_file,file_file): f.close()
scopes=list({tuple(scope(r).items()):scope(r) for r in data[tables[0]]}.values())
output={'database':a.database,'reference_end_us':manifest['reference_end_us'],'scopes':scopes,
        'counts':loaded,'input_units':sum(r[6] for r in data[tables[2]])+sum(r[7] for r in data[tables[3]]),
        'method':'Actual staging daily counts and per-record unit histograms; synthetic keys within each day, group assignment, complete content, IDs and dense random vectors. No real model inference or relevance evaluation.'}
(a.directory/'fixture.json').write_text(json.dumps(output,indent=2)+'\n')
(a.directory/'pg-seed.sql').write_text('\\set ON_ERROR_STOP on\n'+ '\n'.join([
    f"\\copy slack_semantic.search_sources(tenant_id,workspace_id,channel_id,message_ts_us,change_epoch) FROM '{a.directory.resolve()}/sources.csv' WITH (FORMAT CSV, NULL '\\N')",
    f"\\copy slack_semantic.search_components(tenant_id,group_id,connect_id,connect_generation,workspace_id,channel_id,message_ts_us,component,change_epoch,build_id,build_sequence,message_identity,payload_identity,file_id,file_epoch,unit_count,published_at) FROM '{a.directory.resolve()}/publications.csv' WITH (FORMAT CSV, NULL '\\N')",
    f"\\copy slack_semantic.search_files(tenant_id,workspace_id,file_id,change_epoch,deleted) FROM '{a.directory.resolve()}/files.csv' WITH (FORMAT CSV, NULL '\\N')"
])+"\nSELECT setval('slack_semantic.search_build_sequence', (SELECT COALESCE(max(build_sequence),0)+1 FROM slack_semantic.search_components), false);\n")
print(json.dumps({'fixture':str(a.directory/'fixture.json'),'input_units':output['input_units']}),flush=True)
