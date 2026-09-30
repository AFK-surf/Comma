#!/usr/bin/env python3
"""Compare actual optimized SQL against one global exact aggregation, locally only."""
import argparse,json,re
from pathlib import Path
import clickhouse_connect
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--port',type=int,required=True)
p.add_argument('--database',required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
assert re.fullmatch(r'message_search_runtime_[a-z0-9_]+',a.database)
c=clickhouse_connect.get_client(host='127.0.0.1',port=a.port,autogenerate_session_id=False)
c.command('SYSTEM FLUSH LOGS')
queries=c.query("""SELECT DISTINCT query FROM system.query_log
 WHERE type='QueryFinish' AND startsWith(query,'SELECT tenant_id, group_id, workspace_id')
 AND position(query,{db:String})>0 AND position(query,'cosineDistance(')>0
 AND position(query,'FORMAT JSONEachRow')>0
 AND position(query,'SELECT build_id FROM')>0
 AND position(query,'CBENCH')=0 AND position(query,'BY connect_id')>0 LIMIT 200""",parameters={'db':a.database}).result_rows
by_count = {100: [], 200: []}
for row in queries:
    count = int(re.findall(r"LIMIT _CAST\((\d+), 'UInt32'\) SETTINGS", row[0])[-1])
    if count in by_count and len(by_count[count]) < 10:
        by_count[count].append(row)
queries = by_count[100] + by_count[200]
assert len(queries)==20, 'Run the complete varied-query fixture first (ten queries at each candidate limit)'
settings={'max_memory_usage':128*1024**2,'max_threads':1,'max_execution_time':2,
          'max_rows_to_read':2097152,'max_bytes_to_read':512*1024**2,
          'do_not_merge_across_partitions_select_final':1,'join_use_nulls':0}
checks=[]
def wide_final_reference(rows):
    """Restore the unoptimized wide FINAL; production instead finalizes UUIDs."""
    wrapped = 'WHERE (build_id IN (' in rows
    marker = 'WHERE (build_id IN (' if wrapped else 'WHERE build_id IN ('
    assert marker in rows, 'Expected the final runtime build-ID preselection'
    begin = rows.index(marker)
    pos = begin + len(marker)
    depth, quote = 1, False
    while depth:
        char = rows[pos]
        if char == '\\' and quote:
            pos += 2
            continue
        if char == "'":
            quote = not quote
        elif not quote:
            depth += int(char == '(') - int(char == ')')
        pos += 1
    if wrapped:
        assert rows[pos] == ')'
        pos += 1
    assert rows[pos:].startswith(' AND ')
    rows = rows[:begin] + 'WHERE ' + rows[pos+5:]
    rows, replaced = re.subn(r'SELECT \* FROM (\S+) PREWHERE', r'SELECT * FROM \1 FINAL PREWHERE', rows, count=1)
    assert replaced == 1
    assert 'SELECT build_id FROM' not in rows
    return rows

for number,(query,) in enumerate(queries):
    query=query.rsplit('FORMAT JSONEachRow',1)[0]
    start=query.index('SELECT tenant_id, group_id, connect_id, connect_generation, workspace_id, channel_id, message_ts_us, component')
    end=query.index(') AS r GROUP BY tenant_id, group_id, connect_id, workspace_id, channel_id, message_ts_us',start)
    rows=wide_final_reference(query[start:end])
    count=int(re.findall(r"LIMIT _CAST\((\d+), 'UInt32'\) SETTINGS",query)[-1])
    oracle=f'''SELECT tenant_id, group_id, workspace_id, channel_id, message_ts_us,
      hit.1 AS connect_id, hit.2 AS connect_generation, hit.3 AS component,
      hit.4 AS build_id, hit.5 AS message_identity, hit.6 AS payload_identity,
      hit.7 AS unit, hit.8 AS match_offset, hit.9 AS match_length, distance
    FROM (SELECT tenant_id,group_id,workspace_id,channel_id,message_ts_us,
      argMin(tuple(r.connect_id,r.connect_generation,r.component,r.build_id,
        r.message_identity,r.payload_identity,r.unit,r.match_offset,r.match_length),
        tuple(r.distance,r.component,r.unit,r.connect_id)) AS hit,min(r.distance) AS distance
      FROM ({rows}) AS r GROUP BY tenant_id,group_id,workspace_id,channel_id,message_ts_us)
    ORDER BY distance,message_ts_us DESC,workspace_id,channel_id LIMIT {count}
    SETTINGS max_block_size=2048'''
    actual=c.query(query,settings=settings)
    expected=c.query(oracle,settings=dict(settings,max_memory_usage=512*1024**2))
    assert actual.result_rows==expected.result_rows, f'Ranking mismatch in query {number}'
    checks.append({'case':number,'count':count,'hits':len(actual.result_rows),'exact_equal':True})
a.output.write_text(json.dumps({'cases':checks,'reference':'Wide-vector FINAL (without the build-ID metadata preselection), same filtered complete components/distances, and one untruncated global argMin/group/sort. Diagnostic reference alone may use 512 MiB. The implementation retains 128 MiB.'},indent=2)+'\n')
print(json.dumps({'queries':len(checks),'identical_hits':sum(x['hits'] for x in checks)}))
