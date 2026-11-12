defmodule SalixWeb.StationHostedTasks do
  @moduledoc """
  `SalixIM.Ports.StationHostedTasks`: the Router reads a Task a station hosts
  and writes in it, through the station's Connector (`task.read`,
  `task.say`). The Task is found in the Group's Task index
  (`SalixStore.StationTaskIndex`), which says which Device runs the station;
  only that Device's connected run is asked. A write names its Group
  (`requester_name`), for a station several Groups write in.

  What a station says of its own Task carries no information-flow label, so
  the IFC check reads it as an unlabelled read (agent-private), and a write
  into it is decided like any write into a Conversation whose audience Salix
  does not know (`SalixAgent.IFC.Check`).
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
      %{
        "task" => task,
        "text" => text,
        "key" => key,
        "requester" => requester,
        "requester_name" => requester_name(scope, requester)
      }
    end)
  end

  # Who writes, as people see it where several Groups write in one place (a
  # still.fail workspace connected to several Comma workspaces and Agent
  # Swarms): the Group, by its name; the Router's own name when it has none.
  defp requester_name(scope, requester) do
    case Salix.Control.Groups.get(scope.group_id) do
      {:ok, %{"name" => name}} when is_binary(name) and name != "" -> name
      _ -> requester
    end
  end

  defp ask(scope, station_id, thread, method, params) do
    with %StationTaskIndex.Row{} = row <-
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
