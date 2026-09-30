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
    ExternalAgentRuntime,
    InternalAgentRuntime,
    WorkspaceEvents
  }

  alias SalixStore.Ids

  @internal_runtime_only_error {:error,
                                {:bad_request,
                                 "operation is only available for internal runtime agents"}}

  def list_sessions(agent_or_id, opts \\ []) do
    with {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" ->
          ExternalAgentRuntime.list_session_summaries(agent)

        _ ->
          InternalAgentRuntime.list_sessions(
            agent["agent_id"],
            Keyword.get(opts, :include_hidden, false)
          )
      end
    end
  end

  def get_session(agent_or_id, session_id, _opts \\ []) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" -> ExternalAgentRuntime.get_session_summary(agent, session_id)
        _ -> InternalAgentRuntime.get_session_summary(agent["agent_id"], session_id)
      end
    end
  end

  def get_session_activity(agent_or_id, session_id) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" -> ExternalAgentRuntime.get_session_activity(agent, session_id)
        _ -> InternalAgentRuntime.get_session_activity(agent["agent_id"], session_id)
      end
    end
  end

  def get_session_status(agent_or_id, session_id) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" -> ExternalAgentRuntime.get_session_status(agent, session_id)
        _ -> InternalAgentRuntime.get_session_summary(agent["agent_id"], session_id)
      end
    end
  end

  def get_session_messages(agent_or_id, session_id, opts \\ []) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" -> ExternalAgentRuntime.get_session_messages(agent, session_id)
        _ -> InternalAgentRuntime.get_session_messages(agent["agent_id"], session_id, opts)
      end
    end
  end

  def list_project_knowledge_uses(agent_or_id, opts \\ []) do
    with {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" ->
          {:ok,
           %{
             "uses" => [],
             "complete" => true,
             "history_truncated" => false,
             "sessions_scanned" => 0
           }}

        _ ->
          InternalAgentRuntime.list_project_knowledge_uses(agent["agent_id"], opts)
      end
    end
  end

  def session_records(agent_or_id, session_id, opts \\ []) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" -> ExternalAgentRuntime.session_records(agent, session_id, opts)
        _ -> InternalAgentRuntime.session_records(agent["agent_id"], session_id, opts)
      end
    end
  end

  def session_billing_context(agent_id, session_id) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- Control.get_record(agent_id) do
      case Control.runtime_kind(agent) do
        "external" ->
          with {:ok, context} <- ExternalAgentRuntime.session_context(agent_id, session_id) do
            {:ok, context["billing_context"] || context[:billing_context] || %{}}
          end

        _ ->
          InternalAgentRuntime.session_billing_context(agent_id, session_id)
      end
    end
  end

  def get_async_tool_call(agent_id, session_id, tool_call_id) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- Control.get_record(agent_id) do
      case Control.runtime_kind(agent) do
        "external" ->
          ExternalAgentRuntime.get_async_tool_call(agent_id, session_id, tool_call_id)

        _ ->
          InternalAgentRuntime.get_async_tool_call(agent_id, session_id, tool_call_id)
      end
    end
  end

  @doc false
  def get_async_tool_setup_result(agent_id, session_id, tool_call_id)
      when is_binary(tool_call_id) and tool_call_id != "" do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- Control.get_record(agent_id),
         runtime_kind <- runtime_kind_atom(agent),
         operation_id <-
           WorkspaceEvents.operation_id(
             AsyncToolResults.operation_source(runtime_kind),
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

  @doc """
  Fork an internal runtime session.

  External runtime sessions are not forkable: their Codex thread, runtime
  capability, connector placement, and event stream are current-session runtime
  facts, not copyable transcript state.
  """
  def fork_session(agent_or_id, session_id, attrs) when is_map(attrs) do
    with :ok <- require_session_id(session_id) do
      route_internal(agent_or_id, fn agent ->
        InternalAgentRuntime.fork_session(agent["agent_id"], session_id, attrs)
      end)
    end
  end

  # Model and context-window occupancy are facts about the SALIX-MANAGED
  # session loop, which an external runtime does not have: it owns its own
  # transcript and provider config. So this routes internal-only and refuses
  # external with the shared explainable reason, rather than reading a store
  # that has no record for that agent and surfacing a raw storage error.
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

  def microcompact_session(agent_or_id, session_id) do
    with :ok <- require_session_id(session_id) do
      route_internal(agent_or_id, fn agent ->
        InternalAgentRuntime.microcompact_session(agent["agent_id"], session_id)
      end)
    end
  end

  def emergency_compact_session(agent_or_id, session_id) do
    with :ok <- require_session_id(session_id) do
      route_internal(agent_or_id, fn agent ->
        InternalAgentRuntime.emergency_compact_session(agent["agent_id"], session_id)
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
      case Control.runtime_kind(agent) do
        "external" ->
          ExternalAgentRuntime.execute_session_tool(
            agent["agent_id"],
            session_id,
            tool_name,
            attrs
          )

        _ ->
          InternalAgentRuntime.execute_session_tool(
            agent["agent_id"],
            session_id,
            tool_name,
            attrs
          )
      end
    end
  end

  def session_trace(agent_or_id, session_id, opts \\ []) do
    with :ok <- require_session_id(session_id),
         {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" -> ExternalAgentRuntime.session_trace(agent, session_id, opts)
        _ -> InternalAgentRuntime.session_trace(agent["agent_id"], session_id, opts)
      end
    end
  end

  def search_messages(agent_or_id, query, limit \\ 20) do
    with {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" -> ExternalAgentRuntime.search_messages(agent, query, limit)
        _ -> InternalAgentRuntime.search_messages(agent["agent_id"], query, limit)
      end
    end
  end

  defp route_internal(agent_or_id, fun) do
    with {:ok, agent} <- resolve_agent(agent_or_id) do
      case Control.runtime_kind(agent) do
        "external" -> @internal_runtime_only_error
        _ -> fun.(agent)
      end
    end
  end

  defp runtime_kind_atom(agent) do
    if Control.runtime_kind(agent) == "external", do: :external, else: :internal
  end

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
