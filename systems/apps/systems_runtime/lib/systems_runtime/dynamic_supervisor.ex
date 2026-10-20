defmodule SystemsRuntime.DynamicSupervisor do
  @moduledoc "`DynamicSupervisor`: each function is the `DynamicSupervisor` function of the same name."

  alias SystemsRuntime.Supervisor

  @doc "A child spec, as `DynamicSupervisor.child_spec/1`."
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "As `DynamicSupervisor.start_link/1`."
  def start_link(opts), do: Supervisor.start_dynamic(opts)

  @doc "As `DynamicSupervisor.start_child/2`."
  def start_child(sup, spec), do: DynamicSupervisor.start_child(sup, spec)

  @doc "As `DynamicSupervisor.terminate_child/2`."
  def terminate_child(sup, pid), do: Supervisor.terminate_child(sup, pid)

  @doc "As `DynamicSupervisor.which_children/1`."
  def which_children(sup), do: Supervisor.which_children(sup)

  @doc "As `DynamicSupervisor.count_children/1`."
  def count_children(sup), do: Supervisor.count_children(sup)
end
