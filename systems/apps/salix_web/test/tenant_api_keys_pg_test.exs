defmodule SalixWeb.TenantApiKeysPgTest do
  # Exercises the Postgres-backed tenant API keys through Salix.Control.Tenants
  # (docs/storage-search.md). Serving reads Postgres directly;
  # the cutover marker is a readiness/deploy-time fact, not a per-request gate
  # (Comma.PodLifecycle.ready(:salix) keeps an unmigrated pod out of service).
  # Serial: shares the node-global Fake bucket and control tables.
  use SystemsClock.Case, async: false

  alias Salix.Control.Tenants
  alias SalixStore.{Keys, S3, TenantApiKeys}

  setup do
    # Node-global Fake bucket + control table: reset both so a legacy object or
    # row cannot leak into another app's suite (the --seed 228054 cross-suite
    # leak). The cutover marker is seeded once by RepoTestSetup for the VM and
    # is not touched here — serving no longer consults it per request.
    S3.Fake.reset()
    SalixStore.Repo.query!("TRUNCATE tenant_api_keys")
    on_exit(fn -> S3.Fake.reset() end)
    :ok
  end

  defp create_tenant! do
    {:ok, tenant} = Tenants.create(%{"name" => "api-key-pg-test"})
    tenant["tenant_id"]
  end

  test "create/list/validate/delete round-trip against Postgres" do
    tenant_id = create_tenant!()

    assert {:ok, %{"key" => raw, "key_hash" => hash}} =
             Tenants.create_api_key(tenant_id, %{"name" => "roundtrip"})

    assert [%{"key_hash" => ^hash, "name" => "roundtrip"}] = Tenants.list_api_keys(tenant_id)

    assert {:ok, ^tenant_id, %{"key_hash" => ^hash}} = Tenants.validate_api_key(raw)

    assert :ok = Tenants.delete_api_key(tenant_id, hash)
    assert [] = Tenants.list_api_keys(tenant_id)
    assert {:error, :unauthorized} = Tenants.validate_api_key(raw)
  end

  test "a key whose tenant no longer resolves stays unauthorized" do
    tenant_id = create_tenant!()
    {:ok, %{"key" => raw, "key_hash" => hash}} = Tenants.create_api_key(tenant_id, %{})

    # Simulate the tenant record disappearing from the control plane.
    :ok = S3.delete(Keys.ctl_tenant(tenant_id)) |> normalize_delete()

    assert {:error, :unauthorized} = Tenants.validate_api_key(raw)

    # The row still exists; only authorization is refused.
    assert {:ok, _} = TenantApiKeys.get_by_hash(hash)
  end

  defp normalize_delete({:ok, _}), do: :ok
  defp normalize_delete(:ok), do: :ok
end
