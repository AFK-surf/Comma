defmodule Salix.Control.Tailnet do
  @moduledoc """
  The Group's Tailscale network (`SalixAgent.Tailnet`) for the human
  surfaces: the Comma app settings, the BFT dashboard (over erpc) and the
  Salix dashboard. Each call first checks that the Group belongs to the
  tenant. The router Agent uses the `tailnet.*` tools instead.

  `actor` records who changed the settings: `comma_user:<id>`,
  `bft_user:<id>` or `salix_admin`.
  """

  alias Salix.Control.Groups

  @doc "The Group's tailnet settings and node status. Never starts the node."
  def status(group_id, tenant_id) do
    with {:ok, _group} <- Groups.get(group_id, tenant_id), do: SalixAgent.Tailnet.status(group_id)
  end

  @doc "Enable or change the Group's tailnet; returns the status, with a login link when needed."
  def connect(group_id, tenant_id, attrs, actor) when is_map(attrs) do
    with {:ok, _group} <- Groups.get(group_id, tenant_id),
         do:
           SalixAgent.Tailnet.connect(
             group_id,
             Map.take(attrs, ~w(tags accept_routes expected_tailnet)),
             actor
           )
  end

  @doc "Disconnect the Group: its node logs out and forgets its keys."
  def disconnect(group_id, tenant_id, actor) do
    with {:ok, _group} <- Groups.get(group_id, tenant_id),
         do: SalixAgent.Tailnet.disconnect(group_id, actor)
  end

  @doc "One page of the tailnet's devices. Starts the node when it is idle."
  def peers(group_id, tenant_id, cursor \\ 0) do
    with {:ok, _group} <- Groups.get(group_id, tenant_id),
         do: SalixAgent.Tailnet.peers(group_id, cursor)
  end
end
