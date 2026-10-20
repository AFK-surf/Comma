defmodule SalixAgent.Migrations.SlackTaskBindings do
  @moduledoc """
  The Salix half of BridgeForTeams migration
  `20261019160001_bind_worker_slack_connections_to_tasks`
  (`BridgeForTeams.Migrations.SlackTaskBindings`): a Slack connection of the
  Group that delivers to a Worker binds to Tasks instead (`inbound_tasks` on
  the connection record), so each new thread becomes a Task of the Group's
  Task agent (`SalixAgent.TaskAgent`), which Salix resolves when an event
  arrives. Those Tasks run the Worker's model when it is a catalog choice or
  the platform model; a Worker without one gives none, and the Tasks run the
  default Task model. No Agent is made or changed here.

  A thread bound to the Worker before stays bound to it, so its Task finishes
  there. A connection bound to the Router, already bound to Tasks, deleted, or
  of a Worker that is gone is left as it is, so a pass run again changes
  nothing. It lists at most 1,000 connection records of the Group; a Group
  with more is refused.
  """

  alias SalixAgent.Control
  alias SalixStore.{CasRecord, Keys, S3}

  @max_connects 1_000

  @doc "Bind the Group's Worker-bound Slack connections to Tasks; answers how many."
  @spec bind(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def bind(tenant_id, group_id) do
    with {:ok, keys} <- connect_keys(group_id) do
      Enum.reduce_while(keys, {:ok, 0}, fn key, {:ok, count} ->
        case bind_key(tenant_id, group_id, key) do
          {:ok, :bound} -> {:cont, {:ok, count + 1}}
          {:ok, :kept} -> {:cont, {:ok, count}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp connect_keys(group_id) do
    case S3.list(Keys.ctl_im_connects_prefix(group_id), max_keys: @max_connects) do
      {:ok, %{objects: objects, next: nil}} -> {:ok, Enum.map(objects, & &1.key)}
      {:ok, _more} -> {:error, :too_many_connects}
      error -> error
    end
  end

  defp bind_key(tenant_id, group_id, key) do
    with {:ok, rec} <- CasRecord.get(key),
         true <- bindable?(rec, tenant_id, group_id),
         {:ok, %{"role" => "worker", "group_id" => ^group_id} = worker} <-
           Control.get_record(rec["inbound_agent_id"]),
         true <- worker["agent_id"] != task_agent_id(group_id) do
      write(key, worker)
    else
      false -> {:ok, :kept}
      {:ok, _router_or_other} -> {:ok, :kept}
      {:error, :not_found} -> {:ok, :kept}
      {:error, _reason} = error -> error
    end
  end

  defp bindable?(rec, tenant_id, group_id) do
    rec["provider"] == "slack" and rec["tenant_id"] == tenant_id and
      rec["group_id"] == group_id and is_nil(rec["deleted_at"]) and
      is_nil(rec["inbound_tasks"]) and is_binary(rec["inbound_agent_id"])
  end

  defp task_agent_id(group_id) do
    case CasRecord.get(Keys.ctl_group(group_id)) do
      {:ok, group} -> SalixAgent.TaskAgent.of_group(group)
      _missing -> nil
    end
  end

  defp write(key, worker) do
    worker_id = worker["agent_id"]
    tasks = if model = task_model(worker["model"]), do: %{"model" => model}, else: %{}

    CasRecord.update(
      key,
      fn rec ->
        if rec["inbound_agent_id"] == worker_id and is_nil(rec["inbound_tasks"]) and
             is_nil(rec["deleted_at"]),
           do:
             rec
             |> Map.put("inbound_tasks", tasks)
             |> Map.put("updated_at", SystemsClock.system_time(:millisecond)),
           else: {:unchanged, rec}
      end,
      create: false
    )
    |> case do
      {:ok, %{"inbound_tasks" => ^tasks, "inbound_agent_id" => ^worker_id}} -> {:ok, :bound}
      {:ok, _unchanged} -> {:ok, :kept}
      {:error, :not_found} -> {:ok, :kept}
      error -> error
    end
  end

  # The values a Group's default Task model takes (`SalixAgent.TaskModel`).
  defp task_model(model) do
    if SalixAgent.TaskModel.valid?(model), do: model
  end
end
