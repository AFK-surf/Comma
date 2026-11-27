defmodule SalixWeb.TenantDirectoryWritesTest do
  use SystemsClock.Case, async: false

  alias Salix.Control.{Store, Tenants}
  alias SalixStore.{Ids, Keys, TenantDirectory}
  alias SalixStore.S3.Fake

  setup do
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    Fake.reset()
    :ok
  end

  test "each creator records its product and the Tenant's directory row" do
    # Made in Salix: a caller cannot claim a product.
    {:ok, direct} = Tenants.create(%{"name" => "Direct", "product" => "comma"})
    refute Map.has_key?(direct, "product")

    assert {:ok, %{"name" => "Direct", "product" => nil}} =
             TenantDirectory.get(direct["tenant_id"])

    id = Ids.new_tenant_id()
    {:ok, cft} = Tenants.create_preallocated(%{"name" => "Org", "product" => "cft"}, id)
    assert cft["product"] == "cft"
    assert {:ok, %{"product" => "cft"}} = Tenants.get(id)
    assert {:ok, %{"name" => "Org", "product" => "cft"}} = TenantDirectory.get(id)

    assert {:error, {:bad_request, "invalid product"}} =
             Tenants.create_preallocated(%{"product" => "other"}, Ids.new_tenant_id())

    # A rename reaches the row; the admin PATCH cannot change the product.
    {:ok, renamed} = Tenants.update(id, %{"name" => "Org renamed", "product" => "comma"})
    assert renamed["product"] == "cft"
    assert {:ok, %{"name" => "Org renamed", "product" => "cft"}} = TenantDirectory.get(id)
  end

  test "the idempotent create paths converge a Tenant made before products were recorded" do
    # As a release before this one wrote it: no product, no directory row.
    id = Ids.new_tenant_id()
    old = %{"tenant_id" => id, "name" => "Old", "created_at" => 1_800_000_000, "config" => "{}"}
    {:ok, _} = Store.put_new(Keys.ctl_tenant(id), old)
    assert {:error, :not_found} = TenantDirectory.get(id)

    # CFT's retried create finds the Tenant and records its product.
    assert {:ok, %{"product" => "cft"}} =
             Tenants.create_preallocated(%{"name" => "Old", "product" => "cft"}, id)

    assert {:ok, %{"product" => "cft", "name" => "Old"}} = TenantDirectory.get(id)

    # A product once recorded is kept.
    assert {:ok, %{"product" => "cft"}} = Tenants.ensure_product(id, "comma")
    assert {:ok, %{"product" => "cft"}} = Tenants.get(id)

    # Comma's existing-Tenant branch: the record and row get the product.
    other = Ids.new_tenant_id()
    {:ok, _} = Store.put_new(Keys.ctl_tenant(other), %{old | "tenant_id" => other})
    assert {:ok, %{"product" => "comma"}} = Tenants.ensure_product(other, "comma")
    assert {:ok, %{"product" => "comma"}} = Tenants.get(other)
    assert {:ok, %{"product" => "comma", "name" => "Old"}} = TenantDirectory.get(other)

    assert {:error, {:bad_request, "invalid product"}} = Tenants.ensure_product(other, "x")
  end
end
