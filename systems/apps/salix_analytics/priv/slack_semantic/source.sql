WITH if(p.message_ts_us > 0, p.payload, m.payload) AS source_payload
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
