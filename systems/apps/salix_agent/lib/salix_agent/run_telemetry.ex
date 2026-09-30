defmodule SalixAgent.RunTelemetry do
  require SalixAgent.InternalSession
  @moduledoc false

  require Logger

  # A guard ended these runs on purpose to stop a loop.
  @parked_statuses ~w(
    runaway_guard_parked
    repeated_tool_result_parked
    input_round_budget_parked
  )

  # Every status a run ends with. This list is a contract with the readers:
  # `AgentTelemetryQueries.run_outcomes/2` counts these names and the Runtime
  # Health page labels them. A status missing here reaches ClickHouse as
  # `actor_failed`, which is why the three guard parks and `repair_failed`
  # were indistinguishable from an actor that crashed.
  @terminal_statuses ~w(completed llm_failed actor_failed repair_failed) ++ @parked_statuses

  @doc """
  Every status a run ends with, as written to `agent_run_events_v2`.

  Readers that count or label run outcomes read this list rather than
  repeating it, so a status added here cannot reach a dashboard unnamed.
  """
  def terminal_statuses, do: @terminal_statuses

  @doc """
  The statuses where a guard ended the run on purpose to stop a loop.

  A park is not a crash. The runtime worked as designed, and the input still
  got no answer, so readers show these apart from `actor_failed`.
  """
  def parked_statuses, do: @parked_statuses

  def emit_agent_run(attrs) when is_map(attrs) do
    do_emit_agent_run(attrs)
  rescue
    exception ->
      Logger.warning("agent run telemetry build failed: #{Exception.message(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning("agent run telemetry build exited: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  def build_agent_run(attrs) when is_map(attrs) do
    session = field(attrs, :session) || %{}
    meter_ctx = field(attrs, :meter_ctx) || %{}
    billing_context = field(attrs, :billing_context) || field(meter_ctx, :billing_context) || %{}
    trace_ctx = field(attrs, :trace_ctx) || %{}
    started_at_ms = int(field(attrs, :started_at_ms) || field(meter_ctx, :started_at_ms))
    started_at_ms = started_at_ms || System.system_time(:millisecond)

    duration_ms =
      int(field(attrs, :duration_ms)) || max(System.system_time(:millisecond) - started_at_ms, 0)

    round_id =
      field(trace_ctx, :round_id) || field(meter_ctx, :round_id) || field(attrs, :round_id)

    %{
      source: "salix_agent.run",
      source_key: round_id || "run:" <> random_id(),
      entrypoint: "agent_run",
      surface: nested(attrs, meter_ctx, billing_context, :surface) || "unknown",
      tenant_id: field(attrs, :tenant_id) || field(meter_ctx, :tenant_id) || "unknown",
      group_id: field(attrs, :group_id) || field(meter_ctx, :group_id) || "unknown",
      actor_type: nested(attrs, meter_ctx, billing_context, :actor_type) || "user",
      status: status(field(attrs, :status)),
      duration_ms: duration_ms,
      started_at: timestamp(started_at_ms),
      metered_at: DateTime.utc_now(),
      trace_id:
        field(trace_ctx, :trace_id) || field(meter_ctx, :trace_id) || field(attrs, :trace_id),
      request_id:
        field(trace_ctx, :request_id) || field(meter_ctx, :request_id) ||
          field(attrs, :request_id),
      salix_agent_id:
        field(attrs, :salix_agent_id) || field(attrs, :agent_id) ||
          field(meter_ctx, :salix_agent_id) ||
          field(meter_ctx, :agent_id),
      session_id: field(attrs, :session_id) || field(meter_ctx, :session_id),
      round_id: round_id,
      charge_status: "unattributed",
      app_revision:
        field(attrs, :app_revision) || field(meter_ctx, :app_revision) ||
          SalixAgent.AppRevision.value(),
      task_origin: field(session, :task_origin),
      platform: field(session, :platform),
      source_schedule_id: field(session, :source_schedule_id)
    }
  end

  defp do_emit_agent_run(attrs) do
    fact = build_agent_run(attrs)

    if fact.status in @terminal_statuses do
      SalixAgent.Observability.agent_run(fact)
    else
      :ok
    end
  end

  defp status(value) when value in @terminal_statuses, do: value

  defp status(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> status()

  defp status(nil), do: "actor_failed"

  # An ending this module cannot name stays a failure, because an unnamed
  # ending is not a success. Warn so that the next unregistered status shows
  # up in the log instead of merging silently into the crash bucket.
  defp status(other) do
    Logger.warning("agent run telemetry saw an unregistered status: #{inspect(other)}")
    "actor_failed"
  end

  defp timestamp(%DateTime{} = value), do: value
  defp timestamp(value) when is_integer(value), do: DateTime.from_unix!(value, :millisecond)
  defp timestamp(_), do: DateTime.utc_now()

  defp nested(attrs, meter_ctx, billing_context, key),
    do: field(attrs, key) || field(meter_ctx, key) || field(billing_context, key)

  defp field(session, key) when SalixAgent.InternalSession.is_session(session),
    do: SalixAgent.InternalSession.get(session, key)

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_map, _key), do: nil

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_binary(value), do: String.to_integer(value)
  defp int(_), do: nil

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
