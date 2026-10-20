defmodule SalixAgent.TailnetTest do
  @moduledoc """
  A Group's tailnet node against a real gateway and a test tailnet: login
  approval, dials to a device, restore from the lease record without a new
  approval, the expected-tailnet check, disconnect, the lease fence, the
  cross-node relay and the tool roles.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{Tailnet, TailnetTestPeer, TestSupport}
  alias SalixAgent.Tailnet.{NodeRecord, Owner, Relay}
  alias SalixAgent.Tools.Tailnet, as: Tools
  alias SalixStore.{Ids, S3}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    case SystemsRuntime.Proc.whereis(S3.Fake) do
      nil -> start_supervised!(S3.Fake)
      _pid -> S3.Fake.reset()
    end

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)

    agent_id = TestSupport.new_agent_id()
    group_id = Ids.group_id_from_agent!(agent_id)
    {:ok, agent_id: agent_id, group_id: group_id}
  end

  test "an approved node serves dials, survives its owner and leaves on disconnect",
       %{group_id: group_id} do
    peer = TailnetTestPeer.start!()

    # Before approval the Group has a login link and nothing to dial.
    {:ok, pending} = Tailnet.connect(group_id, %{}, "salix_admin")
    assert pending["state"] == "needs_login"
    assert pending["settings"]["tags"] == ["tag:comma-agent"]
    assert pending["updated_by"] == "salix_admin"
    assert {:error, %{"code" => "tailnet_needs_login"}} = Tailnet.dial(group_id, "nas", 7, 5_000)

    TailnetTestPeer.approve!(peer, pending["login_url"])
    running = TailnetTestPeer.await_state!(group_id, "running")
    assert running["approved"]
    assert running["node_name"] =~ "comma-"
    assert running["login_url"] == nil
    assert_echo(group_id)

    assert {:ok, %{"peers" => [%{"name" => "nas", "online" => true}], "next" => 0}} =
             Tailnet.peers(group_id)

    # Only peers of the tailnet are reachable, never the platform's network.
    assert {:error, %{"code" => "tailnet_destination_not_allowed"}} =
             Tailnet.dial(group_id, "127.0.0.1", 7, 5_000)

    assert {:error, %{"code" => "tailnet_host_unknown"}} =
             Tailnet.dial(group_id, "example.com", 443, 5_000)

    # Drain releases the lease and keeps the keys: the next dial restores the
    # same node, with no new approval.
    Owner.drain()
    idle = TailnetTestPeer.await_state!(group_id, "idle")
    assert idle["node_name"] == running["node_name"]
    assert_echo(group_id)
    assert TailnetTestPeer.await_state!(group_id, "running")["node_name"] == running["node_name"]

    # The node is in one tailnet, not the expected one: it logs out and its
    # keys are cleared.
    {:ok, _} = Tailnet.connect(group_id, %{"expected_tailnet" => "other.example"}, "salix_admin")
    mismatch = TailnetTestPeer.await_state!(group_id, "error")
    assert mismatch["error"]["code"] == "tailnet_mismatch"
    refute mismatch["approved"]
    assert %{"body" => %{"state" => nil}} = await_released!(group_id)

    # A new link, approved, with the expectation cleared.
    {:ok, again} = Tailnet.connect(group_id, %{"expected_tailnet" => nil}, "salix_admin")
    assert again["state"] == "needs_login"
    TailnetTestPeer.approve!(peer, again["login_url"])
    TailnetTestPeer.await_state!(group_id, "running")

    {:ok, disabled} = Tailnet.disconnect(group_id, "salix_admin")
    assert disabled["state"] == "disabled"
    refute disabled["approved"]
    assert {:ok, %{"holder" => nil, "body" => %{"state" => nil}}} = NodeRecord.read(group_id)

    assert {:error, %{"code" => "tailnet_not_configured"}} =
             Tailnet.dial(group_id, "nas", 7, 5_000)
  end

  test "web.http_request reaches a tailnet device with via_tailnet", %{group_id: group_id} do
    peer = TailnetTestPeer.start!()
    {:ok, pending} = Tailnet.connect(group_id, %{}, "salix_admin")
    TailnetTestPeer.approve!(peer, pending["login_url"])
    TailnetTestPeer.await_state!(group_id, "running")
    ctx = %{agent_id: TestSupport.new_agent_id(), group_id: group_id}

    response =
      Jason.decode!(
        SalixAgent.Tools.HttpRequest.request(
          %{"url" => "http://nas/status", "via_tailnet" => true},
          ctx
        )
      )

    assert %{"status" => 200, "body" => %{"device" => "nas", "path" => "/status"}} = response

    # Without via_tailnet the same name is a public-internet request, which the
    # destination policy refuses.
    assert_raise RuntimeError, fn ->
      SalixAgent.Tools.HttpRequest.request(%{"url" => "http://nas/status"}, ctx)
    end
  end

  test "a holder that lost the lease cannot overwrite the node state", %{group_id: group_id} do
    {:ok, first} = NodeRecord.acquire(group_id, "a|1")
    {:ok, first} = NodeRecord.write(first, %{"state" => %{"k" => "first"}})

    assert {:error, {:held_by, "a|1", _}} = NodeRecord.acquire(group_id, "b|1")

    # After expiry another holder takes over, with the saved state.
    later = SystemsClock.system_time(:millisecond) + NodeRecord.ttl_ms() + 1
    {:ok, second} = NodeRecord.acquire(group_id, "b|1", now: later)
    assert second.epoch == first.epoch + 1
    assert second.body == %{"state" => %{"k" => "first"}}

    assert {:error, :lost} = NodeRecord.write(first, %{"state" => %{"k" => "stale"}})
    assert {:ok, %{"body" => %{"state" => %{"k" => "first"}}}} = NodeRecord.read(group_id)
  end

  test "only the Router manages the tailnet and sees the login link", %{
    agent_id: agent_id,
    group_id: group_id
  } do
    TailnetTestPeer.start!()
    tenant_id = Ids.tenant_id_from_group!(group_id)
    TestSupport.create_control_agent!(agent_id, %{"role" => "worker"})
    worker = %{agent_id: agent_id, group_id: group_id, tenant_id: tenant_id}

    assert {:tool_failure, _, "forbidden", _, _, _} = Tools.connect(%{}, worker)

    router_id = Ids.new_agent_id(group_id)
    TestSupport.create_control_agent!(router_id, %{"role" => "router"})
    router = %{agent_id: router_id, group_id: group_id, tenant_id: tenant_id}

    status = Jason.decode!(Tools.connect(%{"accept_routes" => true}, router))
    assert status["state"] == "needs_login"
    assert is_binary(status["login_url"])
    assert status["updated_by"] == "agent:" <> router_id
    assert status["settings"]["accept_routes"]

    refute Map.has_key?(Jason.decode!(Tools.status(%{}, worker)), "login_url")
    assert Jason.decode!(Tools.status(%{}, router))["login_url"] == status["login_url"]

    assert {:tool_failure, _, "confirmation_required", _, _, _} = Tools.disconnect(%{}, router)

    assert {:tool_failure, _, "invalid_tags", _, _, _} =
             Tools.connect(%{"tags" => ["not-a-tag"]}, router)
  end

  defp assert_echo(group_id) do
    {:ok, socket, %{"peer" => "nas" <> _}} = Tailnet.dial(group_id, "nas", 7, 30_000)
    :ok = :gen_tcp.send(socket, "ping\n")
    assert {:ok, "ping\n"} = :gen_tcp.recv(socket, 5, 10_000)
    :gen_tcp.close(socket)
  end

  # The owner records the reason before its node stops; it clears the keys
  # and releases the lease once the node has stopped.
  defp await_released!(group_id) do
    TailnetTestPeer.await!(group_id, fn ->
      case NodeRecord.read(group_id) do
        {:ok, %{"holder" => nil} = record} -> record
        _ -> nil
      end
    end)
  end
end
