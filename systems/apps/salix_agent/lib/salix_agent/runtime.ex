defmodule SalixAgent.Runtime do
  @moduledoc """
  Agent runtime session public API.

  Functions accepting an agent map require a persisted control projection that
  the caller has already scope-validated for the current request.
  """

  alias SalixAgent.{
    AgentWorkspace,
    AsyncToolResults,
    Control,
    InternalAgentRuntime,
    RetiredSessions,
    WorkspaceEvents
  }

  alias SalixStore.Ids

  def list_sessions(agent_or_id, opts \\ []) do
    with {:ok, agent} <- resolve_agent(agent_or_id),
         {:ok, sessions} <-
           InternalAgentRuntime.list_sessions(
             agent["agent_id"],
             Keyword.get(opts, :include_hidden, false)
           ) do
      case RetiredSessions.list(agent) do
        {:ok, []} ->
          {:ok, sessions}

        {:ok, retired} ->
          retired =
            if Keyword.get(opts, :include_hidden, false),
              do: retired,
              else: Enum.reject(retired, &(&1["hidden"] == true))

          {:ok, Enum.sort_by(sessions ++ retired, &(&1["created_at"] || 0), :desc)}

        {:error, _} = error ->
          error
      end
    end
  end

  def get_session(agent_or_id, session_id, _opts \\ []) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      agent["agent_id"]
      |> InternalAgentRuntime.get_session_summary(session_id)
      |> or_retired(fn -> RetiredSessions.get_summary(agent, session_id) end)
    end
  end

  def get_session_activity(agent_or_id, session_id) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      InternalAgentRuntime.get_session_activity(agent["agent_id"], session_id)
    end
  end

  def get_session_status(agent_or_id, session_id) do
    get_session(agent_or_id, session_id)
  end

  def get_session_messages(agent_or_id, session_id, opts \\ []) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      agent["agent_id"]
      |> InternalAgentRuntime.get_session_messages(session_id, opts)
      |> or_retired(fn -> RetiredSessions.get_messages(agent, session_id) end)
    end
  end

  def list_project_knowledge_uses(agent_or_id, opts \\ []) do
    with {:ok, agent} <- resolve_agent(agent_or_id) do
      InternalAgentRuntime.list_project_knowledge_uses(agent["agent_id"], opts)
    end
  end

  def session_records(agent_or_id, session_id, opts \\ []) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      agent["agent_id"]
      |> InternalAgentRuntime.session_records(session_id, opts)
      |> or_retired(fn -> RetiredSessions.records(agent, session_id, opts) end)
    end
  end

  def session_billing_context(agent_id, session_id) do
    with :ok <- require_session_id(session_id),
         {:ok, _agent} <- Control.get_record(agent_id) do
      InternalAgentRuntime.session_billing_context(agent_id, session_id)
    end
  end

  def get_async_tool_call(agent_id, session_id, tool_call_id) do
    with :ok <- require_session_id(session_id),
         {:ok, _agent} <- Control.get_record(agent_id) do
      InternalAgentRuntime.get_async_tool_call(agent_id, session_id, tool_call_id)
    end
  end

  @doc false
  def get_async_tool_setup_result(agent_id, session_id, tool_call_id)
      when is_binary(tool_call_id) and tool_call_id != "" do
    with :ok <- require_session_id(session_id),
         {:ok, _agent} <- Control.get_record(agent_id),
         operation_id <-
           WorkspaceEvents.operation_id(
             AsyncToolResults.operation_source(:internal),
             agent_id,
             session_id,
             tool_call_id
           ),
         {:ok, result} <- AgentWorkspace.operation_result(agent_id, operation_id) do
      {:ok, WorkspaceEvents.restore_operation_result(result)}
    end
  end

  def get_async_tool_setup_result(_agent_id, _session_id, _tool_call_id),
    do: {:error, :not_found}

  @doc "Fork a session."
  def fork_session(agent_or_id, session_id, attrs) when is_map(attrs) do
    with :ok <- require_session_id(session_id) do
      route_internal(agent_or_id, fn agent ->
        InternalAgentRuntime.fork_session(agent["agent_id"], session_id, attrs)
      end)
    end
  end

  def session_status(agent_or_id, session_id) do
    with :ok <- require_session_id(session_id) do
      route_internal(agent_or_id, fn agent ->
        InternalAgentRuntime.session_status(agent["agent_id"], session_id)
      end)
    end
  end

  def compact_session(agent_or_id, session_id) do
    with :ok <- require_session_id(session_id) do
      route_internal(agent_or_id, fn agent ->
        InternalAgentRuntime.compact_session(agent["agent_id"], session_id)
      end)
    end
  end

  def seed_transcript(agent_or_id, session_id, attrs) when is_map(attrs) do
    with :ok <- require_session_id(session_id) do
      route_internal(agent_or_id, fn agent ->
        InternalAgentRuntime.seed_transcript(agent["agent_id"], session_id, attrs)
      end)
    end
  end

  def execute_session_tool(agent_or_id, session_id, tool_name, attrs, tenant_id)
      when is_map(attrs) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_scoped_agent(agent_or_id, tenant_id) do
      InternalAgentRuntime.execute_session_tool(agent["agent_id"], session_id, tool_name, attrs)
    end
  end

  def session_trace(agent_or_id, session_id, opts \\ []) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      InternalAgentRuntime.session_trace(agent["agent_id"], session_id, opts)
    end
  end

  def search_messages(agent_or_id, query, limit \\ 20) do
    with {:ok, agent} <- resolve_agent(agent_or_id) do
      InternalAgentRuntime.search_messages(agent["agent_id"], query, limit)
    end
  end

  defp route_internal(agent_or_id, fun) do
    with {:ok, agent} <- resolve_agent(agent_or_id), do: fun.(agent)
  end

  # A Session id that is not in the internal store may be a retired Session
  # (`SalixAgent.RetiredSessions`), which is read-only history.
  defp or_retired({:error, :not_found}, read_retired), do: read_retired.()
  defp or_retired(result, _read_retired), do: result

  defp require_session_id(session_id) do
    if Ids.valid_session_id?(session_id),
      do: :ok,
      else: {:error, {:bad_request, "invalid session_id"}}
  end

  defp resolve_agent(
         %{"agent_id" => agent_id, "tenant_id" => tenant_id, "group_id" => group_id} = agent
       )
       when is_binary(agent_id) and agent_id != "" and is_binary(tenant_id) and tenant_id != "" and
              is_binary(group_id) and group_id != "",
       do: {:ok, agent}

  defp resolve_agent(%{}), do: {:error, :not_found}
  defp resolve_agent(agent_id) when is_binary(agent_id), do: Control.get_record(agent_id)

  defp resolve_scoped_agent(%{"tenant_id" => tenant_id} = agent, tenant_id) do
    with {:ok, agent} <- resolve_agent(agent),
         true <- Control.visible?(agent) do
      {:ok, agent}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp resolve_scoped_agent(%{}, _tenant_id), do: {:error, :not_found}
  defp resolve_scoped_agent(agent_id, tenant_id), do: Control.get(agent_id, tenant_id)
end
