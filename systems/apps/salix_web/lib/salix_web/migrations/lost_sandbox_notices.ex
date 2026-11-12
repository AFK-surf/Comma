defmodule SalixWeb.Migrations.LostSandboxNotices do
  @moduledoc """
  Tell the active Tasks whose sandbox was `lost` before such a Task was told.
  Those Workloads have no check due, so nothing reaches them on its own.

  Run over `bin/comma rpc`, once the release that has this module serves.
  `run(workload: id, generation: n)` marks one Workload, only while it is
  `lost` at that generation. `run/1` without `workload` marks every `lost`
  Workload, at most 100 a page and 10 pages a run: an answer with `done: false`
  is continued with `run(after: cursor)`.

  A mark says the Workload owes its notice and changes nothing else. The pass
  writes no Message: `SalixWeb.CodingSandboxes.check/1` writes the same notice
  as for a sandbox lost now, at most 20 Workloads per 15 s on each node, once
  per generation, only in a Task that is active then. No generation, Task
  status or delegation changes, and nothing starts a sandbox. A run repeated
  checks the Workloads again and adds no Message. A store error stops the run
  with an error; the run can be repeated.
  """

  alias SalixStore.CodingSandboxes, as: Store

  @page 100
  @max_pages 10

  @doc """
  Marks the Workloads asked for. Answers how many, in how many pages, the
  `cursor` to continue after, and whether the run is `done`.
  """
  def run(opts \\ []) do
    case Keyword.fetch(opts, :workload) do
      {:ok, id} ->
        one(id, Keyword.fetch!(opts, :generation))

      :error ->
        page(
          Keyword.get(opts, :after),
          Keyword.get(opts, :page, @page),
          Keyword.get(opts, :max_pages, @max_pages),
          %{marked: 0, pages: 0, cursor: Keyword.get(opts, :after), done: false}
        )
    end
  end

  defp one(id, generation) do
    with {:ok, id} <- Store.mark_lost_notice(id, generation),
         do: {:ok, %{marked: 1, pages: 1, cursor: id, done: true}}
  end

  defp page(_cursor, _limit, 0, counts), do: {:ok, counts}

  defp page(cursor, limit, pages_left, counts) do
    case Store.mark_lost_notices(cursor, limit) do
      {:ok, ids} ->
        counts = %{
          counts
          | marked: counts.marked + length(ids),
            pages: counts.pages + 1,
            cursor: List.last(ids) || cursor,
            done: length(ids) < limit
        }

        if counts.done,
          do: {:ok, counts},
          else: page(counts.cursor, limit, pages_left - 1, counts)

      {:error, _} = error ->
        error
    end
  end
end
