defmodule SalixIM.ProviderPrincipalRef do
  @moduledoc """
  Builds the server-sealed member principal carried by trusted IM origins.

  The caller owns authentication of every source value. This module only keeps
  Conversation-backed and direct Router deliveries on one validation and shape
  contract; it never accepts model-authored identity.
  """

  alias SalixStore.Ids

  @type source :: %{
          optional(String.t()) => term()
        }

  @spec seal(source()) :: map() | nil
  def seal(%{"source_actor_type" => "user", "group_id" => group_id, "subject_id" => subject_id})
      when is_binary(group_id) and is_binary(subject_id) and subject_id != "" do
    if Ids.valid_group_id?(group_id),
      do: %{
        "namespace" => "comma_user",
        "tenant_id" => Ids.tenant_id_from_group!(group_id),
        "subject_id" => subject_id
      }
  end

  def seal(
        %{
          "source_actor_type" => "provider_user",
          "provider" => provider,
          "group_id" => group_id,
          "subject_id" => subject_id
        } = source
      )
      when is_binary(provider) and provider != "" and is_binary(subject_id) and subject_id != "" and
             is_binary(group_id) do
    if Ids.valid_group_id?(group_id) do
      %{
        "namespace" => provider <> "_user",
        "tenant_id" => Ids.tenant_id_from_group!(group_id),
        "subject_id" => subject_id
      }
      |> maybe_put_connect_id(source["connect_id"])
    end
  end

  # Slack encodes app-authored messages as system actors in the transport,
  # but their user id is the same membership identity as a person's. Require
  # an actual message event and an exact sender match; lifecycle events and
  # bot-id-only webhook posts do not manufacture a member identity.
  def seal(
        %{
          "source_actor_type" => "provider_system",
          "provider" => "slack",
          "subject_id" => user_id,
          "provider_context" => %{"event_type" => event_type, "user_id" => user_id}
        } = source
      )
      when event_type in ["message", "app_mention"] and is_binary(user_id) and user_id != "" do
    seal(Map.put(source, "source_actor_type", "provider_user"))
  end

  def seal(_source), do: nil

  @doc "Seal a provider principal only when its exact inbound connect is present."
  @spec seal_connected(source()) :: map() | nil
  def seal_connected(%{"connect_id" => connect_id} = source)
      when is_binary(connect_id) and connect_id != "",
      do: seal(source)

  def seal_connected(_source), do: nil

  defp maybe_put_connect_id(principal, connect_id)
       when is_binary(connect_id) and connect_id != "",
       do: Map.put(principal, "connect_id", connect_id)

  defp maybe_put_connect_id(principal, _connect_id), do: principal
end
