defmodule SystemsRuntime.Agent do
  @moduledoc "`Agent`: each function is the `Agent` function of the same name."

  @doc "A child spec for an agent whose state `fun` returns, as `Agent.child_spec/1`."
  def child_spec(fun) when is_function(fun, 0),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [fun]}}

  @doc "As `Agent.start_link/2`."
  def start_link(fun, opts \\ []), do: Agent.start_link(fun, opts)

  @doc "As `Agent.start/2`."
  def start(fun, opts \\ []), do: Agent.start(fun, opts)

  @doc "As `Agent.get/3`."
  # ast-grep-ignore: ex-lib-wait -- the caller chooses the timeout
  def get(agent, fun, timeout \\ 5000), do: Agent.get(agent, fun, timeout)

  @doc "As `Agent.update/3`."
  # ast-grep-ignore: ex-lib-wait -- the caller chooses the timeout
  def update(agent, fun, timeout \\ 5000), do: Agent.update(agent, fun, timeout)

  @doc "As `Agent.get_and_update/3`."
  def get_and_update(agent, fun, timeout \\ 5000),
    # ast-grep-ignore: ex-lib-wait -- the caller chooses the timeout
    do: Agent.get_and_update(agent, fun, timeout)

  @doc "As `Agent.cast/2`."
  def cast(agent, fun), do: Agent.cast(agent, fun)

  @doc "As `Agent.stop/3`."
  def stop(agent, reason \\ :normal, timeout \\ :infinity), do: Agent.stop(agent, reason, timeout)
end
