defmodule SalixAgent.DeliveryTelemetry do
  @moduledoc "Bounded diagnostics for Conversation admission and Session archive maintenance."
  use SystemsRuntime.Server
  require Logger

  @table __MODULE__.Buffer
  @capacity 256
  @events ~w(admission_attempt admission_deferred retry_exhausted revision_conflict admission_committed archive_published model_started queue_wait conversation_committed slack_reply)a
  @numbers ~w(attempt cached_revision current_revision archived_from archived_through conversation_seq queue_age_ms source_created_at_ms source_sent_at_ms reply_at_ms)a

  def create_table do
    SystemsRuntime.ETS.new(@table, [:named_table, :public, :set, write_concurrency: true])
  end

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  def identity(agent, session, source \\ nil) do
    %{
      agent_id: id(agent, "agt1_"),
      session_id: id(session, "ses1_"),
      source_key: source_key(source)
    }
  end

  def source_key(source) when is_binary(source) and byte_size(source) in 1..512,
    do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  def source_key(_), do: nil

  defp id(value, prefix) when is_binary(value) and byte_size(value) <= 128 do
    if String.starts_with?(value, prefix) and Regex.match?(~r/\A[a-z0-9_]+\z/, value),
      do: value
  end

  defp id(_, _), do: nil

  # Producers never wait for a logger or collector. The fixed-slot buffer can
  # drop diagnostics. It cannot retain payloads or control delivery results.
  def emit(event, outcome, duration_ms, fields \\ %{}, reason \\ :none) when event in @events do
    metadata = Salix.Telemetry.delivery_tags(%{phase: event, outcome: outcome, reason: reason})
    duration_ms = if is_number(duration_ms), do: max(duration_ms, 0), else: 0
    metric([:salix, :delivery, :stop], %{duration: duration_ms}, metadata)

    safe =
      Enum.reduce(@numbers, %{}, fn key, acc ->
        if is_integer(fields[key]), do: Map.put(acc, key, fields[key]), else: acc
      end)

    safe =
      safe
      |> Map.merge(identity(fields[:agent_id], fields[:session_id]))
      |> Map.put(:source_key, hash_key(fields[:source_key]))
      |> Map.put(:request_key, hash_key(fields[:request_key]))
      |> Map.put(:tool_key, hash_key(fields[:tool_key]))
      |> Map.put(:thread_key, hash_key(fields[:thread_key]))
      |> Map.put(:error_class, class_key(fields[:error_class]))
      |> Map.merge(metadata)
      |> Map.put(:observed_at_ms, SystemsClock.system_time(:millisecond))
      |> Map.put(:duration_ms, duration_ms)
      |> Map.merge(trace_context())

    slot =
      rem(
        SystemsRuntime.ETS.update_counter(
          @table,
          :sequence,
          {2, 1, @capacity - 1, 0},
          {:sequence, 0}
        ),
        @capacity
      )

    unless SystemsRuntime.ETS.insert_new(@table, {slot, safe}), do: dropped(:buffer_full)
    :ok
  rescue
    _ -> dropped(:unavailable)
  catch
    _, _ -> dropped(:unavailable)
  end

  defp trace_context do
    context = SystemsObservability.Context.inject()
    Map.take(context, ["traceparent", "correlation_id"])
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  @doc """
  The shape of a failed result without its contents: atom tags and exception
  modules, at most three levels deep, e.g. `retired_router_session` for
  `{:error, {:retired_router_session, session_id}}`. Strings, ids and other
  data are left out, so the class can be logged for any result.
  """
  def error_class({:error, reason}), do: error_class(reason)
  def error_class({:error, reason, _}), do: error_class(reason)
  def error_class(reason), do: reason |> class_parts(3) |> Enum.join(":") |> class_key()

  defp class_parts(_, 0), do: []
  defp class_parts(value, _) when is_boolean(value) or is_nil(value), do: [to_string(value)]
  defp class_parts(value, _) when is_atom(value), do: [Atom.to_string(value)]

  defp class_parts(%{__exception__: true, __struct__: module}, _),
    do: [module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")]

  defp class_parts(value, depth) when is_tuple(value) and tuple_size(value) > 0 do
    case elem(value, 0) do
      tag when is_atom(tag) ->
        [Atom.to_string(tag) | value |> Tuple.to_list() |> tl() |> nested(depth)]

      _ ->
        []
    end
  end

  defp class_parts(_, _), do: []

  defp nested([value | _], depth), do: class_parts(value, depth - 1)
  defp nested([], _), do: []

  defp class_key(value) when is_binary(value) and byte_size(value) in 1..120 do
    if Regex.match?(~r/\A[A-Za-z0-9_.:]+\z/, value), do: value
  end

  defp class_key(_), do: nil

  defp hash_key(value) when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: value
  end

  defp hash_key(_), do: nil

  defp metric(event, measurements, metadata) do
    SystemsRuntime.Telemetry.execute(event, measurements, metadata)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp dropped(reason), do: metric([:salix, :delivery, :diagnostic_drop], %{}, %{reason: reason})

  # Independent per-phase limits would keep a different subset of sources in
  # each phase. Every node and phase keeps the same sixteenth of source keys
  # under a separate budget, so their whole chains survive the limit together.
  defp budget(%{source_key: "0" <> _} = event), do: {{:sampled, event.phase, event.outcome}, 64}
  defp budget(event), do: {{event.phase, event.outcome}, 16}

  @impl true
  def init(_opts) do
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :flush, 250)
    {:ok, %{window: nil, counts: %{}}}
  end

  @impl true
  def handle_info(:flush, state) do
    window = div(SystemsClock.monotonic_time(:millisecond), 10_000)
    state = if state.window == window, do: state, else: %{window: window, counts: %{}}

    state =
      Enum.reduce(0..(@capacity - 1), state, fn slot, state ->
        case SystemsRuntime.ETS.take(@table, slot) do
          [{_, event}] ->
            {key, limit} = budget(event)
            count = Map.get(state.counts, key, 0)

            if count < limit do
              Logger.info("session_delivery_diagnostic", diagnostic: event)
            else
              dropped(:rate_limited)
            end

            %{state | counts: Map.put(state.counts, key, min(count + 1, limit))}

          [] ->
            state
        end
      end)

    SystemsClock.send_after(SystemsRuntime.Proc.self(), :flush, 250)
    {:noreply, state}
  end
end
