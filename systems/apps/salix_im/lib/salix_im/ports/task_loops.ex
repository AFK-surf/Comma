defmodule SalixIM.Ports.TaskLoops do
  @moduledoc """
  The Background Loop of a Task, as the Task layer requests, shows and ends
  it (`SalixIM.TaskLoop`). The Loop runtime (`SalixAgent.Loops`) owns the
  Loop rows and every fact of the Loop; salix_im cannot call it, so the
  composition root binds it here under `config :salix_im, :task_loops_mod`.

  Every call names Tasks of one Group and is one indexed write or read of
  their Loops (a Task has at most one). `task_loops/2` answers
  `%{conversation_id => view}` for at most 50 Tasks, without the Tasks that
  have no Loop; a view carries `loop_id`, `status`, `paused_by`, `trigger`,
  the limits and the run facts.

  Without a binding there is no Loop runtime, so no Task has a Loop.
  """

  @callback request_task_loop(attrs :: map()) :: {:ok, map()} | {:error, term()}
  @callback task_loops(group_id :: String.t(), conversation_ids :: [String.t()]) ::
              {:ok, %{String.t() => map()}} | {:error, term()}
  @callback end_task_loops(group_id :: String.t(), conversation_id :: String.t(), String.t()) ::
              :ok | {:error, term()}
  @callback delete_task_loops(group_id :: String.t(), conversation_id :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  def request_task_loop(attrs), do: impl().request_task_loop(attrs)

  def task_loops(group_id, conversation_ids), do: impl().task_loops(group_id, conversation_ids)

  def end_task_loops(group_id, conversation_id, reason),
    do: impl().end_task_loops(group_id, conversation_id, reason)

  def delete_task_loops(group_id, conversation_id),
    do: impl().delete_task_loops(group_id, conversation_id)

  defp impl, do: SystemsRuntime.get_env(:salix_im, :task_loops_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskLoops

    @impl true
    def request_task_loop(_attrs), do: {:error, :loops_unavailable}

    @impl true
    def task_loops(_group_id, _conversation_ids), do: {:ok, %{}}

    @impl true
    def end_task_loops(_group_id, _conversation_id, _reason), do: :ok

    @impl true
    def delete_task_loops(_group_id, _conversation_id), do: {:ok, 0}
  end
end
