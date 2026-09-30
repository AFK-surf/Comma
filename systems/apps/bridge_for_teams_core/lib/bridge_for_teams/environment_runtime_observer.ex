defmodule BridgeForTeams.EnvironmentRuntimeObserver do
  @moduledoc """
  Asynchronous agent runtime Operations event producer.

  Device listing is a product read path and must not wait on Salix agent
  projection. This actor keeps the agent-runtime health projection separate:
  callers enqueue the latest device runtime record, and the actor resolves the
  current Salix agent bindings with a bounded projection before writing
  `agent.runtime.*` Operations events.
  """
  use GenServer

  require Logger

  alias BridgeForTeams.{Agents, Observability}
  alias BridgeForTeams.Schema.{Agent, Project}
  alias SalixStore.RuntimeIds

  @agent_runtime_event_types ~w(agent.runtime.observed agent.runtime.degraded agent.runtime.recovered)
  @max_concurrent_observations 4
  @pending_table Module.concat(__MODULE__, Pending)
  @wake_key {:__bridge_for_teams_environment_runtime_observer__, :wake}

  @doc "Start the asynchronous runtime observer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Queue agent-runtime observation for one Salix device connector record."
  @spec observe_agent_runtime(Project.t(), map(), String.t()) :: :ok | :ignored
  def observe_agent_runtime(%Project{} = project, record, source \\ "salix.env")
      when is_map(record) and is_binary(source) do
    record = normalize(record)
    runtimes = agent_runtime_records(record)

    cond do
      runtimes == [] ->
        :ok

      true ->
        record = observation_record(record, runtimes)

        case observer_target() do
          {:ok, pid} ->
            key = observation_key(project, record)
            :ets.insert(@pending_table, {key, {observation_project(project), record, source}})

            # The ETS table is the coalescing queue. Repeated product reads for
            # the same connector overwrite the pending value in place; the wake
            # key ensures those reads still produce at most one GenServer cast
            # until the observer drains the table.
            if :ets.insert_new(@pending_table, {@wake_key, true}) do
              GenServer.cast(pid, :drain_pending)
            end

            :ok

          :error ->
            Logger.warning(
              "environment_runtime_observer_not_running project_id=#{project.id} connector_run_id=#{environment_connector_run_id(record)}"
            )

            :ignored
        end
    end
  end

  @doc "Wait until currently queued observation work has finished."
  @spec drain(timeout()) :: :ok | {:error, :not_running}
  def drain(timeout \\ 5_000) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :drain, timeout)
    end
  end

  @impl true
  def init(opts) do
    _table = ensure_pending_table()

    {:ok,
     %{
       pending: %{},
       running: %{},
       waiters: [],
       max_concurrent: Keyword.get(opts, :max_concurrent, @max_concurrent_observations)
     }}
  end

  @impl true
  def handle_cast(:drain_pending, state) do
    state =
      state
      |> load_external_pending()
      |> start_pending_observations()

    {:noreply, state}
  end

  @impl true
  def handle_call(:drain, from, state) do
    state =
      state
      |> load_external_pending()
      |> start_pending_observations()

    if idle?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {key, running} = Map.pop(state.running, ref)

    if reason not in [:normal, :shutdown] do
      Logger.warning(
        "environment_runtime_observer_worker_failed reason=#{inspect(reason)} key=#{inspect(key)}"
      )
    end

    state =
      %{state | running: running}
      |> load_external_pending()
      |> start_pending_observations()
      |> reply_waiters_if_idle()

    {:noreply, state}
  end

  defp observer_target do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         table when table != :undefined <- :ets.whereis(@pending_table) do
      {:ok, pid}
    else
      _other -> :error
    end
  end

  defp ensure_pending_table do
    case :ets.whereis(@pending_table) do
      :undefined ->
        :ets.new(@pending_table, [
          :named_table,
          :public,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      table ->
        table
    end
  end

  defp load_external_pending(state) do
    # Deleting the wake key before reading lets new writes schedule the next
    # drain while this drain is moving the current latest values into actor
    # state. If a new value arrives for a key we already took, it stays in ETS
    # for the next wake; if it arrives before the take, the take observes the
    # newer value.
    :ets.delete(@pending_table, @wake_key)

    @pending_table
    |> :ets.tab2list()
    |> Enum.reduce(state, fn
      {@wake_key, _value}, acc ->
        acc

      {key, _value}, acc ->
        case :ets.take(@pending_table, key) do
          [{^key, payload}] -> put_in(acc, [:pending, key], payload)
          _other -> acc
        end
    end)
  end

  defp start_pending_observations(
         %{pending: pending, running: running, max_concurrent: max_concurrent} = state
       ) do
    available = max(max_concurrent - map_size(running), 0)
    running_keys = MapSet.new(Map.values(running))

    pending
    |> Enum.reject(fn {key, _payload} -> MapSet.member?(running_keys, key) end)
    |> Enum.take(available)
    |> Enum.reduce(state, fn {key, payload}, acc -> start_observation(acc, key, payload) end)
  end

  defp start_observation(state, key, {project, record, source}) do
    pending = Map.delete(state.pending, key)

    {_pid, ref} =
      spawn_monitor(fn ->
        safe_observe_agent_runtime_records(project, record, source, key)
      end)

    %{state | pending: pending, running: Map.put(state.running, ref, key)}
  end

  defp idle?(state), do: map_size(state.pending) == 0 and map_size(state.running) == 0

  defp reply_waiters_if_idle(%{waiters: waiters} = state) do
    if idle?(state) do
      Enum.each(waiters, &GenServer.reply(&1, :ok))
      %{state | waiters: []}
    else
      state
    end
  end

  defp observation_key(%Project{} = project, record) do
    {project.id, environment_connector_run_id(record)}
  end

  defp observation_project(%Project{} = project) do
    %Project{
      id: project.id,
      name: project.name,
      slug: project.slug,
      status: project.status,
      org_id: project.org_id,
      salix_group_id: project.salix_group_id
    }
  end

  defp safe_observe_agent_runtime_records(project, record, source, key) do
    try do
      observe_agent_runtime_records(project, record, source)
    rescue
      exception ->
        Logger.warning(
          "agent_runtime_observability_failed reason=#{Exception.message(exception)} key=#{inspect(key)}"
        )

        {:error, {:exception, exception}}
    catch
      :exit, reason ->
        Logger.warning(
          "agent_runtime_observability_failed reason=#{inspect({:exit, reason})} key=#{inspect(key)}"
        )

        {:error, {:exit, reason}}

      kind, reason ->
        Logger.warning(
          "agent_runtime_observability_failed reason=#{inspect({kind, reason})} key=#{inspect(key)}"
        )

        {:error, {kind, reason}}
    end
  end

  defp observe_agent_runtime_records(%Project{} = project, record, source) do
    runtimes = agent_runtime_records(record)

    case runtimes do
      [] ->
        :unchanged

      [_ | _] ->
        with {:ok, %{items: active_agents, next_cursor: nil}} <-
               Agents.page_agents(project, limit: 500) do
          Enum.reduce(runtimes, :unchanged, fn runtime, acc ->
            case observe_agent_runtime_record(
                   project,
                   record,
                   runtime,
                   source,
                   active_agents
                 ) do
              :changed -> :changed
              _other -> acc
            end
          end)
        else
          result ->
            reason =
              case result do
                {:error, reason} -> reason
                {:ok, _} -> :agent_page_required
              end

            Logger.warning(
              "agent_runtime_observability_salix_lookup_failed reason=#{inspect(reason)} project_id=#{project.id} runtime_ids=#{inspect(Enum.map(runtimes, &device_runtime_id/1))}"
            )

            :unchanged
        end
    end
  end

  defp agent_runtime_records(record) do
    case record["device_runtimes"] do
      runtimes when is_list(runtimes) ->
        runtimes
        |> Enum.filter(&is_map/1)
        |> Enum.map(&normalize/1)
        |> Enum.filter(fn runtime ->
          RuntimeIds.external_runtime_provider?(runtime_value(runtime, "provider")) and
            nonblank(device_runtime_id(runtime), "") != ""
        end)

      _other ->
        []
    end
  end

  defp observe_agent_runtime_record(
         %Project{} = project,
         record,
         runtime,
         source,
         active_agents
       ) do
    runtime_id = device_runtime_id(runtime)
    status = agent_runtime_status(runtime)

    active_agents
    |> agents_for_runtime(runtime_id)
    |> Enum.reduce(:unchanged, fn agent, acc ->
      latest = latest_agent_runtime_event(project.org_id, agent.id)

      if latest && latest.status == status do
        acc
      else
        attrs = agent_runtime_event_attrs(project, agent, record, runtime, latest, source)

        case Observability.create_event(attrs) do
          {:ok, _event} ->
            :changed

          {:error, reason} ->
            Logger.warning(
              "agent_runtime_observability_failed reason=#{inspect(reason)} agent_id=#{agent.id} runtime_id=#{runtime_id}"
            )

            acc
        end
      end
    end)
  end

  defp agents_for_runtime(active_agents, runtime_id) do
    Enum.filter(active_agents, fn agent ->
      config =
        agent.salix["runtime_config"]
        |> normalize_runtime_config()

      runtime_value(config, "kind") in ["external", "connected_runtime"] and
        RuntimeIds.external_runtime_provider?(runtime_value(config, "provider")) and
        runtime_value(config, "device_runtime_id") == runtime_id
    end)
  end

  defp latest_agent_runtime_event(org_id, agent_id) do
    org_id
    |> Observability.list_events(
      domain: "agent",
      resource_type: "agent",
      resource_id: agent_id,
      source: "salix.env",
      limit: 20
    )
    |> Enum.find(&(&1.event_type in @agent_runtime_event_types))
  end

  defp agent_runtime_event_attrs(project, agent, record, runtime, latest, source) do
    status = agent_runtime_status(runtime)

    %{
      org_id: project.org_id,
      project_id: project.id,
      domain: "agent",
      resource_type: "agent",
      resource_id: agent.id,
      resource_label: agent.salix["name"] || agent.role || agent.salix_agent_id,
      source: source,
      event_type: agent_runtime_event_type(status, latest),
      severity: agent_runtime_severity(status),
      status: status,
      reason_class: agent_runtime_reason(status, latest),
      summary: agent_runtime_summary(agent, runtime, latest),
      evidence: agent_runtime_evidence(project, agent, record, runtime, latest),
      correlation_id: agent_runtime_correlation_id(agent, record, runtime),
      occurred_at: agent_runtime_occurred_at(record, runtime)
    }
    |> compact_attrs()
  end

  defp agent_runtime_event_type("ready", nil), do: "agent.runtime.observed"
  defp agent_runtime_event_type("ready", _latest), do: "agent.runtime.recovered"
  defp agent_runtime_event_type(_status, _latest), do: "agent.runtime.degraded"

  defp agent_runtime_severity("ready"), do: "info"
  defp agent_runtime_severity(status) when status in ~w(failed error critical), do: "error"
  defp agent_runtime_severity(_status), do: "warning"

  defp agent_runtime_reason("ready", nil), do: nil
  defp agent_runtime_reason("ready", _latest), do: "agent_runtime.recovered"
  defp agent_runtime_reason(status, _latest), do: "agent_runtime.#{status}"

  defp agent_runtime_summary(agent, runtime, latest) do
    label = agent.salix["name"] || agent.role || agent.salix_agent_id || "Agent"
    status = agent_runtime_status(runtime)

    case {status, latest && latest.status} do
      {"ready", nil} ->
        "Agent #{label} runtime observed as ready"

      {"ready", previous} ->
        "Agent #{label} runtime recovered from #{previous || "unknown"}"

      {status, previous} when is_binary(previous) ->
        "Agent #{label} runtime changed from #{previous} to #{status}"

      {status, _previous} ->
        "Agent #{label} runtime observed as #{status}"
    end
  end

  defp agent_runtime_evidence(%Project{} = project, %Agent{} = agent, record, runtime, latest) do
    %{
      project_id: project.id,
      project_slug: project.slug,
      agent_id: agent.id,
      salix_agent_id: agent.salix_agent_id,
      connector_run_id: environment_connector_run_id(record),
      device_id: record["device_id"],
      connector_id: record["connector_id"],
      device_name: record["name"],
      runtime_id: runtime_value(runtime, "runtime_id"),
      device_runtime_id: device_runtime_id(runtime),
      runtime_status: runtime_value(runtime, "status"),
      status: agent_runtime_status(runtime),
      previous_status: latest && latest.status,
      issue: runtime_value(runtime, "issue"),
      version: runtime_value(runtime, "version"),
      readiness_checked_at: runtime_value(runtime, "readiness_checked_at"),
      readiness_valid_until: runtime_value(runtime, "readiness_valid_until")
    }
    |> compact_attrs()
  end

  defp agent_runtime_correlation_id(%Agent{} = agent, record, runtime) do
    [
      "agent-runtime",
      agent.id,
      device_runtime_id(runtime),
      agent_runtime_status(runtime),
      runtime_value(runtime, "updated_at") ||
        runtime_value(runtime, "readiness_checked_at") ||
        record["updated_at"] ||
        record["disconnected_at"] ||
        "unknown"
    ]
    |> Enum.join(":")
  end

  defp agent_runtime_occurred_at(record, runtime) do
    case runtime_value(runtime, "updated_at") || runtime_value(runtime, "readiness_checked_at") do
      timestamp when not is_nil(timestamp) -> timestamp_to_datetime(timestamp)
      _ -> environment_runtime_occurred_at(record)
    end
  end

  defp agent_runtime_status(runtime) do
    nonblank(runtime_value(runtime, "status"), "unknown")
  end

  defp device_runtime_id(runtime), do: runtime_value(runtime, "device_runtime_id") || ""

  defp runtime_value(runtime, key) when is_map(runtime) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(runtime, key) -> Map.get(runtime, key)
      Map.has_key?(runtime, atom_key) -> Map.get(runtime, atom_key)
      true -> nil
    end
  rescue
    ArgumentError -> Map.get(runtime, key)
  end

  defp normalize_runtime_config(config) when is_map(config), do: normalize(config)
  defp normalize_runtime_config(_config), do: %{}

  defp observation_record(record, runtimes) do
    record
    |> Map.take(
      ~w(connector_run_id device_id connector_id name updated_at disconnected_at registered_at)
    )
    |> Map.put("device_runtimes", runtimes)
  end

  defp environment_connector_run_id(record), do: nonblank(record["connector_run_id"], "")

  defp environment_runtime_occurred_at(record) do
    case record["updated_at"] || record["disconnected_at"] || record["registered_at"] do
      timestamp when not is_nil(timestamp) -> timestamp_to_datetime(timestamp)
      _ -> DateTime.utc_now()
    end
  end

  defp timestamp_to_datetime(timestamp) when is_integer(timestamp) do
    if timestamp > 9_999_999_999 do
      DateTime.from_unix!(timestamp, :millisecond)
    else
      DateTime.from_unix!(timestamp, :second)
    end
  end

  defp timestamp_to_datetime(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {integer, ""} ->
        timestamp_to_datetime(integer)

      _ ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, datetime, _offset} -> datetime
          _ -> DateTime.utc_now()
        end
    end
  end

  defp timestamp_to_datetime(_timestamp), do: DateTime.utc_now()

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp nonblank(value, _default) when is_binary(value) and value != "", do: value
  defp nonblank(_value, default), do: default

  defp compact_attrs(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
