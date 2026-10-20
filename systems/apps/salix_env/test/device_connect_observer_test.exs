defmodule SalixEnv.DeviceConnectObserverTest do
  use SystemsClock.Case, async: false

  alias SalixEnv.Registry
  alias SalixStore.Ids

  defmodule Observer do
    def device_connected(device),
      do: SystemsRuntime.Proc.send(:device_connect_observer_test, {:connected, device})
  end

  defmodule FailingObserver do
    def device_connected(_device), do: raise("observer failure")
  end

  setup do
    previous_observer = SystemsRuntime.get_env(:salix_env, :device_connect_observer)
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Process.register(SystemsRuntime.Proc.self(), :device_connect_observer_test)

    on_exit(fn ->
      if previous_observer,
        do: SystemsRuntime.put_env(:salix_env, :device_connect_observer, previous_observer),
        else: SystemsRuntime.delete_env(:salix_env, :device_connect_observer)

      if previous,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)

    :ok
  end

  defp connect(name) do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    Registry.connect(
      to_string(node()),
      %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => Ids.new_device_id(),
        "connector_id" => "connector-observer-test",
        "name" => name
      },
      connection_generation: 1,
      transport_id: "transport-" <> name
    )
  end

  test "a committed connection reaches the product observer, which cannot fail it" do
    SystemsRuntime.put_env(:salix_env, :device_connect_observer, Observer)
    assert {:ok, _transport, device} = connect("Comma-5D28")
    assert_receive {:connected, observed}
    assert observed["device_id"] == device["device_id"]
    assert observed["name"] == "Comma-5D28"
    assert observed["group_id"] == device["group_id"]

    # User-assigned names live outside the Connector metadata and survive reconnects.
    assert {:ok, _} =
             Registry.rename_device(
               device["tenant_id"],
               device["group_id"],
               device["device_id"],
               "Kitchen"
             )

    assert {:ok, _, _} =
             Registry.connect(to_string(node()), device["meta"],
               connection_generation: 2,
               transport_id: "transport-reconnected"
             )

    assert_receive {:connected, reconnected}
    assert reconnected["name"] == "Comma-5D28"
    assert reconnected["display_name"] == "Kitchen"

    SystemsRuntime.put_env(:salix_env, :device_connect_observer, FailingObserver)
    assert {:ok, _transport, _device} = connect("Comma-BEEF")
  end
end
