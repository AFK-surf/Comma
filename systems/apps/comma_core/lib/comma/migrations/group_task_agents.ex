defmodule Comma.Migrations.GroupTaskAgents do
  @moduledoc """
  Records each Comma Workspace's Task Worker as its Group's Task agent
  (`SalixAgent.TaskAgent`), once, so the Group keeps running its Tasks on the
  same Agent with the same name.

  The Task Worker is the one Comma gave Tasks before its Group had a Task
  agent: the Workspace's stored default Worker, else its Group's first unarchived
  internal Worker. A Group that already has a Task agent keeps it, so a pass
  run again changes nothing. A Workspace without a Worker is left alone: its
  first Task gets the Task agent Salix makes. No Agent is created or changed.

  Comma's rows are read through the repo the caller gives, 500 at a time;
  each reads the Group record, at most one Agent record, or four pages of 50
  Agent records when it has no stored default Worker, and writes the Group
  record at most once.
  """

  import Ecto.Query

  alias Comma.Data.Workspace
  alias SalixAgent.{Control, TaskAgent}

  @page 500
  @worker_pages 4
  @worker_page_limit 50

  def run(repo), do: page(repo, "", %{set: 0, started: false})

  defp page(repo, after_id, state) do
    rows =
      repo.all(
        from(w in Workspace,
          where:
            w.id > ^after_id and w.kind == "standard" and w.status != "deleted" and
              not is_nil(w.salix_tenant_id) and not is_nil(w.salix_group_id),
          order_by: w.id,
          limit: @page,
          select: %{
            id: w.id,
            tenant_id: w.salix_tenant_id,
            group_id: w.salix_group_id,
            worker_id: w.salix_worker_agent_id
          }
        )
      )

    case rows do
      [] ->
        {:ok, %{set: state.set}}

      rows ->
        state = start_salix(state)

        with {:ok, set} <- adopt_page(rows, state.set),
             do: page(repo, List.last(rows).id, %{state | set: set})
    end
  end

  # A new installation migrates Comma before Salix runs; Salix is started
  # only when a Workspace exists.
  defp start_salix(%{started: true} = state), do: state

  defp start_salix(state) do
    {:ok, _} = Application.ensure_all_started(:salix_store)
    %{state | started: true}
  end

  defp adopt_page(rows, set) do
    Enum.reduce_while(rows, {:ok, set}, fn row, {:ok, set} ->
      case adopt(row) do
        :set -> {:cont, {:ok, set + 1}}
        :skip -> {:cont, {:ok, set}}
        {:error, reason} -> {:halt, {:error, {row.id, reason}}}
      end
    end)
  end

  defp adopt(row) do
    with {:ok, nil} <- TaskAgent.get(row.group_id),
         {:ok, worker} <- task_worker(row),
         {:ok, _stored} <- TaskAgent.adopt(row.tenant_id, row.group_id, worker["agent_id"]) do
      :set
    else
      {:ok, _recorded} -> :skip
      {:error, reason} when reason in [:not_found, :guest_group] -> :skip
      {:error, {:unavailable, :task_agent}} -> :skip
      {:error, _reason} = error -> error
    end
  end

  defp task_worker(%{worker_id: id} = row) when is_binary(id) and id != "" do
    with {:ok, worker} <- Control.get(id, row.tenant_id) do
      if worker["group_id"] == row.group_id and worker["role"] == "worker",
        do: {:ok, worker},
        else: {:error, :not_found}
    end
  end

  defp task_worker(row), do: first_unarchived(row, nil, @worker_pages)

  defp first_unarchived(_row, _cursor, 0), do: {:error, :not_found}

  defp first_unarchived(row, cursor, pages) do
    with {:ok, page} <-
           Control.page_workers(row.tenant_id, row.group_id,
             lifecycle: "unarchived",
             runtime_source: "internal",
             limit: @worker_page_limit,
             cursor: cursor
           ) do
      case {page.items, page.next_cursor} do
        {[worker | _], _} -> {:ok, worker}
        {[], nil} -> {:error, :not_found}
        {[], next} -> first_unarchived(row, next, pages - 1)
      end
    end
  end
end
