defmodule SalixWeb.AndroidControlTest do
  use ExUnit.Case, async: false

  alias Salix.Control.{AndroidControl, Tenants}

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :s3_backend, previous),
        else: Application.delete_env(:salix_store, :s3_backend)
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

  test "profile resolution uses the host default and requires profile on leased actions" do
    policy = %{
      allowed_profiles: ["api30-phone", "api35-phone-google-apis"],
      max_lease_seconds: 900
    }

    metadata = %{
      "protocol_version" => 2,
      "profiles" => policy.allowed_profiles,
      "profile_details" => [
        %{"id" => "api30-phone", "status" => "installed"},
        %{"id" => "api35-phone-google-apis", "status" => "installed"}
      ],
      "default_profile" => "api35-phone-google-apis"
    }

    assert {:ok, %{"profile" => "api35-phone-google-apis"}} =
             AndroidControl.authorize_action(policy, metadata, %{"action" => "start"})

    assert {:ok, %{"profile" => "api30-phone"}} =
             AndroidControl.authorize_action(policy, metadata, %{
               "action" => "start",
               "profile" => "api30-phone"
             })

    assert {:error, :android_profile_required} =
             AndroidControl.authorize_action(policy, metadata, %{"action" => "tap"})

    assert {:error, :android_profile_not_allowed} =
             AndroidControl.authorize_action(
               %{policy | allowed_profiles: ["api30-phone"]},
               metadata,
               %{"action" => "start"}
             )

    assert {:error, :android_profile_unavailable} =
             AndroidControl.authorize_action(
               policy,
               put_in(metadata, ["profile_details", Access.at(1), "status"], "unavailable"),
               %{"action" => "start"}
             )

    assert {:error, :android_profile_unavailable} =
             AndroidControl.authorize_action(policy, Map.put(metadata, "protocol_version", 1), %{
               "action" => "start"
             })

    assert {:error, :android_profile_unavailable} =
             AndroidControl.authorize_action(
               policy,
               Map.put(metadata, "profile_details", [42]),
               %{"action" => "start"}
             )
  end

  test "old policy and profiles outside the bounded contract fail closed", %{tenant_id: tenant_id} do
    config = %{
      "version" => 2,
      "enabled" => true,
      "allowed_modes" => ["connected"],
      "allowed_profiles" => ["api30-phone"],
      "max_concurrent_leases" => 1,
      "max_lease_seconds" => 900
    }

    for invalid <- [
          Map.put(config, "version", 1),
          Map.put(config, "allowed_profiles", []),
          Map.put(config, "allowed_profiles", ["api30-phone", "api30-phone"]),
          Map.put(config, "allowed_profiles", Enum.map(1..9, &"api#{&1}")),
          Map.put(config, "max_concurrent_leases", 2)
        ] do
      assert {:ok, _} = Tenants.update_config(tenant_id, "android_control", invalid)
      assert {:error, :android_not_authorized} = AndroidControl.authorize(tenant_id)
    end
  end
end
