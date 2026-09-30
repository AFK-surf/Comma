defmodule BridgeForTeams.OrgComposioSettingsTest do
  @moduledoc """
  Context tests for org-level (tenant-scoped) Composio settings. The happy
  paths exercise the real erpc boundary into the in-process Salix
  control-plane API (backed by the S3 fake); transport handling and write-only
  key forwarding are covered with swapped-in fake Salix clients.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{OrgComposioSettings, Orgs}

  defmodule UnavailableSalixClient do
    @moduledoc false
    def get_composio_settings(_tenant_id), do: {:error, :unavailable}
    def put_composio_settings(_tenant_id, _attrs), do: {:error, :timeout}
    def delete_composio_settings(_tenant_id), do: {:error, :unavailable}
  end

  defmodule KeyCapturingSalixClient do
    @moduledoc false
    # Records the attrs forwarded to Salix so the test can assert blank keys
    # are dropped (pointer-merge keeps the stored key).
    def put_composio_settings(_tenant_id, attrs) do
      send(self(), {:put_attrs, attrs})
      {:ok, %{"enabled" => true, "api_key_configured" => true, "base_url" => ""}}
    end
  end

  setup do
    SalixStore.S3.Fake.reset()
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-composio"})
    %{org: org}
  end

  defp with_client(mod) do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, mod)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev) end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  test "unconfigured org reads as not configured, source none", %{org: org} do
    assert {:ok, view} = OrgComposioSettings.get_org_composio_settings(org.id)
    assert view["enabled"] == false
    assert view["api_key_configured"] == false
    assert view["source"] == "none"
  end

  test "saves settings, reads back redacted, and deletes", %{org: org} do
    assert {:ok, view} =
             OrgComposioSettings.upsert_org_composio_settings(org.id, %{
               "api_key" => "ck_org_key",
               "enabled" => "true"
             })

    refute Map.has_key?(view, "api_key")
    assert view["api_key_configured"] == true

    assert {:ok, view} = OrgComposioSettings.get_org_composio_settings(org.id)
    assert view["enabled"] == true
    assert view["source"] == "tenant"

    assert {:ok, :ok} = OrgComposioSettings.delete_org_composio_settings(org.id)

    assert {:ok, view} = OrgComposioSettings.get_org_composio_settings(org.id)
    assert view["api_key_configured"] == false
  end

  test "a first save without an api_key is rejected by Salix", %{org: org} do
    assert {:error, {:bad_request, message}} =
             OrgComposioSettings.upsert_org_composio_settings(org.id, %{"enabled" => "true"})

    assert message =~ "api_key is required"
  end

  test "a blank api_key is dropped so the stored key is kept", %{org: org} do
    with_client(KeyCapturingSalixClient)

    assert {:ok, _} =
             OrgComposioSettings.upsert_org_composio_settings(org.id, %{
               "api_key" => "   ",
               "base_url" => " https://eu.example ",
               "enabled" => "true"
             })

    assert_received {:put_attrs, attrs}
    refute Map.has_key?(attrs, "api_key")
    assert attrs["base_url"] == "https://eu.example"
    assert attrs["enabled"] == true
  end

  test "runtime unavailability surfaces as tagged errors", %{org: org} do
    with_client(UnavailableSalixClient)

    assert {:error, :unavailable} = OrgComposioSettings.get_org_composio_settings(org.id)

    assert {:error, :timeout} =
             OrgComposioSettings.upsert_org_composio_settings(org.id, %{"api_key" => "k"})

    assert {:error, :unavailable} = OrgComposioSettings.delete_org_composio_settings(org.id)
  end

  test "unknown org id is an error" do
    assert {:error, _} =
             OrgComposioSettings.get_org_composio_settings(Ecto.UUID.generate())
  end
end
