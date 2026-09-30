defmodule SalixAgent.ExternalAgentRuntime do
  @moduledoc """
  Public external runtime facade.

  This module is the runtime-facing boundary. It validates agent/runtime facts
  and routes mutating work to the target external session owner. Low-level
  persistence lives in `SalixAgent.ExternalSessionStore` and should only be
  called from the matching `ExternalSessionActor` owner path.
  """

  alias SalixAgent.{
    AgentActor,
    AgentControl,
    ExternalSessionStore,
    SessionWorkRecovery
  }

  @connector_event_owner_concurrency 8
  # Keep settlement below the Connector's minimum five-second request budget.
  @connector_event_owner_timeout_ms 4_500
  @connector_event_task_timeout_ms 4_750

  def stage_delivery(agent_id, delivery) when is_map(delivery) do
    with :ok <- AgentControl.ensure_not_stopped(agent_id) do
      case AgentControl.get_record(agent_id) do
        {:ok, agent} ->
          if AgentControl.external_runtime?(agent) do
            with {:ok, session_id} <- delivery_session_id(delivery) do
              case AgentActor.stage_external_delivery(agent_id, session_id, delivery) do
                # The store's birth authority answered "this id was born
                # internally" (#873 round 8): same facade contract as an
                # internal agent record — the caller delivers internally.
                # This ingress can never fabricate an external session for
                # an internally-born id.
                {:error, :external_runtime_declined_delivery} -> {:ok, :internal}
                other -> other
              end
            end
          else
            {:ok, :internal}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  def session_context(agent_id, session_id) do
    case AgentControl.get_record(agent_id) do
      {:ok, agent} ->
        if AgentControl.external_runtime?(agent),
          do: ExternalSessionStore.session_context(agent_id, session_id),
          else: {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  def begin_session(agent_id, session_id, tenant_id, runtime) when is_map(runtime) do
    with :ok <- ensure_external_runtime(agent_id) do
      AgentActor.begin_external_session(agent_id, session_id, tenant_id, runtime)
    end
  end

  def list_sessions(agent_id), do: ExternalSessionStore.list_sessions(agent_id)

  def get_session(agent_id, session_id),
    do: ExternalSessionStore.get_session(agent_id, session_id)

  def get_async_tool_call(agent_id, session_id, tool_call_id)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id),
      do: ExternalSessionStore.get_async_tool_call(agent_id, session_id, tool_call_id)

  def commit_session_events(agent_id, session_id, events)
      when is_binary(agent_id) and is_binary(session_id) and is_list(events) do
    with :ok <- ensure_external_runtime(agent_id) do
      AgentActor.commit_external_session_events(agent_id, session_id, events)
    end
  end

  def list_session_summaries(agent), do: ExternalSessionStore.list_session_summaries(agent)

  def get_session_summary(agent, session_id),
    do: ExternalSessionStore.get_session_summary(agent, session_id)

  def get_session_activity(agent, session_id),
    do: ExternalSessionStore.get_session_activity(agent, session_id)

  def get_session_status(agent, session_id),
    do: ExternalSessionStore.get_session_status(agent, session_id)

  def get_session_messages(agent, session_id),
    do: ExternalSessionStore.get_session_messages(agent, session_id)

  def session_records(agent, session_id, opts \\ []),
    do: ExternalSessionStore.session_records(agent, session_id, opts)

  def session_trace(agent, session_id, opts \\ []),
    do: ExternalSessionStore.session_trace(agent, session_id, opts)

  def search_messages(agent, query, limit \\ 20),
    do: ExternalSessionStore.search_messages(agent, query, limit)

  def update_session(agent_id, session_id, attrs) when is_map(attrs) do
    with :ok <- ensure_external_runtime(agent_id) do
      AgentActor.update_external_session(agent_id, session_id, attrs)
    end
  end

  def accept_session(agent_id, session_id, attrs) when is_map(attrs) do
    with :ok <- ensure_external_runtime(agent_id) do
      AgentActor.accept_external_session(agent_id, session_id, attrs)
    end
  end

  def complete_session(agent_id, session_id, attrs \\ %{}) when is_map(attrs) do
    with :ok <- ensure_external_runtime(agent_id) do
      AgentActor.complete_external_session(agent_id, session_id, attrs)
    end
  end

  def fail_session(agent_id, session_id, reason, attrs \\ %{}) when is_map(attrs) do
    with :ok <- ensure_external_runtime(agent_id) do
      AgentActor.fail_external_session(agent_id, session_id, reason, attrs)
    end
  end

  def append_event(agent_id, session_id, attrs) when is_map(attrs) do
    with :ok <- ensure_external_runtime(agent_id) do
      AgentActor.append_external_event(agent_id, session_id, attrs)
    end
  end

  def validate_runtime_capability(raw_token),
    do: ExternalSessionStore.validate_runtime_capability(raw_token)

  def mint_llm_capability(agent, session_id, connector_run_id),
    do: ExternalSessionStore.mint_llm_capability(agent, session_id, connector_run_id)

  def revoke_runtime_capability_by_hash(token_hash),
    do: ExternalSessionStore.revoke_runtime_capability_by_hash(token_hash)

  def runtime_capability_tools(capability),
    do: ExternalSessionStore.runtime_capability_tools(capability)

  def execute_runtime_capability_tool(capability, tool_name, attrs) when is_map(attrs),
    do: ExternalSessionStore.execute_runtime_capability_tool(capability, tool_name, attrs)

  def execute_session_tool(agent_id, session_id, tool_name, attrs) when is_map(attrs) do
    SalixAgent.execute_session_tool(agent_id, session_id, tool_name, attrs)
  end

  def handle_connector_event(connector_run_id, params, meta \\ %{})

  def handle_connector_event(connector_run_id, params, meta) when is_map(params) do
    with {:ok, capability, params} <- validate_connector_event(connector_run_id, params, meta) do
      SalixAgent.AgentActor.commit_connector_event(capability, params)
    end
  end

  def handle_connector_event(_connector_run_id, _params, _meta),
    do: {:error, {:bad_request, "invalid external runtime event"}}

  # Modeled in tla/salix/ExternalRuntimeEventBatch.tla and
  # ExternalRuntimeEventSessionPartitions.tla: mixed transport batches become
  # ordered exact-Session slices whose owner calls are independently scheduled.
  def handle_connector_events(connector_run_id, params_list, meta \\ %{})

  def handle_connector_events(connector_run_id, params_list, meta)
      when is_list(params_list) and is_map(meta) do
    validated =
      ExternalSessionStore.validate_connector_events(connector_run_id, params_list, meta)

    {results, groups} =
      validated
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn
        {{:ok, capability, params}, index}, {results, groups} ->
          key = {capability["agent_id"], capability["session_id"], capability["token_hash"]}
          entry = {index, capability, params}
          {results, Map.update(groups, key, [entry], &[entry | &1])}

        {{:error, _} = error, index}, {results, groups} ->
          {Map.put(results, index, error), groups}
      end)

    groups =
      groups
      |> Enum.sort_by(fn {_key, entries} -> entries |> List.last() |> elem(0) end)

    context = SystemsObservability.Context.capture()

    group_outcomes =
      Task.async_stream(
        groups,
        fn {_key, reversed} ->
          SystemsObservability.Context.run(context, fn ->
            entries = Enum.reverse(reversed)
            {_index, capability, _params} = hd(entries)
            payload = Enum.map(entries, &elem(&1, 2))

            commit_connector_event_group(capability, payload)
          end)
        end,
        max_concurrency: @connector_event_owner_concurrency,
        ordered: true,
        timeout: @connector_event_task_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    results =
      Enum.zip(groups, group_outcomes)
      |> Enum.reduce(results, fn {{_key, reversed}, outcome}, results ->
        entries = Enum.reverse(reversed)

        group_results =
          case outcome do
            {:ok, {:ok, %{"results" => group_results}}}
            when is_list(group_results) and length(group_results) == length(entries) ->
              group_results

            {:ok, {:ok, _invalid}} ->
              List.duplicate({:error, :invalid_external_runtime_event_response}, length(entries))

            {:ok, {:error, _} = error} ->
              List.duplicate(error, length(entries))

            {:exit, _reason} ->
              List.duplicate({:error, :external_runtime_event_owner_unavailable}, length(entries))
          end

        Enum.zip(entries, group_results)
        |> Enum.reduce(results, fn {{index, _capability, _params}, result}, acc ->
          Map.put(acc, index, result)
        end)
      end)

    params_list
    |> Enum.with_index()
    |> Enum.map(fn {_params, index} -> Map.fetch!(results, index) end)
  end

  def handle_connector_events(_connector_run_id, _params_list, _meta),
    do: [{:error, {:bad_request, "invalid external runtime event batch"}}]

  defp commit_connector_event_group(capability, payload) do
    AgentActor.commit_connector_event(
      capability,
      %{connector_event_batch: payload},
      timeout: @connector_event_owner_timeout_ms
    )
  rescue
    _error -> {:error, :external_runtime_event_owner_unavailable}
  catch
    _kind, _reason -> {:error, :external_runtime_event_owner_unavailable}
  end

  def validate_connector_event(connector_run_id, params, meta \\ %{}),
    do: ExternalSessionStore.validate_connector_event(connector_run_id, params, meta)

  def validate_runtime_capability_scope(capability, connector_run_id, meta \\ %{}),
    do:
      ExternalSessionStore.validate_runtime_capability_scope(
        capability,
        connector_run_id,
        meta
      )

  def catch_up_inputs(group_id, device_id),
    do: SessionWorkRecovery.catch_up_external_inputs(group_id, device_id)

  def commit_connector_event(
        %{"agent_id" => agent_id, "session_id" => session_id} = capability,
        params
      )
      when is_binary(agent_id) and is_binary(session_id) and is_map(params) do
    with :ok <- ensure_external_runtime(agent_id) do
      AgentActor.commit_connector_event(capability, params)
    end
  end

  def commit_connector_event(_capability, _params),
    do: {:error, {:bad_request, "invalid external runtime event"}}

  defp ensure_external_runtime(agent_id) do
    with :ok <- AgentControl.ensure_not_stopped(agent_id),
         {:ok, agent} <- AgentControl.get_record(agent_id) do
      if AgentControl.external_runtime?(agent) do
        :ok
      else
        {:error, {:bad_request, "operation is only available for external runtime agents"}}
      end
    end
  end

  defp delivery_session_id(%{payload: payload}), do: delivery_session_id(payload)
  defp delivery_session_id(%{"payload" => payload}), do: delivery_session_id(payload)

  defp delivery_session_id(payload) when is_map(payload) do
    case trim(payload["session_id"] || payload[:session_id]) do
      "" -> {:error, :missing_session_id}
      session_id -> {:ok, session_id}
    end
  end

  defp delivery_session_id(_payload), do: {:error, :missing_session_id}

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
