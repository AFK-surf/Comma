
    WITH current AS (WITH if(p.message_ts_us > 0, p.payload, m.payload) AS source_payload
SELECT m.tenant_id, m.workspace_id, m.channel_id, m.message_ts_us,
       m.message_ts, m.thread_ts, m.version AS source_version,
       p.version AS payload_version, m.deleted,
       concat('[', arrayStringConcat(arrayDistinct(arrayConcat(
         JSONExtractArrayRaw(source_payload, 'files'),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.blocks[*].slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.blocks[*].accessory.slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.blocks[*].elements[*].slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.attachments[*].blocks[*].slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.attachments[*].blocks[*].accessory.slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.attachments[*].blocks[*].elements[*].slack_file'))
       )), ','), ']') AS source_files,
       substringUTF8(concat(
         if(p.message_ts_us > 0, p.text, m.text), '\n',
         if(p.message_ts_us > 0, p.body_text, m.body_text)), 1, 8000) AS source_text
FROM (
  SELECT * FROM {{database}}.slack_messages FINAL
  -- Immutable sorting-key predicates may run before FINAL. Read them before
  -- wide payload columns so neighboring channels do not spend this scope's budget.
  PREWHERE tenant_id = {tenant_id:String} AND workspace_id = {workspace_id:String}
    AND channel_id = {channel_id:String}
    AND event_date >= toDate(fromUnixTimestamp64Micro(toInt64({oldest:UInt64}), 'UTC'))
    AND event_date <= toDate(fromUnixTimestamp64Micro(toInt64({latest:UInt64}) - 1, 'UTC'))
    AND message_ts_us >= {oldest:UInt64} AND message_ts_us < {latest:UInt64}
) AS m
LEFT JOIN (
  SELECT message_ts_us, version, text, body_text, payload
  FROM {{database}}.slack_message_payloads FINAL
  PREWHERE tenant_id = {tenant_id:String} AND workspace_id = {workspace_id:String}
    AND channel_id = {channel_id:String}
    AND event_date >= toDate(fromUnixTimestamp64Micro(toInt64({oldest:UInt64}), 'UTC'))
    AND event_date <= toDate(fromUnixTimestamp64Micro(toInt64({latest:UInt64}) - 1, 'UTC'))
    AND message_ts_us >= {oldest:UInt64} AND message_ts_us < {latest:UInt64}
) AS p USING (message_ts_us)
),
    content AS (
      SELECT tenant_id, workspace_id, channel_id, message_ts_us, source_version, payload_version,
        source_text, '' AS source_files, '' AS file_id, chunks, embeddings,
        arrayMap(x -> 'message_text', chunks) AS kinds, arrayMap(x -> toUInt32(0), chunks) AS pages,
        arrayMap(x -> toUInt64(0), chunks) AS starts, arrayMap(x -> toUInt64(0), chunks) AS ends
      FROM {{database}}.slack_semantic_documents FINAL
      PREWHERE tenant_id = {tenant_id:String} AND workspace_id = {workspace_id:String}
        AND channel_id = {channel_id:String}
        AND event_date >= toDate(fromUnixTimestamp64Micro(toInt64({oldest:UInt64}), 'UTC'))
        AND event_date <= toDate(fromUnixTimestamp64Micro(toInt64({latest:UInt64}) - 1, 'UTC'))
        AND message_ts_us >= {oldest:UInt64} AND message_ts_us < {latest:UInt64}
      UNION ALL
      SELECT tenant_id, workspace_id, channel_id, message_ts_us, source_version, payload_version,
        '' AS source_text, source_files, file_id, chunks, embeddings, kinds, pages, starts, ends
      FROM {{database}}.slack_semantic_files FINAL
      PREWHERE tenant_id = {tenant_id:String} AND workspace_id = {workspace_id:String}
        AND channel_id = {channel_id:String}
        AND event_date >= toDate(fromUnixTimestamp64Micro(toInt64({oldest:UInt64}), 'UTC'))
        AND event_date <= toDate(fromUnixTimestamp64Micro(toInt64({latest:UInt64}) - 1, 'UTC'))
        AND message_ts_us >= {oldest:UInt64} AND message_ts_us < {latest:UInt64}
    )
    SELECT hit.1 AS ts, hit.2 AS thread_ts, hit.3 AS channel, file_id,
           hit.4 AS text, hit.5 AS content_kind, hit.6 AS page,
           hit.7 AS segment_start_ms, hit.8 AS segment_end_ms, distance
    FROM (
    SELECT d.file_id,
           argMin(tuple(s.message_ts, s.thread_ts, s.channel_id, chunk, kind, page, start, end),
                  tuple(cosineDistance(embedding, {vector:Array(Float32)}), s.message_ts,
                        kind, page, start)) AS hit,
           min(cosineDistance(embedding, {vector:Array(Float32)})) AS distance
    FROM content AS d
    INNER JOIN current AS s USING (tenant_id, workspace_id, channel_id, message_ts_us)
    ARRAY JOIN d.chunks AS chunk, d.embeddings AS embedding, d.kinds AS kind,
      d.pages AS page, d.starts AS start, d.ends AS end
    WHERE NOT s.deleted AND d.source_version = s.source_version
      AND d.payload_version = s.payload_version
      AND if(d.file_id = '', d.source_text = s.source_text,
             d.source_files = s.source_files AND arrayExists(f -> JSONExtractString(f, 'id') = d.file_id,
               JSONExtractArrayRaw(s.source_files)))
      AND length(embedding) = 256
    GROUP BY s.channel_id, d.file_id, if(d.file_id = '', s.message_ts, '')
    )
    ORDER BY distance ASC, ts DESC LIMIT {count:UInt32}
    FORMAT JSONEachRow
    