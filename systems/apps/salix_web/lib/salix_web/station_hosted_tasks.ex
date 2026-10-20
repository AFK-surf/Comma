defmodule SalixWeb.StationHostedTasks do
  @moduledoc """
  `SalixIM.Ports.StationHostedTasks`: the Router reads a Task a station hosts
  and writes in it, through the station's Connector (`task.read`,
  `task.say`). The Task is found in the Group's Task index
  (`SalixStore.StationTaskIndex`), which says which Device runs the station;
  only that Device's connected run is asked.

  What a station says of its own Task carries no information-flow label:
  in a Group whose IFC mode is `enforce` (`SalixAgent.IFC.mode_for/2`), the
  Router neither reads nor writes in such a Task (`:ifc_enforced`).
  """
  @behaviour SalixIM.Ports.StationHostedTasks

  alias SalixStore.StationTaskIndex

  @timeout_ms 15_000
  @read_limit 100

  @impl true
  def read(scope, station_id, thread, opts) do
    after_seq = non_negative(opts["after"]) || 0
    limit = min(non_negative(opts["limit"]) || @read_limit, @read_limit)

    ask(scope, station_id, thread, "task.read", fn task ->
      %{"task" => task, "after" => after_seq, "limit" => limit}
    end)
  end

  @impl true
  def say(scope, station_id, thread, text, key, requester) do
    ask(scope, station_id, thread, "task.say", fn task ->
      %{"task" => task, "text" => text, "key" => key, "requester" => requester}
    end)
  end

  defp ask(scope, station_id, thread, method, params) do
    with true <-
           SalixAgent.IFC.mode_for(scope.tenant_id, scope.group_id) != :enforce ||
             {:error, :ifc_enforced},
         %StationTaskIndex.Row{} = row <-
           StationTaskIndex.get(scope.group_id, station_id, thread) || {:error, :not_found},
         run_id when is_binary(run_id) <-
           online_run(scope.tenant_id, scope.group_id, row.device_id) || {:error, :device_offline} do
      case connector().request(run_id, method, params.(row.task), timeout: @timeout_ms) do
        {:ok, %{} = answer} -> {:ok, answer}
        {:ok, _answer} -> {:error, {:station_refused, "the station answered nothing"}}
        {:error, :disconnected} -> {:error, :device_offline}
        {:error, reason} -> {:error, {:station_refused, reason(reason)}}
      end
    end
  end

  defp online_run(tenant, group, device) do
    case SalixEnv.Registry.get_device(tenant, group, device) do
      {:ok, %{"status" => "connected", "connector_run_id" => run_id}}
      when is_binary(run_id) and run_id != "" ->
        run_id

      _ ->
        nil
    end
  end

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: nil

  defp reason(reason) when is_binary(reason), do: reason
  defp reason(reason), do: inspect(reason)

  defp connector,
    do:
      SystemsRuntime.get_env(:salix_web, :station_tasks, [])[:connector] ||
        SalixEnv.Connector.Live
end
