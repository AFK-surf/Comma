defmodule SalixAgent.Colab.Tunnels do
  @moduledoc """
  Node-local cache of live `SalixAgent.Colab.Tunnel` processes, indexed by `vm_id`.

  Strictly an ephemeral connection cache: PostgreSQL `colab_vm_leases` is the sole
  lifecycle authority. Dropping or stopping a tunnel never calls Colab `unassign`.
  """

  alias SalixAgent.Colab.Tunnel

  @registry SalixAgent.Colab.Tunnels.Registry
  @supervisor SalixAgent.Colab.Tunnels.Supervisor

  @doc "Child specs for `SalixAgent.Application`."
  def children do
    [
      {SystemsRuntime.Registry, keys: :unique, name: @registry},
      {SystemsRuntime.DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  def registry, do: @registry
  def supervisor, do: @supervisor

  @doc "Lookup the live tunnel pid for `vm_id` on this node, if any."
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(vm_id) when is_binary(vm_id) do
    case SystemsRuntime.Registry.lookup(@registry, vm_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Return a live OTP `:ssh` connection pid for `vm_id` at `generation`, starting
  and connecting a new `Tunnel` if none is cached (or if the cached one is stale).
  """
  @spec get_or_connect(String.t(), pos_integer(), map()) :: {:ok, pid()} | {:error, term()}
  def get_or_connect(vm_id, generation, connect_opts)
      when is_binary(vm_id) and is_integer(generation) and is_map(connect_opts) do
    case lookup(vm_id) do
      {:ok, pid} ->
        case safe_connect(pid, generation, connect_opts) do
          {:ok, conn} ->
            {:ok, conn}

          {:error, :stale_tunnel} ->
            drop_pid(vm_id, pid)
            start_and_connect(vm_id, generation, connect_opts)

          {:error, :tunnel_exited} ->
            start_and_connect(vm_id, generation, connect_opts)

          other ->
            other
        end

      :error ->
        start_and_connect(vm_id, generation, connect_opts)
    end
  end

  @doc """
  Close and remove any cached tunnel for `vm_id` on this node.
  Never calls Colab `unassign`.
  """
  @spec drop(String.t()) :: :ok
  def drop(vm_id) when is_binary(vm_id) do
    case lookup(vm_id) do
      {:ok, pid} ->
        terminate_pid(pid)

      :error ->
        :ok
    end
  end

  @doc """
  Close and remove the cached tunnel for `vm_id` ONLY if the registry still
  points to `pid`, preventing a stale reuse failure from killing a newly
  established healthy tunnel. Never calls Colab `unassign`.
  """
  @spec drop_pid(String.t(), pid()) :: :ok
  def drop_pid(vm_id, pid) when is_binary(vm_id) and is_pid(pid) do
    case lookup(vm_id) do
      {:ok, ^pid} -> terminate_pid(pid)
      _ -> :ok
    end
  end

  defp terminate_pid(pid) do
    try do
      SystemsRuntime.DynamicSupervisor.terminate_child(@supervisor, pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp start_and_connect(vm_id, generation, connect_opts) do
    spec = {Tunnel, vm_id: vm_id, generation: generation}

    pid_result =
      case SystemsRuntime.DynamicSupervisor.start_child(@supervisor, spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end

    with {:ok, pid} <- pid_result do
      safe_connect(pid, generation, connect_opts)
    end
  end

  defp safe_connect(pid, generation, connect_opts) do
    Tunnel.connect(pid, generation, connect_opts)
  catch
    :exit, _ -> {:error, :tunnel_exited}
  end
end
