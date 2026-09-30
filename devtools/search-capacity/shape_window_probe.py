#!/usr/bin/env python3
"""Local window replay using real key/unit counts and synthetic content only."""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import gzip
import json
from pathlib import Path
import time
import clickhouse_connect

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--metadata', type=Path, required=True)
parser.add_argument('--query', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--granularity', type=int, default=2048, choices=(1024,2048))
parser.add_argument('--daily', action='store_true', help='Expand per-day count/histogram inputs into synthetic keys')
args = parser.parse_args()
manifest_path=args.metadata/'manifest.json'
metadata_manifest=json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
tables = ('slack_messages','slack_message_payloads','slack_semantic_documents','slack_semantic_files')
data = {}
for table in tables:
    with gzip.open(args.metadata/(table+'.json.gz'),'rt') as source:
        data[table] = [json.loads(line) for line in source if line.strip()]

if args.daily:
    end=metadata_manifest['reference_end_us']
    daily=data
    source_counts={tuple(r[:4]):[r[4],r[5]] for r in daily['slack_messages']}
    payload_counts={tuple(r[:4]):r[4] for r in daily['slack_message_payloads']}
    document_units=defaultdict(list)
    file_units=defaultdict(list)
    for row in daily['slack_semantic_documents']:
        document_units[tuple(row[:4])].extend([row[4]]*row[5])
    for row in daily['slack_semantic_files']:
        file_units[tuple(row[:4])].extend([row[4]]*row[5])
    data={t:[] for t in tables}
    keys=set(source_counts)|set(payload_counts)|set(document_units)|set(file_units)
    for key in sorted(keys):
        tenant,workspace,channel,date=key
        n,deleted=source_counts.get(key,[0,0])
        p=payload_counts.get(key,0)
        units=document_units[key]
        total=max(n,p,len(units),1)
        start=int(datetime.strptime(date,'%Y-%m-%d').replace(tzinfo=timezone.utc).timestamp()*1e6)
        span=min(start+86400000000,end)-start
        assert span>total, 'Invalid daily date/range'
        stamps=[start+(i+1)*span//(total+1) for i in range(total)]
        for i in range(n):
            data['slack_messages'].append([tenant,workspace,channel,stamps[i],1,i>=n-deleted])
        for i in range(p):
            data['slack_message_payloads'].append([tenant,workspace,channel,stamps[i],1])
        for i,count in enumerate(units):
            position=i*max(n,len(units))//max(len(units),1)
            data['slack_semantic_documents'].append([tenant,workspace,channel,stamps[position],1,int(position<p),count])
        for i,count in enumerate(file_units[key]):
            position=i*7919%max(n,1)
            data['slack_semantic_files'].append([tenant,workspace,channel,stamps[position],1,int(position<p),f'F{start}{i:06d}',count])
    for table in tables:
        count_column=4 if table in tables[:2] else 5
        assert len(data[table])==sum(row[count_column] for row in daily[table])

client = clickhouse_connect.get_client(host='127.0.0.1',port=args.port,
                                      autogenerate_session_id=False)
db = f'row_shape_g{args.granularity}'
client.command(f'CREATE DATABASE {db}')
for table in tables:
    client.command(f'CREATE TABLE {db}.{table} AS row_layout_probe_compact_g{args.granularity}.{table}')

file_ids = defaultdict(set)
for row in data['slack_semantic_files']:
    file_ids[tuple(row[:4])].add(row[6])
manifest = {key:json.dumps([{'id':fid} for fid in sorted(ids)],separators=(',',':'))
            for key,ids in file_ids.items()}
vector = [1.0]+[0.0]*255
def day(ts):
    return datetime.fromtimestamp(ts/1e6,timezone.utc).date()
def text(row):
    return 'synthetic message '+str(row[3])
def generated_rows(table, records):
    for row in records:
        tenant,workspace,channel,ts = row[:4]
        key = tuple(row[:4])
        if table in ('slack_messages','slack_message_payloads'):
            payload='{"files":'+manifest.get(key,'[]')+',"padding":"'+str(ts)*110+'"}'
            yield [day(ts),tenant,workspace,channel,ts,f'{ts//1000000}.{ts%1000000:06d}',
                   '',row[4],bool(row[5]) if table=='slack_messages' else False,
                   text(row),'',payload]
        elif table=='slack_semantic_documents':
            units=row[6]
            yield [day(ts),tenant,workspace,channel,ts,row[4],row[5],text(row)+'\n',
                   [(text(row)+' synthetic chunk '+str(i)+' '+('x'*160)) for i in range(units)],
                   [vector]*units]
        else:
            units=row[7]
            yield [day(ts),tenant,workspace,channel,ts,row[4],row[5],manifest.get(key,'[]'),row[6],
                   [(text(row)+' synthetic file chunk '+str(i)+' '+('x'*160)) for i in range(units)],
                   ['document_text']*units,[0]*units,list(range(units)),list(range(1,units+1)),
                   [vector]*units]

columns={
 'slack_messages':'event_date tenant_id workspace_id channel_id message_ts_us message_ts thread_ts version deleted text body_text payload'.split(),
 'slack_message_payloads':'event_date tenant_id workspace_id channel_id message_ts_us message_ts thread_ts version deleted text body_text payload'.split(),
 'slack_semantic_documents':'event_date tenant_id workspace_id channel_id message_ts_us source_version payload_version source_text chunks embeddings'.split(),
 'slack_semantic_files':'event_date tenant_id workspace_id channel_id message_ts_us source_version payload_version source_files file_id chunks kinds pages starts ends embeddings'.split()
}
for table in tables:
    records=sorted(data[table],key=lambda r:(day(r[3]).replace(day=1),r[:4]))
    for start in range(0,len(records),10000):
        client.insert(f'{db}.{table}',list(generated_rows(table,records[start:start+10000])),
                      column_names=columns[table],settings={'max_threads':2})
    actual=client.query(f'SELECT count() FROM {db}.{table}').result_rows[0][0]
    assert actual==len(records),(table,actual,len(records))
    print(json.dumps({'loaded':table,'rows':actual}),flush=True)

scopes=sorted({tuple(row[:3]) for t in tables[2:] for row in data[t]})
assert len(scopes)<=50, 'This one-off replay is bounded to 50 scopes'
latest=metadata_manifest.get('reference_end_us',int(time.time()*1000000))
result={'granularity':args.granularity,'query_end_us':latest,
        'metadata_counts':{t:len(data[t]) for t in tables},'scopes':len(scopes),
        'method':metadata_manifest.get('method','Supplied keys, timestamps, versions and vector counts; synthetic bodies, chunks, file manifests and vectors.')+' Compact layout, 20 candidates, sequential one-sample SQL; not P95/SLA.',
        'cases':[]}
sql=args.query.read_text().replace('{{database}}',db).replace('FORMAT JSONEachRow','')
settings={'max_rows_to_read':65536,'max_bytes_to_read':256*1024**2,
          'max_memory_usage':128*1024**2,'max_execution_time':2,'max_threads':1,
          'join_use_nulls':0,'do_not_merge_across_partitions_select_final':1}
counts=defaultdict(int)
for row in data['slack_messages']:
    if not row[5]:counts[tuple(row[:3])]+=1
for days in (30,60,90,180,365):
    current=[]
    for index,(tenant,workspace,channel) in enumerate(scopes):
        params={'tenant_id':tenant,'workspace_id':workspace,'channel_id':channel,
                'oldest':latest-days*86400000000,'latest':latest,'count':20,'vector':vector}
        started=time.perf_counter()
        record={'scope':index,'days':days,'scope_total_messages':counts[(tenant,workspace,channel)]}
        try:
            reply=client.query(sql,parameters=params,settings=settings)
            record.update(ok=True,hits=len(reply.result_rows),summary=reply.summary)
        except Exception as error:
            record.update(ok=False,error=str(error)[:700])
        record['elapsed_ms']=(time.perf_counter()-started)*1000
        current.append(record)
    result['cases']+=current
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'days':days,'passed':sum(r['ok'] for r in current),'total':len(current),
          'max_ms':max(r['elapsed_ms'] for r in current),
          'max_passed_rows':max((int(r['summary']['read_rows']) for r in current if r['ok']),default=None),
          'failures':[{'scope':r['scope'],'messages':r['scope_total_messages'],'error':r['error']} for r in current if not r['ok']]}),flush=True)
result['parts']=client.query('''SELECT table,sum(rows),sum(marks),sum(bytes_on_disk),groupUniqArray(part_type)
    FROM system.parts WHERE active AND database={db:String} GROUP BY table ORDER BY table''',parameters={'db':db}).result_rows
args.output.write_text(json.dumps(result,indent=2)+'\n')
