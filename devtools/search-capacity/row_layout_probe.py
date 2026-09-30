#!/usr/bin/env python3
"""Local-only physical row-read comparison; never an online table migration."""
import argparse
import json
from pathlib import Path
import time
import clickhouse_connect

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--query', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--layout', choices=('auto', 'Compact'), default='auto')
args = parser.parse_args()
client = clickhouse_connect.get_client(host='127.0.0.1', port=args.port,
                                      autogenerate_session_id=False)
latest = 1788678000000000
query_template = args.query.read_text()
results = []
baseline = None

for granularity in (8192, 2048, 1024):
    database = f'row_layout_probe_{args.layout.lower()}_g{granularity}'
    layout_settings = (',min_bytes_for_wide_part=1000000000,min_rows_for_wide_part=1000000'
                       if args.layout == 'Compact' else '')
    client.command(f'CREATE DATABASE {database}')
    source_schema = '''event_date Date, tenant_id String, workspace_id String,
        channel_id String, message_ts_us UInt64, message_ts String, thread_ts String,
        version UInt64, deleted Bool, text String, body_text String, payload String'''
    for table in ('slack_messages', 'slack_message_payloads'):
        client.command(f'''CREATE TABLE {database}.{table} ({source_schema})
            ENGINE=ReplacingMergeTree(version) PARTITION BY toYYYYMM(event_date)
            ORDER BY (tenant_id,workspace_id,channel_id,message_ts_us)
            SETTINGS index_granularity={granularity},index_granularity_bytes=10485760{layout_settings}''')
    client.command(f'''CREATE TABLE {database}.slack_semantic_documents (
        event_date Date,tenant_id String,workspace_id String,channel_id String,message_ts_us UInt64,
        source_version UInt64,payload_version UInt64,source_text String,chunks Array(String),
        embeddings Array(Array(Float32)),indexed_at DateTime64(3) DEFAULT now64(3))
        ENGINE=ReplacingMergeTree(indexed_at) PARTITION BY toYYYYMM(event_date)
        ORDER BY (tenant_id,workspace_id,channel_id,message_ts_us)
        SETTINGS index_granularity={granularity},index_granularity_bytes=10485760{layout_settings}''')
    client.command(f'''CREATE TABLE {database}.slack_semantic_files (
        event_date Date,tenant_id String,workspace_id String,channel_id String,message_ts_us UInt64,
        source_version UInt64,payload_version UInt64,source_files String,file_id String,
        chunks Array(String),kinds Array(String),pages Array(UInt32),starts Array(UInt64),
        ends Array(UInt64),embeddings Array(Array(Float32)),indexed_at DateTime64(3) DEFAULT now64(3))
        ENGINE=ReplacingMergeTree(indexed_at) PARTITION BY toYYYYMM(event_date)
        ORDER BY (tenant_id,workspace_id,channel_id,message_ts_us,file_id)
        SETTINGS index_granularity={granularity},index_granularity_bytes=10485760{layout_settings}''')
    client.command(f'''INSERT INTO {database}.slack_messages
        SELECT toDate(fromUnixTimestamp64Micro(toInt64({latest}-120000*60000000+number*60000000),'UTC')),
            'tenant','workspace',concat('C',leftPad(toString(number%40),3,'0')),
            {latest}-120000*60000000+number*60000000,
            toString({latest}-120000*60000000+number*60000000),'',1,false,
            concat('message ',toString(number)),'',
            concat('{{"files":[],"padding":"',repeat(toString(cityHash64(number)),100),'"}}')
        FROM numbers(120000)''', settings={'max_threads': 2})
    client.command(f'INSERT INTO {database}.slack_message_payloads SELECT * FROM {database}.slack_messages')
    client.command(f'''INSERT INTO {database}.slack_semantic_documents
        (event_date,tenant_id,workspace_id,channel_id,message_ts_us,source_version,payload_version,
         source_text,chunks,embeddings)
        SELECT event_date,tenant_id,workspace_id,channel_id,message_ts_us,1,1,concat(text,'\n'),[text],
            [arrayResize([toFloat32(1)],256,toFloat32(0))]
        FROM {database}.slack_messages WHERE cityHash64(message_ts_us)%100 < 55''')
    query = query_template.replace('{{database}}', database)
    parameters = {'tenant_id': 'tenant', 'workspace_id': 'workspace', 'channel_id': 'C010',
                  'oldest': latest - 60 * 86400000000, 'latest': latest, 'count': 20,
                  'vector': [1.0]+[0.0]*255}
    settings = {'max_threads': 1, 'max_execution_time': 2, 'max_rows_to_read': 200000,
                'max_bytes_to_read': 256*1024**2, 'max_memory_usage': 128*1024**2,
                'do_not_merge_across_partitions_select_final': 1, 'join_use_nulls': 0}
    # The first run measures the complete read with a bounded diagnostic row
    # ceiling. A separate run checks the original 65,536-row application budget.
    started = time.perf_counter()
    reply = client.query(query.removesuffix('\n').replace('FORMAT JSONEachRow',''),
                         parameters=parameters, settings=settings)
    rows = reply.result_rows
    if baseline is None:
        baseline = rows
    assert rows == baseline, 'A physical layout change must preserve all results'
    record = {'granularity': granularity, 'requested_layout': args.layout,
              'latency_ms': (time.perf_counter()-started)*1000,
              'hits': len(rows), 'same_results': True, 'summary': reply.summary,
              'application_budget_passed': None}
    try:
        checked = client.query(query.replace('FORMAT JSONEachRow',''), parameters=parameters,
                               settings={**settings, 'max_rows_to_read': 65536})
        assert checked.result_rows == baseline
        record['application_budget_passed'] = True
    except Exception as error:
        record['application_budget_passed'] = False
        record['budget_error'] = str(error)[:700]
    record['parts'] = client.query('''SELECT table,sum(rows),sum(marks),sum(bytes_on_disk),
        groupUniqArray(part_type) FROM system.parts WHERE active AND database={db:String}
        GROUP BY table ORDER BY table''', parameters={'db': database}).result_rows
    results.append(record)
    args.output.write_text(json.dumps(results, indent=2)+'\n')
    print(json.dumps(record), flush=True)
