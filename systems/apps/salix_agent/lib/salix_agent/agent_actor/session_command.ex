defmodule SalixAgent.AgentActor.SessionCommand do
  @moduledoc """
  Session tool and consultation commands, routed to the Session's owner.
  """

  alias SalixAgent.{Control, InternalSessionFleet, MemoryConsultationRuntime}
  alias SalixAgent.AgentActor.SessionDelivery

  def execute_session_tool(agent_id, session_id, tool_name, attrs, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_name) and
             is_map(attrs) do
    with :ok <- Control.ensure_not_stopped(agent_id) do
      InternalSessionFleet.execute_tool(agent_id, session_id, tool_name, attrs, opts)
    end
  end

  def complete_async_tool_call(agent_id, session_id, tool_call_id, result, meta, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id) and
             is_map(result) and is_map(meta) do
    with :ok <- Control.ensure_not_stopped(agent_id) do
      InternalSessionFleet.complete_async_tool_call(
        agent_id,
        session_id,
        tool_call_id,
        result,
        meta,
        opts
      )
    end
  end

  def update_async_tool_call_progress(agent_id, session_id, tool_call_id, progress, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id) and
             is_map(progress) do
    with :ok <- Control.ensure_not_stopped(agent_id) do
      InternalSessionFleet.update_async_tool_call_progress(
        agent_id,
        session_id,
        tool_call_id,
        progress,
        opts
      )
    end
  end

  def consult_worker_session(agent_id, session_id, question, request_id, _opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(question) and
             is_binary(request_id) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         {:ok, runtime_kind} <- SessionDelivery.session_birth_runtime(agent_id, session_id) do
      case runtime_kind do
        :internal ->
          agent_id
          |> MemoryConsultationRuntime.consult_internal(session_id, question)
          |> consultation_runtime_result("internal")

        # A retired Session has no runtime to consult.
        _retired_or_new ->
          {:error, :not_found}
      end
    end
  end

  defp consultation_runtime_result({:ok, result}, runtime_kind) when is_map(result),
    do: {:ok, Map.put(result, "runtime_kind", runtime_kind)}

  defp consultation_runtime_result({:error, _reason} = error, _runtime_kind), do: error
end
