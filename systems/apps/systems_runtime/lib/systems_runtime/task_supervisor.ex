defmodule SystemsRuntime.TaskSupervisor do
  @moduledoc "`Task.Supervisor`: each function is the `Task.Supervisor` function of the same name."

  @doc "A child spec, as `Task.Supervisor.child_spec/1`."
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "As `Task.Supervisor.start_link/1`."
  def start_link(opts \\ []), do: Task.Supervisor.start_link(opts)

  @doc "As `Task.Supervisor.start_child/2`."
  def start_child(sup, fun, opts \\ []) when is_function(fun, 0),
    do: Task.Supervisor.start_child(sup, fun, opts)

  @doc "As `Task.Supervisor.async_nolink/2`: a task monitored, not linked, by the caller."
  def async_nolink(sup, fun, opts \\ []) when is_function(fun, 0),
    do: Task.Supervisor.async_nolink(sup, fun, opts)

  @doc "As `Task.Supervisor.async/2`: a task linked to and monitored by the caller."
  def async(sup, fun, opts \\ []) when is_function(fun, 0),
    do: Task.Supervisor.async(sup, fun, opts)

  @doc "As `Task.Supervisor.children/1`."
  def children(sup), do: Task.Supervisor.children(sup)

  @doc "Stops a supervised task, as `Task.Supervisor.terminate_child/2`."
  def terminate_child(sup, pid), do: Task.Supervisor.terminate_child(sup, pid)
end
