defmodule SalixCluster.NodeLifecycle do
  @moduledoc """
  Local node lifecycle flags used by Kubernetes rolling updates.

  The flags are intentionally node-local: a pod entering preStop should stop
  accepting new work on that BEAM node, while other pods continue serving.

  New work includes placement: a draining node leaves `SalixCluster.Ring`
  (`leave/0`), so agents it releases during drain start on another ready node
  and not here again, and `admit_start/0` refuses a new agent Server here
  while the ring places keys elsewhere.
  """

  require Logger

  @key {__MODULE__, :state}

  @doc "Mark this node as draining and leave the placement ring."
  @spec mark_draining() :: :ok
  def mark_draining do
    update(&Map.put(&1, :draining, true))
    ring(:leave)
  end

  @doc "Clear the draining flag and rejoin the ring. Intended for tests and explicit local recovery."
  @spec clear_draining() :: :ok
  def clear_draining do
    update(&Map.put(&1, :draining, false))
    ring(:rejoin)
  end

  @spec draining?() :: boolean()
  def draining?, do: Map.get(state(), :draining, false) == true

  @doc """
  Whether a new agent Server may start on this node (`SalixAgent.Fleet`'s
  `:start_admission`): not while the node is draining and the ring places
  keys elsewhere. A Server already running here is unaffected. Without a
  ring, or alone in it, the node keeps starting its own agents.
  """
  @spec admit_start() :: :ok | {:error, :draining}
  def admit_start do
    if draining?() and placing_elsewhere?(), do: {:error, :draining}, else: :ok
  end

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
    SystemsRuntime.PersistentTerm.erase(@key)
    ring(:rejoin)
  end

  # The ring is the placement projection of the draining flag. A node without a
  # running ring (a product-only pod) has nothing to place. A ring that does
  # not answer (restarting, or stopped between the check and the call) must
  # not take the flag or the rest of preStop down with it.
  defp ring(call) do
    if SystemsRuntime.Proc.whereis(SalixCluster.Ring), do: apply(SalixCluster.Ring, call, [])
    :ok
  catch
    :exit, reason ->
      Logger.warning("node lifecycle: ring #{call} failed: #{inspect(reason)}")
      :ok
  end

  defp placing_elsewhere? do
    SystemsRuntime.Proc.whereis(SalixCluster.Ring) != nil and
      Node.self() not in SalixCluster.Ring.nodes()
  catch
    :exit, _reason -> false
  end

  defp state, do: SystemsRuntime.PersistentTerm.get(@key, %{})

  defp update(fun) do
    SystemsRuntime.PersistentTerm.put(@key, fun.(state()))
    :ok
  end

  defp now_ms, do: SystemsClock.system_time(:millisecond)
end
