defmodule SalixAnalytics.SlackMessageSearchIndex do
  @moduledoc """
  Independent, group-scoped Slack search over complete indexed components.

  Ranking never reads canonical text/payload. A bounded second read observes
  source-write identities from the actual FINAL winners in both source tables.
  MessageSearchSource.tla models those observations; MessageSearchComponentRow.tla
  models complete rows and sequence-fenced replacement.
  """
  alias SalixAnalytics.SlackSemanticIndex, as: Transport

  @table "{{database}}.slack_message_search_components"
  @documents "{{database}}.slack_message_search_documents"
  @source_path Path.expand("../../priv/slack_semantic/search_source.sql", __DIR__)
  @external_resource @source_path
  @source File.read!(@source_path)
  @rank_budget [max_rows_to_read: 2_097_152, max_bytes_to_read: 512 * 1024 * 1024]
  @probe_budget [max_rows_to_read: 4_194_304, max_bytes_to_read: 256 * 1024 * 1024]
  @zero_id "00000000-0000-0000-0000-000000000000"

  @doc "Existing complete component metadata; required before capturing a source."
  def indexed_components(scope, timestamp) do
    sql = """
    SELECT component, connect_generation, change_epoch, message_identity, payload_identity, file_id, file_epoch,
      toString(build_id) AS build_id, build_sequence, length(embeddings) AS unit_count,
      indexed_at < now64(3) - INTERVAL 1 HOUR AS refresh_due
    FROM #{@table} FINAL
    PREWHERE tenant_id={tenant_id:String} AND group_id={group_id:String}
      AND connect_id={connect_id:String}
      AND workspace_id={workspace_id:String} AND channel_id={channel_id:String}
      AND message_ts_us={timestamp:UInt64}
    UNION ALL
    SELECT 'lexical' AS component, connect_generation, change_epoch, message_identity, payload_identity,
      '' AS file_id, toUInt64(0) AS file_epoch,
      toString(build_id) AS build_id, build_sequence, if(deleted, 0, 1) AS unit_count, 0 AS refresh_due
    FROM #{@documents} FINAL
    PREWHERE tenant_id={tenant_id:String} AND group_id={group_id:String}
      AND connect_id={connect_id:String}
      AND workspace_id={workspace_id:String} AND channel_id={channel_id:String}
      AND message_ts_us={timestamp:UInt64}
    LIMIT 8193 FORMAT JSONEachRow
    """

    with {:ok, rows} <- Transport.query(sql, scope_params(scope, timestamp), 8193) do
      if length(rows) > 8192,
        do: {:error, :source_over_budget},
        else: {:ok, Map.new(rows, &{&1["component"], &1})}
    end
  end

  @doc "Copy normalized text inside ClickHouse and confirm that the exact build exists."
  def document(scope, source, captured) do
    reference =
      scope
      |> Map.take(~w(tenant_id group_id connect_id connect_generation workspace_id channel_id))
      |> Map.put("connect_generation", scope["connect_generation"] || "")
      |> Map.merge(Map.take(source, ~w(message_ts_us message_identity payload_identity)))
      |> Map.merge(%{
        "component" => "lexical",
        "file_id" => "",
        "change_epoch" => captured.change_epoch,
        "build_sequence" => captured.build_sequence,
        "build_id" => Ecto.UUID.generate(),
        "unit_count" => if(source["deleted"], do: 0, else: 1)
      })

    sql = """
    INSERT INTO #{@documents}
      (event_date, tenant_id, group_id, connect_id, connect_generation, workspace_id, channel_id,
       message_ts_us, message_ts, thread_ts, actor_id, actor_kind, change_epoch,
       message_identity, payload_identity, source_version, payload_version,
       build_id, build_sequence, deleted, search_text)
    SELECT toDate(fromUnixTimestamp64Micro(toInt64(message_ts_us), 'UTC')), tenant_id,
      {group_id:String}, {connect_id:String}, {connect_generation:String}, workspace_id, channel_id,
      message_ts_us, message_ts, thread_ts, actor_id, actor_kind, {change_epoch:UInt64},
      message_identity, payload_identity, source_version, payload_version,
      {build_id:UUID}, {build_sequence:UInt64}, deleted, if(deleted, '', source_text)
    FROM (#{@source})
    WHERE message_identity={message_identity:String} AND payload_identity={payload_identity:String}
    SETTINGS async_insert=0
    """

    params =
      scope_params(scope, source["message_ts_us"]) ++
        Enum.map(
          ~w(change_epoch build_id build_sequence message_identity payload_identity),
          &{"param_#{&1}", to_string(reference[&1])}
        )

    # INSERT SELECT may acknowledge zero rows if the captured source changed.
    # A point read confirms this complete build, never a whole-table/readiness
    # inventory. A higher sequence can supersede it while this worker waits.
    confirm = """
    SELECT toString(d.build_id) AS build_id FROM #{@documents} AS d FINAL
    PREWHERE tenant_id={tenant_id:String} AND group_id={group_id:String}
      AND connect_id={connect_id:String} AND workspace_id={workspace_id:String}
      AND channel_id={channel_id:String} AND message_ts_us={timestamp:UInt64}
    WHERE d.build_id={build_id:UUID} LIMIT 1 FORMAT JSONEachRow
    """

    expected = reference["build_id"]

    with :ok <- Transport.execute_search_sql(sql, params),
         {:ok, [%{"build_id" => ^expected}]} <-
           Transport.query(confirm, params, 1) do
      SalixStore.SlackSearchSources.publish(reference)
    else
      {:ok, []} -> {:error, :source_changed}
      error -> error
    end
  end

  @doc "Read a bounded text slice and media references in the background only."
  def source(scope, timestamp, slice_start \\ 0, slice_size \\ 5800) do
    read_source(scope, timestamp, slice_start, slice_size, true)
  end

  defp read_source(scope, timestamp, slice_start, slice_size, initialize?) do
    sql = """
    SELECT tenant_id, workspace_id, channel_id, message_ts_us, message_ts, thread_ts,
      actor_id, actor_kind, message_part, message_offset, payload_part, payload_offset,
      source_version, payload_version, message_identity, payload_identity, deleted, source_files,
      lengthUTF8(s.source_text) AS source_characters,
      substringUTF8(s.source_text, {slice_start:UInt32} + 1, {slice_size:UInt32}) AS source_text
    FROM (#{@source}) AS s LIMIT 1 FORMAT JSONEachRow
    """

    params =
      scope_params(scope, timestamp) ++
        [
          {"param_oldest", to_string(timestamp)},
          {"param_latest", to_string(timestamp + 1)},
          {"param_slice_start", to_string(slice_start)},
          {"param_slice_size", to_string(slice_size)}
        ]

    with {:ok, rows} <- Transport.query(sql, params, 1, @probe_budget) do
      case rows do
        [%{"deleted" => false} = row] ->
          if row["message_identity"] == @zero_id or row["payload_identity"] == @zero_id do
            if initialize? do
              with :ok <- initialize_ids(row) do
                read_source(scope, timestamp, slice_start, slice_size, false)
              end
            else
              {:error, :source_initializing}
            end
          else
            {:ok, rows}
          end

        _ ->
          {:ok, rows}
      end
    end
  end

  defp initialize_ids(row) do
    for {table, side} <- [{:messages, "message"}, {:payloads, "payload"}],
        row["#{side}_identity"] == @zero_id,
        reduce: :ok do
      :ok -> Transport.initialize_source_ids(table, row["#{side}_part"], row["#{side}_offset"])
      error -> error
    end
  end

  @doc "Rank a finite window of distinct messages; one long attachment cannot fill it."
  def candidates(scope, connects, query, vector, filters, count) when count in 1..200 do
    rows =
      if filters.mode == :semantic do
        """
        SELECT tenant_id, group_id, connect_id, connect_generation, workspace_id, channel_id,
          message_ts_us, component, toString(build_id) AS build_id, message_identity, payload_identity,
          indexOf(distances, arrayMin(distances)) AS unit, arrayMin(distances) AS distance,
          toUInt64(0) AS match_offset, toUInt64(0) AS match_length
        FROM (
          SELECT *, arrayMap((v, k) ->
            if(length(v)=256 AND ({kind:String}='' OR k={kind:String}),
              cosineDistance(v, {vector:Array(Float32)}), toFloat64('inf')),
            embeddings, kinds) AS distances
          FROM (#{current_components()})
        ) WHERE notEmpty(distances) AND isFinite(distance)
        """
      else
        """
        SELECT tenant_id, group_id, connect_id, connect_generation, workspace_id, channel_id,
          message_ts_us, 'lexical' AS component, toString(build_id) AS build_id,
          message_identity, payload_identity, toUInt64(1) AS unit,
          toFloat64(positionCaseInsensitiveUTF8(search_text, {query:String})) AS distance,
          toUInt64(positionCaseInsensitiveUTF8(search_text, {query:String})) AS match_offset,
          toUInt64(lengthUTF8({query:String})) AS match_length
        FROM #{@documents} FINAL #{scope_filter()}
        WHERE NOT deleted AND positionCaseInsensitiveUTF8(search_text, {query:String}) > 0
          AND ({kind:String}='' OR {kind:String}='message_text')
          AND ({sender:String}='' OR actor_id={sender:String})
        UNION ALL
        SELECT tenant_id, group_id, connect_id, connect_generation, workspace_id, channel_id,
          message_ts_us, component, toString(build_id) AS build_id, message_identity, payload_identity,
          unit, toFloat64(positionCaseInsensitiveUTF8(chunk, {query:String})) AS distance,
          toUInt64(positionCaseInsensitiveUTF8(chunk, {query:String})) AS match_offset,
          toUInt64(lengthUTF8({query:String})) AS match_length
        FROM (#{current_components()})
        ARRAY JOIN chunks AS chunk, kinds AS kind, arrayEnumerate(chunks) AS unit
        WHERE file_id != '' AND positionCaseInsensitiveUTF8(chunk, {query:String}) > 0
          AND ({kind:String}='' OR kind={kind:String})
        """
      end

    # Group in primary-key order within each connect before the final merge.
    # A source outside every connect's best N already has N distinct sources
    # ahead of it in one connect, so it cannot enter the global best N. At
    # most 64*N rows reach the last aggregation, without a per-connect RPC.
    sql = """
    SELECT tenant_id, group_id, workspace_id, channel_id, message_ts_us,
      hit.1 AS connect_id, hit.2 AS connect_generation, hit.3 AS component,
      hit.4 AS build_id, hit.5 AS message_identity, hit.6 AS payload_identity,
      hit.7 AS unit, hit.8 AS match_offset, hit.9 AS match_length, distance
    FROM (
      SELECT tenant_id, group_id, workspace_id, channel_id, message_ts_us,
        argMin(r.hit, tuple(r.distance, r.hit.3, r.hit.7, r.hit.1)) AS hit,
        min(r.distance) AS distance
      FROM (
        SELECT tenant_id, group_id, connect_id, workspace_id, channel_id, message_ts_us,
          argMin(tuple(r.connect_id, r.connect_generation, r.component, r.build_id,
            r.message_identity, r.payload_identity, r.unit, r.match_offset, r.match_length),
            tuple(r.distance, r.component, r.unit)) AS hit,
          min(r.distance) AS distance
        FROM (#{rows}) AS r
        GROUP BY tenant_id, group_id, connect_id, workspace_id, channel_id, message_ts_us
        ORDER BY connect_id, distance, message_ts_us DESC, workspace_id, channel_id
        LIMIT {count:UInt32} BY connect_id
      ) AS r
      GROUP BY tenant_id, group_id, workspace_id, channel_id, message_ts_us
    ) ORDER BY distance, message_ts_us DESC, workspace_id, channel_id
    LIMIT {count:UInt32} SETTINGS max_block_size=2048, optimize_aggregation_in_order=1
    FORMAT JSONEachRow
    """

    params = [
      {"param_tenant_id", scope.tenant_id},
      {"param_group_id", scope.group_id},
      {"param_connects",
       Jason.encode!(Enum.map(connects, &[&1["connect_id"], &1["workspace_id"]]))},
      {"param_query", query},
      {"param_vector", Jason.encode!(vector || [])},
      {"param_oldest", to_string(filters.oldest)},
      {"param_latest", to_string(filters.latest)},
      {"param_workspace", filters.workspace},
      {"param_channel", filters.channel},
      {"param_sender", Map.get(filters, :sender, "")},
      {"param_kind", filters.kind},
      {"param_count", to_string(count)}
    ]

    Transport.query(sql, params, count, @rank_budget)
  end

  defp scope_filter do
    """
    PREWHERE tenant_id={tenant_id:String} AND group_id={group_id:String}
      AND (connect_id, workspace_id) IN JSONExtract({connects:String}, 'Array(Tuple(String,String))')
      AND message_ts_us >= {oldest:UInt64} AND message_ts_us < {latest:UInt64}
      AND ({workspace:String}='' OR workspace_id={workspace:String})
      AND ({channel:String}='' OR channel_id={channel:String})
    """
  end

  defp current_components do
    # The lexical row is also the index's current message state. Joining its
    # narrow metadata suppresses removed slices and deletion tombstones before
    # ranking, without querying canonical content or inventing a second source
    # authority. FINAL resolves only build IDs before loading wide arrays:
    # merging vector columns across unmerged parts can exceed the query budget.
    # A build owns one immutable complete row, so duplicate physical packets
    # are equivalent and the later source grouping absorbs them. Final source/PG
    # checks still decide what may be returned. MessageSearchComponentRow models
    # this immutable-packet/late-read boundary; this does not add a publisher.
    """
    SELECT * FROM #{@table} #{scope_filter()}
    WHERE build_id IN (SELECT build_id FROM #{@table} FINAL #{scope_filter()})
    AND (connect_id, workspace_id, channel_id, message_ts_us,
      change_epoch, message_identity, payload_identity) IN (
      SELECT connect_id, workspace_id, channel_id, message_ts_us,
        change_epoch, message_identity, payload_identity
      FROM #{@documents} FINAL #{scope_filter()}
      WHERE NOT deleted AND ({sender:String}='' OR actor_id={sender:String})
    )
    """
  end

  @doc "Only sorting keys, source-write IDs and deletion state; no body/JSON access."
  def current_sources(_tenant, []), do: {:ok, %{}}

  def current_sources(tenant, candidates) when length(candidates) <= 200 do
    keys =
      candidates
      |> Enum.map(&Enum.map(~w(workspace_id channel_id message_ts_us), fn k -> &1[k] end))
      |> Enum.uniq()

    params = [{"param_tenant_id", tenant}, {"param_keys", Jason.encode!(keys)}]

    predicate = """
    PREWHERE tenant_id={tenant_id:String} AND (workspace_id, channel_id, message_ts_us) IN
      JSONExtract({keys:String}, 'Array(Tuple(String,String,UInt64))')
    """

    messages = """
    SELECT workspace_id, channel_id, message_ts_us, deleted,
      toString(source_write_id) AS identity
    FROM {{database}}.slack_messages FINAL #{predicate}
    LIMIT 201 FORMAT JSONEachRow
    """

    payloads = """
    SELECT workspace_id, channel_id, message_ts_us,
      toString(source_write_id) AS identity
    FROM {{database}}.slack_message_payloads FINAL #{predicate}
    LIMIT 201 FORMAT JSONEachRow
    """

    with {:ok, m} <- Transport.query(messages, params, 201, @probe_budget),
         {:ok, p} <- Transport.query(payloads, params, 201, @probe_budget) do
      payloads = Map.new(p, &{source_key(&1), &1["identity"]})

      {:ok,
       Map.new(m, fn row ->
         {source_key(row),
          %{
            deleted: row["deleted"],
            message_identity: row["identity"],
            payload_identity: Map.get(payloads, source_key(row), "absent")
          }}
       end)}
    end
  end

  @doc "Fetch finite, already-validated units without reading vectors or canonical payloads."
  def excerpts(_scope, []), do: {:ok, []}

  def excerpts(scope, candidates) when length(candidates) <= 200 do
    {documents, components} = Enum.split_with(candidates, &(&1["component"] == "lexical"))

    with {:ok, text} <- document_excerpts(scope, documents),
         {:ok, units} <- component_excerpts(scope, components),
         do: {:ok, text ++ units}
  end

  defp document_excerpts(_scope, []), do: {:ok, []}

  defp document_excerpts(scope, candidates) do
    sql = """
    SELECT toString(build_id) AS build_id, toUInt64(1) AS unit, message_ts AS ts, thread_ts,
      workspace_id, channel_id AS channel, connect_id, '' AS file_id, actor_id, actor_kind,
      'message_text' AS content_kind, toUInt32(0) AS page,
      toUInt64(0) AS segment_start_ms, toUInt64(0) AS segment_end_ms,
      substringUTF8(search_text, greatest(1, toInt64(requested.2) - 120), 1024) AS text,
      greatest(0, toInt64(requested.2) - 121) AS text_start,
      greatest(0, toInt64(requested.2) - 121) + lengthUTF8(text) AS text_end,
      requested.2 - 1 AS match_start, requested.2 - 1 + requested.3 AS match_end
    FROM #{@documents} FINAL
    ARRAY JOIN JSONExtract({matches:String}, 'Array(Tuple(String,UInt64,UInt64))') AS requested
    PREWHERE tenant_id={tenant_id:String} AND group_id={group_id:String}
      AND (connect_id, workspace_id, channel_id, message_ts_us) IN
        JSONExtract({keys:String}, 'Array(Tuple(String,String,String,UInt64))')
    WHERE toString(build_id)=requested.1 AND NOT deleted
    LIMIT 201 FORMAT JSONEachRow
    """

    keys =
      Enum.map(
        candidates,
        &[&1["connect_id"], &1["workspace_id"], &1["channel_id"], &1["message_ts_us"]]
      )

    matches = Enum.map(candidates, &[&1["build_id"], &1["match_offset"], &1["match_length"]])

    Transport.query(
      sql,
      [
        {"param_tenant_id", scope.tenant_id},
        {"param_group_id", scope.group_id},
        {"param_keys", Jason.encode!(keys)},
        {"param_matches", Jason.encode!(matches)}
      ],
      201,
      @probe_budget
    )
  end

  defp component_excerpts(_scope, []), do: {:ok, []}

  defp component_excerpts(scope, candidates) do
    # Project only requested units after FINAL, then expand the narrow tuples.
    # Expanding every chunk first can exhaust the read budget for one page.
    # Keep set semantics, including multiple units from one complete build.
    sql = """
    SELECT toString(build_id) AS build_id, message_ts AS ts, thread_ts, workspace_id,
      channel_id AS channel, connect_id, file_id, actor_id, actor_kind,
      excerpt.1 AS unit, excerpt.2 AS text, excerpt.3 AS content_kind, excerpt.4 AS page,
      excerpt.5 AS segment_start_ms, excerpt.6 AS segment_end_ms,
      if(file_id='', toUInt64OrZero(substring(component, 6)), NULL) AS text_start,
      text_start + lengthUTF8(text) AS text_end
    FROM (
      SELECT build_id, message_ts, thread_ts, workspace_id, channel_id, connect_id,
        file_id, actor_id, actor_kind, component,
        arrayMap(u -> tuple(u.2, chunks[u.2], kinds[u.2], pages[u.2], starts[u.2], ends[u.2]),
          arrayDistinct(arrayFilter(u -> u.1=toString(build_id) AND u.2>=1 AND u.2<=length(chunks),
            JSONExtract({units:String}, 'Array(Tuple(String,UInt64))')))) AS requested_excerpts
      FROM #{@table} FINAL
      PREWHERE tenant_id={tenant_id:String} AND group_id={group_id:String}
        AND (connect_id, workspace_id, channel_id, message_ts_us, component) IN
          JSONExtract({keys:String}, 'Array(Tuple(String,String,String,UInt64,String))')
    ) ARRAY JOIN requested_excerpts AS excerpt
    LIMIT 201 FORMAT JSONEachRow
    """

    keys =
      Enum.map(
        candidates,
        &Enum.map(
          ~w(connect_id workspace_id channel_id message_ts_us component),
          fn k -> &1[k] end
        )
      )

    units = Enum.map(candidates, &[&1["build_id"], &1["unit"]])

    Transport.query(
      sql,
      [
        {"param_tenant_id", scope.tenant_id},
        {"param_group_id", scope.group_id},
        {"param_keys", Jason.encode!(keys)},
        {"param_units", Jason.encode!(units)}
      ],
      201,
      @probe_budget
    )
  end

  def source_key(row), do: {row["workspace_id"], row["channel_id"], row["message_ts_us"]}

  defp scope_params(scope, timestamp),
    do:
      Enum.map(
        ~w(tenant_id group_id connect_id connect_generation workspace_id channel_id),
        &{"param_#{&1}", scope[&1] || ""}
      ) ++
        [{"param_timestamp", to_string(timestamp)}]
end
