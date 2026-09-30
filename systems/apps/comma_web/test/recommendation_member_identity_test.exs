defmodule CommaWeb.RecommendationMemberIdentityTest do
  use ExUnit.Case, async: false

  alias CommaWeb.RecommendationMemberIdentity, as: Identity

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :s3_backend, previous),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    :ok
  end

  test "resolution follows the live binding and rejects disablement or another account owner" do
    {workspace, connection} = fixture()
    workspace = Map.put(workspace, "default_group_id", "group-1")
    assert :ok = SalixStore.OAuth.put("conn-1", connection)

    assert {:ok, binding, nil} =
             Salix.Control.OAuthBindings.put("tenant-1", "group-1", "linear", "linear", "conn-1")

    source = %{
      "kind" => "managed_oauth",
      "appId" => "linear",
      "connectionId" => binding["binding_id"]
    }

    assert {:ok, %{"connection_id" => "conn-1"}} = Identity.resolve(workspace, "user-1", source)

    key = SalixStore.Keys.ctl_oauth_group_binding("group-1", binding["binding_id"])
    assert {:ok, _} = Salix.Control.Store.update_record(key, &Map.put(&1, "enabled", false))
    assert {:error, :member_identity_unavailable} = Identity.resolve(workspace, "user-1", source)
    assert {:ok, _} = Salix.Control.Store.update_record(key, &Map.put(&1, "enabled", true))

    replacement =
      connection
      |> Map.put("connection_id", "conn-2")
      |> put_in(["comma_member", "user_id"], "other-member")

    assert :ok = SalixStore.OAuth.put("conn-2", replacement)

    assert {:ok, _, "conn-1"} =
             Salix.Control.OAuthBindings.put("tenant-1", "group-1", "linear", "linear", "conn-2")

    assert {:error, :member_identity_unavailable} = Identity.resolve(workspace, "user-1", source)
  end

  test "uses the verified Linear viewer, never the organization account id" do
    {workspace, connection} = fixture()
    assert {:ok, identity} = Identity.from_connection(workspace, "user-1", connection)
    assert identity["provider_user_id"] == "viewer-1"
    assert identity["provider_workspace_id"] == "linear-org"
    assert identity["connection_id"] == "conn-1"
  end

  test "does not infer the member from a shared or legacy connection" do
    {workspace, connection} = fixture()

    assert {:error, :member_identity_unavailable} =
             Identity.from_connection(workspace, "user-1", Map.delete(connection, "comma_member"))

    other = put_in(connection, ["comma_member", "user_id"], "other-member")

    assert {:error, :member_identity_unavailable} =
             Identity.from_connection(workspace, "user-1", other)

    assert {:error, :member_identity_unavailable} =
             Identity.from_connection(workspace, "other-member", connection)
  end

  test "rejects cross-workspace, cross-tenant, revoked and incomplete identity" do
    {workspace, connection} = fixture()

    for invalid <- [
          put_in(connection, ["comma_member", "workspace_id"], "other-workspace"),
          Map.put(connection, "tenant", "other-tenant"),
          Map.put(connection, "status", "revoked"),
          put_in(connection, ["metadata", "metadata", "viewer_id"], nil),
          put_in(connection, ["metadata", "metadata", "workspace_id"], ""),
          put_in(connection, ["metadata", "metadata", "actor"], "app")
        ] do
      assert {:error, :member_identity_unavailable} =
               Identity.from_connection(workspace, "user-1", invalid)
    end
  end

  test "GitHub uses the numeric account identity and its query login" do
    {workspace, connection} = fixture()

    connection =
      connection
      |> Map.put("provider", "github")
      |> Map.put("metadata", %{"metadata" => %{"user_id" => 123, "login" => "octocat"}})

    assert {:ok, %{"provider_user_id" => "123", "provider_login" => "octocat"}} =
             Identity.from_connection(workspace, "user-1", connection)

    assert {:error, :member_identity_unavailable} =
             Identity.from_connection(
               workspace,
               "user-1",
               put_in(connection, ["metadata", "metadata", "user_id"], nil)
             )
  end

  test "Notion requires an explicit user owner, not its bot or workspace id" do
    {workspace, connection} = fixture()

    metadata = %{
      "workspace_id" => "notion-workspace",
      "bot_id" => "bot-1",
      "owner" => %{"type" => "user", "user" => %{"id" => "notion-user"}}
    }

    connection =
      connection
      |> Map.put("provider", "notion")
      |> Map.put("metadata", %{"metadata" => metadata})

    assert {:ok,
            %{"provider_user_id" => "notion-user", "provider_workspace_id" => "notion-workspace"}} =
             Identity.from_connection(workspace, "user-1", connection)

    assert {:error, :member_identity_unavailable} =
             Identity.from_connection(
               workspace,
               "user-1",
               put_in(connection, ["metadata", "metadata", "owner"], %{"type" => "workspace"})
             )
  end

  defp fixture do
    {%{"id" => "workspace-1", "owner_user_id" => "user-1", "salix_tenant_id" => "tenant-1"},
     %{
       "connection_id" => "conn-1",
       "tenant" => "tenant-1",
       "provider" => "linear",
       "provider_account_id" => "linear-org",
       "status" => "active",
       "comma_member" => %{"user_id" => "user-1", "workspace_id" => "workspace-1"},
       "metadata" => %{
         "metadata" => %{
           "viewer_id" => "viewer-1",
           "workspace_id" => "linear-org",
           "actor" => "user"
         }
       }
     }}
  end
end
