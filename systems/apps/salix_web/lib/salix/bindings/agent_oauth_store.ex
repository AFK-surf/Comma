defmodule Salix.Bindings.AgentOAuthStore do
  @moduledoc false

  require SystemsClock

  @behaviour SalixAgent.OAuthStore

  @impl true
  def agent_oauth_context(agent_id), do: SalixWeb.OAuthStore.agent_oauth_context(agent_id)

  @impl true
  def provider_app(tenant, provider), do: SalixWeb.OAuthStore.provider_app(tenant, provider)

  @impl true
  def source_app(tenant, provider, source),
    do: SalixWeb.OAuthFlow.source_app(tenant, provider, source)

  @impl true
  def bindings_for_group(group_id), do: SalixWeb.OAuthStore.bindings_for_group(group_id)

  @impl true
  def public_base_url, do: SalixWeb.OAuthStore.public_base_url()

  @impl true
  def define_provider(tenant, provider, attrs),
    do: Salix.Control.OAuthApps.put_custom(tenant, provider, attrs)

  @impl true
  def poll_device(record), do: SalixWeb.OAuthFlow.poll_device(record)

  @impl true
  def latest_message(group_id, conversation_id) do
    case SalixWeb.StationTasks.last_message(group_id, conversation_id) do
      {:ok, %{"message_id" => message_id}} -> message_id
      _none -> nil
    end
  end

  @impl true
  def own_provider_app?(tenant, provider),
    do: match?({:ok, _app}, Salix.Control.OAuthApps.get_own(tenant, provider))

  # Subscribed before it reads: an ending meanwhile is read or arrives as an event.
  @impl true
  def await_request(%{"group_id" => group, "tenant_id" => tenant, "request_id" => id}, wait_ms) do
    topic = SalixAgent.CapabilityRequests.topic(group)
    :ok = Phoenix.PubSub.subscribe(SalixWeb.PubSub, topic)
    deadline = SystemsClock.monotonic_time(:millisecond) + wait_ms

    try do
      await_ended(group, tenant, id, deadline)
    after
      Phoenix.PubSub.unsubscribe(SalixWeb.PubSub, topic)
    end
  end

  defp await_ended(group, tenant, id, deadline) do
    case SalixAgent.CapabilityRequests.get(group, id, tenant) do
      {:ok, %{"status" => "pending"} = request} ->
        left = deadline - SystemsClock.monotonic_time(:millisecond)

        if left <= 0 do
          {:ok, request}
        else
          SystemsClock.vreceive do
            {:capability_request_event, ^group, ^id} -> await_ended(group, tenant, id, deadline)
          after
            left -> await_ended(group, tenant, id, deadline)
          end
        end

      other ->
        other
    end
  end

  @impl true
  def remote_mcp_token(tenant, connection_id),
    do: Salix.Control.RemoteMCPOAuth.connection_token(tenant, connection_id)

  @impl true
  def delete_binding(tenant, group_id, binding_id),
    do: SalixWeb.OAuthStore.delete_binding(tenant, group_id, binding_id)
end
