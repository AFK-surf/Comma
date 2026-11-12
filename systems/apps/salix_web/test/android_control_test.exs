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

  test "the device mode is admitted only where the record names it, and a start names a device",
       %{tenant_id: tenant_id} do
    device = %{
      "version" => 2,
      "enabled" => true,
      "allowed_modes" => ["device"],
      "allowed_profiles" => [],
      "max_concurrent_leases" => 1,
      "max_lease_seconds" => 600
    }

    own = %{"protocol_version" => 3, "mode" => "device"}

    hosted = %{
      "protocol_version" => 2,
      "default_profile" => "api30-phone",
      "profiles" => ["api30-phone"],
      "profile_details" => [%{"id" => "api30-phone", "status" => "installed"}]
    }

    assert {:ok, _} = Tenants.update_config(tenant_id, "android_control", device)
    assert {:ok, policy} = AndroidControl.authorize(tenant_id)

    assert {:ok, %{"target" => "android:3B162S00P0N00000"} = action} =
             AndroidControl.authorize_action(policy, own, %{
               "action" => "start",
               "target" => "android:3B162S00P0N00000",
               "profile" => "ignored"
             })

    refute Map.has_key?(action, "profile")

    assert {:error, :android_target_required} =
             AndroidControl.authorize_action(policy, own, %{"action" => "start"})

    assert {:ok, _} = AndroidControl.authorize_action(policy, own, %{"action" => "observe"})
    # A device-only record admits no hosted emulator.
    assert {:error, :android_mode_not_allowed} =
             AndroidControl.authorize_action(policy, hosted, %{"action" => "start"})

    # A record of hosted emulators admits no computer's own device.
    connected = %{
      device
      | "allowed_modes" => ["connected"],
        "allowed_profiles" => ["api30-phone"]
    }

    assert {:ok, _} = Tenants.update_config(tenant_id, "android_control", connected)
    assert {:ok, policy} = AndroidControl.authorize(tenant_id)

    assert {:error, :android_mode_not_allowed} =
             AndroidControl.authorize_action(policy, own, %{
               "action" => "start",
               "target" => "android:emulator-5554"
             })

    assert {:ok, %{"profile" => "api30-phone"}} =
             AndroidControl.authorize_action(policy, hosted, %{"action" => "start"})

    # Profiles stay required with `connected`; an unknown mode fails closed.
    for modes <- [["connected", "device"], ["device", "device"], ["other"], []] do
      assert {:ok, _} =
               Tenants.update_config(tenant_id, "android_control", %{
                 device
                 | "allowed_modes" => modes
               })

      assert {:error, :android_not_authorized} = AndroidControl.authorize(tenant_id),
             inspect(modes)
    end
  end
end
