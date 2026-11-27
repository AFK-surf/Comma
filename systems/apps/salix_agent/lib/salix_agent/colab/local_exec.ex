defmodule SalixAgent.Colab.LocalExec do
  @moduledoc """
  Single-owner node execution & cross-node `:erpc` forwarding for Google Colab VMs.

  Routing and takeover rules:
  1. `lease.owner_node == node()` -> run locally on this node's cached tunnel,
     fenced on `lease.generation`.
  2. `lease.owner_node` names a live cluster peer (`peer in Node.list()`) ->
     forward via bounded `:erpc.call(peer, __MODULE__, :run, [op_spec, gen],
     timeout_ms + 15_000)`. Any post-dispatch `:erpc` failure (`:timeout`,
     `:noconnection`, `:undef`, exit) returns `{:error, :result_unknown}` —
     NEVER replays, NEVER calls `drop`, NEVER auto-takes-over while `owner_node`
     remains a live peer.
  3. `lease.owner_node` is absent from `[node() | Node.list()]` -> perform a
     single atomic compare-and-set takeover (`WHERE vm_id=$1 AND state='active'
     AND generation=$2` -> `owner_node=node(), generation=generation+1`).
  """

  alias SalixAgent.Colab.{Account, Client, Leases, Transfer, Tunnels}

  @rpc_grace_ms 15_000
  @busy_margin_seconds 30

  @spec execute(Leases.lease(), map()) :: {:ok, term()} | {:ok, map(), [map()]} | {:error, term()}
  def execute(lease, op_spec) when is_map(lease) and is_map(op_spec) do
    do_execute(lease, op_spec, false)
  end

  defp do_execute(lease, op_spec, retried?) do
    local = Atom.to_string(node())
    owner_node = lease.owner_node
    timeout_ms = Map.get(op_spec, :timeout_ms, 120_000)

    cond do
      owner_node == local ->
        run(op_spec, lease.generation)

      is_binary(owner_node) ->
        case Enum.find(Node.list(), &(Atom.to_string(&1) == owner_node)) do
          nil ->
            adopt_and_execute(lease, op_spec, local, retried?)

          peer ->
            forward_to_peer(peer, op_spec, lease.generation, timeout_ms)
        end

      true ->
        adopt_and_execute(lease, op_spec, local, retried?)
    end
  end

  defp forward_to_peer(peer, op_spec, generation, timeout_ms) do
    :erpc.call(
      peer,
      __MODULE__,
      :run,
      [op_spec, generation],
      timeout_ms + @rpc_grace_ms
    )
  catch
    _kind, _reason -> {:error, :result_unknown}
  end

  defp adopt_and_execute(lease, op_spec, local, retried?) do
    case Leases.claim_orphaned_owner(lease.vm_id, lease.generation, local) do
      {:ok, adopted} ->
        run(op_spec, adopted.generation)

      {:error, :stale_generation} when not retried? ->
        case Leases.get_for_owner(
               op_spec.vm_id,
               op_spec.tenant_id,
               op_spec.group_id,
               op_spec.owner_scope
             ) do
          {:ok, %{state: "active"} = fresh} ->
            cond do
              fresh.owner_node == local ->
                run(op_spec, fresh.generation)

              is_binary(fresh.owner_node) and
                  Enum.any?(Node.list(), &(Atom.to_string(&1) == fresh.owner_node)) ->
                do_execute(fresh, op_spec, true)

              true ->
                {:error, :owner_unavailable}
            end

          {:ok, _not_active} ->
            {:error, :vm_not_active}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :stale_generation} ->
        {:error, :owner_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute `op_spec` locally on the owning node, re-verifying `(tenant_id,
  group_id, owner_scope, vm_id, generation)` and account usability first.
  """
  @spec run(map(), pos_integer()) :: {:ok, term()} | {:ok, map(), [map()]} | {:error, term()}
  def run(op_spec, expected_generation)
      when is_map(op_spec) and is_integer(expected_generation) do
    with {:ok, lease} <-
           Leases.get_for_owner(
             op_spec.vm_id,
             op_spec.tenant_id,
             op_spec.group_id,
             op_spec.owner_scope
           ),
         :ok <- verify_local_owner(lease, expected_generation),
         {:ok, account} <-
           verify_usable_account(lease.tenant_id, lease.group_id, lease.account_id),
         {:ok, lease} <- extend_protection(lease, op_spec),
         {:ok, ssh_conn} <- ensure_tunnel(lease, account) do
      try do
        dispatch_op(ssh_conn, op_spec)
      after
        # Never clears `busy_until`; updates only `last_used_at`.
        _ = Leases.touch_last_used(lease.vm_id, lease.generation)
      end
    end
  end

  defp verify_local_owner(lease, expected_generation) do
    cond do
      lease.state != "active" -> {:error, :vm_not_active}
      lease.generation != expected_generation -> {:error, :stale_generation}
      lease.owner_node != Atom.to_string(node()) -> {:error, :owner_unavailable}
      true -> :ok
    end
  end

  defp verify_usable_account(tenant_id, group_id, binding_id) do
    case Account.get_account(tenant_id, group_id, binding_id) do
      {:ok, %{state: "active", status: "ok"} = account} ->
        {:ok, account}

      _ ->
        {:error, :account_unavailable}
    end
  end

  defp extend_protection(lease, op_spec) do
    now = SystemsClock.utc_now()
    timeout_s = div(Map.get(op_spec, :timeout_ms, 120_000) + 999, 1_000)
    busy_until = DateTime.add(now, timeout_s + @busy_margin_seconds, :second)

    hold_until =
      case Map.get(op_spec, :hold_minutes) do
        mins when is_integer(mins) and mins > 0 ->
          DateTime.add(now, mins * 60, :second)

        _ ->
          nil
      end

    Leases.extend_busy_and_hold(lease.vm_id, lease.generation, busy_until, hold_until)
  end

  defp ensure_tunnel(lease, account) do
    case Tunnels.lookup(lease.vm_id) do
      {:ok, pid} ->
        case safe_reuse(pid, lease.generation) do
          {:ok, conn} ->
            {:ok, conn}

          {:error, :not_connected} ->
            connect_fresh_tunnel(lease, account)

          _ ->
            Tunnels.drop_pid(lease.vm_id, pid)
            connect_fresh_tunnel(lease, account)
        end

      :error ->
        connect_fresh_tunnel(lease, account)
    end
  end

  defp safe_reuse(pid, generation) do
    SalixAgent.Colab.Tunnel.connect(pid, generation, %{})
  catch
    :exit, _ -> {:error, :tunnel_exited}
  end

  defp connect_fresh_tunnel(lease, account) do
    with {:ok, proxy_url, proxy_token} <- refresh_proxy_info(lease, account) do
      Tunnels.get_or_connect(lease.vm_id, lease.generation, %{
        proxy_url: proxy_url,
        proxy_token: proxy_token
      })
    end
  end

  defp refresh_proxy_info(lease, account) do
    with {:ok, token_info} <-
           Account.get_access_token(
             lease.tenant_id,
             lease.group_id,
             account.binding_id,
             mode: :execute
           ) do
      case fetch_proxy_with_401_retry(lease, account, token_info, false) do
        {:ok, %{url: url, token: token}} ->
          {:ok, url, token}

        {:error, :vm_terminated_externally} ->
          Tunnels.drop(lease.vm_id)
          _ = Leases.delete_if_generation(lease.vm_id, lease.generation)
          {:error, :vm_terminated_externally}

        error ->
          error
      end
    end
  end

  defp fetch_proxy_with_401_retry(lease, account, token_info, retried?) do
    case Client.refresh_proxy_info(token_info.access_token, lease.endpoint) do
      {:ok, info} ->
        {:ok, info}

      {:error, {:http_error, 401, _}} when not retried? ->
        with {:ok, next_token_info} <-
               Account.get_access_token(
                 lease.tenant_id,
                 lease.group_id,
                 account.binding_id,
                 mode: :execute,
                 rejected_revision: token_info.credential_revision
               ) do
          fetch_proxy_with_401_retry(lease, account, next_token_info, true)
        end

      {:error, {:http_error, 403, body}} = err ->
        if Account.classify_colab_http_error(403, body) == :auth_revoked do
          Account.mark_reauthorization_required(
            lease.tenant_id,
            lease.group_id,
            account.binding_id,
            token_info.credential_revision
          )
        end

        err

      other ->
        other
    end
  end

  defp dispatch_op(ssh_conn, %{op: :exec} = op_spec) do
    Transfer.exec(ssh_conn, op_spec.command,
      cwd: Map.get(op_spec, :cwd, "/content"),
      stdin: Map.get(op_spec, :stdin, ""),
      timeout_ms: Map.get(op_spec, :timeout_ms, 120_000)
    )
  end

  defp dispatch_op(ssh_conn, %{op: :upload} = op_spec) do
    Transfer.upload(
      ssh_conn,
      op_spec.ctx,
      op_spec.source,
      op_spec.destination,
      op_spec.overwrite == true,
      Map.get(op_spec, :timeout_ms, 600_000)
    )
  end

  defp dispatch_op(ssh_conn, %{op: :download} = op_spec) do
    Transfer.download(
      ssh_conn,
      op_spec.ctx,
      op_spec.source,
      op_spec.destination,
      op_spec.overwrite == true,
      Map.get(op_spec, :timeout_ms, 600_000)
    )
  end
end
