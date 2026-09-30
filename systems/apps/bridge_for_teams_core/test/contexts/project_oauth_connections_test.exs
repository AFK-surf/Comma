defmodule BridgeForTeams.ProjectOAuthConnectionsTest do
  @moduledoc """
  Context tests for project-scoped OAuth account connections. The happy paths
  exercise the real erpc boundary into the in-process Salix control-plane /
  `OAuthFlow` (backed by the S3 fake); authorization and transport handling is
  covered with swapped-in fake Salix clients. Connected-account reads/deletes
  are checked against Salix bindings seeded directly through the control store
  (the provider HTTP token exchange is Salix's concern, not BridgeForTeams's).
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Observability, OrgOAuthApps, Orgs, Projects, ProjectOAuthConnections}

  defmodule UnavailableSalixClient do
    @moduledoc false
    def list_oauth_provider_apps(_tenant_id), do: {:error, :unavailable}
    def list_group_oauth_bindings(_group_id), do: {:error, :unavailable}
  end

  setup do
    SalixStore.S3.Fake.reset()
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-proj-oauth"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    %{org: org, project: project}
  end

  defp with_client(mod) do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, mod)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev) end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp configure_provider(org, provider) do
    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, provider, %{
        "client_id" => "#{provider}-client-id",
        "client_secret" => "#{provider}-secret"
      })
  end

  # Seed a connected account the way Salix's OAuth callback would: a connection
  # record (holding the tokens) plus a (group, provider, alias) binding pointing
  # at it. BridgeForTeams only ever reads the token-free joined view.
  defp seed_connection(org, project, provider, alias_name, account_name \\ "Test Account") do
    connection_id = "conn-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    :ok =
      SalixStore.OAuth.put(connection_id, %{
        "connection_id" => connection_id,
        "tenant" => org.salix_tenant_id,
        "provider" => provider,
        "provider_account_id" => "acct-123",
        "provider_account_name" => account_name,
        "access_token" => "secret-access-token",
        "refresh_token" => "secret-refresh-token",
        "scopes" => ["read"],
        "status" => "active",
        "created_at" => 1,
        "updated_at" => 1
      })

    {:ok, binding, _prev} =
      Salix.Control.OAuthBindings.put(
        org.salix_tenant_id,
        project.salix_group_id,
        provider,
        alias_name,
        connection_id
      )

    binding
  end

  defp provider!(apps, provider) do
    Enum.find(apps, &(&1["provider"] == provider)) ||
      flunk(
        "expected provider #{inspect(provider)} in #{inspect(Enum.map(apps, & &1["provider"]))}"
      )
  end

  describe "list_available_providers/1" do
    test "surfaces supported providers before tenant OAuth app setup", %{org: org} do
      assert {:ok, apps} = ProjectOAuthConnections.list_available_providers(org.id)
      assert Enum.map(apps, & &1["provider"]) == ProjectOAuthConnections.providers()

      assert Enum.all?(apps, fn app ->
               app["authorization_configured"] == false and
                 app["can_request_authorization"] == false
             end)
    end

    test "marks configured tenant OAuth apps as authorization-ready", %{org: org} do
      configure_provider(org, "notion")

      assert {:ok, apps} = ProjectOAuthConnections.list_available_providers(org.id)
      notion = provider!(apps, "notion")
      assert notion["provider"] == "notion"
      assert notion["client_id"] == "notion-client-id"
      assert notion["client_secret_configured"] == true
      assert notion["authorization_configured"] == true
      assert notion["can_request_authorization"] == true
      # Secrets are never reflected back.
      refute Map.has_key?(notion, "client_secret")

      configure_provider(org, "linear")
      assert {:ok, apps} = ProjectOAuthConnections.list_available_providers(org.id)
      assert provider!(apps, "linear")["authorization_configured"] == true
      assert provider!(apps, "github")["authorization_configured"] == false
    end

    test "a platform default makes the provider authorization-ready without tenant credentials",
         %{
           org: org
         } do
      {:ok, _} =
        Salix.Control.OAuthApps.put_default("notion", %{
          "client_id" => "platform-notion",
          "client_secret" => "platform-secret"
        })

      on_exit(fn -> Salix.Control.OAuthApps.delete_default("notion") end)

      assert {:ok, apps} = ProjectOAuthConnections.list_available_providers(org.id)
      notion = provider!(apps, "notion")
      assert notion["provider"] == "notion"
      assert notion["source"] == "default"
      assert notion["authorization_configured"] == true
      assert notion["can_request_authorization"] == true
      # The org typed nothing; only the public default client id is advertised.
      assert notion["client_id"] == ""
      assert notion["default_client_id"] == "platform-notion"

      # Tenant credentials flip the source back to the org's own app.
      configure_provider(org, "notion")
      assert {:ok, apps} = ProjectOAuthConnections.list_available_providers(org.id)
      notion = provider!(apps, "notion")
      assert notion["source"] == "tenant"
      assert notion["client_id"] == "notion-client-id"
    end

    test "unknown org is rejected before any Salix call" do
      assert {:error, :not_found} =
               ProjectOAuthConnections.list_available_providers(Ecto.UUID.generate())
    end

    test "runtime errors surface as tagged errors", %{org: org} do
      with_client(UnavailableSalixClient)
      assert {:error, :unavailable} = ProjectOAuthConnections.list_available_providers(org.id)
    end
  end

  describe "list_connections/2" do
    test "is empty for a fresh project", %{org: org, project: project} do
      assert {:ok, []} = ProjectOAuthConnections.list_connections(org.id, project.id)

      assert [] =
               Observability.list_events(org.id,
                 event_type: "project.oauth_connections.unavailable"
               )
    end

    test "returns the project group's bindings as token-free views", %{org: org, project: project} do
      seed_connection(org, project, "notion", "Work", "Acme Workspace")

      assert {:ok, [binding]} = ProjectOAuthConnections.list_connections(org.id, project.id)
      assert binding["provider"] == "notion"
      assert binding["alias"] == "Work"
      assert binding["provider_account_name"] == "Acme Workspace"
      assert binding["scopes"] == ["read"]
      refute Map.has_key?(binding, "access_token")
      refute Map.has_key?(binding, "refresh_token")
    end

    test "cross-org project is rejected", %{project: project} do
      {:ok, other_org} = Orgs.create_org(%{name: "Other", slug: "other-proj-oauth"})

      assert {:error, :not_found} =
               ProjectOAuthConnections.list_connections(other_org.id, project.id)
    end

    test "runtime errors surface as tagged errors", %{org: org, project: project} do
      with_client(UnavailableSalixClient)
      assert {:error, :unavailable} = ProjectOAuthConnections.list_connections(org.id, project.id)
      assert {:error, :unavailable} = ProjectOAuthConnections.list_connections(org.id, project.id)

      assert [event] =
               Observability.list_events(org.id,
                 event_type: "project.oauth_connections.unavailable",
                 resource_type: "project_oauth_connection_index"
               )

      assert event.domain == "integration"
      assert event.source == "salix.control"
      assert event.project_id == project.id
      assert event.resource_id == project.id
      assert event.severity == "warning"
      assert event.status == "unavailable"
      assert event.reason_class == "unavailable"
      assert event.correlation_id == "project:#{project.id}:oauth-connections"
      assert event.evidence["project_id"] == project.id
      assert event.evidence["salix_group_id"] == project.salix_group_id
      assert event.evidence["surface"] == "project_integrations"
      assert event.evidence["status"] == "unavailable"
      refute inspect(event.evidence) =~ "access_token"
      refute inspect(event.evidence) =~ "refresh_token"
    end
  end

  describe "enable_connection/4 and disable_connection/4" do
    test "toggle credential availability without deleting the binding or token", %{
      org: org,
      project: project
    } do
      binding = seed_connection(org, project, "notion", "Work")
      binding_id = binding["binding_id"]
      connection_id = binding["connection_id"]

      assert {:ok, [listed]} = ProjectOAuthConnections.list_connections(org.id, project.id)
      assert listed["binding_id"] == binding_id
      assert listed["connection_id"] == connection_id
      assert listed["enabled"] == true
      assert listed["status"] == "active"

      assert {:ok, _} =
               ProjectOAuthConnections.disable_connection(
                 org.id,
                 project.id,
                 binding_id,
                 actor_label: "project-admin@example.com",
                 request_id: "req_project_oauth_disable"
               )

      assert {:ok, [disabled]} = ProjectOAuthConnections.list_connections(org.id, project.id)
      assert disabled["binding_id"] == binding_id
      assert disabled["connection_id"] == connection_id
      assert disabled["enabled"] == false
      assert disabled["status"] == "disabled"
      assert {:ok, _connection} = SalixStore.OAuth.get(connection_id)

      assert {:ok, _} =
               ProjectOAuthConnections.enable_connection(
                 org.id,
                 project.id,
                 binding_id,
                 actor_label: "project-admin@example.com",
                 request_id: "req_project_oauth_enable"
               )

      assert {:ok, [enabled]} = ProjectOAuthConnections.list_connections(org.id, project.id)
      assert enabled["binding_id"] == binding_id
      assert enabled["connection_id"] == connection_id
      assert enabled["enabled"] == true
      assert enabled["status"] == "active"

      assert [disable_audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_oauth_connection.disabled"
               )

      assert disable_audit.result == "ok"
      assert disable_audit.request_id == "req_project_oauth_disable"
      assert disable_audit.resource_id == binding_id
      assert disable_audit.metadata["enabled"] == "false"

      assert [enable_audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_oauth_connection.enabled"
               )

      assert enable_audit.result == "ok"
      assert enable_audit.request_id == "req_project_oauth_enable"
      assert enable_audit.resource_id == binding_id
      assert enable_audit.metadata["enabled"] == "true"
    end
  end

  describe "start_connection/4" do
    test "rejects a provider the tenant has not configured", %{org: org, project: project} do
      assert {:error, :provider_not_configured} =
               ProjectOAuthConnections.start_connection(org.id, project.id, "notion", %{})
    end

    test "rejects an unsupported provider", %{org: org, project: project} do
      assert {:error, :unsupported_provider} =
               ProjectOAuthConnections.start_connection(
                 org.id,
                 project.id,
                 "telegram",
                 %{},
                 actor_label: "project-admin@example.com",
                 request_id: "req_project_oauth_unsupported"
               )

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_oauth_connection.authorization_started"
               )

      assert audit.result == "failed"
      assert audit.reason_class == "unsupported_provider"
      assert audit.resource_type == "project_oauth_connection"
      assert audit.resource_id == "telegram"
      assert audit.metadata["project_id"] == project.id
      assert audit.metadata["provider"] == "telegram"
    end

    test "capability-derived scopes ride the authorization request", %{
      org: org,
      project: project
    } do
      configure_provider(org, "google")

      capabilities = %{"inbox.draft_replies" => true, "meetings.meeting_briefing" => true}

      assert {:ok, %{"authorization_url" => url}} =
               ProjectOAuthConnections.start_connection(
                 org.id,
                 project.id,
                 "google",
                 %{
                   "alias" => "Work",
                   "scopes" => BridgeForTeams.ProviderScopes.scopes("google", capabilities)
                 }
               )

      scope_param =
        url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("scope", "")

      requested = String.split(scope_param, " ", trim: true)

      assert "https://www.googleapis.com/auth/gmail.drafts.create" in requested
      assert "https://www.googleapis.com/auth/gmail.readonly" in requested
      assert "https://www.googleapis.com/auth/calendar.readonly" in requested
      # The adapter keeps its identity floor and nothing send-capable sneaks in.
      assert "openid" in requested
      refute Enum.any?(requested, &String.contains?(&1, "compose"))

      # No scopes attr (or none derived) keeps identity-only consent.
      assert {:ok, %{"authorization_url" => bare_url}} =
               ProjectOAuthConnections.start_connection(org.id, project.id, "google", %{
                 "alias" => "Bare"
               })

      bare_scope =
        bare_url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("scope", "")

      refute bare_scope =~ "gmail"
    end

    test "builds an authorization URL for a configured provider", %{org: org, project: project} do
      configure_provider(org, "notion")

      assert {:ok, %{"authorization_url" => url, "state" => state}} =
               ProjectOAuthConnections.start_connection(
                 org.id,
                 project.id,
                 "notion",
                 %{
                   "alias" => "Work",
                   "redirect_after" =>
                     "https://teams.example.test/orgs/acme/projects/x/connections"
                 },
                 actor_label: "project-admin@example.com",
                 request_id: "req_project_oauth_start"
               )

      assert is_binary(state) and state != ""
      assert url =~ "notion-client-id"
      assert url =~ "state=#{state}"

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_oauth_connection.authorization_started"
               )

      assert audit.result == "ok"
      assert audit.request_id == "req_project_oauth_start"
      assert audit.actor_label == "project-admin@example.com"
      assert audit.resource_type == "project_oauth_connection"
      assert audit.resource_id == "notion"
      assert audit.resource_label == "#{project.name}: notion"
      assert audit.metadata["provider"] == "notion"
      assert audit.metadata["alias_configured"] == "true"
      assert audit.metadata["redirect_after_configured"] == "true"
      refute inspect(audit) =~ "authorization_url"

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.domain == "audit"
      assert event.correlation_id == "req_project_oauth_start"
    end
  end

  describe "delete_connection/3" do
    test "disconnects an existing binding", %{org: org, project: project} do
      binding = seed_connection(org, project, "notion", "Work")
      assert {:ok, [_]} = ProjectOAuthConnections.list_connections(org.id, project.id)

      assert {:ok, _} =
               ProjectOAuthConnections.delete_connection(
                 org.id,
                 project.id,
                 binding["binding_id"],
                 actor_label: "project-admin@example.com",
                 request_id: "req_project_oauth_delete"
               )

      assert {:ok, []} = ProjectOAuthConnections.list_connections(org.id, project.id)

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_oauth_connection.deleted"
               )

      assert audit.result == "ok"
      assert audit.request_id == "req_project_oauth_delete"
      assert audit.resource_id == binding["binding_id"]
      assert audit.metadata["binding_id"] == binding["binding_id"]
    end

    test "deleting an unknown binding is reported as not found", %{org: org, project: project} do
      assert {:error, :not_found} =
               ProjectOAuthConnections.delete_connection(
                 org.id,
                 project.id,
                 "oauth-missing",
                 actor_label: "project-admin@example.com",
                 request_id: "req_project_oauth_delete_missing"
               )

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_oauth_connection.deleted"
               )

      assert audit.result == "failed"
      assert audit.reason_class == "not_found"
      assert audit.request_id == "req_project_oauth_delete_missing"
      assert audit.resource_id == "oauth-missing"
      assert audit.metadata["binding_id"] == "oauth-missing"
    end
  end
end
