defmodule Comma.TaskPanelDismissals do
  @moduledoc """
  The settled Tasks a User cleared out of the chat Task panel ("Dismiss", or
  "Reveal in Chat" on a settled row), each with the run the User acknowledged
  (`revision`: the Task's `run_started_at`, or 0 for a Task from before Salix
  kept it). They belong to the User, so every device and client hides the
  same rows. A client hides a settled row only until the Task's latest run
  started after the acknowledged one, so a Task that runs again shows again
  without anyone lifting the dismissal.

  A Task id is an opaque value here: a dismissal grants nothing and reads no
  Task, so storing an id the User cannot read changes only that User's own
  panel. A revision never moves back. Bounds: at most 300 dismissals per User
  (the most recently dismissed stay) and at most 300 per request, with ids of
  at most 256 bytes.
  """

  import Ecto.Query

  alias Comma.Data.TaskPanelDismissal
  alias Comma.Repo

  @max_kept 300
  @max_dismissals 300
  @max_id_bytes 256
  # The largest integer a JavaScript client reads exactly.
  @max_revision 9_007_199_254_740_991

  @doc "The User's dismissals, most recently dismissed first, as `task_id` and `revision`."
  def list(user_id) when is_binary(user_id) do
    {:ok, read(user_id)}
  rescue
    _error -> {:error, :task_panel_unavailable}
  end

  @doc """
  Dismisses each `%{"task_id" => id, "revision" => version}` now: a repeated id
  keeps the newer revision. Answers the User's dismissals.
  """
  def dismiss(user_id, dismissals) when is_binary(user_id) do
    with {:ok, dismissals} <- valid(dismissals) do
      now = SystemsClock.utc_now()

      rows =
        Enum.map(dismissals, fn {task_id, revision} ->
          %{user_id: user_id, task_id: task_id, revision: revision, dismissed_at: now}
        end)

      Repo.transaction(fn ->
        Repo.insert_all(TaskPanelDismissal, rows,
          conflict_target: [:user_id, :task_id],
          on_conflict:
            from(d in TaskPanelDismissal,
              update: [
                set: [
                  revision: fragment("GREATEST(?, EXCLUDED.revision)", d.revision),
                  dismissed_at: fragment("EXCLUDED.dismissed_at")
                ]
              ]
            )
        )

        kept =
          from(d in TaskPanelDismissal,
            where: d.user_id == ^user_id,
            order_by: [desc: d.dismissed_at, desc: d.task_id],
            limit: @max_kept,
            select: d.task_id
          )

        Repo.delete_all(
          from(d in TaskPanelDismissal,
            where: d.user_id == ^user_id and d.task_id not in subquery(kept)
          )
        )

        read(user_id)
      end)
    end
  rescue
    _error -> {:error, :task_panel_unavailable}
  end

  defp read(user_id) do
    from(d in TaskPanelDismissal,
      where: d.user_id == ^user_id,
      order_by: [desc: d.dismissed_at, desc: d.task_id],
      limit: @max_kept,
      select: %{"task_id" => d.task_id, "revision" => d.revision}
    )
    |> Repo.all()
  end

  # One row per Task id, with the newest revision a request names for it.
  defp valid(dismissals)
       when is_list(dismissals) and dismissals != [] and length(dismissals) <= @max_dismissals do
    if Enum.all?(dismissals, &valid_dismissal?/1) do
      {:ok,
       dismissals
       |> Enum.group_by(& &1["task_id"], & &1["revision"])
       |> Enum.map(fn {task_id, revisions} -> {task_id, Enum.max(revisions)} end)}
    else
      {:error,
       {:bad_request,
        "each dismissal needs a task_id of at most 256 bytes and a non-negative integer revision"}}
    end
  end

  defp valid(_dismissals),
    do: {:error, {:bad_request, "dismissals must list 1 to 300 Tasks"}}

  defp valid_dismissal?(%{"task_id" => task_id, "revision" => revision}),
    do:
      is_binary(task_id) and task_id != "" and byte_size(task_id) <= @max_id_bytes and
        is_integer(revision) and revision >= 0 and revision <= @max_revision

  defp valid_dismissal?(_dismissal), do: false
end
