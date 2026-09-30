defmodule Salix.Runtime.Placement do
  @moduledoc """
  Central boundary for local/remote runtime placement decisions.
  """

  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(agent_id, opts \\ []),
    do: SalixAgent.Placement.ensure_started(agent_id, opts)

  @spec owner(String.t()) :: node()
  def owner(agent_id) do
    ring = Module.concat([SalixCluster, Ring])

    if Code.ensure_loaded?(ring) and Process.whereis(ring) do
      apply(ring, :owner, [agent_id])
    else
      Node.self()
    end
  end

  @spec local_owner?(String.t()) :: boolean()
  def local_owner?(agent_id), do: owner(agent_id) == Node.self()

  @doc """
  Returns the remote call boundary module/function for audits.

  Runtime callers should keep durable delivery before wake. This module exposes
  placement; durable write/recovery is owned by `Salix.Runtime.deliver/3`.
  """
  def remote_boundary, do: {:erpc, SalixAgent.Fleet, :ensure_started}
end
