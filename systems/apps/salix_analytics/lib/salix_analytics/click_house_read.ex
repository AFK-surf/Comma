defmodule SalixAnalytics.ClickHouseRead do
  @moduledoc """
  Shared plumbing for read-side dashboard queries against ClickHouse.

  Deliberately NOT built on the typed sink client (`Sink.ClickHouseTyped`
  must stay a narrow insert path): this speaks the same minimal HTTP dialect
  as `SalixAnalytics.Migrations` — `Req.post` with the SQL in the request
  body — with results in `FORMAT JSONEachRow`, decoded line by line, or in
  `FORMAT JSONCompactEachRowWithNames` (`format: :compact_with_names`) for a
  wide feed, where repeating every column name on every row would be most
  of the bytes; both decode to the same list of maps.

  Values are never interpolated into SQL. Every statement binds via
  ClickHouse native query parameters (`{name:Type}` placeholders + HTTP
  `param_<name>` params), and the only dynamic identifier — the database —
  comes from config and is validated against `[A-Za-z_][A-Za-z0-9_]*`.
  """

  @type rows :: [map()]
  @type result :: {:ok, rows()} | {:error, term()}

  # The request-path boundedness contract. Projections keep the COMMON case
  # cheap, but they cannot bound every case — a single session with millions
  # of rows must be read and converged before the outer LIMIT, so no
  # projection saves it. These are the guarantee instead: every dashboard read
  # completes within a fixed row/byte/memory/time budget or fails fast with a
  # tagged `:read_over_budget` error the page surfaces as "narrow the window",
  # rather than hanging past the transport timeout or exhausting server memory.
  # `read_overflow_mode`/`timeout_overflow_mode` default to `throw`, so
  # exceeding any budget aborts the query. Defaults are generous — a legitimate
  # busy-tenant window passes; only a runaway is stopped — and every ceiling is
  # overridable via `config :salix_analytics, :clickhouse`.
  @default_max_rows 500_000_000
  @default_max_bytes 20 * 1024 * 1024 * 1024
  @default_max_memory_bytes 2 * 1024 * 1024 * 1024
  # Server-side wall-clock ceiling, set below the transport `receive_timeout`
  # so ClickHouse returns a clean limit error before Req times out the socket
  # (a socket timeout is an opaque `%Mint.TransportError{}`, not an actionable
  # "too much data" signal).
  @default_max_execution_seconds 14
  @receive_timeout_ms 15_000

  # ClickHouse error codes for the four budgets above: TOO_MANY_ROWS,
  # TIMEOUT_EXCEEDED, TOO_SLOW, MEMORY_LIMIT_EXCEEDED, TOO_MANY_BYTES. A query
  # that trips one of these did not fail — it declined to scan an unbounded
  # amount, exactly as the contract intends.
  @over_budget_codes ~w(158 159 160 241 307)

  @doc """
  Run `sql_fn.(database)` with the given binds.

  `sql_fn` receives the validated database name and returns the SQL text;
  binds become `param_<name>` HTTP params, never SQL text.

  `opts[:query]` names the query family for telemetry. It must come from the
  finite set registered in `Salix.Telemetry` — a free-form name would make the
  metric's label cardinality unbounded — and unregistered names normalize to
  `other` there.

  Returns `{:error, {:read_over_budget, detail}}` when the query would exceed
  the configured row/byte/memory/time budget; callers on a user-facing path
  should render this as "this view has too much data — narrow the time window",
  not as an internal error.
  """
  @spec run((String.t() -> String.t()), keyword(), keyword()) :: result()
  def run(sql_fn, binds, opts \\ []) do
    started = System.monotonic_time()
    result = do_run(sql_fn, binds, opts[:format] || :json_each_row)

    # A dashboard read is a synchronous dependency with a hard 15s ceiling;
    # without this the only symptom of a slow or failing query is a blank
    # panel. Emitted after the call so telemetry never sits on the request.
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{
        component: "salix_analytics",
        operation: opts[:query] || "other",
        surface: SystemsObservability.Context.current_surface(),
        outcome: outcome(result)
      }
    )

    result
  end

  # `:not_configured` is a deployment without analytics, not a failure.
  # `over_budget` is a distinct outcome: the query hit its read/memory/time
  # ceiling and declined to scan further — an operator signal, not an error.
  defp outcome({:ok, _}), do: "ok"
  defp outcome({:error, :not_configured}), do: "ok"
  defp outcome({:error, {:read_over_budget, _}}), do: "over_budget"
  defp outcome({:error, %{reason: :timeout}}), do: "timeout"
  defp outcome({:error, :timeout}), do: "timeout"
  defp outcome({:error, _}), do: "error"

  defp do_run(sql_fn, binds, format) do
    with {:ok, cfg} <- config(),
         {:ok, _} <- Application.ensure_all_started(:req) do
      # SQL travels in the request body (ClickHouse reads the query there);
      # only the `param_*` bindings go in the URL. A body is also required —
      # ClickHouse 411s a POST with neither Content-Length nor chunking.
      #
      # `output_format_json_quote_64bit_integers=0`: uniqExact/count return
      # UInt64, which JSONEachRow quotes as strings by default. The dashboard
      # does arithmetic on these counts, so emit them as JSON numbers (our
      # counts are far under 2^53, so precision is not a concern).
      params =
        [{"output_format_json_quote_64bit_integers", "0"}] ++
          budget_params(cfg) ++
          Enum.map(binds, fn {name, value} -> {"param_#{name}", to_string(value)} end)

      case Req.post(cfg.base_url,
             params: params,
             body: sql_fn.(cfg.database),
             headers: headers(cfg),
             receive_timeout: @receive_timeout_ms,
             # Interactive dashboard read — fail fast rather than block the
             # page behind Req's transient-retry backoff.
             retry: false
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          decode_rows(body, format)

        {:ok, %{status: _status, body: body}} ->
          classify_error(body)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Per-query read budgets. `read_overflow_mode`/`timeout_overflow_mode` are
  # left at their `throw` default so exceeding a ceiling aborts rather than
  # silently truncating — this contract fails fast, it does not return partial
  # numbers without a caller-visible signal.
  defp budget_params(cfg) do
    [
      {"max_rows_to_read", to_string(cfg.read_max_rows)},
      {"max_bytes_to_read", to_string(cfg.read_max_bytes)},
      {"max_memory_usage", to_string(cfg.read_max_memory_bytes)},
      {"max_execution_time", to_string(cfg.read_max_execution_seconds)}
    ]
  end

  # A non-2xx body carries `Code: NNN.` as its first token. The budget codes
  # become the tagged `:read_over_budget` result the dashboard renders as
  # "narrow the window"; everything else stays a generic http error.
  defp classify_error(body) do
    text = to_string(body)

    case Regex.run(~r/Code:\s*(\d+)/, text) do
      [_, code] when code in @over_budget_codes ->
        {:error, {:read_over_budget, %{code: String.to_integer(code), message: trim(text)}}}

      _ ->
        {:error, {:http, text}}
    end
  end

  defp trim(text), do: text |> String.slice(0, 300) |> String.trim()

  @doc false
  # `JSONCompactEachRowWithNames`: the first line is the array of column
  # names, every later line one array of values in that order. Rows come out
  # as the same maps `JSONEachRow` would give, so callers cannot tell the
  # formats apart.
  def decode_rows(body, :compact_with_names) do
    case body |> to_string() |> String.split("\n", trim: true) do
      [] ->
        {:ok, []}

      [header | lines] ->
        case Jason.decode(header) do
          {:ok, names} when is_list(names) ->
            width = length(names)

            lines
            |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
              case Jason.decode(line) do
                {:ok, values} when is_list(values) and length(values) == width ->
                  {:cont, {:ok, [Map.new(Enum.zip(names, values)) | acc]}}

                _ ->
                  {:halt, {:error, {:bad_row, line}}}
              end
            end)
            |> case do
              {:ok, rows} -> {:ok, Enum.reverse(rows)}
              error -> error
            end

          _ ->
            {:error, {:bad_row, header}}
        end
    end
  end

  def decode_rows(body, _json_each_row) do
    body
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, _} -> {:halt, {:error, {:bad_row, line}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp headers(%{user: user, password: pass}) when is_binary(user) and user != "" do
    [{"x-clickhouse-user", user}, {"x-clickhouse-key", pass || ""}]
  end

  defp headers(_), do: []

  defp config do
    cfg = Application.get_env(:salix_analytics, :clickhouse, [])
    base_url = cfg[:base_url]
    table = cfg[:table] || "salix_analytics.events"
    database = table |> to_string() |> String.split(".", parts: 2) |> hd()

    cond do
      not is_binary(base_url) or String.trim(base_url) == "" ->
        {:error, :not_configured}

      not Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, database) ->
        {:error, {:invalid_table, table}}

      true ->
        {:ok,
         %{
           base_url: base_url,
           database: database,
           user: cfg[:user],
           password: cfg[:password],
           read_max_rows: cfg[:read_max_rows] || @default_max_rows,
           read_max_bytes: cfg[:read_max_bytes] || @default_max_bytes,
           read_max_memory_bytes: cfg[:read_max_memory_bytes] || @default_max_memory_bytes,
           read_max_execution_seconds:
             cfg[:read_max_execution_seconds] || @default_max_execution_seconds
         }}
    end
  end
end
