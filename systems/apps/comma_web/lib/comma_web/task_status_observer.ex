defmodule CommaWeb.TaskStatusObserver do
  @moduledoc """
  Salix's status observer for owned Tasks (`:task_status_observer`): the
  analytics of an ended Task (`CommaWeb.TaskEndedAnalytics`), then the owner's
  attention (`CommaWeb.ProactiveTask`) and the receipt of a Task made from a
  request (`CommaWeb.TaskRequestReceipts`). Salix keeps an error from either of
  the last two, so both see the status again. A Task together goes to
  `CommaWeb.CollaborationNotice` instead.
  """

  def task_status_changed(%{"collaboration" => true} = snapshot) do
    # A Task together's host hears only its status
    # (`CommaWeb.CollaborationNotice`), never a Home matter that reads it.
    CommaWeb.TaskEndedAnalytics.observe(snapshot)
    CommaWeb.CollaborationNotice.task_status_changed(snapshot)
  end

  def task_status_changed(snapshot) do
    CommaWeb.TaskEndedAnalytics.observe(snapshot)

    with :ok <- CommaWeb.ProactiveTask.task_status_changed(snapshot),
         do: CommaWeb.TaskRequestReceipts.task_status_changed(snapshot)
  end
end
