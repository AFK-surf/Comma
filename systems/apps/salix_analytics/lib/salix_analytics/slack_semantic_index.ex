defmodule SalixAnalytics.SlackSemanticIndex do
  @moduledoc """
  Bounded Slack text/media-vector reads outside production. No ingestion or readiness dependency.
  Source/derived-result checks are modeled in tla/salix/SlackSemanticIndex.tla.
  Transport uses Req and dedicated Finch pools: three connections per host,
  six for the configured GPU origin. No retries, redirects, dynamic hosts or
  shared ordinary HTTP capacity.
  """

  @source_path Path.expand("../../priv/slack_semantic/source.sql", __DIR__)
  @external_resource @source_path
  @source File.read!(@source_path)
  @max_body 2 * 1024 * 1024

  # runtime.exs supplies the existing COMMA_ENVIRONMENT; no JSON activation field.
  # The protocol models describe this active, non-production service.
  def active?, do: config()[:environment] in ~w(local development dev test staging)

  def children do
    if active?(),
      do: [
        {Oban, SalixAnalytics.SlackSemanticQueue.oban_options()},
        SalixAnalytics.SlackSemanticQueue,
        {Finch, name: __MODULE__.HTTP, pools: http_pools()},
        SalixAnalytics.SlackSemanticIndexer
      ],
      else: []
  end

  defp http_pools do
    options = [size: 3, count: 1, conn_opts: [transport_opts: [timeout: 1000]]]
    defaults = %{default: options}
    url = config()[:url] || ""

    # Four foreground requests plus one text and one file worker per Pod.
    # Invalid optional GPU configuration must not prevent Comma from starting.
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        Map.put(defaults, url, Keyword.put(options, :size, 6))

      _ ->
        defaults
    end
  end

  def search(scope, query, oldest, latest, count) do
    started = System.monotonic_time()
    result = do_search(scope, query, oldest, latest, count)

    outcome =
      case result do
        {:ok, _} -> "ok"
        {:error, :read_over_budget} -> "over_budget"
        _ -> "error"
      end

    observe("slack_semantic_search", started, outcome)
    result
  end

  @doc false
  def observe(operation, started, outcome) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{
        component: "salix_analytics",
        operation: operation,
        outcome: outcome,
        surface: SystemsObservability.Context.current_surface()
      }
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp do_search(scope, query, oldest, latest, count) do
    cfg = config()
    ch = Application.get_env(:salix_analytics, :clickhouse, [])

    database =
      ch[:database] || (ch[:table] || "salix_analytics.events") |> String.split(".") |> hd()

    with true <- configured?(cfg, ch, database),
         {:ok, vector} <- embed(query),
         {:ok, rows} <- read(ch, database, scope, vector, oldest, latest, count) do
      {:ok, rows}
    else
      {:error, :read_over_budget} = error -> error
      _ -> {:error, :semantic_unavailable}
    end
  rescue
    _ -> {:error, :semantic_unavailable}
  catch
    _, _ -> {:error, :semantic_unavailable}
  end

  defp config, do: Application.get_env(:salix_analytics, :slack_semantic_search, [])

  @doc false
  def source_sql(database), do: String.replace(@source, "{{database}}", database)

  @doc false
  def query(sql, params, limit, budget \\ []) do
    {ch, database} = database_config()

    read_rows(
      ch,
      String.replace(sql, "{{database}}", database),
      params,
      limit,
      budget |> Keyword.put(:max_result_rows, limit) |> Keyword.put_new(:pool_timeout, 500)
    )
  end

  @doc false
  def insert_search_component(component) do
    {ch, database} = database_config()

    sql =
      "INSERT INTO #{database}.slack_message_search_components SETTINGS async_insert=0 FORMAT JSONEachRow\n" <>
        Jason.encode!(component) <> "\n"

    case post(ch[:base_url], body: sql, headers: ch_headers(ch)) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc false
  def execute_search_sql(sql, params) do
    {ch, database} = database_config()

    case post(ch[:base_url],
           body: String.replace(sql, "{{database}}", database),
           params: params,
           headers: ch_headers(ch)
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc false
  def initialize_source_ids(table, part, offset) when table in [:messages, :payloads] do
    {ch, database} = database_config()
    start = div(offset, 5000) * 5000
    # These literals are generated once for this request. An uncertain outcome
    # may be retried with fresh IDs because the mutation only fills zero cells.
    # The exact physical part/offset fence prevents assigning an old literal
    # to different content after an insert or merge. No source text is read.
    ids = Enum.map_join(1..5000, ",", fn _ -> "'" <> Ecto.UUID.generate() <> "'" end)
    part = part |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
    name = if table == :messages, do: "slack_messages", else: "slack_message_payloads"

    sql = """
    ALTER TABLE #{database}.#{name}
    UPDATE source_write_id = arrayElement(arrayMap(x -> toUUID(x), [#{ids}]), _part_offset - #{start} + 1)
    WHERE _part='#{part}' AND _part_offset >= #{start} AND _part_offset < #{start + 5000}
      AND source_write_id=toUUID('00000000-0000-0000-0000-000000000000')
    SETTINGS mutations_sync=1
    """

    case post(ch[:base_url], body: sql, headers: ch_headers(ch)) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc false
  def embed(text, opts \\ []) do
    cfg = config()
    background = Keyword.get(opts, :background, false)

    with {:ok, body} <-
           post(
             cfg[:url],
             [
               json: %{
                 text: text,
                 background: background,
                 live: Keyword.get(opts, :live, false)
               },
               headers: [
                 {"cf-access-client-id", cfg[:client_id]},
                 {"cf-access-client-secret", cfg[:client_secret]}
               ]
             ],
             if(background, do: 50, else: 500),
             if(background, do: :semantic_unavailable, else: :semantic_busy)
           ),
         {:ok, %{"embedding" => vector}} <- Jason.decode(body),
         true <- valid_vector?(vector) do
      {:ok, vector}
    else
      {:error, :semantic_busy} = error -> error
      _ -> {:error, :semantic_unavailable}
    end
  end

  @doc false
  def message_page(scope, before_timestamp) do
    {ch, database} = database_config()

    # Read only the physical sorting key, in reverse order. No FINAL, payload
    # join or missing-index predicate: poison or pending jobs cannot trap the
    # cursor on the newest page. Duplicate versions share one message job.
    sql = """
    SELECT message_ts_us FROM #{database}.slack_messages
    PREWHERE tenant_id = {tenant_id:String} AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String} AND message_ts_us < {latest:UInt64}
    ORDER BY message_ts_us DESC LIMIT 20 FORMAT JSONEachRow
    """

    # Multiple monthly parts each read a small key granule. These rows have
    # no payloads/vectors; cap bytes more tightly while allowing sparse parts.
    key_budget = [max_rows_to_read: 1_048_576, max_bytes_to_read: 8 * 1024 * 1024]

    with {:ok, rows} <-
           read_rows(ch, sql, scope_params(scope, 0, before_timestamp), 20, key_budget),
         do: {:ok, Enum.uniq_by(rows, & &1["message_ts_us"])}
  end

  @doc false
  def source_document(scope, timestamp) do
    {ch, database} = database_config()

    sql = "SELECT * FROM (#{source_sql(database)}) WHERE NOT deleted LIMIT 1 FORMAT JSONEachRow"
    read_rows(ch, sql, scope_params(scope, timestamp, timestamp + 1), 1)
  end

  @doc false
  def missing_documents(scope, oldest, latest) do
    {ch, database} = database_config()

    sql = """
    SELECT s.* FROM (#{source_sql(database)}) AS s
    LEFT JOIN (
      SELECT message_ts_us, source_version, payload_version, source_text
      FROM #{database}.slack_semantic_documents FINAL
      PREWHERE tenant_id = {tenant_id:String} AND workspace_id = {workspace_id:String}
        AND channel_id = {channel_id:String}
        AND event_date >= toDate(fromUnixTimestamp64Micro(toInt64({oldest:UInt64}), 'UTC'))
        AND event_date <= toDate(fromUnixTimestamp64Micro(toInt64({latest:UInt64}) - 1, 'UTC'))
        AND message_ts_us >= {oldest:UInt64} AND message_ts_us < {latest:UInt64}
    ) AS d USING (message_ts_us)
    WHERE NOT s.deleted AND notEmpty(trimBoth(s.source_text, ' \\t\\r\\n'))
      AND (d.message_ts_us = 0 OR d.source_version != s.source_version
        OR d.payload_version != s.payload_version OR d.source_text != s.source_text)
    ORDER BY s.message_ts_us DESC LIMIT 20 FORMAT JSONEachRow
    """

    read_rows(ch, sql, scope_params(scope, oldest, latest), 20)
  end

  @doc false
  def insert(document, table \\ :documents) when table in [:documents, :files] do
    {ch, database} = database_config()

    sql =
      "INSERT INTO #{database}.slack_semantic_#{table} FORMAT JSONEachRow\n" <>
        Jason.encode!(document) <> "\n"

    case post(ch[:base_url], body: sql, headers: ch_headers(ch)) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc false
  def missing_files(scope, oldest, latest, file_id \\ nil) do
    {ch, database} = database_config()

    sql = """
    SELECT s.*, JSONExtractString(file, 'id') AS file_id
    FROM (#{source_sql(database)}) AS s
    ARRAY JOIN JSONExtractArrayRaw(s.source_files) AS file
    LEFT JOIN (
      SELECT message_ts_us, file_id, source_version, payload_version, source_files, indexed_at
      FROM #{database}.slack_semantic_files FINAL
      PREWHERE tenant_id = {tenant_id:String} AND workspace_id = {workspace_id:String}
        AND channel_id = {channel_id:String}
        AND event_date >= toDate(fromUnixTimestamp64Micro(toInt64({oldest:UInt64}), 'UTC'))
        AND event_date <= toDate(fromUnixTimestamp64Micro(toInt64({latest:UInt64}) - 1, 'UTC'))
        AND message_ts_us >= {oldest:UInt64} AND message_ts_us < {latest:UInt64}
    ) AS d ON d.message_ts_us = s.message_ts_us AND d.file_id = JSONExtractString(file, 'id')
    WHERE NOT s.deleted AND length(s.source_files) <= 65536
      AND notEmpty(JSONExtractString(file, 'id'))
      AND ({file_id:String} = '' OR JSONExtractString(file, 'id') = {file_id:String})
      AND (d.message_ts_us = 0 OR d.source_version != s.source_version
        OR d.payload_version != s.payload_version OR d.source_files != s.source_files
        OR ((JSONExtractBool(file, 'editable') OR JSONExtractString(file, 'mode') IN ('post', 'snippet')
             OR JSONExtractString(file, 'mimetype') = 'application/vnd.slack-docs')
            AND d.indexed_at < now() - INTERVAL 1 HOUR))
    -- Sample the bounded missing set so an unsupported newest file does not
    -- permanently occupy every pass. No probabilistic progress is promised.
    GROUP BY ALL ORDER BY rand() LIMIT 2 FORMAT JSONEachRow
    """

    read_rows(
      ch,
      sql,
      scope_params(scope, oldest, latest) ++ [{"param_file_id", file_id || ""}],
      2
    )
  end

  @doc false
  def media(path, mime, opts \\ []) do
    cancelled = Keyword.get(opts, :cancelled, fn -> false end)

    result =
      SalixAnalytics.SlackSemanticUpload.run(
        path,
        mime,
        config(),
        &consume_media(&1, &2, cancelled),
        cancelled: cancelled
      )

    if cancelled.(), do: {:error, :preempted}, else: result
  end

  defp consume_media(url, headers, cancelled) do
    deadline = System.monotonic_time(:millisecond) + 1_210_000

    with {:ok, %{status: 200, body: body, private: private}} <-
           Req.post(url,
             headers: headers,
             finch: __MODULE__.HTTP,
             retry: false,
             redirect: false,
             decode_body: false,
             receive_timeout: 15_000,
             pool_timeout: 50,
             into: fn chunk, acc ->
               if cancelled.(),
                 do: {:halt, acc},
                 else: collect(chunk, acc, deadline, 8 * 1024 * 1024)
             end
           ),
         nil <- private[:semantic_overflow],
         rows = body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1),
         :ok <-
           if(Enum.any?(rows, &(&1["error"] == "unsupported_media")),
             do: {:error, :unsupported_attachment},
             else: :ok
           ),
         %{"complete" => true, "units" => count} <- List.last(rows),
         units = for(%{"unit" => unit} <- rows, do: unit),
         true <- count == length(units) and count <= 1024,
         true <- Enum.all?(units, &valid_unit?/1),
         false <- Enum.any?(rows, &Map.has_key?(&1, "error")) do
      {:ok, units}
    else
      {:error, :unsupported_attachment} = error -> error
      _ -> {:error, :semantic_unavailable}
    end
  rescue
    _ -> {:error, :semantic_unavailable}
  end

  defp valid_unit?(unit) do
    unit["content_kind"] in ~w(image video_segment ocr_text asr_transcript document_text) and
      is_binary(unit["text"]) and byte_size(unit["text"]) <= 1600 and
      is_integer(unit["page"]) and unit["page"] in 0..500 and
      is_integer(unit["segment_start_ms"]) and is_integer(unit["segment_end_ms"]) and
      unit["segment_start_ms"] >= 0 and unit["segment_end_ms"] >= unit["segment_start_ms"] and
      unit["segment_end_ms"] <= 10_800_000 and valid_vector?(unit["embedding"])
  end

  defp database_config do
    ch = Application.get_env(:salix_analytics, :clickhouse, [])

    database =
      ch[:database] || (ch[:table] || "salix_analytics.events") |> String.split(".") |> hd()

    if not Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, database), do: raise(ArgumentError)
    {ch, database}
  end

  defp configured?(cfg, ch, database) do
    active?() and
      Enum.all?(
        [cfg[:url], cfg[:client_id], cfg[:client_secret], ch[:base_url]],
        &(is_binary(&1) and &1 != "")
      ) and
      Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, database)
  end

  defp valid_vector?(vector) when is_list(vector) and length(vector) == 256 do
    Enum.all?(vector, &(is_number(&1) and abs(&1) <= 1.001)) and
      abs(Enum.reduce(vector, 0.0, &(&1 * &1 + &2)) - 1.0) < 0.01
  end

  defp valid_vector?(_), do: false

  defp read(ch, database, scope, vector, oldest, latest, count) do
    # Read immutable sorting keys before wide columns, FINAL/join/array expansion.
    # Version/content/deletion checks stay after FINAL; the budgets remain unchanged.
    sql = """
    WITH current AS (#{String.replace(@source, "{{database}}", database)}),
    content AS (
      SELECT tenant_id, workspace_id, channel_id, message_ts_us, source_version, payload_version,
        source_text, '' AS source_files, '' AS file_id, chunks, embeddings,
        arrayMap(x -> 'message_text', chunks) AS kinds, arrayMap(x -> toUInt32(0), chunks) AS pages,
        arrayMap(x -> toUInt64(0), chunks) AS starts, arrayMap(x -> toUInt64(0), chunks) AS ends
      FROM #{database}.slack_semantic_documents FINAL
      PREWHERE tenant_id = {tenant_id:String} AND workspace_id = {workspace_id:String}
        AND channel_id = {channel_id:String}
        AND event_date >= toDate(fromUnixTimestamp64Micro(toInt64({oldest:UInt64}), 'UTC'))
        AND event_date <= toDate(fromUnixTimestamp64Micro(toInt64({latest:UInt64}) - 1, 'UTC'))
        AND message_ts_us >= {oldest:UInt64} AND message_ts_us < {latest:UInt64}
      UNION ALL
      SELECT tenant_id, workspace_id, channel_id, message_ts_us, source_version, payload_version,
        '' AS source_text, source_files, file_id, chunks, embeddings, kinds, pages, starts, ends
      FROM #{database}.slack_semantic_files FINAL
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
    """

    params =
      scope_params(scope, oldest, latest) ++
        [
          param_count: count,
          param_vector: Jason.encode!(vector)
        ]

    # Compact parts read whole column granules even for a selective PREWHERE.
    # A normal 14-day staging query reads about 120 MiB while using <64 MiB
    # of memory. Keep the background budget smaller; all other limits stay fixed.
    with {:ok, rows} <- read_rows(ch, sql, params, count, max_bytes_to_read: 256 * 1024 * 1024),
         true <- Enum.all?(rows, &valid_hit?(&1, scope)) do
      {:ok, rows}
    else
      {:error, _} = error -> error
      _ -> {:error, :semantic_unavailable}
    end
  end

  defp scope_params(scope, oldest, latest) do
    [
      param_tenant_id: scope["tenant_id"],
      param_workspace_id: scope["workspace_id"],
      param_channel_id: scope["channel_id"],
      param_oldest: oldest,
      param_latest: latest
    ]
  end

  defp read_rows(ch, sql, params, count, budget \\ []) do
    params =
      params ++
        [
          output_format_json_quote_64bit_integers: 0,
          join_use_nulls: 0,
          max_rows_to_read: Keyword.get(budget, :max_rows_to_read, 65_536),
          max_bytes_to_read: Keyword.get(budget, :max_bytes_to_read, 64 * 1024 * 1024),
          max_memory_usage: 128 * 1024 * 1024,
          max_execution_time: 2,
          max_threads: 1,
          # Canonical/legacy month keys and the independent search's tenant
          # bucket are immutable. Versions cannot cross these partitions.
          # This lets FINAL prune irrelevant months before enforcing row limits.
          do_not_merge_across_partitions_select_final: 1,
          max_result_rows: Keyword.get(budget, :max_result_rows, 40),
          max_result_bytes: @max_body,
          read_overflow_mode: "throw",
          result_overflow_mode: "throw",
          timeout_overflow_mode: "throw"
        ]

    with {:ok, body} <-
           post(
             ch[:base_url],
             [body: sql, params: params, headers: ch_headers(ch)],
             Keyword.get(budget, :pool_timeout, 50)
           ),
         {:ok, rows} <- decode_rows(body),
         true <- length(rows) <= count do
      {:ok, rows}
    else
      {:error, _} = error -> error
      _ -> {:error, :semantic_unavailable}
    end
  end

  defp decode_rows(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
      case Jason.decode(line) do
        {:ok, %{"exception" => text}} when is_binary(text) -> {:halt, classify_error(text)}
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        _ -> {:halt, classify_error(line)}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp ch_headers(ch),
    do: [{"x-clickhouse-user", ch[:user] || "default"}, {"x-clickhouse-key", ch[:password] || ""}]

  defp valid_hit?(row, scope) do
    is_map(row) and row["channel"] == scope["channel_id"] and
      is_binary(row["ts"]) and Regex.match?(~r/\A\d+\.\d{6}\z/, row["ts"]) and
      is_binary(row["thread_ts"]) and is_binary(row["text"]) and
      byte_size(row["text"]) <= 4096 and is_number(row["distance"]) and
      row["distance"] >= -0.001 and row["distance"] <= 2.001
  end

  defp post(url, opts, pool_timeout \\ 50, busy_error \\ :semantic_unavailable) do
    deadline = System.monotonic_time(:millisecond) + 2500

    opts =
      opts ++
        [
          finch: __MODULE__.HTTP,
          retry: false,
          redirect: false,
          decode_body: false,
          receive_timeout: 2500,
          pool_timeout: pool_timeout,
          into: fn chunk, acc -> collect(chunk, acc, deadline) end
        ]

    case Req.post(url, opts) do
      {:ok, %{status: 200, body: body, private: private}} ->
        if private[:semantic_overflow], do: {:error, :semantic_unavailable}, else: {:ok, body}

      {:ok, %{status: 429}} when busy_error == :semantic_busy ->
        {:error, busy_error}

      {:ok, %{body: body}} when is_binary(body) ->
        classify_error(body)

      _ ->
        {:error, :semantic_unavailable}
    end
  end

  defp classify_error(body) do
    # ClickHouse 25.3 formats exceptions as JSON even for a failed HTTP
    # response; newer servers may send plain text. Errors can also terminate
    # an already-started 200 response. Never consume its partial rows.
    text =
      case Jason.decode(body) do
        {:ok, %{"exception" => text}} when is_binary(text) -> text
        _ -> body
      end

    if Regex.match?(~r/\ACode: (158|159|160|241|307)\./, String.trim_leading(text)),
      do: {:error, :read_over_budget},
      else: {:error, :semantic_unavailable}
  end

  defp collect(chunk, acc, deadline, max_body \\ @max_body)

  defp collect({:data, data}, {request, response}, deadline, max_body) do
    body = response.body || ""

    if byte_size(body) + byte_size(data) > max_body or
         System.monotonic_time(:millisecond) > deadline do
      {:halt,
       {request, %{response | private: Map.put(response.private, :semantic_overflow, true)}}}
    else
      {:cont, {request, %{response | body: body <> data}}}
    end
  end
end
