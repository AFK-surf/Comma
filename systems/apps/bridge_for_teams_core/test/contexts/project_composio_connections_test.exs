defmodule BridgeForTeams.ProjectComposioConnectionsTest do
  @moduledoc """
  Context tests for project-scoped Composio connections. The happy paths
  exercise the real erpc boundary into the in-process `Salix.Composio` helper
  (tenant settings from the S3 fake, the HTTP client stubbed via
  `:composio_client_mod`); transport handling uses a swapped-in fake Salix
  client.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{OrgComposioSettings, Orgs, ProjectComposioConnections, Projects}

  defmodule StubComposioHttpClient do
    @moduledoc "Stub for SalixStore.Composio, wired via :salix_web :composio_client_mod."

    def list_connected_accounts(_settings, user_id) do
      {:ok,
       [
         %{
           "id" => "ca_1",
           "user_id" => user_id,
           "toolkit" => %{"slug" => "gmail"},
           "status" => "ACTIVE"
         }
       ]}
    end

    def ensure_auth_config(_settings, toolkit), do: {:ok, "ac_" <> toolkit}

    def create_connect_link(settings, auth_config_id, user_id, opts \\ []) do
      send(Application.get_env(:bridge_for_teams_core, :composio_test_pid), {
        :connect_link,
        settings,
        auth_config_id,
        user_id,
        opts
      })

      {:ok,
       %{
         "redirect_url" => "https://connect.composio.dev/link/lk_test",
         "connected_account_id" => "ca_new"
       }}
    end

    def get_connected_account(_settings, id),
      do: {:ok, %{"id" => id, "user_id" => "someone-else", "status" => "ACTIVE"}}

    def delete_connected_account(_settings, _id), do: :ok
  end

  defmodule UnavailableSalixClient do
    @moduledoc false
    def list_composio_connected_accounts(_tenant_id, _group_id), do: {:error, :unavailable}

    def create_composio_connect_link(_tenant_id, _group_id, _toolkit, _attrs),
      do: {:error, :timeout}
  end

  setup do
    SalixStore.S3.Fake.reset()

    prev_http = Application.get_env(:salix_web, :composio_client_mod)
    Application.put_env(:salix_web, :composio_client_mod, StubComposioHttpClient)
    Application.put_env(:bridge_for_teams_core, :composio_test_pid, self())

    on_exit(fn ->
      if prev_http do
        Application.put_env(:salix_web, :composio_client_mod, prev_http)
      else
        Application.delete_env(:salix_web, :composio_client_mod)
      end

      Application.delete_env(:bridge_for_teams_core, :composio_test_pid)
    end)

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-composio-conn"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "P", "slug" => "p"})
    %{org: org, project: project}
  end

  defp with_salix_client(mod) do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, mod)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)
  end

  test "configured? follows org settings including the platform default", %{org: org} do
    refute ProjectComposioConnections.configured?(org.id)

    {:ok, _} = OrgComposioSettings.upsert_org_composio_settings(org.id, %{"api_key" => "ck_org"})
    assert ProjectComposioConnections.configured?(org.id)
  end

  test "list_connections returns the group's accounts through the real chain", %{
    org: org,
    project: project
  } do
    {:ok, _} = OrgComposioSettings.upsert_org_composio_settings(org.id, %{"api_key" => "ck_org"})

    assert {:ok, [account]} = ProjectComposioConnections.list_connections(org.id, project.id)
    assert account["toolkit"]["slug"] == "gmail"
    assert account["user_id"] == project.salix_group_id
    assert ProjectComposioConnections.connection_active?(account)
    assert ProjectComposioConnections.connection_toolkit(account) == "gmail"
  end

  test "list_connections without org settings is :not_configured", %{
    org: org,
    project: project
  } do
    assert {:error, :not_configured} =
             ProjectComposioConnections.list_connections(org.id, project.id)
  end

  test "start_connection creates a connect link keyed by the project group", %{
    org: org,
    project: project
  } do
    {:ok, _} = OrgComposioSettings.upsert_org_composio_settings(org.id, %{"api_key" => "ck_org"})

    assert {:ok, %{"redirect_url" => "https://connect.composio.dev/link/lk_test"}} =
             ProjectComposioConnections.start_connection(
               org.id,
               project.id,
               "Gmail",
               %{"callback_url" => "https://bft.example/onboarding/integrations"}
             )

    assert_received {:connect_link, settings, "ac_gmail", user_id, opts}
    assert settings["api_key"] == "ck_org"
    assert user_id == project.salix_group_id
    assert opts[:callback_url] == "https://bft.example/onboarding/integrations"
  end

  test "start_connection audits when an actor is given", %{org: org, project: project} do
    {:ok, _} = OrgComposioSettings.upsert_org_composio_settings(org.id, %{"api_key" => "ck_org"})

    assert {:ok, _} =
             ProjectComposioConnections.start_connection(org.id, project.id, "gmail", %{},
               actor_label: "admin@acme.test"
             )

    assert [audit] =
             BridgeForTeams.Observability.list_audit_logs(org.id,
               action: "project_composio_connection.authorization_started"
             )

    assert audit.resource_id == "gmail"
  end

  test "delete_connection refuses accounts owned by another group", %{
    org: org,
    project: project
  } do
    {:ok, _} = OrgComposioSettings.upsert_org_composio_settings(org.id, %{"api_key" => "ck_org"})

    # The stub's get_connected_account reports a foreign user_id.
    assert {:error, :not_found} =
             ProjectComposioConnections.delete_connection(org.id, project.id, "ca_foreign")
  end

  test "a blank toolkit is rejected before any call", %{org: org, project: project} do
    assert {:error, :toolkit_required} =
             ProjectComposioConnections.start_connection(org.id, project.id, "  ")
  end

  test "transport errors pass through tagged", %{org: org, project: project} do
    with_salix_client(UnavailableSalixClient)

    assert {:error, :unavailable} =
             ProjectComposioConnections.list_connections(org.id, project.id)

    assert {:error, :timeout} =
             ProjectComposioConnections.start_connection(org.id, project.id, "gmail")
  end

  test "unknown project or mismatched org is :not_found", %{org: org} do
    {:ok, other_org} = Orgs.create_org(%{name: "Other", slug: "other-composio-conn"})
    {:ok, other_project} = Projects.create_project(other_org.id, %{"name" => "Q", "slug" => "q"})

    assert {:error, :not_found} =
             ProjectComposioConnections.list_connections(org.id, other_project.id)
  end
end
