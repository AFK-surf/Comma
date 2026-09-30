defmodule SalixAnalytics.EventArchive.Sink do
  @moduledoc """
  Inserts sealed archive rows into ClickHouse.

  Replaces the object-storage segment writer. The batching above it survives the
  change for a different reason than it was built for: object storage batched to
  avoid per-item PUT cost, MergeTree batches because a stream of small inserts
  creates a part per insert and drives the merge scheduler into the ground. Same
  shape, different failure it is avoiding.

  This is deliberately a narrow HTTP sink, matching
  `SalixAnalytics.Sink.ClickHouseTyped` — and for the same dependency reason
  recorded there: the actively maintained `ch` driver conflicts with the
  umbrella's Ecto version, and the older `clickhouse` client conflicts with the
  Stripe adapter's Hackney version. Do not expand it into a general client
  without rechecking both.

  ## Retries are idempotent here, and were not before

  The table is a ReplacingMergeTree keyed on
  `(event_date, tenant_id, stream, writer, seq)`. A retried insert of the same
  item collapses into one row. Against object storage a retry wrote a second
  segment containing the same line, and `verify` reported it as a DUPLICATE the
  operator then had to reason about. That whole class of finding is gone.

  This is exactly why `writer` has to exist and has to be in the key — see
  `SalixAnalytics.EventArchive.Sequence`.
  """

  require Logger

  @table "agent_event_archive"

  @doc "Write already-sealed rows. Returns `:ok` or `{:error, reason}`."
  @spec write([map()]) :: :ok | {:error, term()}
  def write([]), do: :ok

  def write(rows) when is_list(rows) do
    cfg = config()
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)

    case request(cfg, "INSERT INTO #{qualified(cfg)} FORMAT JSONEachRow", body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read rows back. Tooling and tests only; nothing in the runtime calls this.

  A running node is not expected to hold SELECT on this table at all — see the
  deployment note in the design doc about granting INSERT without SELECT.
  """
  @spec select(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def select(where, opts \\ []) do
    cfg = config(opts)
    columns = opts[:columns] || "*"
    order = opts[:order] || "event_date, tenant_id, stream, writer, seq"
    limit = opts[:limit] || 10_000

    query = """
    SELECT #{columns} FROM #{qualified(cfg)} FINAL
    WHERE #{where}
    ORDER BY #{order}
    LIMIT #{limit}
    FORMAT JSONEachRow
    """

    case request(cfg, query, "") do
      {:ok, body} -> {:ok, decode_rows(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Run an arbitrary read-only query returning JSONEachRow. Tooling only.

  Used by `Completeness` so the gap analysis runs server-side over the whole
  archive rather than over whatever a reader managed to download.
  """
  @spec query(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query(sql, opts \\ []) do
    case request(config(opts), sql <> "\nFORMAT JSONEachRow", "") do
      {:ok, body} -> {:ok, decode_rows(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The fully qualified table name, for tooling that renders queries."
  @spec table(keyword()) :: String.t()
  def table(opts \\ []), do: qualified(config(opts))

  @doc """
  Probe that the archive table exists with the layout the writer assumes.

  Existence is not enough. The migration is `CREATE TABLE IF NOT EXISTS`, so a
  precreated table with a DIFFERENT sorting key satisfies it — and on a
  ReplacingMergeTree a wrong sorting key is not a failed query, it is silent
  destruction of archived events as the engine merges rows it believes are
  duplicates.

  This is the ONLY check for that: the migration carries no structural
  assertions, so nothing catches a near-miss table at migrate time. Two callers
  run it — a `:clickhouse` test after migrating, which covers CI, and
  `SalixAnalytics.EventArchive.Worker` before its first insert, which covers a
  live node by refusing to write rather than by failing readiness (see
  `SalixAnalytics.event_archive_ready?/0` for why not readiness).
  """
  @spec readiness(keyword()) :: :ok | {:error, term()}
  def readiness(opts \\ []) do
    cfg = config(opts)

    query = """
    SELECT count() FROM system.tables
    WHERE database = '#{cfg.database}' AND name = '#{@table}'
      AND engine IN ('ReplacingMergeTree', 'SharedReplacingMergeTree')
      AND partition_key = 'toYYYYMM(event_date)'
      AND sorting_key = 'event_date, tenant_id, stream, writer, seq'
    """

    case request(cfg, query, "") do
      {:ok, body} ->
        if body |> to_string() |> String.trim() == "1" do
          :ok
        else
          {:error, {:archive_table_layout_mismatch, qualified(cfg)}}
        end

      {:error, reason} ->
        {:error, {:archive_table_unavailable, qualified(cfg), reason}}
    end
  end

  defp decode_rows(body) do
    body
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, row} when is_map(row) -> [row]
        _ -> []
      end
    end)
  end

  defp request(cfg, query, body) do
    case Req.post(cfg.base_url,
           params: params(cfg, query),
           headers: headers(cfg),
           body: body,
           receive_timeout: cfg.receive_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status, body: response}} ->
        # Bounded: a ClickHouse error body can echo the offending row, and the
        # offending row carries ciphertext plus a plaintext header. Neither
        # belongs in a log line at full length.
        Logger.error("event archive clickhouse #{status}: #{brief(response)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.error("event archive clickhouse transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp brief(value), do: value |> to_string() |> String.slice(0, 200)

  defp params(cfg, query) do
    # Pin the UInt64 wire format. With quoting on — the documented default on
    # many builds — `seq` comes back as "42" and every sealed-header comparison
    # in `Item.open/2` fails, which silently disables tamper detection.
    # `Item.header_of_row/1` also coerces; this makes the two agree at the wire
    # rather than relying on either alone.
    base = [query: query, output_format_json_quote_64bit_integers: 0]
    if cfg.database, do: [{:database, cfg.database} | base], else: base
  end

  defp headers(%{user: user, password: pass}) when is_binary(user) and user != "" do
    [{"x-clickhouse-user", user}, {"x-clickhouse-key", pass || ""}]
  end

  defp headers(_), do: []

  defp qualified(cfg), do: "#{cfg.database}.#{@table}"

  defp config(opts \\ []) do
    cfg = Keyword.merge(Application.get_env(:salix_analytics, :clickhouse, []), opts)
    table = cfg[:table] || "salix_analytics.events"

    database =
      cfg[:archive_database] || cfg[:typed_database] || cfg[:database] ||
        table |> String.split(".", parts: 2) |> hd()

    %{
      base_url: cfg[:base_url] || "http://127.0.0.1:8123",
      database: database,
      user: cfg[:user],
      password: cfg[:password],
      # Longer than the metering sink's 5s: archive batches are much larger
      # (whole conversations, not counters) and a timeout here DROPS the batch,
      # so waiting is much cheaper than giving up early.
      receive_timeout_ms: cfg[:archive_receive_timeout_ms] || 15_000
    }
  end
end
