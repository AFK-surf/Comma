defmodule SalixAgent.Migrations.DefaultTaskPlaces do
  @moduledoc """
  The Salix half of BridgeForTeams migration
  `20261019140001_derive_default_task_places`
  (`BridgeForTeams.Migrations.DefaultTaskPlaces`): a Group whose live Workers
  all run their Tasks on the Group's Cloud VM (each bound to it,
  `SalixAgent.StationBinding.cloud_vm?/1`) gets the Cloud VM as its default
  place to run Tasks (`SalixAgent.TaskPlace`), so a Task that names no Worker
  place still runs there once Workers no longer decide it.

  A Group with no live Worker, or one Worker that runs elsewhere (inside Salix
  or on a station), keeps none: its Tasks run inside Salix. The Group's Task
  agent (`task_agent_id` on the Group record) is not one of its Workers. A
  Group that already has a default keeps it, so a pass run again changes
  nothing. No Agent is changed.

  It reads at most four pages of 50 Agent records of the Group; a Group with
  more is left without a default.
  """

  alias SalixAgent.{Control, StationBinding, TaskPlace}
  alias SalixStore.{CasRecord, Keys}

  @pages 4
  @page_limit 50

  @doc """
  Derive the default place of one Group. Answers `{:ok, :cloud_vm}` when the
  Group's default is the Cloud VM afterwards because its Workers agree,
  `{:ok, :none}` when they do not decide one.
  """
  @spec derive(String.t(), String.t()) :: {:ok, :cloud_vm | :none} | {:error, term()}
  def derive(tenant_id, group_id) do
    with {:ok, group} <- group(group_id),
         {:ok, workers} <- live_workers(tenant_id, group_id, group["task_agent_id"]) do
      if workers != [] and Enum.all?(workers, &StationBinding.cloud_vm?/1) do
        with {:ok, _place} <- TaskPlace.put_new(tenant_id, group_id, TaskPlace.cloud_vm()),
             do: {:ok, :cloud_vm}
      else
        {:ok, :none}
      end
    else
      {:error, :not_found} -> {:ok, :none}
      {:error, :too_many_workers} -> {:ok, :none}
      error -> error
    end
  end

  defp group(group_id) do
    CasRecord.get(Keys.ctl_group(group_id))
  end

  defp live_workers(tenant_id, group_id, task_agent_id),
    do: live_workers(tenant_id, group_id, task_agent_id, nil, @pages, [])

  defp live_workers(_tenant_id, _group_id, _task_agent_id, _cursor, 0, _workers),
    do: {:error, :too_many_workers}

  defp live_workers(tenant_id, group_id, task_agent_id, cursor, pages, workers) do
    with {:ok, page} <-
           Control.page_workers(tenant_id, group_id,
             lifecycle: "unarchived",
             limit: @page_limit,
             cursor: cursor
           ) do
      workers =
        workers ++
          Enum.filter(page.items, fn worker ->
            worker["agent_id"] != task_agent_id and worker["permanent_archive"] != true and
              worker["status"] not in ["cancelled", "failed"]
          end)

      case page.next_cursor do
        nil -> {:ok, workers}
        next -> live_workers(tenant_id, group_id, task_agent_id, next, pages - 1, workers)
      end
    end
  end
end
