defmodule SalixWeb.TenantApiKeysPgTest do
  # Exercises the Postgres-backed tenant API keys through Salix.Control.Tenants
  # (docs/storage-search.md). Serving reads Postgres directly;
  # the cutover marker is a readiness/deploy-time fact, not a per-request gate
  # (Comma.PodLifecycle.ready(:salix) keeps an unmigrated pod out of service).
  # Serial: shares the node-global Fake bucket and control tables.
  use ExUnit.Case, async: false

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

  test "validate never LISTs S3 and only reads the tenant record" do
    tenant_id = create_tenant!()
    {:ok, %{"key" => raw}} = Tenants.create_api_key(tenant_id, %{"name" => "hot path"})

    S3.Fake.reset_read_log()
    assert {:ok, ^tenant_id, _rec} = Tenants.validate_api_key(raw)

    reads = S3.Fake.read_log()
    lists = Enum.filter(reads, &match?({:list, _}, &1))
    assert lists == [], "validate must not LIST S3, saw: #{inspect(reads)}"
  end

  test "an unknown key is unauthorized (no marker gate in the request path)" do
    # A key with no PG row is a clean 401 — serving reads Postgres directly and
    # never returns the marker-derived :unavailable it used to under the gate.
    assert {:error, :unauthorized} = Tenants.validate_api_key("salix_nonexistent")
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

  test "a transient tenant-record store fault is unavailable (503), not unauthorized (401)" do
    tenant_id = create_tenant!()
    {:ok, %{"key" => raw}} = Tenants.create_api_key(tenant_id, %{"name" => "faulty"})

    # The PG lookup succeeds and yields the tenant; the tenant-record S3 read
    # then faults. That must read as unavailable (a valid key must never be
    # told it is invalid), which SalixWeb.Auth maps to 503.
    S3.Fake.set_fault({:fail, 503, :get, Keys.ctl_tenant(tenant_id)})
    assert {:error, :unavailable} = Tenants.validate_api_key(raw)
  end

  test "create/delete surface a Postgres fault as {:unavailable}, not a raise (503 contract)" do
    tenant_id = create_tenant!()

    # Make the PG writes fault by renaming the table away; RENAME preserves the
    # exact schema for a clean restore before the next test's setup.
    SalixStore.Repo.query!("ALTER TABLE tenant_api_keys RENAME TO tenant_api_keys_tmp")

    on_exit(fn ->
      SalixStore.Repo.query!("ALTER TABLE tenant_api_keys_tmp RENAME TO tenant_api_keys")
    end)

    # Both must return a structured unavailable result (router maps it to 503),
    # never raise a Plug.Conn.WrapperError.
    assert {:error, {:unavailable, _}} = Tenants.create_api_key(tenant_id, %{"name" => "x"})
    assert {:error, {:unavailable, _}} = Tenants.delete_api_key(tenant_id, "deadbeef")
  end

  defp normalize_delete({:ok, _}), do: :ok
  defp normalize_delete(:ok), do: :ok
end
