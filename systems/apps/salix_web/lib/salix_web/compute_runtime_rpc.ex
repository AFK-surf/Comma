defmodule SalixWeb.ComputeRuntimeRPC do
  @moduledoc """
  Live, credential-free RPC to one exact Compute Runtime carrier.

  The distributed `:pg` membership is transport presence only. Durable
  Workload/RuntimeInstance facts remain in SalixStore and every request carries
  the current generation and connection epoch fence.
  """

  @timeout 30_000
  @scope SalixWeb.ComputeRuntimeRPCPG

  def join(runtime_instance_id, connection_epoch) do
    :pg.join(@scope, group(runtime_instance_id, connection_epoch), self())
  end

  def call(runtime_instance_id, connection_epoch, request, timeout \\ @timeout)
      when is_binary(runtime_instance_id) and is_binary(connection_epoch) and is_map(request) do
    case :pg.get_members(@scope, group(runtime_instance_id, connection_epoch)) do
      [owner] -> call_owner(owner, request, timeout)
      [] -> {:error, :runtime_transport_unavailable}
      _multiple -> {:error, :runtime_rpc_target_changed}
    end
  rescue
    _ -> {:error, :runtime_transport_unavailable}
  end

  defp call_owner(owner, request, timeout) do
    ref = Process.monitor(owner)
    send(owner, {:compute_runtime_rpc, ref, self(), request})

    receive do
      {:compute_runtime_rpc_reply, ^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        {:error, :runtime_transport_unavailable}
    after
      timeout ->
        send(owner, {:compute_runtime_rpc_cancel, ref, self()})
        Process.demonitor(ref, [:flush])
        {:error, :runtime_rpc_timeout}
    end
  end

  defp group(runtime_instance_id, connection_epoch),
    do: {__MODULE__, runtime_instance_id, connection_epoch}
end
