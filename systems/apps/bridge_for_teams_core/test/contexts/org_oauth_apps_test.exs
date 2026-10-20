defmodule BridgeForTeams.OrgOAuthAppsTest do
  @moduledoc """
  Context tests for org-level (tenant-scoped) OAuth provider apps. The happy
  paths exercise the real erpc boundary into the in-process Salix
  Salix control-plane API (backed by the S3 fake); transport/validation handling is
  covered with a swapped-in fake Salix client.
  """
  use BridgeForTeams.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]

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
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:put_attrs, attrs})
      {:ok, %{"provider" => "notion", "client_id" => attrs["client_id"]}}
    end
  end

  setup do
    SalixStore.S3.Fake.reset()
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-oauth"})
    %{org: org}
  end
  defp app(apps, provider), do: Enum.find(apps, &(&1["provider"] == provider))

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

  test "unknown org is rejected before any Salix call", %{} do
    assert {:error, :not_found} =
             OrgOAuthApps.list_org_oauth_apps(SystemsRuntime.Proc.uuid())
  end
end
