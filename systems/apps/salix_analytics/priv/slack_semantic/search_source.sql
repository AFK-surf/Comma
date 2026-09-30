-- Background-only source projection. Query-time ranking and validation never
-- execute this JSON/text projection. Source IDs are read with the same rows.
WITH if(p.message_ts_us > 0, p.payload, m.payload) AS source_payload
SELECT m.tenant_id, m.workspace_id, m.channel_id, m.message_ts_us,
       m.message_ts, m.thread_ts, m.actor_id, m.actor_kind,
       m.version AS source_version, p.version AS payload_version, m.deleted,
       toString(m.source_write_id) AS message_identity,
       if(p.message_ts_us > 0, toString(p.source_write_id), 'absent') AS payload_identity,
       m._part AS message_part, m._part_offset AS message_offset,
       p._part AS payload_part, p._part_offset AS payload_offset,
       concat('[', arrayStringConcat(arrayDistinct(arrayConcat(
         JSONExtractArrayRaw(source_payload, 'files'),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.blocks[*].slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.blocks[*].accessory.slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.blocks[*].elements[*].slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.attachments[*].blocks[*].slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.attachments[*].blocks[*].accessory.slack_file')),
         JSONExtractArrayRaw(JSON_QUERY(source_payload, '$.attachments[*].blocks[*].elements[*].slack_file'))
       )), ','), ']') AS source_files,
       concat(if(p.message_ts_us > 0, p.text, m.text), '\n',
              if(p.message_ts_us > 0, p.body_text, m.body_text)) AS source_text
FROM (
  SELECT *, _part, _part_offset FROM {{database}}.slack_messages FINAL
  PREWHERE tenant_id={tenant_id:String} AND workspace_id={workspace_id:String}
    AND channel_id={channel_id:String}
    AND message_ts_us={timestamp:UInt64}
) AS m
LEFT JOIN (
  SELECT message_ts_us, version, text, body_text, payload, source_write_id, _part, _part_offset
  FROM {{database}}.slack_message_payloads FINAL
  PREWHERE tenant_id={tenant_id:String} AND workspace_id={workspace_id:String}
    AND channel_id={channel_id:String}
    AND message_ts_us={timestamp:UInt64}
) AS p USING (message_ts_us)
