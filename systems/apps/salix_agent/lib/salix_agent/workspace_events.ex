defmodule SalixAgent.WorkspaceEvents do
  @moduledoc """
  Splits tool side effects between agent workspace state and runtime session state.

  Tools may return `vfs_*` events together with session events such as `wait_set`.
  Workspace events must be committed through `SalixAgent.AgentWorkspace`; the
  runtime journal receives only session-local events.
  """

  alias SalixAgent.{AgentWorkspace, SkillStore}

  @spec commit_results(String.t(), String.t(), [map()], String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def commit_results(agent_id, session_id, results, source, opts \\ []) when is_list(results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case commit_result(agent_id, session_id, result, source, opts) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = err -> err
    end
  end

  @spec commit_result(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def commit_result(agent_id, session_id, result, source, opts \\ []) when is_map(result) do
    {workspace_events, skill_events, session_events} = split_events(result_events(result))

    if workspace_events == [] and skill_events == [] and
         not Keyword.get(opts, :store_result, false) do
      {:ok, put_result_events(result, session_events)}
    else
      with {:ok, tool_call_id} <- tool_call_id(result),
           operation_id <- operation_id(source, agent_id, session_id, tool_call_id),
           operation_result <- workspace_operation_result(result, tool_call_id, session_events),
           {:ok, committed_result} <-
             commit_storage_operations(
               agent_id,
               operation_id,
               operation_result,
               workspace_events,
               skill_events,
               opts
             ) do
        {:ok,
         result
         |> inherit_tool_result_projection(committed_result)
         |> put_result_events(session_events)}
      else
        {:error, _} = err ->
          err
      end
    end
  end

  @doc false
  @spec prepare_result_commit(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map(), SalixAgent.AgentWorkspace.PreparedOperation.t() | nil}
          | {:error, term()}
  def prepare_result_commit(agent_id, session_id, result, source, opts \\ [])
      when is_map(result) and is_list(opts) do
    {workspace_events, skill_events, session_events} = split_events(result_events(result))

    if Keyword.get(opts, :session_result, false) and workspace_events == [] and skill_events == [] do
      {:ok, put_result_events(result, session_events), nil}
    else
      prepare_stored_result_commit(agent_id, session_id, result, source, opts)
    end
  end

  defp prepare_stored_result_commit(agent_id, session_id, result, source, opts) do
    if Keyword.get(opts, :store_result, false) do
      {workspace_events, skill_events, session_events} = split_events(result_events(result))

      with {:ok, tool_call_id} <- tool_call_id(result),
           operation_id <- operation_id(source, agent_id, session_id, tool_call_id),
           operation_result <- workspace_operation_result(result, tool_call_id, session_events),
           {:ok, prepared} <-
             prepare_storage_result_commit(
               agent_id,
               session_id,
               operation_id,
               operation_result,
               workspace_events,
               skill_events,
               opts
             ) do
        case prepared do
          {:committed, committed_result} ->
            {:ok,
             result
             |> inherit_tool_result_projection(committed_result)
             |> put_result_events(session_events), nil}

          {:prepared, workspace_commit} ->
            {:ok,
             result
             |> inherit_tool_result_projection(operation_result)
             |> put_result_events(session_events), workspace_commit}
        end
      end
    else
      {:error, :stored_result_commit_required}
    end
  end

  @doc false
  @spec commit_prepared_result(
          String.t(),
          String.t(),
          SalixAgent.AgentWorkspace.PreparedOperation.t() | nil
        ) :: :ok | {:error, term()}
  def commit_prepared_result(_agent_id, _session_id, nil), do: :ok

  def commit_prepared_result(agent_id, session_id, %AgentWorkspace.PreparedOperation{} = prepared) do
    case SalixAgent.AgentActor.commit_prepared_workspace_operation_for_session(
           agent_id,
           session_id,
           prepared
         ) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec runtime_configuration_neutral_result?(map()) :: boolean()
  def runtime_configuration_neutral_result?(result) when is_map(result) do
    result
    |> result_events()
    |> Enum.all?(&(not SkillStore.skill_event?(&1)))
  end

  defp result_events(result), do: result[:events] || result["events"] || []

  defp split_events(events) do
    Enum.reduce(events, {[], [], []}, fn event, {workspace, skill, session} ->
      cond do
        AgentWorkspace.workspace_event?(event) -> {[event | workspace], skill, session}
        SkillStore.skill_event?(event) -> {workspace, [event | skill], session}
        true -> {workspace, skill, [event | session]}
      end
    end)
    |> then(fn {workspace, skill, session} ->
      {Enum.reverse(workspace), Enum.reverse(skill), Enum.reverse(session)}
    end)
  end

  defp put_result_events(result, events) do
    result
    |> Map.delete("events")
    |> Map.put(:events, events)
  end

  defp commit_skill_operation(_operation_id, result, [], _opts), do: {:ok, result}

  defp commit_skill_operation(operation_id, result, events, opts) do
    SkillStore.commit_operation(operation_id, result, events, opts)
  end

  defp prepare_storage_result_commit(
         agent_id,
         session_id,
         operation_id,
         result,
         workspace_events,
         skill_events,
         opts
       ) do
    cond do
      workspace_events == [] and skill_events == [] ->
        prepare_workspace_result(
          agent_id,
          session_id,
          operation_id,
          result,
          [],
          opts
        )

      workspace_events == [] ->
        with {:ok, _} <-
               commit_skill_operation(operation_id <> ":skill", result, skill_events, opts) do
          prepare_workspace_result(
            agent_id,
            session_id,
            operation_id,
            result,
            [],
            opts
          )
        end

      skill_events == [] ->
        prepare_workspace_result(
          agent_id,
          session_id,
          operation_id,
          result,
          workspace_events,
          opts
        )

      true ->
        with {:ok, _} <-
               commit_mixed_storage_operations(
                 agent_id,
                 operation_id,
                 result,
                 workspace_events,
                 skill_events,
                 opts
               ) do
          prepare_workspace_result(
            agent_id,
            session_id,
            operation_id,
            result,
            [],
            opts
          )
        end
    end
  end

  defp prepare_workspace_result(
         agent_id,
         session_id,
         operation_id,
         result,
         events,
         opts
       ) do
    SalixAgent.AgentActor.prepare_workspace_operation_for_session(
      agent_id,
      session_id,
      operation_id,
      result,
      events,
      opts
    )
  end

  defp commit_storage_operations(
         agent_id,
         operation_id,
         result,
         workspace_events,
         skill_events,
         opts
       ) do
    cond do
      Keyword.get(opts, :store_result, false) and workspace_events == [] and skill_events == [] ->
        SalixAgent.AgentActor.commit_workspace_operation(agent_id, operation_id, result, [], opts)

      Keyword.get(opts, :store_result, false) and workspace_events == [] ->
        with {:ok, _} <-
               commit_skill_operation(operation_id <> ":skill", result, skill_events, opts),
             {:ok, committed_result} <-
               SalixAgent.AgentActor.commit_workspace_operation(
                 agent_id,
                 operation_id,
                 result,
                 [],
                 opts
               ) do
          {:ok, committed_result}
        end

      Keyword.get(opts, :store_result, false) and skill_events == [] ->
        commit_workspace_operation(agent_id, operation_id, result, workspace_events, opts)

      Keyword.get(opts, :store_result, false) ->
        with {:ok, _} <-
               commit_mixed_storage_operations(
                 agent_id,
                 operation_id,
                 result,
                 workspace_events,
                 skill_events,
                 opts
               ),
             {:ok, committed_result} <-
               SalixAgent.AgentActor.commit_workspace_operation(
                 agent_id,
                 operation_id,
                 result,
                 [],
                 opts
               ) do
          {:ok, committed_result}
        end

      workspace_events != [] and skill_events != [] ->
        commit_mixed_storage_operations(
          agent_id,
          operation_id,
          result,
          workspace_events,
          skill_events,
          opts
        )

      true ->
        with {:ok, _} <-
               commit_workspace_operation(agent_id, operation_id, result, workspace_events, opts),
             {:ok, _} <- commit_skill_operation(operation_id, result, skill_events, opts) do
          {:ok, result}
        end
    end
  end

  defp commit_mixed_storage_operations(
         agent_id,
         operation_id,
         result,
         workspace_events,
         skill_events,
         opts
       ) do
    {workspace_delete_events, workspace_write_events} =
      Enum.split_with(workspace_events, &delete_event?/1)

    {skill_delete_events, skill_write_events} = Enum.split_with(skill_events, &delete_event?/1)

    with {:ok, _} <-
           commit_workspace_operation(
             agent_id,
             operation_id <> ":workspace-write",
             result,
             workspace_write_events,
             opts
           ),
         {:ok, _} <-
           commit_skill_operation(
             operation_id <> ":skill-write",
             result,
             skill_write_events,
             opts
           ),
         {:ok, _} <-
           commit_workspace_operation(
             agent_id,
             operation_id <> ":workspace-delete",
             result,
             workspace_delete_events,
             opts
           ),
         {:ok, _} <-
           commit_skill_operation(
             operation_id <> ":skill-delete",
             result,
             skill_delete_events,
             opts
           ) do
      {:ok, result}
    end
  end

  defp commit_workspace_operation(_agent_id, _operation_id, result, [], _opts), do: {:ok, result}

  defp commit_workspace_operation(agent_id, operation_id, result, events, opts) do
    SalixAgent.AgentActor.commit_workspace_operation(agent_id, operation_id, result, events, opts)
  end

  defp delete_event?(event) when is_map(event) do
    (event["type"] || event[:type]) in ["vfs_delete", "skill_file_delete"]
  end

  defp delete_event?(_event), do: false

  @spec operation_id(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def operation_id(source, agent_id, session_id, tool_call_id),
    do: source <> ":" <> agent_id <> ":" <> session_id <> ":" <> tool_call_id

  @spec restore_operation_result(map()) :: map()
  def restore_operation_result(result) when is_map(result) do
    events = result["session_events"] || result[:session_events] || []

    result
    |> Map.drop(["session_events", :session_events])
    |> Map.put("events", events)
  end

  defp tool_call_id(result) do
    case result[:id] || result["id"] || result[:tool_call_id] || result["tool_call_id"] do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_binary(value) -> {:error, :missing_tool_call_id}
      value when not is_nil(value) -> {:ok, to_string(value)}
      _ -> {:error, :missing_tool_call_id}
    end
  end

  defp workspace_operation_result(result, tool_call_id, session_events) do
    %{
      "tool_call_id" => tool_call_id,
      "tool_name" => result[:name] || result["name"],
      "status" => result[:status] || result["status"],
      "content" => result[:content] || result["content"],
      "error" => result[:error] || result["error"] || false,
      "error_class" => result[:error_class] || result["error_class"],
      "error_message" => result[:error_message] || result["error_message"],
      "diagnostic_visibility" =>
        result[:diagnostic_visibility] || result["diagnostic_visibility"],
      "public_summary" => result[:public_summary] || result["public_summary"],
      "repair_outcome" => result[:repair_outcome] || result["repair_outcome"],
      "visible_reply_origin" => result[:visible_reply_origin] || result["visible_reply_origin"],
      "duration_ms" => result[:duration_ms] || result["duration_ms"],
      "_tool_result_projection" =>
        result[:_tool_result_projection] || result["_tool_result_projection"],
      "session_events" => session_events
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # A zero-wait terminal may stage successfully and then lose its session CAS.
  # The idempotent workspace operation is the recovery authority for the
  # opaque ref/timestamp chosen on that first attempt; copy only that private
  # projection identity back onto the live result used to retry the session
  # batch. Ordinary tool results are unchanged.
  defp inherit_tool_result_projection(result, committed_result)
       when is_map(result) and is_map(committed_result) do
    case committed_result["_tool_result_projection"] ||
           committed_result[:_tool_result_projection] do
      %{} = projection -> Map.put(result, "_tool_result_projection", projection)
      _ -> result
    end
  end

  defp inherit_tool_result_projection(result, _committed_result), do: result
end
