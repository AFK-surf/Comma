#!/usr/bin/env python3
"""Replay actual metadata SQL against an isolated ten-times-larger body copy."""
import argparse, json, re, uuid
from pathlib import Path
import clickhouse_connect

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--port', type=int, required=True)
p.add_argument('--database', required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
assert re.fullmatch(r'message_search_runtime_[a-z0-9_]+', a.database)
c = clickhouse_connect.get_client(host='127.0.0.1', port=a.port, autogenerate_session_id=False)
copy = 'message_search_runtime_body_' + uuid.uuid4().hex[:10]
c.command('CREATE DATABASE ' + copy)
results = []
try:
    c.command('SYSTEM FLUSH LOGS')
    for table in ('slack_messages', 'slack_message_payloads'):
        ddl = c.query(f'SHOW CREATE TABLE {a.database}.{table}').first_row[0]
        c.command(ddl.replace(a.database + '.', copy + '.', 1))
        # Valid JSON plus large scalar text. No authority or metadata changes.
        days = c.query(f'SELECT DISTINCT event_date FROM {a.database}.{table} ORDER BY event_date').result_rows
        for (day,) in days:
            c.command(f'''INSERT INTO {copy}.{table} SELECT * REPLACE(
              repeat(text, 10) AS text, repeat(body_text, 10) AS body_text,
              toJSONString(map('padding', repeat(payload, 10))) AS payload)
              FROM {a.database}.{table} WHERE event_date={{day:Date}}
              SETTINGS max_threads=1, max_block_size=256, max_insert_block_size=256,
                min_insert_block_size_rows=0, min_insert_block_size_bytes=0,
                max_memory_usage=536870912''', parameters={'day': day})
        query = c.query('''SELECT query FROM system.query_log
          WHERE type='QueryFinish' AND startsWith(query,'SELECT workspace_id, channel_id')
            AND position(query,{table:String})>0 LIMIT 1''',
          parameters={'table': a.database + '.' + table + ' FINAL'}).first_row[0].rsplit('FORMAT JSONEachRow', 1)[0]
        rows, ids = [], []
        for database in (a.database, copy):
            result = c.query(query.replace(a.database + '.', database + '.'),
              settings={'max_threads': 1, 'max_memory_usage': 64*1024**2})
            rows.append(sorted(result.result_rows)); ids.append(result.query_id)
        assert rows[0] == rows[1]
        c.command('SYSTEM FLUSH LOGS')
        stats = c.query('''SELECT query_id, read_rows, read_bytes, memory_usage,
          query_duration_ms FROM system.query_log WHERE type='QueryFinish'
          AND query_id IN {ids:Array(String)}''', parameters={'ids': ids}).named_results()
        stats = {r['query_id']: r for r in stats}
        sizes = []
        for database in (a.database, copy):
            sizes.append(c.query(f'''SELECT sum(length(text)+length(body_text)+length(payload))
              FROM {database}.{table} SETTINGS max_threads=1,max_memory_usage=536870912''').first_row[0])
        results.append({'table': table, 'equal_metadata': True, 'hits': len(rows[0]),
          'body_bytes': sizes, 'normal': stats[ids[0]], 'large': stats[ids[1]]})
        print(json.dumps(results[-1]), flush=True)
    a.output.write_text(json.dumps({'tables': results,
      'method': 'Independent table copy; identical metadata, valid expanded JSON and tenfold text. Actual runtime current_sources SQL. Logical bytes from query_log, not physical disk IO.'}, indent=2)+'\n')
finally:
    c.command('DROP DATABASE ' + copy)
