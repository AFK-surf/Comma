defmodule Salix.Bindings.AgentInboundApiKeys do
  @moduledoc """
  `SalixAgent.InboundApiKeyStore` over `Salix.Control.GroupApiKeys`.

  The Router reaches its Group's inbound API keys through here. Every call
  carries the tenant and group the tool resolved from the runtime identity,
  and `GroupApiKeys` re-checks that the group exists under that tenant before
  it reads or writes a record, so a stale runtime context cannot reach another
  workspace's keys.

  A key minted here records `agent:<agent_id>` as its creator, which
  `GroupApiKeys.principal/1` reads as the `system` information-flow creator.
  """

  @behaviour SalixAgent.InboundApiKeyStore

  alias Salix.Control.GroupApiKeys

  @impl true
  def list(tenant, group_id), do: GroupApiKeys.list(group_id, tenant)

  @impl true
  def create(tenant, group_id, agent_id, attrs) when is_map(attrs),
    do: GroupApiKeys.create(group_id, tenant, attrs, "agent:" <> agent_id)

  @impl true
  def disable(tenant, group_id, key_id),
    do: GroupApiKeys.update(group_id, tenant, key_id, %{"status" => "disabled"})

  @impl true
  def delete(tenant, group_id, key_id), do: GroupApiKeys.delete(group_id, tenant, key_id)

  @impl true
  defdelegate post_message_url(group_id), to: Salix.App.RouterInbox
end
