defmodule BillingCore.AgentObservability do
  @moduledoc """
  Production adapter for agent observability facts.

  Tool facts are non-billable telemetry, so they use the typed sink worker's
  bounded, nonblocking enqueue path. The caller-side
  `SalixAgent.Observability` wrapper catches exits and exceptions.
  """

  @worker SalixAnalytics.AgentObservabilitySinkWorker

  require Logger

  def tool_call(fact) when is_map(fact) do
    row = SalixAnalytics.ToolCallEvent.build(fact)

    enqueue_observation(:tool_call, row)
  rescue
    exception ->
      result = {:error, {exception.__struct__, Exception.message(exception)}}
      log_discard(:tool_call, result)
      result
  catch
    kind, reason ->
      result = {:error, {kind, reason}}
      log_discard(:tool_call, result)
      result
  end

  def agent_run(fact) when is_map(fact) do
    row = SalixAnalytics.AgentRunEvent.build(fact)

    enqueue_observation(:agent_run, row)
  rescue
    exception ->
      result = {:error, {exception.__struct__, Exception.message(exception)}}
      log_discard(:agent_run, result)
      result
  catch
    kind, reason ->
      result = {:error, {kind, reason}}
      log_discard(:agent_run, result)
      result
  end

  def round_phase(fact) when is_map(fact) do
    row = SalixAnalytics.AgentPhaseEvent.build(fact)

    enqueue_observation(:round_phase, row)
  rescue
    exception ->
      result = {:error, {exception.__struct__, Exception.message(exception)}}
      log_discard(:round_phase, result)
      result
  catch
    kind, reason ->
      result = {:error, {kind, reason}}
      log_discard(:round_phase, result)
      result
  end

  def llm_attempt(fact) when is_map(fact) do
    row = SalixAnalytics.LlmAttemptEvent.build(fact)

    enqueue_observation(:llm_attempt, row)
  rescue
    exception ->
      result = {:error, {exception.__struct__, Exception.message(exception)}}
      log_discard(:llm_attempt, result)
      result
  catch
    kind, reason ->
      result = {:error, {kind, reason}}
      log_discard(:llm_attempt, result)
      result
  end

  defp enqueue_observation(kind, row) do
    result = sink().enqueue([row], server: sink_server())
    log_discard(kind, result)
    result
  end

  defp log_discard(_kind, :ok), do: :ok

  # Buffer pressure is counted by the worker, not logged on the session path.
  defp log_discard(_kind, {:error, reason}) when reason in [:queue_full, :unavailable], do: :ok

  defp log_discard(kind, {:error, reason}) do
    Logger.warning("agent observability #{kind} discard: #{inspect(reason)}")
    :ok
  end

  defp log_discard(_kind, _result), do: :ok

  defp sink do
    Application.get_env(
      :billing_core,
      :agent_observability_typed_sink,
      SalixAnalytics.TypedSinkWorker
    )
  end

  defp sink_server do
    Application.get_env(:billing_core, :agent_observability_typed_sink_server, @worker)
  end
end
