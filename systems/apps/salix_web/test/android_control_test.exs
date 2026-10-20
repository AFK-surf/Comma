defmodule SalixWeb.AndroidControlTest do
  use SystemsClock.Case, async: false

  alias Salix.Control.{AndroidControl, Tenants}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)

    {:ok, tenant} = Tenants.create(%{"name" => "Android control"})
    {:ok, tenant_id: tenant["tenant_id"]}
  end

  test "missing and malformed records fail closed", %{tenant_id: tenant_id} do
    assert {:error, :android_not_authorized} = AndroidControl.authorize(tenant_id)

    assert {:ok, _} =
             Tenants.update_config(tenant_id, "android_control", %{
               "version" => 2,
               "enabled" => true
             })

    assert {:error, :android_not_authorized} = AndroidControl.authorize(tenant_id)
  end

  test "version-two bounded profile policy authorizes", %{tenant_id: tenant_id} do
    config = %{
      "version" => 2,
      "enabled" => true,
      "allowed_modes" => ["connected"],
      "allowed_profiles" => ["api30-phone", "api35-phone-google-apis"],
      "max_concurrent_leases" => 1,
      "max_lease_seconds" => 3600
    }

    assert {:ok, _} = Tenants.update_config(tenant_id, "android_control", config)
    assert {:ok, %{max_lease_seconds: 3600}} = AndroidControl.authorize(tenant_id)

    assert {:ok, _} =
             Tenants.update_config(
               tenant_id,
               "android_control",
               Map.put(config, "unknown", true)
             )

    assert {:error, :android_not_authorized} = AndroidControl.authorize(tenant_id)
  end
end
