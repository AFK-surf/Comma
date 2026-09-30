defmodule SalixCluster.NodeLifecycle do
  @moduledoc """
  Local node lifecycle flags used by Kubernetes rolling updates.

  The flags are intentionally node-local: a pod entering preStop should stop
  accepting new work on that BEAM node, while other pods continue serving.
  """

  @key {__MODULE__, :state}

  @doc "Mark this node as draining."
  @spec mark_draining() :: :ok
  def mark_draining do
    update(&Map.put(&1, :draining, true))
  end

  @doc "Clear the draining flag. Intended for tests and explicit local recovery."
  @spec clear_draining() :: :ok
  def clear_draining do
    update(&Map.put(&1, :draining, false))
  end

  @spec draining?() :: boolean()
  def draining?, do: Map.get(state(), :draining, false) == true

  @doc "Readiness gate for HTTP health checks."
  @spec readiness() :: :ok | {:error, :draining}
  def readiness do
    if draining?(), do: {:error, :draining}, else: :ok
  end

  @doc "Pause new mutating cloud-vm operations for a breaking service migration."
  @spec begin_vm_maintenance(map()) :: :ok
  def begin_vm_maintenance(metadata \\ %{}) when is_map(metadata) do
    update(&Map.put(&1, :vm_maintenance, Map.put_new(metadata, "started_at", now_ms())))
  end

  @doc "Resume new mutating cloud-vm operations."
  @spec clear_vm_maintenance() :: :ok
  def clear_vm_maintenance do
    update(&Map.delete(&1, :vm_maintenance))
  end

  @spec vm_maintenance() :: map() | nil
  def vm_maintenance, do: Map.get(state(), :vm_maintenance)

  @doc "Reset all local flags. Intended for tests."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  defp state, do: :persistent_term.get(@key, %{})

  defp update(fun) do
    :persistent_term.put(@key, fun.(state()))
    :ok
  end

  defp now_ms, do: System.system_time(:millisecond)
end
