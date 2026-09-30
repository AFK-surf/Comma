defmodule CommaWeb.RecommendationMemberIdentity do
  @moduledoc """
  Resolves a Routine member from an explicit Comma OAuth authorization.

  The caller must authorize the workspace first. A group-visible credential
  does not prove member identity. Legacy and non-Comma connections fail closed.
  No provider request or email/name matching runs on this path.
  """

  alias Salix.Control.OAuthBindings

  def resolve(workspace, user_id, %{"kind" => "managed_oauth", "appId" => provider} = source)
      when provider in ~w(linear github notion slack) do
    with true <- present?(user_id) and workspace["owner_user_id"] == user_id,
         {:ok, binding} <-
           OAuthBindings.get(workspace["default_group_id"], source["connectionId"]),
         true <- binding["tenant_id"] == workspace["salix_tenant_id"],
         true <- binding["group_id"] == workspace["default_group_id"],
         true <- binding["provider"] == provider and binding["alias"] == provider,
         true <- binding["enabled"] != false,
         true <- present?(binding["connection_id"]),
         {:ok, connection} <- SalixStore.OAuth.get(binding["connection_id"]),
         true <- connection["provider"] == provider,
         true <- connection["connection_id"] == binding["connection_id"],
         {:ok, identity} <- from_connection(workspace, user_id, connection) do
      {:ok, Map.put(identity, "binding_id", source["connectionId"])}
    else
      _ -> {:error, :member_identity_unavailable}
    end
  end

  def resolve(_workspace, _user_id, _source), do: {:error, :member_source_unsupported}

  @doc false
  def from_connection(workspace, user_id, connection) do
    # Linear and Notion account IDs can identify a workspace, not a member.
    # OAuthFlow preserves the adapter's metadata under metadata.metadata.
    metadata = get_in(connection, ["metadata", "metadata"]) || %{}

    with true <- present?(user_id) and workspace["owner_user_id"] == user_id,
         true <- connection["tenant"] == workspace["salix_tenant_id"],
         true <- connection["status"] == "active",
         %{"user_id" => ^user_id, "workspace_id" => workspace_id} <- connection["comma_member"],
         true <- present?(workspace_id) and workspace_id == workspace["id"],
         true <- present?(connection["connection_id"]),
         {:ok, provider_identity} <- provider_identity(connection["provider"], metadata) do
      {:ok,
       Map.merge(provider_identity, %{
         "user_id" => user_id,
         "connection_id" => connection["connection_id"]
       })}
    else
      _ -> {:error, :member_identity_unavailable}
    end
  end

  defp provider_identity("linear", %{"actor" => "user"} = metadata),
    do: scoped_identity(metadata["viewer_id"], metadata["workspace_id"])

  defp provider_identity("github", metadata) do
    id = metadata["user_id"]
    login = metadata["login"]

    if is_integer(id) and id > 0 and present?(login),
      do: {:ok, %{"provider_user_id" => Integer.to_string(id), "provider_login" => login}},
      else: {:error, :member_identity_unavailable}
  end

  defp provider_identity("notion", %{"owner" => %{"type" => "user", "user" => user}} = metadata)
       when is_map(user),
       do: scoped_identity(user["id"], metadata["workspace_id"])

  defp provider_identity("slack", metadata),
    do: scoped_identity(metadata["authed_user_id"], metadata["team_id"])

  defp provider_identity(_provider, _metadata), do: {:error, :member_identity_unavailable}

  defp scoped_identity(user_id, workspace_id) do
    if present?(user_id) and present?(workspace_id),
      do: {:ok, %{"provider_user_id" => user_id, "provider_workspace_id" => workspace_id}},
      else: {:error, :member_identity_unavailable}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
