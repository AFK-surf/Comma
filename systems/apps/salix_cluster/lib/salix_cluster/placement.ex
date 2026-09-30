defmodule SalixCluster.Placement do
  @moduledoc """
  Cluster-aware agent placement. A live durable lease takes precedence over the
  ring: rolling node replacement can move the preferred node while the previous
  holder is still running sessions. Unowned or expired agents use the ring.

  A disconnected live holder is an explicit error, not permission to start a
  competing owner. Claim/commit fencing remains authoritative after resolution.
  """
  @behaviour SalixAgent.Placement

  @impl true
  def ensure_started(agent_id, opts) do
    with {:ok, owner} <- owner(agent_id) do
      on_owner(owner, :ensure_started, [agent_id, opts], 5_000)
    end
  end

  @impl true
  def stop_existing(agent_id, opts) do
    with {:ok, owner} <- owner(agent_id) do
      on_owner(owner, :stop_existing, [agent_id, opts], Keyword.get(opts, :timeout, 5_000))
    end
  end

  @impl true
  def run_on_owner(agent_id, {module, function, args}, timeout) do
    with {:ok, owner} <- owner(agent_id) do
      if owner == node() do
        apply(module, function, args)
      else
        :erpc.call(owner, module, function, args, timeout)
      end
    end
  rescue
    error -> {:error, {:owner_unreachable, error}}
  catch
    :exit, reason -> {:error, {:owner_unreachable, reason}}
  end

  # A live claim held on this node routes locally without reading the head:
  # the cell mirrors the claim this node's Server installed, and the stage
  # itself still verifies the durable head before committing (the RPC
  # delivery owner fence), so a head that moved is refused there and the
  # caller re-resolves. Anything else consults the durable head.
  defp owner(agent_id) do
    case SalixAgent.OwnershipCell.fetch(agent_id) do
      {:ok, _epoch} -> {:ok, node()}
      _absent_or_fenced -> durable_owner(agent_id)
    end
  end

  defp durable_owner(agent_id) do
    case SalixStore.Agent.peek_in_scope(agent_id) do
      {:ok, %{owner_node: holder, lease_until: until}}
      when is_binary(holder) and is_integer(until) ->
        if until > System.system_time(:millisecond) do
          # Never turn a persisted name into a new atom. Only already-connected
          # visible peers (and ourselves) may be selected as the live holder.
          case Enum.find([node() | Node.list(:visible)], &(to_string(&1) == holder)) do
            nil -> {:error, {:owner_unreachable, holder, :not_connected}}
            owner -> {:ok, owner}
          end
        else
          {:ok, SalixCluster.Ring.owner(agent_id)}
        end

      {:ok, _unowned} ->
        {:ok, SalixCluster.Ring.owner(agent_id)}

      {:error, :not_found} ->
        {:ok, SalixCluster.Ring.owner(agent_id)}

      {:error, _reason} = error ->
        error
    end
  end

  defp on_owner(owner, operation, args, timeout) do
    if owner == node() do
      apply(SalixAgent.Fleet, operation, args)
    else
      :erpc.call(owner, SalixAgent.Fleet, operation, args, timeout)
    end
  rescue
    error -> {:error, {:owner_unreachable, owner, error}}
  end
end
