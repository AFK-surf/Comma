defmodule Salix.Control.ComposioSettingsTest do
  @moduledoc """
  Tenant Composio settings control plane: tenant-first resolution with
  deployment-default fallback (mirroring `Salix.Control.OAuthApps`),
  write-only api_key semantics (redacted views, keep-on-omit updates),
  the enabled flag, and delete. Storage is Postgres (SalixStore.ComposioSettings).
  """
  # Shares the node-global composio_settings table; keep serial.
  use ExUnit.Case, async: false

  alias Salix.Control.ComposioSettings

  @tenant "tenant-composio-test"

  setup do
    SalixStore.Repo.query!("TRUNCATE composio_settings")
    :ok
  end

  test "a Postgres fault reads as :unavailable, and the view degrades to none" do
    # Make every read of the table fault by renaming it away; RENAME preserves
    # the exact schema for a clean restore. Both the tenant lookup and the
    # default fallback query hit the same table, so a fault surfaces on whichever
    # query runs first.
    SalixStore.Repo.query!("ALTER TABLE composio_settings RENAME TO composio_settings_tmp")

    on_exit(fn ->
      SalixStore.Repo.query!("ALTER TABLE composio_settings_tmp RENAME TO composio_settings")
    end)

    # Hot resolve paths surface a structured error, never an unhandled Postgrex crash.
    assert {:error, :unavailable} = ComposioSettings.get(@tenant)
    assert {:error, :unavailable} = ComposioSettings.get_default()

    # Redacted views degrade to "none" instead of crashing the dashboard/API.
    assert %{"source" => "none", "api_key_configured" => false} = ComposioSettings.view(@tenant)
    assert %{"api_key_configured" => false} = ComposioSettings.view_default()
  end

  test "unconfigured tenant is :not_configured with source none" do
    assert {:error, :not_configured} = ComposioSettings.get(@tenant)

    assert %{"source" => "none", "enabled" => false, "api_key_configured" => false} =
             ComposioSettings.view(@tenant)
  end

  test "tenant record wins and the api key never appears in views" do
    assert {:ok, view} =
             ComposioSettings.put(@tenant, %{"api_key" => "ck_tenant", "base_url" => ""})

    refute Map.has_key?(view, "api_key")
    assert view["api_key_configured"]
    assert view["enabled"]

    assert {:ok, %{"api_key" => "ck_tenant"}} = ComposioSettings.get(@tenant)
    assert %{"source" => "tenant"} = ComposioSettings.view(@tenant)
  end

  test "updating without api_key keeps the stored secret" do
    {:ok, _} = ComposioSettings.put(@tenant, %{"api_key" => "ck_tenant"})
    assert {:ok, _} = ComposioSettings.put(@tenant, %{"base_url" => "https://eu.composio.dev"})

    assert {:ok, %{"api_key" => "ck_tenant", "base_url" => "https://eu.composio.dev"}} =
             ComposioSettings.get(@tenant)
  end

  test "a blank api_key on first write is rejected" do
    assert {:error, {:bad_request, "api_key is required"}} =
             ComposioSettings.put(@tenant, %{"api_key" => "  "})
  end

  test "a disabled tenant record falls back to the default, like an absent one" do
    {:ok, _} = ComposioSettings.put_default(%{"api_key" => "ck_default"})
    {:ok, _} = ComposioSettings.put(@tenant, %{"api_key" => "ck_tenant", "enabled" => false})

    assert {:ok, %{"api_key" => "ck_default"}} = ComposioSettings.get(@tenant)
    assert %{"source" => "default"} = ComposioSettings.view(@tenant)
  end

  test "default fallback applies when the tenant has no record" do
    {:ok, _} = ComposioSettings.put_default(%{"api_key" => "ck_default"})

    assert {:ok, %{"api_key" => "ck_default"}} = ComposioSettings.get(@tenant)

    assert %{"source" => "default", "api_key_configured" => false} =
             ComposioSettings.view(@tenant)
  end

  test "deleting the tenant record restores default resolution, deleting the default clears it" do
    {:ok, _} = ComposioSettings.put_default(%{"api_key" => "ck_default"})
    {:ok, _} = ComposioSettings.put(@tenant, %{"api_key" => "ck_tenant"})

    assert :ok = ComposioSettings.delete(@tenant)
    assert {:ok, %{"api_key" => "ck_default"}} = ComposioSettings.get(@tenant)

    assert :ok = ComposioSettings.delete_default()
    assert {:error, :not_configured} = ComposioSettings.get(@tenant)
  end

  test "default view is redacted" do
    {:ok, view} = ComposioSettings.put_default(%{"api_key" => "ck_default"})
    refute Map.has_key?(view, "api_key")
    assert %{"api_key_configured" => true} = ComposioSettings.view_default()
  end
end
