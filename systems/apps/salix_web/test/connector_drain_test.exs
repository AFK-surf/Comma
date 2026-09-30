defmodule SalixWeb.ConnectorDrainTest do
  use ExUnit.Case, async: false

  alias SalixEnv.{ConnectorTokens, Registry}
  alias SalixWeb.{ConnectorDrain, ConnectorSocket}

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Drain test"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Drain test"}, tenant["tenant_id"])

    {:ok, credential} =
      ConnectorTokens.create_group_connector_token(
        group["group_id"],
        tenant["tenant_id"],
        %{}
      )

    %{tenant: tenant["tenant_id"], group: group["group_id"], credential: credential}
  end

  test "a teardown reply is not death proof, and confirmation preserves a racing successor",
       ctx do
    {owner, run} = start_owner(ctx)
    task = Task.async(fn -> ConnectorDrain.drain() end)
    assert_receive {:drain_reply_sent, ^owner}, 1_000

    # The old socket has replied but remains alive. Reconnection moves its
    # target into the pending list before the drain can prove its death.
    reconnect = Task.async(fn -> connect(ctx) end)
    key = to_string(ctx.credential["credential_generation"])
    wait_for_pending(ctx, key)
    {:ok, device} = Registry.get_device(ctx.tenant, ctx.group, ctx.credential["device_id"])
    assert [target] = device["pending_connector_revocations"][key]
    assert target["connector_run_id"] == run["connector_run_id"]
    assert Task.yield(task, 20) == nil

    send(owner, :allow_exit)
    assert :ok = Task.await(task)
    assert {:ok, _, successor} = Task.await(reconnect)
    {:ok, device} = Registry.get_device(ctx.tenant, ctx.group, ctx.credential["device_id"])
    assert device["connector_run_id"] == successor["connector_run_id"]
    assert device["status"] == "connected"
    refute Map.has_key?(device, "pending_connector_revocations")
  end

  test "drain does not confirm an owner that replies but never stops", ctx do
    {owner, _run} = start_owner(ctx)

    {:ok, _, _} =
      Registry.revoke_connector_credential(
        ctx.tenant,
        ctx.group,
        ctx.credential["device_id"],
        ctx.credential["connector_id"],
        ctx.credential["credential_generation"]
      )

    task = Task.async(fn -> ConnectorDrain.drain() end)
    assert_receive {:drain_reply_sent, ^owner}, 1_000
    assert {:error, {:connector_drain_incomplete, _}} = Task.await(task, 12_000)
    assert Process.alive?(owner)
    {:ok, device} = Registry.get_device(ctx.tenant, ctx.group, ctx.credential["device_id"])

    assert [_] =
             device["pending_connector_revocations"][
               to_string(ctx.credential["credential_generation"])
             ]
  end

  test "an upgrade admitted before drain cannot begin serving afterwards", ctx do
    {:ok, transport, run} = connect(ctx)
    SalixCluster.NodeLifecycle.mark_draining()
    on_exit(fn -> SalixCluster.NodeLifecycle.clear_draining() end)

    assert {:stop, {:shutdown, :connector_draining}, _} =
             ConnectorSocket.init(
               env_id: transport,
               connector_run_id: run["connector_run_id"],
               connection_generation: run["connection_generation"]
             )
  end

  defp wait_for_pending(ctx, key, attempts \\ 100)
  defp wait_for_pending(_ctx, _key, 0), do: flunk("reconnect never recorded its predecessor")

  defp wait_for_pending(ctx, key, attempts) do
    {:ok, device} = Registry.get_device(ctx.tenant, ctx.group, ctx.credential["device_id"])

    if get_in(device, ["pending_connector_revocations", key]) do
      :ok
    else
      Process.sleep(10)
      wait_for_pending(ctx, key, attempts - 1)
    end
  end

  defp connect(ctx) do
    Registry.connect(
      to_string(node()),
      %{
        "tenant_id" => ctx.tenant,
        "group_id" => ctx.group,
        "device_id" => ctx.credential["device_id"],
        "connector_id" => ctx.credential["connector_id"],
        "credential_generation" => ctx.credential["credential_generation"]
      },
      credential_generation: ctx.credential["credential_generation"],
      token_expires_at: ctx.credential["expires_at"]
    )
  end

  defp start_owner(ctx) do
    {:ok, transport, run} = connect(ctx)
    parent = self()

    state =
      struct!(ConnectorSocket.State, %{
        env_id: transport,
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        device_id: ctx.credential["device_id"],
        connector_id: ctx.credential["connector_id"],
        credential_generation: ctx.credential["credential_generation"],
        connector_run_id: run["connector_run_id"],
        connection_generation: run["connection_generation"]
      })

    owner =
      spawn(fn ->
        :ok = SalixEnv.Bridge.register_owner(transport)
        send(parent, {:ready, self()})

        receive do
          {:connector_drain, _, _} = message ->
            {:stop, _, _} = ConnectorSocket.handle_info(message, state)
            send(parent, {:drain_reply_sent, self()})
            receive do: (:allow_exit -> :ok)
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:ready, ^owner}, 1_000
    {owner, run}
  end
end
