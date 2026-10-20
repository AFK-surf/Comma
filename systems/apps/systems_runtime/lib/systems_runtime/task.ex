defmodule SystemsRuntime.Task do
  @moduledoc "`Task`: each function is the `Task` function of the same name."

  @doc "Starts `fun` linked to and monitored by the caller, as `Task.async/1`."
  def async(fun) when is_function(fun, 0), do: Task.async(fun)

  @doc "Waits for a task's reply, as `Task.await/2`."
  # ast-grep-ignore: ex-lib-wait -- the caller chooses the timeout
  def await(%Task{} = task, timeout \\ 5000), do: Task.await(task, timeout)

  @doc "Waits up to `timeout` for a task's reply, as `Task.yield/2`."
  # ast-grep-ignore: ex-lib-wait -- the caller chooses the timeout
  def yield(%Task{} = task, timeout \\ 5000), do: Task.yield(task, timeout)

  @doc "Stops a task and takes a reply that came, as `Task.shutdown/2`."
  def shutdown(%Task{} = task, shutdown \\ 5000), do: Task.shutdown(task, shutdown)

  @doc "Waits for every task's reply, as `Task.await_many/2`."
  def await_many(tasks, timeout \\ 5000) when is_list(tasks),
    # ast-grep-ignore: ex-lib-wait -- the caller chooses the timeout
    do: Task.await_many(tasks, timeout)

  @doc "Lets a task run on and drops its reply, as `Task.ignore/1`."
  def ignore(%Task{} = task), do: Task.ignore(task)

  @doc "Starts `fun` unlinked, as `Task.start/1`."
  def start(fun) when is_function(fun, 0), do: Task.start(fun)

  @doc "Starts `fun` linked to the caller, as `Task.start_link/1`."
  def start_link(fun) when is_function(fun, 0), do: Task.start_link(fun)
end
