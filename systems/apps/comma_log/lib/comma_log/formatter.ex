defmodule CommaLog.Formatter do
  @moduledoc """
  JSON-line formatter for Elixir's default `Logger` handler, so the *whole*
  release emits structured logs — one JSON object per line — consistent with the
  `CommaLog` diagnostic stream. Metadata is sanitized + secret-redacted through
  `CommaLog.jsonable/1` (tuples→lists, pids/refs inspected, long strings truncated,
  api_key/token/… redacted), and the formatter never raises (a format error
  degrades to a minimal JSON line rather than breaking logging).

  Wire it via `config/config.exs`:

      config :logger, :default_formatter,
        Logger.Formatter.new(format: {CommaLog.Formatter, :format}, metadata: :all)

  This is distinct from `CommaLog` itself: `CommaLog` is the opt-in per-event
  diagnostic file; this routes the standard `Logger` (app/Ecto/Bandit/…) to the
  same JSON shape on the console.
  """

  alias SystemsObservability.{Classifier, Resource}

  @doc """
  Logger format callback. Returns one JSON object (chardata) + newline carrying
  `ts`, `level`, `msg`, and the sanitized log metadata.
  """
  @spec format(Logger.level(), IO.chardata(), :calendar.datetime() | tuple(), keyword() | map()) ::
          IO.chardata()
  def format(level, message, timestamp, metadata) do
    metadata =
      metadata
      |> Map.new()
      # Cloud Logging reserves the top-level `time` field for an RFC3339
      # timestamp. Logger supplies it as Unix microseconds, which makes the
      # GKE log collector reject the entire JSON record. The formatter-owned
      # `ts` field below is the canonical application timestamp; the CRI
      # envelope supplies the LogEntry timestamp.
      |> Map.delete(:time)
      |> enrich_observability()
      |> redact_crash_metadata()

    entry =
      metadata
      |> normalize_charlists()
      |> CommaLog.jsonable()
      |> Map.merge(%{
        "ts" => iso8601(timestamp),
        "level" => to_string(level),
        "msg" => message_to_string(message, metadata)
      })

    [Jason.encode_to_iodata!(entry), ?\n]
  rescue
    _ ->
      [
        Jason.encode_to_iodata!(%{"level" => to_string(level), "msg" => "[log format error]"}),
        ?\n
      ]
  end

  defp enrich_observability(metadata) do
    resource = Resource.current()

    metadata
    |> trace_fields()
    |> Map.put(:workload, resource[:workload] || "unknown")
    |> Map.put(:revision, resource[:revision] || "unknown")
    |> Map.update(:surface, "system", &Classifier.surface/1)
    |> put_component(metadata[:application])
    |> Map.update(:error_class, "none", &Classifier.error_class/1)
  end

  defp put_component(metadata, application) do
    case Map.fetch(metadata, :component) do
      {:ok, component} -> Map.put(metadata, :component, Classifier.component(component))
      :error -> Map.put(metadata, :component, Classifier.component_for_application(application))
    end
  end

  defp trace_fields(%{otel_span_ctx: span_ctx} = metadata) do
    case OpenTelemetry.Span.hex_span_ctx(span_ctx) do
      %{otel_trace_id: trace_id, otel_span_id: span_id} ->
        metadata
        |> Map.delete(:otel_span_ctx)
        |> Map.put(:trace_id, trace_id)
        |> Map.put(:span_id, span_id)

      _ ->
        Map.delete(metadata, :otel_span_ctx)
    end
  rescue
    _ -> Map.delete(metadata, :otel_span_ctx)
  end

  defp trace_fields(metadata) do
    span_ctx = OpenTelemetry.Tracer.current_span_ctx()

    if OpenTelemetry.Span.is_valid(span_ctx) do
      trace_fields(Map.put(metadata, :otel_span_ctx, span_ctx))
    else
      metadata
    end
  end

  defp redact_crash_metadata(%{crash_reason: reason} = metadata) do
    {reason, stack} =
      case reason do
        {reason, stack} when is_list(stack) -> {reason, stack}
        reason -> {reason, []}
      end

    metadata =
      metadata
      # Bandit's error metadata includes the entire Plug.Conn; OTP reports can
      # also attach state. Neither belongs in the reconstructed crash record.
      |> Map.drop([:conn, :state, :last_message])
      |> Map.update(:plug, nil, fn
        {module, _opts} when is_atom(module) -> module
        module when is_atom(module) -> module
        _other -> "[redacted]"
      end)
      |> Map.put(:crash_reason, CommaLog.Crash.reason(reason))
      |> Map.put(:crash_kind, crash_kind(reason))
      |> Map.put(:crash_stacktrace, CommaLog.Crash.stacktrace(stack))
      |> Map.update(:error_class, "internal", fn
        "none" -> "internal"
        classified -> classified
      end)

    case metadata.crash_stacktrace do
      [%{module: module, function: function, arity: arity} | _] ->
        Map.put(metadata, :crash_mfa, [module, function, arity])

      [] ->
        metadata
    end
  end

  defp redact_crash_metadata(metadata), do: metadata

  # Finite classification stays separate from the detailed log diagnostics.
  defp crash_kind(%{__struct__: type}) do
    case type do
      FunctionClauseError -> "function_clause"
      MatchError -> "badmatch"
      CaseClauseError -> "case_clause"
      ArgumentError -> "badarg"
      UndefinedFunctionError -> "undef"
      _ -> "exception"
    end
  end

  defp crash_kind(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: crash_kind(elem(reason, 0))

  defp crash_kind(reason)
       when reason in [
              :function_clause,
              :badmatch,
              :case_clause,
              :badarg,
              :undef,
              :timeout,
              :noproc,
              :shutdown,
              :killed,
              :normal
            ],
       do: Atom.to_string(reason)

  defp crash_kind(_reason), do: "other"

  # Logger sets some metadata (e.g. :file) as Erlang charlists; render those as
  # strings rather than int arrays. Only printable charlists are converted.
  defp normalize_charlists(map) do
    Map.new(map, fn
      {k, v} when is_list(v) -> {k, if(printable_charlist?(v), do: List.to_string(v), else: v)}
      {k, v} -> {k, v}
    end)
  end

  defp printable_charlist?([]), do: false
  defp printable_charlist?(list), do: List.ascii_printable?(list)

  defp message_to_string(_message, %{crash_reason: reason}), do: CommaLog.Crash.summary(reason)

  defp message_to_string(message, _metadata), do: render_message(message)

  defp render_message(message) do
    message |> IO.chardata_to_string()
  rescue
    _ -> inspect(message, limit: 50, printable_limit: 4096)
  end

  defp iso8601({{y, mo, d}, {h, mi, s, ms}}) do
    :io_lib.format(
      "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
      [y, mo, d, h, mi, s, ms]
    )
    |> IO.iodata_to_binary()
  end

  defp iso8601(_other) do
    System.system_time(:microsecond) |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end
end
