defmodule SystemsRuntime.Supervisor do
  @moduledoc """
  `Supervisor` and `DynamicSupervisor`: each function is the `Supervisor` or
  `DynamicSupervisor` function it names.
  """

  @doc "Starts a supervisor of `children`, as `Supervisor.start_link/2`."
  def start_link(children, opts) when is_list(children), do: Supervisor.start_link(children, opts)

  @doc """
  Starts a supervisor of a module that uses `Supervisor`, as
  `Supervisor.start_link/3`: its `init/1` gives the children.
  """
  def start_link(module, arg, opts) when is_atom(module),
    do: Supervisor.start_link(module, arg, opts)

  @doc "Stops a supervisor, as `Supervisor.stop/3`."
  def stop(sup, reason \\ :normal, timeout \\ :infinity),
    do: Supervisor.stop(sup, reason, timeout)

  @doc "Starts a dynamic supervisor, as `DynamicSupervisor.start_link/1`."
  def start_dynamic(opts \\ []), do: DynamicSupervisor.start_link(opts)

  @doc "Starts a child, as `Supervisor.start_child/2` or `DynamicSupervisor.start_child/2`."
  def start_child(sup, spec) do
    case :supervisor.get_callback_module(GenServer.whereis(sup)) do
      DynamicSupervisor -> DynamicSupervisor.start_child(sup, spec)
      _module -> Supervisor.start_child(sup, spec)
    end
  end

  @doc "Stops a child, as `Supervisor.terminate_child/2` (by id) or `DynamicSupervisor.terminate_child/2` (by pid)."
  def terminate_child(sup, pid) when is_pid(pid), do: DynamicSupervisor.terminate_child(sup, pid)
  def terminate_child(sup, id), do: Supervisor.terminate_child(sup, id)

  @doc "The supervisor's children, as `Supervisor.which_children/1`."
  def which_children(sup), do: Supervisor.which_children(sup)

  @doc "Counts the supervisor's children, as `Supervisor.count_children/1`."
  def count_children(sup), do: Supervisor.count_children(sup)
end
