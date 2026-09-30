defmodule SalixAgent.PhaseTelemetry do
  @moduledoc """
  Round phase facts — what the runtime was doing between the calls
  `llm_call_events` and `tool_call_events` record.

  One fact per `(round, phase)`, emitted from the round's own chokepoints
  through `SalixAgent.Observability.round_phase/1` (the non-billable
  observability path; best-effort, never on the loop's critical path,
  every failure swallowed). Phases and where they are measured:

    * `delivery_wait` — the input's arrival at the runtime
      (`SalixAgent.deliver/3` stamps `delivered_at_ms` on the payload; the
      queued item carries it into the transcript message) up to the
      actor's processing entry. Only rounds whose input carries the stamp
      emit it, and `no_wake` deliveries never do: they schedule no round,
      so they are never waiting for one.
    * `activation` — the session actor's processing entry (stamped into
      the actor state, handed to `Round.run/3` as `activation_started_ms`)
      up to the moment Round.run began. Only rounds dispatched by the
      actor's activation carry it; direct `run_round` calls don't.
    * `miniskill` — selection job admission through decision inference and instruction reads.
      It overlaps activation work and excludes cold catalog prewarming.
    * `prepare` — Round.run entry up to the provider dispatch.
    * `response_commit` — provider completion up to the assistant turn
      committed, on the tool path. Measured from the provider's own
      completion instant, so the actor mailbox wait is inside it.
    * `tool_batch` — wall clock of the synchronous tool batch.
    * `tool_commit` — tool results committed to the session.
    * `boundary` — the status=idle write that ends a tool round.
    * `finalize` — provider completion up to the final message committed,
      on the round that produces text.

  `activation_key` is the runtime's identity for the input the round is
  answering (`InternalSession.current_activation_key/2`, joined),
  shared by every round of one activation chain.
  """

  require Logger

  @phases ~w(miniskill response_pickup delivery_wait activation prepare response_commit tool_batch tool_commit boundary finalize async_pickup async_commit async_config)a

  @doc "Wall-clock milliseconds, the unit every phase boundary is stamped in."
  def now_ms, do: System.system_time(:millisecond)

  @doc """
  The earliest `delivered_at_ms` among the transcript messages this round
  answers (its `source_message_ids`) that the runtime has NOT yet begun
  answering — the instant the input reached the runtime. nil when none of
  them carries the stamp (inputs from before it existed, or delivered
  outside `SalixAgent.deliver/3`).

  A `no_wake` delivery is excluded outright. It commits durably but
  schedules no round — it is context staged for whichever ordinary input
  activates next, not work the runtime owes an answer to. Counting its
  arrival would charge the whole gap until that unrelated input arrived as
  queueing delay.

  An input counts as "not yet begun" while no assistant turn follows it in
  the transcript. A continuation round answers the same input as the
  round before it (the ids stay unacked until the final text), and its
  wait is the previous round's commits plus the re-activation — already
  recorded as `tool_commit`, `boundary` and `activation`. Reporting the
  arrival→now span again there would count the model and tool time in
  between as waiting, so only the first round of an input reports
  `delivery_wait`.
  """
  def earliest_delivered_at_ms(session, source_message_ids) when is_list(source_message_ids),
    do: SalixAgent.InternalSession.query(session, :earliest_delivered_at_ms, source_message_ids)

  def earliest_delivered_at_ms(_session, _ids), do: nil

  @doc """
  `delivery_wait`: from the input's arrival to the actor's processing
  entry (or, without an activation stamp, to Round.run). Emits nothing
  without an arrival stamp; a stamp later than the end (clock skew across
  nodes) yields a zero-length fact rather than a negative one.
  """
  def emit_delivery_wait(meter_ctx, opts, activation_key, delivered_at_ms) when is_list(opts) do
    ended = opts[:activation_started_ms] || opts[:round_started_ms]

    if is_integer(delivered_at_ms) and is_integer(ended) do
      emit(
        :delivery_wait,
        meter_ctx,
        activation_key,
        delivered_at_ms,
        max(ended, delivered_at_ms)
      )
    else
      :skip
    end
  end

  @doc """
  The instant a provider call completed, from its metering context and
  measured duration — the start of `response_commit` / `finalize`. Falls
  back to now when the context carries no start.
  """
  def execution_meter_context(meter_ctx, %{execution_timing: %{"started_at_ms" => started}})
      when is_integer(started), do: Map.put(meter_ctx, :started_at_ms, started)

  def execution_meter_context(meter_ctx, _), do: meter_ctx

  def response_at_ms(meter_ctx, duration_ms) when is_map(meter_ctx) do
    case {field(meter_ctx, :started_at_ms), duration_ms} do
      {started, duration} when is_integer(started) and is_integer(duration) ->
        started + duration

      _ ->
        now_ms()
    end
  end

  def response_at_ms(_meter_ctx, _duration_ms), do: now_ms()

  @doc """
  The two facts every provider-dispatching round emits right before the
  dispatch: `activation` when the actor stamped one, and `prepare`.
  """
  def emit_pre_dispatch(meter_ctx, opts, activation_key) when is_list(opts) do
    round_started = opts[:round_started_ms]
    activation_started = opts[:activation_started_ms]

    if is_integer(activation_started) and is_integer(round_started) do
      emit(:activation, meter_ctx, activation_key, activation_started, round_started)
    end

    emit(:prepare, meter_ctx, activation_key, round_started, now_ms())
  end

  @doc """
  Emit one phase fact spanning `started_ms`..`ended_ms` (default: now).
  A nil start (the boundary was never stamped) emits nothing.
  """
  def emit(phase, meter_ctx, activation_key, started_ms, ended_ms \\ nil)

  def emit(_phase, _meter_ctx, _activation_key, nil, _ended_ms), do: :skip

  def emit(phase, meter_ctx, activation_key, started_ms, ended_ms)
      when phase in @phases and is_integer(started_ms) do
    fact = build(phase, meter_ctx, activation_key, started_ms, ended_ms || now_ms())
    SalixAgent.Observability.round_phase(fact)
  rescue
    exception ->
      Logger.warning("phase telemetry emit failed: #{Exception.message(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning("phase telemetry emit exited: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  def emit(_phase, _meter_ctx, _activation_key, _started_ms, _ended_ms), do: :skip

  @doc false
  def build(phase, meter_ctx, activation_key, started_ms, ended_ms) do
    meter_ctx = meter_ctx || %{}
    billing = field(meter_ctx, :billing_context) || %{}
    round_id = field(meter_ctx, :round_id)

    %{
      source: "salix_agent.phase",
      source_key: source_key(round_id, phase, field(meter_ctx, :source_scope)),
      entrypoint: "agent_phase",
      surface: field(meter_ctx, :surface) || field(billing, :surface) || "unknown",
      tenant_id: field(meter_ctx, :tenant_id) || "unknown",
      group_id: field(meter_ctx, :group_id) || "unknown",
      actor_type: field(meter_ctx, :actor_type) || field(billing, :actor_type) || "user",
      phase: to_string(phase),
      status: "ok",
      duration_ms: max(ended_ms - started_ms, 0),
      started_at: DateTime.from_unix!(started_ms, :millisecond),
      metered_at: DateTime.utc_now(),
      trace_id: field(meter_ctx, :trace_id),
      request_id: field(meter_ctx, :request_id),
      salix_agent_id: field(meter_ctx, :salix_agent_id) || field(meter_ctx, :agent_id),
      session_id: field(meter_ctx, :session_id),
      round_id: round_id,
      activation_key: normalize_key(activation_key),
      charge_status: "unattributed",
      app_revision: field(meter_ctx, :app_revision) || SalixAgent.AppRevision.value()
    }
  end

  # One fact per (round, phase) — except when the caller scopes the fact
  # to something narrower, such as one background tool's settlement in a
  # round that ran several: readers converge on (source, source_key), so
  # two facts sharing a key would collapse into one.
  defp source_key(round_id, phase, scope) do
    base = "#{round_id || "round:" <> random_id()}:#{phase}"

    case scope do
      scope when is_binary(scope) and scope != "" -> base <> ":" <> scope
      _ -> base
    end
  end

  @doc "Joined, stable text form of an activation key; nil when empty."
  def normalize_key(nil), do: nil
  def normalize_key([]), do: nil
  def normalize_key(key) when is_binary(key), do: if(key == "", do: nil, else: key)

  def normalize_key(key) when is_list(key) do
    key
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
    |> Enum.uniq()
    |> case do
      [] -> nil
      ids -> Enum.join(ids, ",")
    end
  end

  def normalize_key(_), do: nil

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_map, _key), do: nil

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
