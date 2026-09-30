defmodule BridgeForTeams.OrgOAuthAppsTest do
  @moduledoc """
  Context tests for org-level (tenant-scoped) OAuth provider apps. The happy
  paths exercise the real erpc boundary into the in-process Salix
  Salix control-plane API (backed by the S3 fake); transport/validation handling is
  covered with a swapped-in fake Salix client.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Observability, OrgOAuthApps, Orgs}

  defmodule UnavailableSalixClient do
    @moduledoc false
    def list_oauth_provider_apps(_tenant_id), do: {:error, :unavailable}
    def put_oauth_provider_app(_tenant_id, _provider, _attrs), do: {:error, :timeout}
    def delete_oauth_provider_app(_tenant_id, _provider), do: {:error, :unavailable}
  end

  defmodule SecretCapturingSalixClient do
    @moduledoc false
    # Records the attrs forwarded to Salix so the test can assert blank secrets
    # are dropped (pointer-merge keeps the stored secret).
    def put_oauth_provider_app(_tenant_id, _provider, attrs) do
      send(self(), {:put_attrs, attrs})
      {:ok, %{"provider" => "notion", "client_id" => attrs["client_id"]}}
    end
  end

  setup do
    SalixStore.S3.Fake.reset()
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-oauth"})
    %{org: org}
  end

  defp with_client(mod) do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, mod)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev) end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp app(apps, provider), do: Enum.find(apps, &(&1["provider"] == provider))

  test "lists one view per supported provider, all unconfigured initially", %{org: org} do
    assert {:ok, apps} = OrgOAuthApps.list_org_oauth_apps(org.id)

    providers = apps |> Enum.map(& &1["provider"]) |> Enum.sort()
    assert "notion" in providers
    assert "linear" in providers

    notion = app(apps, "notion")
    assert notion["client_id"] == ""
    assert notion["client_secret_configured"] == false
  end

  test "saves client credentials and surfaces them as configured", %{org: org} do
    assert {:ok, _} =
             OrgOAuthApps.upsert_org_oauth_app(org.id, "notion", %{
               "client_id" => "notion-client-id",
               "client_secret" => "s3cret"
             })

    assert {:ok, apps} = OrgOAuthApps.list_org_oauth_apps(org.id)
    notion = app(apps, "notion")
    assert notion["client_id"] == "notion-client-id"
    assert notion["client_secret_configured"] == true
    # Secret is never reflected back in the list view.
    refute Map.has_key?(notion, "client_secret")
  end

  test "save and delete can record redacted OAuth provider app audit", %{org: org} do
    assert {:ok, _} =
             OrgOAuthApps.upsert_org_oauth_app(
               org.id,
               "notion",
               %{
                 "client_id" => "notion-client-id",
                 "client_secret" => "s3cret"
               },
               actor_label: "owner@example.com"
             )

    assert [saved] =
             Observability.list_audit_logs(org.id, action: "oauth_provider_app.saved")

    assert saved.resource_id == "notion"
    assert saved.metadata["client_id"] == "notion-client-id"
    assert saved.metadata["credential_submitted"] == "true"
    refute inspect(saved) =~ "s3cret"

    assert {:ok, _} =
             OrgOAuthApps.delete_org_oauth_app(org.id, "notion", actor_label: "owner@example.com")

    assert [deleted] =
             Observability.list_audit_logs(org.id, action: "oauth_provider_app.deleted")

    assert deleted.resource_id == "notion"
    assert deleted.redacted_diff["deleted"] == %{"from" => "false", "to" => "true"}
  end

  test "blank secret keeps the existing one (pointer-merge)", %{org: org} do
    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, "linear", %{
        "client_id" => "linear-id",
        "client_secret" => "keep-me"
      })

    # Resubmit a new client_id with a blank secret.
    assert {:ok, _} =
             OrgOAuthApps.upsert_org_oauth_app(org.id, "linear", %{
               "client_id" => "linear-id-2",
               "client_secret" => ""
             })

    assert {:ok, apps} = OrgOAuthApps.list_org_oauth_apps(org.id)
    linear = app(apps, "linear")
    assert linear["client_id"] == "linear-id-2"
    assert linear["client_secret_configured"] == true
  end

  test "drops a blank secret before forwarding to Salix", %{org: org} do
    with_client(SecretCapturingSalixClient)

    assert {:ok, _} =
             OrgOAuthApps.upsert_org_oauth_app(org.id, "notion", %{
               "client_id" => "id",
               "client_secret" => "   "
             })

    assert_received {:put_attrs, attrs}
    refute Map.has_key?(attrs, "client_secret")
    assert attrs["client_id"] == "id"
  end

  test "delete removes the configured credentials and is idempotent", %{org: org} do
    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, "notion", %{
        "client_id" => "id",
        "client_secret" => "secret"
      })

    assert {:ok, _} = OrgOAuthApps.delete_org_oauth_app(org.id, "notion")

    assert {:ok, apps} = OrgOAuthApps.list_org_oauth_apps(org.id)
    assert app(apps, "notion")["client_secret_configured"] == false

    # Deleting again still succeeds.
    assert {:ok, _} = OrgOAuthApps.delete_org_oauth_app(org.id, "notion")
  end

  test "unsupported provider is rejected by Salix", %{org: org} do
    assert {:error, {:bad_request, _msg}} =
             OrgOAuthApps.upsert_org_oauth_app(
               org.id,
               "telegram",
               %{"client_id" => "x", "client_secret" => "oauth-secret"},
               actor_label: "owner@example.com",
               request_id: "req_oauth_provider_failed"
             )

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "oauth_provider_app.saved",
               result: "failed"
             )

    assert audit.resource_id == "telegram"
    assert audit.reason_class == "bad_request"
    assert audit.request_id == "req_oauth_provider_failed"
    assert audit.metadata["write_attempt"] == "true"
    assert audit.metadata["surface"] == "oauth"
    assert audit.metadata["client_id_configured"] == "true"
    assert audit.metadata["credential_submitted"] == "true"

    assert [audit_event] = Observability.list_events(org.id, audit_log_id: audit.id)
    assert audit_event.event_type == "audit.oauth_provider_app.saved"
    assert audit_event.severity == "error"
    assert audit_event.status == "failed"
    assert audit_event.reason_class == "bad_request"
    assert audit_event.correlation_id == "req_oauth_provider_failed"

    assert [event] =
             Observability.list_events(org.id,
               domain: "integration",
               resource_type: "oauth_provider_app"
             )

    assert event.event_type == "oauth.validation.failed"
    assert event.status == "fail"
    assert event.reason_class == "bad_request"
    assert event.evidence["settings_path"] == "settings/oauth"
    assert event.evidence["provider"] == "telegram"
    assert event.evidence["field_errors"]["provider_error_class"] == "bad_request"
    refute inspect([audit, audit_event, event]) =~ "oauth-secret"
  end

  test "missing client_id is rejected", %{org: org} do
    assert {:error, {:bad_request, _msg}} =
             OrgOAuthApps.upsert_org_oauth_app(org.id, "notion", %{"client_id" => ""})
  end

  test "unknown org is rejected before any Salix call", %{} do
    assert {:error, :not_found} =
             OrgOAuthApps.list_org_oauth_apps(Ecto.UUID.generate())
  end

  test "runtime errors surface as tagged errors", %{org: org} do
    with_client(UnavailableSalixClient)

    assert {:error, :unavailable} = OrgOAuthApps.list_org_oauth_apps(org.id)
    assert {:error, :unavailable} = OrgOAuthApps.list_org_oauth_apps(org.id)

    assert [event] =
             Observability.list_events(org.id,
               event_type: "oauth.provider_apps.unavailable",
               resource_type: "oauth_provider_app_index"
             )

    assert event.domain == "integration"
    assert event.source == "salix.control"
    assert event.resource_id == org.id
    assert event.severity == "warning"
    assert event.status == "unavailable"
    assert event.reason_class == "unavailable"
    assert event.correlation_id == "org:#{org.id}:oauth-provider-apps"
    assert event.evidence["settings_path"] == "settings/oauth"
    assert event.evidence["surface"] == "oauth"
    assert event.evidence["status"] == "unavailable"
    refute inspect(event.evidence) =~ "client_secret"

    assert {:error, :timeout} =
             OrgOAuthApps.upsert_org_oauth_app(
               org.id,
               "notion",
               %{"client_id" => "x"},
               actor_label: "owner@example.com",
               request_id: "req_oauth_timeout"
             )

    assert [save_audit] =
             Observability.list_audit_logs(org.id, request_id: "req_oauth_timeout")

    assert save_audit.action == "oauth_provider_app.saved"
    assert save_audit.result == "failed"
    assert save_audit.reason_class == "timeout"

    assert {:error, :unavailable} =
             OrgOAuthApps.delete_org_oauth_app(org.id, "notion",
               actor_label: "owner@example.com",
               request_id: "req_oauth_delete_unavailable"
             )

    assert [delete_audit] =
             Observability.list_audit_logs(org.id, request_id: "req_oauth_delete_unavailable")

    assert delete_audit.action == "oauth_provider_app.deleted"
    assert delete_audit.result == "failed"
    assert delete_audit.reason_class == "unavailable"
  end
end
