defmodule Salix.Control.DriveBindingsTest do
  @moduledoc """
  The Drive control records: settings resolution (tenant, then platform
  default), binding validation and write-only key, and the handle the agent
  mount reaches a group's Drive with.
  """
  use ExUnit.Case, async: false

  alias Salix.Control.{DriveBindings, DriveSettings}

  setup do
    SalixStore.Repo.query!("TRUNCATE drive_settings, drive_bindings")
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Drive"})
    tenant_id = tenant["tenant_id"]
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Drive group"}, tenant_id)

    on_exit(fn ->
      DriveSettings.delete(tenant_id)
      DriveSettings.delete_default()
      DriveBindings.delete(group["group_id"])
    end)

    {:ok, tenant_id: tenant_id, group_id: group["group_id"]}
  end

  test "settings resolve tenant first, then the platform default", %{tenant_id: tenant_id} do
    assert {:error, :not_configured} = DriveSettings.get(tenant_id)
    assert %{"source" => "none", "enabled" => false} = DriveSettings.view(tenant_id)

    assert {:ok, %{"base_url" => "https://sync.example.com"}} =
             DriveSettings.put_default(%{"base_url" => "https://sync.example.com/"})

    assert {:ok, %{"base_url" => "https://sync.example.com"}} = DriveSettings.get(tenant_id)
    assert %{"source" => "default"} = DriveSettings.view(tenant_id)

    assert {:ok, _} = DriveSettings.put(tenant_id, %{"base_url" => "https://tenant.example.com"})
    assert {:ok, %{"base_url" => "https://tenant.example.com"}} = DriveSettings.get(tenant_id)
    assert %{"source" => "tenant"} = DriveSettings.view(tenant_id)

    # A disabled tenant record falls back to the default.
    assert {:ok, _} = DriveSettings.put(tenant_id, %{"enabled" => false})
    assert {:ok, %{"base_url" => "https://sync.example.com"}} = DriveSettings.get(tenant_id)
  end

  test "settings refuse anything but one HTTPS origin" do
    assert {:error, {:bad_request, msg}} =
             DriveSettings.put_default(%{"base_url" => "sync.example.com"})

    assert msg =~ "HTTPS origin"

    assert {:error, {:bad_request, _}} =
             DriveSettings.put_default(%{"base_url" => "https://sync.example.com/api"})

    assert {:ok, %{"base_url" => "http://127.0.0.1:8080"}} =
             DriveSettings.put_default(%{"base_url" => "http://127.0.0.1:8080"})
  end

  test "a binding keeps its key write-only and validates its names", %{group_id: group_id} do
    assert {:error, :not_configured} = DriveBindings.get(group_id)
    assert %{"configured" => false, "source" => ""} = DriveBindings.view(group_id)

    assert {:error, {:bad_request, "api_key is required"}} =
             DriveBindings.put(group_id, %{"org_slug" => "acme"})

    assert {:error, {:bad_request, msg}} =
             DriveBindings.put(group_id, %{"org_slug" => "Acme Inc", "api_key" => "synch_x"})

    assert msg =~ "org_slug"

    assert {:ok, view} =
             DriveBindings.put(group_id, %{"org_slug" => "acme", "api_key" => "synch_x"})

    assert %{
             "configured" => true,
             "api_key_configured" => true,
             "org_slug" => "acme",
             "network" => "default",
             "space" => "comma-drive",
             "source" => "manual"
           } = view

    refute Map.has_key?(view, "api_key")
    assert {:ok, %{"api_key" => "synch_x"}} = DriveBindings.get(group_id)

    # A save without the key keeps the stored one; a disabled binding is not configured.
    assert {:ok, _} = DriveBindings.put(group_id, %{"space" => "docs"})
    assert {:ok, %{"api_key" => "synch_x", "space" => "docs"}} = DriveBindings.get(group_id)
    assert {:ok, _} = DriveBindings.put(group_id, %{"enabled" => false})
    assert {:error, :not_configured} = DriveBindings.get(group_id)
    assert %{"configured" => false, "api_key_configured" => true} = DriveBindings.view(group_id)

    assert {:error, {:bad_request, _}} =
             DriveBindings.put(group_id, %{"enabled" => true, "source" => "elsewhere"})
  end

  test "the handle takes the binding's own origin, else the tenant's or the default", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    assert {:ok, _} = DriveBindings.put(group_id, %{"org_slug" => "acme", "api_key" => "synch_x"})
    assert {:error, :not_configured} = DriveBindings.handle(group_id)

    assert {:ok, _} = DriveSettings.put_default(%{"base_url" => "https://default.example.com"})

    assert {:ok, handle} = DriveBindings.handle(group_id)
    assert handle.base_url == "https://default.example.com"
    assert handle.group_id == group_id
    assert handle.org_slug == "acme"
    assert handle.network == "default"
    assert handle.space == "comma-drive"
    assert handle.token == "synch_x"
    refute inspect(handle) =~ "synch_x"

    assert {:ok, _} = DriveSettings.put(tenant_id, %{"base_url" => "https://tenant.example.com"})
    assert {:ok, %{base_url: "https://tenant.example.com"}} = DriveBindings.handle(group_id)

    assert {:ok, _} = DriveBindings.put(group_id, %{"base_url" => "https://own.example.com"})
    assert {:ok, %{base_url: "https://own.example.com"}} = DriveBindings.handle(group_id)

    assert {:ok, _} = DriveBindings.put(group_id, %{"base_url" => ""})
    assert {:ok, %{base_url: "https://tenant.example.com"}} = DriveBindings.handle(group_id)

    assert :ok = DriveBindings.delete(group_id)
    assert {:error, :not_configured} = DriveBindings.handle(group_id)
  end

  test "stored/1 reads a disabled or incomplete row that get/1 hides", %{group_id: group_id} do
    assert {:error, :not_found} = DriveBindings.stored(group_id)

    assert {:ok, _} =
             DriveBindings.put(group_id, %{
               "org_slug" => "manual-org",
               "api_key" => "synch_operator",
               "source" => "manual",
               "enabled" => false
             })

    assert {:error, :not_configured} = DriveBindings.get(group_id)
    assert {:error, :not_configured} = DriveBindings.handle(group_id)

    assert {:ok, %{"source" => "manual", "enabled" => false, "api_key" => "synch_operator"}} =
             DriveBindings.stored(group_id)

    assert {:ok, _} = DriveBindings.put(group_id, %{"enabled" => true})
    assert {:ok, %{"org_slug" => "manual-org"}} = DriveBindings.get(group_id)
  end

  test "retired key ids are kept as a clean list until a caller replaces them", %{
    group_id: group_id
  } do
    assert {:ok, %{"retired_key_ids" => ["key-1"]}} =
             DriveBindings.put(group_id, %{
               "org_slug" => "comma-abc",
               "api_key" => "synch_new",
               "api_key_id" => "key-2",
               "retired_key_ids" => [" key-1 ", "", "key-1", nil],
               "source" => "comma"
             })

    assert {:ok, %{"retired_key_ids" => ["key-1"]}} = DriveBindings.stored(group_id)
    assert %{"retired_key_ids" => ["key-1"]} = DriveBindings.view(group_id)

    # A save that does not mention the list keeps it; one that does replaces it.
    assert {:ok, _} = DriveBindings.put(group_id, %{"enabled" => true})
    assert {:ok, %{"retired_key_ids" => ["key-1"]}} = DriveBindings.stored(group_id)
    assert {:ok, _} = DriveBindings.put(group_id, %{"retired_key_ids" => []})
    assert {:ok, %{"retired_key_ids" => []}} = DriveBindings.stored(group_id)
  end
end
