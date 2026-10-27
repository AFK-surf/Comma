defmodule SalixWeb.ConnectorSocketTest do
  require SystemsRuntime.Proc

  @moduledoc """
  End-to-end remote connector over a real WebSocket: a `websockex` client
  connects to the live `/v1/connect` Bandit endpoint (the same wire protocol the
  Go Connector speaks), and we drive RPCs through the full production path —
  `SalixWeb.EnvDispatch` → `SalixEnv.Connector.Live` → `SalixEnv.Bridge` →
  the socket — including the agent's `env.exec`/`env.list` tools, durable
  `/v1/admin/runtime/environments` registration, and disconnect cleanup.
  """
  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  alias SalixWeb.{ConnectorDisconnectQueue, EnvDispatch}
  alias SalixStore.Compute, as: GroupCompute

  alias SalixAgent.MeetingLLMCapability
  alias SalixAgent.{SkillProjection, SkillStore}
  alias Salix.Control.{Plugins, Tenants}
  alias SalixStore.RuntimeIds
  alias SalixAgent.Tools.Peers
  alias SalixStore.{Keys, S3}

  @tag :subscription_runtime
  test "subscription binding supplies only the scoped account and revokes disabled credentials",
       %{group_id: group, connector_token: token} do
    alias SalixAgent.{SubscriptionStore, AccountPool}
    alias SalixWeb.SubscriptionRuntimeAuth

    tenant = tenant_id()
    {pid, run} = connect(group, "subscription-worker", token)
    device = environment_for_run!(run)["device_id"]
    identity = "/private/bin/subscription-codex"
    runtime = RuntimeIds.device_runtime_id(device, "codex", RuntimeIds.runtime_id(identity))
    now = SystemsClock.system_time(:millisecond)

    snapshot = %{
      "schema_version" => 1,
      "status" => "unauthenticated",
      "requires_openai_auth" => true,
      "observed_at" => now
    }

    metadata = %{
      "type" => "metadata",
      "capabilities" => %{
        "runtime_auth_v1" => true,
        "runtime_probe" => true,
        "agent_runtimes" => [
          %{
            "kind" => "external",
            "provider" => "codex",
            "identity_material" => identity,
            "version_detected" => true,
            "auth_ready" => false,
            "native_server_startable" => true,
            "ready" => false,
            "auth" => snapshot,
            "readiness_checked_at" => now,
            "readiness_valid_until" => now + 600_000
          }
        ]
      }
    }

    SystemsRuntime.Proc.send(pid, {:send_frame, metadata})

    assert eventually(fn ->
             match?(
               {:ok, _},
               SalixEnv.Control.subscription_runtime_target(device, runtime, group, tenant)
             )
           end)

    account = SubscriptionStore.id()

    {:ok, sealed} =
      SubscriptionStore.seal(tenant, account, %{
        "access_token" => "access-secret",
        "refresh_token" => "refresh-never-leaves",
        "id_token" => "id-never-leaves",
        "account_id" => "chatgpt-workspace",
        "expired" => DateTime.to_iso8601(DateTime.add(SystemsClock.utc_now(), 3600))
      })

    {:ok, saved_account} =
      SubscriptionStore.create(tenant, %{
        "id" => account,
        "credential" => "subscription",
        "source" => "codex",
        "status" => "ok",
        "disabled" => false,
        "credentials" => sealed
      })

    {:ok, api_key} = Salix.Control.Tenants.create_api_key(tenant, %{"name" => "managed runtime"})
    path = "/v1/runtime/groups/#{group}/environments/#{device}/runtimes/#{runtime}/managed-auth"

    request = fn method, attrs ->
      method
      |> Plug.Test.conn(path, Jason.encode!(attrs))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))
    end

    unauthorized = Plug.Test.conn(:get, path) |> SalixWeb.Router.call(SalixWeb.Router.init([]))
    assert unauthorized.status == 401
    assert Plug.Conn.get_resp_header(unauthorized, "cache-control") == ["no-store"]
    read = request.(:get, %{})
    assert read.status == 200
    assert Jason.decode!(read.resp_body)["state"] == "unbound"
    refute read.resp_body =~ "access-secret"
    refute read.resp_body =~ "never-leaves"

    attrs = %{
      "account_id" => account,
      "expected_account_version" => saved_account["version"],
      "expected_binding" => nil
    }

    assert request.(:put, Map.put(attrs, "expected_account_version", "stale")).status == 409

    task =
      SystemsRuntime.Task.async(fn ->
        request.(:put, Map.put(attrs, "account_cursor", String.duplicate("x", 257)))
      end)

    settle_receive({:runtime_auth_request, ^pid, id, "runtime_auth_subscription", params})
    assert params["access_token"] == "access-secret"
    refute inspect(params) =~ "never-leaves"

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "authenticated"}}
       }}
    )

    settle_receive({:runtime_probe_request, ^pid, probe_id, probe_params})
    assert probe_params == %{"provider" => "codex", "identity_material" => identity}

    ready_runtime =
      metadata["capabilities"]["agent_runtimes"]
      |> hd()
      |> Map.merge(%{
        "auth_ready" => true,
        "ready" => true,
        "auth" => %{snapshot | "status" => "authenticated"}
      })

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame, put_in(metadata, ["capabilities", "agent_runtimes"], [ready_runtime])}
    )

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{"id" => probe_id, "type" => "response", "result" => %{"runtimes" => [ready_runtime]}}}
    )

    bound = settled_await(task)
    assert bound.status == 200
    bound_auth = Jason.decode!(bound.resp_body)
    assert bound_auth["accounts_unavailable"]
    assert bound_auth["accounts"] == []
    assert bound_auth["state"] == "configured"
    assert bound_auth["source"] == "organization"
    refute bound.resp_body =~ "access-secret"
    refute bound.resp_body =~ "never-leaves"
    assert request.(:put, attrs).status == 409

    assert request.(:delete, %{"expected_binding" => Map.put(bound_auth["binding"], "id", -1)}).status ==
             409

    assert {:ok, %{account_id: ^account, status: "ready"}} =
             SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    assert {:ok, environment} = SalixEnv.Control.get_environment(device, group, tenant)

    assert Enum.any?(
             environment["device_runtimes"],
             &(&1["device_runtime_id"] == runtime and &1["status"] == "ready")
           )

    replacement_id = SubscriptionStore.id()

    {:ok, replacement_sealed} =
      SubscriptionStore.seal(tenant, replacement_id, %{
        "access_token" => "replacement-secret",
        "account_id" => "replacement-workspace",
        "expired" => DateTime.to_iso8601(DateTime.add(SystemsClock.utc_now(), 3600))
      })

    {:ok, replacement} =
      SubscriptionStore.create(tenant, %{
        "id" => replacement_id,
        "credential" => "subscription",
        "source" => "codex",
        "status" => "ok",
        "disabled" => false,
        "credentials" => replacement_sealed
      })

    original_binding = bound_auth["binding"]

    bound_auth =
      Enum.reduce(
        [{replacement, "replacement-secret"}, {saved_account, "access-secret"}],
        bound_auth,
        fn {selected, secret}, previous ->
          switch =
            SystemsRuntime.Task.async(fn ->
              request.(:put, %{
                "account_id" => selected["id"],
                "expected_account_version" => selected["version"],
                "expected_binding" => previous["binding"]
              })
            end)

          settle_receive(
            {:runtime_auth_request, ^pid, switch_id, "runtime_auth_subscription", delivery}
          )

          assert delivery["access_token"] == secret
          assert delivery["subscription_account_id"] == selected["id"]
          refute delivery["revoked"]

          SystemsRuntime.Proc.send(
            pid,
            {:send_frame,
             %{
               "id" => switch_id,
               "type" => "response",
               "result" => %{"auth" => %{snapshot | "status" => "authenticated"}}
             }}
          )

          settle_receive({:runtime_probe_request, ^pid, check_id, _})

          SystemsRuntime.Proc.send(
            pid,
            {:send_frame,
             %{
               "id" => check_id,
               "type" => "response",
               "result" => %{"runtimes" => [ready_runtime]}
             }}
          )

          response = SystemsRuntime.Task.await(switch, :infinity)
          assert response.status == 200
          refute response.resp_body =~ secret
          current = Jason.decode!(response.resp_body)
          assert current["binding"]["account_id"] == selected["id"]
          refute current["binding"]["id"] == previous["binding"]["id"]
          current
        end
      )

    # Compute ownership forbids account replacement before changing durable selection.
    {:ok, _, _} =
      GroupCompute.ensure_group_workload(%{
        "tenant_id" => tenant,
        "group_id" => group,
        "device_id" => device,
        "env_id" => run,
        "connector_id" => SalixWeb.ComputeProviders.Cloudflare.cloudvm_connector_id(group),
        "provider" => "cloudflare",
        "provider_resource_name" => "managed-binding-test"
      })

    compute_auth = request.(:get, %{}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    refute "bind" in compute_auth["actions"]
    assert "retry" in compute_auth["actions"]

    assert request.(:put, %{
             "account_id" => replacement["id"],
             "expected_account_version" => replacement["version"],
             "expected_binding" => bound_auth["binding"]
           }).status == 409

    assert {:ok, %{account_id: ^account, status: "ready"}} =
             SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    settle_refute_receive({:runtime_auth_request, ^pid, _, "runtime_auth_subscription", _}, 100)
    # A -> B -> A does not revive an old page's authority to unbind.
    assert request.(:delete, %{"expected_binding" => original_binding}).status == 409

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => "pull",
         "type" => "request",
         "method" => "runtime_subscription_access",
         "params" => %{"identity_material" => identity, "account_id" => "attacker-selected"}
       }}
    )

    settle_receive(
      {:connector_frame, %{"id" => "pull", "type" => "response", "result" => access}}
    )

    assert access["subscription_account_id"] == account
    assert access["delivery_revision"] > params["delivery_revision"]
    refute inspect(access) =~ "never-leaves"

    state = %SalixWeb.ConnectorSocket.State{
      tenant_id: tenant,
      group_id: group,
      device_id: device,
      connector_run_id: run,
      connection_generation: 0,
      scope: "full"
    }

    assert {:error, :subscription_target_changed} =
             SubscriptionRuntimeAuth.access(state, %{"identity_material" => identity})

    SystemsRuntime.Proc.exit(pid, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(device, group, tenant)
             )
           end)

    for _ <- 1..3 do
      {:ok, _} =
        SubscriptionStore.query(
          "UPDATE runtime_subscription_bindings SET next_delivery_at=now() WHERE tenant_id=$1 AND account_id=$2",
          [tenant, account]
        )

      assert {:noreply, _} = SalixWeb.SubscriptionRuntimeWorker.handle_info(:deliver, nil)
    end

    assert {:ok, %{status: "delivery_failed", failures: 3}} =
             SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    {pid, new_run} = connect(group, "subscription-worker", token)
    assert new_run != run
    SystemsRuntime.Proc.send(pid, {:send_frame, metadata})

    assert eventually(fn ->
             match?(
               {:ok, _},
               SalixEnv.Control.subscription_runtime_target(device, runtime, group, tenant)
             )
           end)

    assert eventually(fn ->
             match?(
               {:ok, %{status: "pending", failures: 0}},
               SubscriptionRuntimeAuth.status(tenant, group, device, runtime)
             )
           end)

    background =
      SystemsRuntime.Task.async(fn ->
        SalixWeb.SubscriptionRuntimeWorker.handle_info(:deliver, nil)
      end)

    settle_receive(
      {:runtime_auth_request, ^pid, background_id, "runtime_auth_subscription", background_access}
    )

    assert background_access["subscription_account_id"] == account

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => background_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "authenticated"}}
       }}
    )

    assert {:noreply, _} = settled_await(background)

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => "restored",
         "type" => "request",
         "method" => "runtime_subscription_access",
         "params" => %{"identity_material" => identity}
       }}
    )

    settle_receive(
      {:connector_frame, %{"id" => "restored", "type" => "response", "result" => restored}}
    )

    assert restored["subscription_account_id"] == account
    assert restored["delivery_revision"] > access["delivery_revision"]
    # The predecessor cannot obtain credentials after the replacement connected.
    assert {:error, :subscription_target_changed} =
             SubscriptionRuntimeAuth.access(state, %{"identity_material" => identity})

    {:ok, record} = SubscriptionStore.get(tenant, account)

    assert {:ok, _} =
             AccountPool.update(tenant, account, %{
               "version" => record["version"],
               "disabled" => true
             })

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => "disabled",
         "type" => "request",
         "method" => "runtime_subscription_access",
         "params" => %{"identity_material" => identity}
       }}
    )

    settle_receive({:connector_frame, %{"id" => "disabled", "type" => "error"}})

    revoke =
      SystemsRuntime.Task.async(fn ->
        SubscriptionRuntimeAuth.deliver([tenant, group, device, runtime])
      end)

    settle_receive(
      {:runtime_auth_request, ^pid, revoke_id, "runtime_auth_subscription", revocation}
    )

    assert revocation["revoked"] == true
    refute Map.has_key?(revocation, "access_token")

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => revoke_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "error"}}
       }}
    )

    assert {:ok, _} = settled_await(revoke)

    unbind =
      SystemsRuntime.Task.async(fn ->
        request.(:delete, %{
          "expected_binding" => bound_auth["binding"],
          "account_cursor" => String.duplicate("x", 257)
        })
      end)

    settle_receive(
      {:runtime_auth_request, ^pid, unbind_id, "runtime_auth_subscription", %{"revoked" => true}}
    )

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => unbind_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "error"}}
       }}
    )

    settle_receive({:runtime_probe_request, ^pid, restore_probe_id, _})

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => restore_probe_id,
         "type" => "response",
         "result" => %{"runtimes" => [ready_runtime]}
       }}
    )

    assert %{status: 200, resp_body: unbound_body} = settled_await(unbind)
    assert Jason.decode!(unbound_body)["state"] == "unbound"
    assert Jason.decode!(unbound_body)["accounts_unavailable"]
    assert {:error, :not_found} = SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => "unbound",
         "type" => "request",
         "method" => "runtime_subscription_access",
         "params" => %{"identity_material" => identity}
       }}
    )

    settle_receive({:connector_frame, %{"id" => "unbound", "result" => %{"bound" => false}}})
    # Pause real unbind after its durable disable, before it can issue revocation.
    # An older ordinary login ACK must not remove the revocation obligation.
    {:ok, record} = SubscriptionStore.get(tenant, account)

    assert {:ok, _} =
             AccountPool.update(tenant, account, %{
               "version" => record["version"],
               "disabled" => false
             })

    delivery =
      SystemsRuntime.Task.async(fn ->
        SubscriptionRuntimeAuth.distribute(tenant, group, device, runtime, account)
      end)

    settle_receive({:runtime_auth_request, ^pid, old_id, "runtime_auth_subscription", old_access})
    refute old_access["revoked"]

    handler = {__MODULE__, :subscription_unbind_ack, SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, test_pid ->
          if Process.get(:pause_subscription_unbind) &&
               String.contains?(meta.query, "SET enabled=false") do
            SystemsRuntime.Proc.send(
              test_pid,
              {:subscription_unbind_paused, SystemsRuntime.Proc.self()}
            )

            SystemsClock.vreceive do
              :continue_subscription_unbind -> :ok
            after
              5_000 -> raise "unbind barrier timed out"
            end
          end
        end,
        SystemsRuntime.Proc.self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    unbind =
      SystemsRuntime.Task.async(fn ->
        Process.put(:pause_subscription_unbind, true)
        SubscriptionRuntimeAuth.unbind(tenant, group, device, runtime)
      end)

    settle_receive({:subscription_unbind_paused, unbind_pid})

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => old_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "authenticated"}}
       }}
    )

    assert {:ok, _} = settled_await(delivery)

    assert {:ok, %{account_id: ^account}} =
             SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    SystemsRuntime.Proc.send(unbind_pid, :continue_subscription_unbind)

    settle_receive(
      {:runtime_auth_request, ^pid, final_id, "runtime_auth_subscription", final_revocation}
    )

    assert final_revocation["revoked"] == true
    assert final_revocation["delivery_revision"] > old_access["delivery_revision"]
    assert {:ok, _} = SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => final_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "error"}}
       }}
    )

    assert {:ok, _} = settled_await(unbind)
    assert {:error, :not_found} = SubscriptionRuntimeAuth.status(tenant, group, device, runtime)
    SystemsRuntime.Telemetry.detach(handler)
  end

  test "graceful drain closes a real socket and permits token recovery without its old node", %{
    group_id: group_id
  } do
    {:ok, credential} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "meta" => %{"owner_user_id" => "usr_drain"}
      })

    token = credential["token"]
    {_client, run_id} = connect(group_id, "draining-device", token)
    device_id = environment_for_run!(run_id)["device_id"]
    [{owner, :connector}] = Registry.lookup(SalixEnv.Bridges, run_id)
    ref = SystemsRuntime.Proc.monitor(owner)
    SalixCluster.NodeLifecycle.mark_draining()
    on_exit(fn -> SalixCluster.NodeLifecycle.clear_draining() end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = SalixWeb.ConnectorDrain.drain()
      end)

    assert log =~ "reason=connector_draining"
    settle_receive({:DOWN, ^ref, :process, ^owner, _})
    assert {:ok, device} = SalixEnv.Registry.get_device(tenant_id(), group_id, device_id)
    assert device["status"] == "disconnected"
    refute Map.has_key?(device, "pending_connector_revocations")

    assert :ok =
             SalixEnv.ConnectorTokens.revoke_group_connector_token(group_id, tenant_id(), token)

    SalixCluster.NodeLifecycle.clear_draining()

    {:ok, successor} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "stable_device_id" => device_id,
        "meta" => %{"owner_user_id" => "usr_drain"}
      })

    {_client, successor_run} = connect(group_id, "draining-device", successor["token"])
    assert successor_run != run_id
  end

  test "a tunnel opens through a pending dial and forwards frames to its relay only" do
    alias SalixWeb.ConnectorSocket

    tunnel_in = fn state, frame ->
      ConnectorSocket.handle_in({Jason.encode!(frame), [opcode: :text]}, state)
    end

    dial =
      SalixEnv.Protocol.request("lan_tcp_dial", %{"host" => "10.0.0.2", "port" => 22}, "tun-1")

    ref = SystemsRuntime.Proc.make_ref()

    assert {:push, {:text, encoded}, state} =
             ConnectorSocket.handle_info(
               {:env_tunnel_open, ref, SystemsRuntime.Proc.self(), SystemsRuntime.Proc.self(),
                dial},
               %ConnectorSocket.State{}
             )

    assert Jason.decode!(encoded) == dial

    # Bytes can arrive before the dial reply; they still reach the relay.
    data = %{
      "id" => "tun-1",
      "type" => "stream",
      "stream" => %{"channel" => "tcp", "data" => "aGk="}
    }

    assert {:ok, state} = tunnel_in.(state, data)
    settle_receive({:env_tunnel_frame, "tun-1", %{"channel" => "tcp", "data" => "aGk="}})

    assert {:ok, state} =
             tunnel_in.(state, %{
               "id" => "tun-1",
               "type" => "response",
               "result" => %{"status" => "connected"}
             })

    settle_receive({:env_rpc_reply, ^ref, {:ok, %{"status" => "connected"}}})
    ack = %{"channel" => "tcp_ack", "seq" => 2}

    assert {:push, {:text, pushed}, state} =
             ConnectorSocket.handle_info(
               {:env_tunnel_send, SystemsRuntime.Proc.self(), "tun-1", ack},
               state
             )

    assert Jason.decode!(pushed) == %{"id" => "tun-1", "type" => "stream", "stream" => ack}

    stranger = SystemsRuntime.Proc.spawn(fn -> :ok end)

    assert {:ok, state} =
             ConnectorSocket.handle_info({:env_tunnel_send, stranger, "tun-1", ack}, state)

    assert {:ok, state} =
             tunnel_in.(state, %{
               "id" => "tun-1",
               "type" => "stream",
               "error" => "connection reset",
               "stream" => %{"channel" => "tcp", "eof" => true}
             })

    settle_receive(
      {:env_tunnel_frame, "tun-1",
       %{"channel" => "tcp", "eof" => true, "error" => "connection reset"}}
    )

    assert state.tunnels == %{}
    assert {:ok, state} = tunnel_in.(state, data)
    settle_refute_receive({:env_tunnel_frame, _, _})
    # A relay that exits closes its tunnel on the connector.
    relay = SystemsRuntime.Proc.spawn(fn -> SystemsRuntime.Proc.receive(do: (:stop -> :ok)) end)
    dial = Map.put(dial, "id", "tun-2")

    assert {:push, _dial, state} =
             ConnectorSocket.handle_info(
               {:env_tunnel_open, SystemsRuntime.Proc.make_ref(), SystemsRuntime.Proc.self(),
                relay, dial},
               state
             )

    SystemsRuntime.Proc.send(relay, :stop)
    settle_receive({:DOWN, _monitor, :process, ^relay, _reason} = down)
    assert {:push, {:text, eof}, state} = ConnectorSocket.handle_info(down, state)

    assert Jason.decode!(eof) == %{
             "id" => "tun-2",
             "type" => "stream",
             "stream" => %{"channel" => "tcp", "eof" => true}
           }

    assert state.tunnels == %{}

    # A failed dial replies with the error and keeps no tunnel.
    ref = SystemsRuntime.Proc.make_ref()
    dial = Map.put(dial, "id", "tun-3")

    assert {:push, _dial, state} =
             ConnectorSocket.handle_info(
               {:env_tunnel_open, ref, SystemsRuntime.Proc.self(), SystemsRuntime.Proc.self(),
                dial},
               state
             )

    assert {:ok, state} =
             tunnel_in.(state, %{
               "id" => "tun-3",
               "type" => "error",
               "error" => "connection refused"
             })

    settle_receive({:env_rpc_reply, ^ref, {:error, "connection refused"}})
    assert state.tunnels == %{}

    ref = SystemsRuntime.Proc.make_ref()

    assert {:ok, _state} =
             ConnectorSocket.handle_info(
               {:env_tunnel_open, ref, SystemsRuntime.Proc.self(), SystemsRuntime.Proc.self(),
                Map.put(dial, "id", "tun-4")},
               %{state | scope: "local_file_read"}
             )

    settle_receive({:env_rpc_reply, ^ref, {:error, :connector_scope_forbidden}})
  end

  # A real WebSocket connector built on websockex: registers, then answers exec
  # and read RPCs, forwarding the connected connector run id to the test process.
  defmodule FakeConnector do
    use WebSockex

    def start(ws_url, _group_id, name, token, test_pid) do
      start_query(
        ws_url,
        %{"name" => name, "alias" => name, "os" => "linux"},
        token,
        test_pid
      )
    end

    def start_query(ws_url, query, token, test_pid, label \\ nil) do
      WebSockex.start(
        ws_url <> "/v1/connect?" <> URI.encode_query(query),
        __MODULE__,
        %{
          test: test_pid,
          writes: %{},
          reads: %{},
          label: label,
          reply_heartbeat: Map.get(query, "reply_heartbeat", true),
          report_connected: Map.get(query, "report_connected", false)
        },
        extra_headers:
          [{"authorization", "Bearer " <> token}] ++
            if(query["process_instance_id"],
              do: [{"x-salix-connector-instance-id", query["process_instance_id"]}],
              else: []
            )
      )
    end

    @impl true
    def handle_frame({:text, raw}, state) do
      msg = Jason.decode!(raw)

      case msg["type"] do
        "connected" ->
          SystemsRuntime.Proc.send(state.test, {:connected, msg["connector_run_id"]})

          if state.report_connected,
            do: SystemsRuntime.Proc.send(state.test, {:connected_frame, msg})

          {:ok, state}

        "heartbeat" ->
          if state.reply_heartbeat do
            {:reply, {:text, Jason.encode!(%{"type" => "heartbeat"})}, state}
          else
            {:ok, state}
          end

        type when type in ["response", "error"] ->
          SystemsRuntime.Proc.send(state.test, {:connector_frame, msg})
          {:ok, state}

        "stream" ->
          handle_stream(msg, state)

        "request" ->
          handle_request(msg, state)

        _ ->
          {:ok, state}
      end
    end

    @impl true
    def handle_info({:send_frame, frame}, state) do
      {:reply, {:text, Jason.encode!(frame)}, state}
    end

    defp handle_request(%{"id" => id, "method" => "read_stream", "params" => p} = msg, state) do
      SystemsRuntime.Proc.send(
        state.test,
        {:read_stream_request, p["path"], Map.has_key?(msg, "transfer")}
      )

      if p["path"] == "/blocked-stream" do
        frame = read_stream_frame(id, 1)
        {:reply, {:text, Jason.encode!(frame)}, put_in(state, [:reads, id], true)}
      else
        body = "stream@" <> p["path"]

        SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {
          :send_frame,
          %{
            "id" => id,
            "type" => "stream",
            "stream" => %{
              "channel" => "data",
              "data" => Base.encode64(body),
              "eof" => true,
              "seq" => 1
            }
          }
        })

        reply = %{"id" => id, "type" => "response", "result" => %{"size" => byte_size(body)}}
        {:reply, {:text, Jason.encode!(reply)}, state}
      end
    end

    defp handle_request(
           %{"id" => id, "method" => "meeting_artifact_read", "params" => p} = msg,
           state
         ) do
      SystemsRuntime.Proc.send(
        state.test,
        {:meeting_artifact_read_request, p["meeting_id"], p["source_ref"], p["expected_size"],
         p["max_bytes"], Map.has_key?(msg, "transfer")}
      )

      body = "meeting-artifact@" <> p["source_ref"]

      frame = %{
        "id" => id,
        "type" => "stream",
        "stream" => %{
          "channel" => "data",
          "data" => Base.encode64(body),
          "eof" => true,
          "seq" => 1
        }
      }

      SystemsClock.send_after(
        SystemsRuntime.Proc.self(),
        {:send_frame, frame},
        meeting_artifact_delay_ms(p["source_ref"])
      )

      reply = %{"id" => id, "type" => "response", "result" => %{"size" => byte_size(body)}}
      {:reply, {:text, Jason.encode!(reply)}, state}
    end

    defp handle_request(%{"id" => id, "method" => "write_stream", "params" => p} = msg, state) do
      SystemsRuntime.Proc.send(
        state.test,
        {:write_stream_request, p["path"], Map.has_key?(msg, "transfer")}
      )

      if p["path"] == "/write-error-begin" do
        reply = %{"id" => id, "type" => "error", "error" => "disk full at begin"}
        {:reply, {:text, Jason.encode!(reply)}, state}
      else
        state = put_in(state, [:writes, id], %{path: p["path"], chunks: []})

        if p["path"] == "/hold-write-begin" do
          {:ok, state}
        else
          reply = %{"id" => id, "type" => "response", "result" => %{"status" => "ready"}}
          {:reply, {:text, Jason.encode!(reply)}, state}
        end
      end
    end

    defp handle_request(%{"id" => id, "method" => "runtime_probe", "params" => params}, state) do
      SystemsRuntime.Proc.send(
        state.test,
        {:runtime_probe_request, SystemsRuntime.Proc.self(), id, params}
      )

      {:ok, state}
    end

    defp handle_request(
           %{"id" => id, "method" => method, "params" => params},
           state
         )
         when method in [
                "runtime_auth_subscription",
                "runtime_auth_read",
                "runtime_auth_login_start",
                "runtime_auth_login_cancel",
                "runtime_auth_status",
                "runtime_auth_verify",
                "runtime_auth_input_begin",
                "runtime_auth_input_submit",
                "runtime_auth_input_cancel"
              ] do
      SystemsRuntime.Proc.send(
        state.test,
        {:runtime_auth_request, SystemsRuntime.Proc.self(), id, method, params}
      )

      {:ok, state}
    end

    defp handle_request(
           %{"id" => id, "method" => "exec", "params" => %{"command" => "hold-exec"}},
           state
         ) do
      SystemsRuntime.Proc.send(state.test, {:held_exec_request, state.label, id})
      {:ok, state}
    end

    defp handle_request(%{"id" => id, "method" => "hold_rpc", "params" => params}, state) do
      SystemsRuntime.Proc.send(state.test, {:held_rpc_request, id, params})
      {:ok, state}
    end

    # A LAN gateway. A body asked for in chunks comes in one `response_chunk`
    # frame before the response, as a board sends it.
    defp handle_request(%{"id" => id, "method" => "lan_discover", "params" => params}, state) do
      SystemsRuntime.Proc.send(state.test, {:lan_gateway_request, "lan_discover", params})
      reply = %{"id" => id, "type" => "response", "result" => %{"hosts" => []}}
      {:reply, {:text, Jason.encode!(reply)}, state}
    end

    defp handle_request(
           %{"id" => id, "method" => "http_request", "params" => %{"url" => url} = params},
           state
         ) do
      SystemsRuntime.Proc.send(state.test, {:lan_gateway_request, "http_request", params})
      body = "body@" <> url

      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {
        :send_frame,
        %{
          "id" => id,
          "type" => "response",
          "result" => %{
            "status" => 200,
            "headers" => %{"Content-Type" => ["application/octet-stream"]},
            "body_encoding" => "chunks",
            "chunks" => 1,
            "body_bytes" => byte_size(body),
            "sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
            "truncated" => false,
            "final_url" => url,
            "method" => "GET"
          }
        }
      })

      chunk = %{
        "id" => id,
        "type" => "response_chunk",
        "seq" => 0,
        "data_b64" => Base.encode64(body)
      }

      {:reply, {:text, Jason.encode!(chunk)}, state}
    end

    defp handle_request(msg, state) do
      case msg do
        %{"id" => id, "method" => "agent_runtime_input", "params" => params} ->
          SystemsRuntime.Proc.send(state.test, {:agent_runtime_input, state.label, params})

          reply = %{
            "id" => id,
            "type" => "response",
            "result" => %{
              "accepted" => true,
              "dispatch_id" => params["dispatch_id"]
            }
          }

          {:reply, {:text, Jason.encode!(reply)}, state}

        %{"method" => "read", "params" => %{"path" => path}} ->
          SystemsRuntime.Proc.send(state.test, {:read_request, state.label, path})
          {:reply, {:text, Jason.encode!(reply(msg))}, state}

        _ ->
          {:reply, {:text, Jason.encode!(reply(msg))}, state}
      end
    end

    defp meeting_artifact_delay_ms("slow-" <> rest) do
      case Integer.parse(rest) do
        {delay, _suffix} when delay >= 0 and delay <= 1_000 -> delay
        _ -> 0
      end
    end

    defp meeting_artifact_delay_ms(_source_ref), do: 0

    defp handle_stream(%{"id" => id, "stream" => stream} = message, state) do
      stream_error = message["error"] || stream["error"]

      cond do
        state.reads[id] && stream["channel"] == "ack" && is_binary(stream_error) ->
          SystemsRuntime.Proc.send(
            state.test,
            {:read_stream_error_ack, id, stream["seq"], stream_error}
          )

          {:ok, update_in(state, [:reads], &Map.delete(&1, id))}

        state.reads[id] && stream["channel"] == "ack" ->
          next_seq = stream["seq"] + 1

          if next_seq <= 65 do
            if next_seq == 65,
              do: SystemsRuntime.Proc.send(state.test, {:read_stream_backpressured, id})

            {:reply, {:text, Jason.encode!(read_stream_frame(id, next_seq))}, state}
          else
            SystemsRuntime.Proc.send(state.test, {:read_stream_unexpected_ack, stream["seq"]})
            {:ok, state}
          end

        write = state.writes[id] ->
          chunk =
            case stream["data"] do
              data when is_binary(data) and data != "" ->
                Base.decode64!(data)

              _ ->
                ""
            end

          write = %{write | chunks: [chunk | write.chunks]}

          cond do
            write.path == "/hold-write-chunk" and stream["eof"] != true ->
              {:ok, put_in(state, [:writes, id], write)}

            write.path == "/hold-write-finish" and stream["eof"] == true ->
              {:ok, put_in(state, [:writes, id], write)}

            write.path == "/write-error-chunk" and stream["eof"] != true ->
              {:reply, {:text, Jason.encode!(write_stream_error(id, "disk full at chunk"))},
               update_in(state, [:writes], &Map.delete(&1, id))}

            write.path == "/write-error-finish" and stream["eof"] == true ->
              {:reply, {:text, Jason.encode!(write_stream_error(id, "disk full at finish"))},
               update_in(state, [:writes], &Map.delete(&1, id))}

            stream["eof"] == true ->
              body = write.chunks |> Enum.reverse() |> IO.iodata_to_binary()
              SystemsRuntime.Proc.send(state.test, {:write_stream_body, write.path, body})

              done = %{
                "id" => id,
                "type" => "stream",
                "stream" => %{
                  "channel" => "done",
                  "data" => Jason.encode!(%{"size" => byte_size(body)}),
                  "eof" => true
                }
              }

              {:reply, {:text, Jason.encode!(done)},
               update_in(state, [:writes], &Map.delete(&1, id))}

            true ->
              ack = %{
                "id" => id,
                "type" => "stream",
                "stream" => %{"channel" => "ack", "seq" => stream["seq"]}
              }

              {:reply, {:text, Jason.encode!(ack)}, put_in(state, [:writes, id], write)}
          end

        true ->
          {:ok, state}
      end
    end

    defp handle_stream(_msg, state), do: {:ok, state}

    defp read_stream_frame(id, seq) do
      %{
        "id" => id,
        "type" => "stream",
        "stream" => %{
          "channel" => "data",
          "data" => Base.encode64("x"),
          "seq" => seq
        }
      }
    end

    defp write_stream_error(id, reason) do
      %{
        "id" => id,
        "type" => "stream",
        "error" => reason,
        "stream" => %{"channel" => "done", "eof" => true}
      }
    end

    defp reply(%{"id" => id, "method" => "exec", "params" => p}) do
      %{
        "id" => id,
        "type" => "response",
        "result" => %{
          "exit_code" => 0,
          "stdout" => "ran: " <> p["command"],
          "stderr" => "",
          "truncated" => false,
          "status" => "completed",
          "env" => p["env"] || %{}
        }
      }
    end

    defp reply(%{"id" => id, "method" => "read", "params" => p}) do
      %{
        "id" => id,
        "type" => "response",
        "result" => %{"content" => "file@" <> p["path"], "size" => 5}
      }
    end

    defp reply(%{"id" => id, "method" => "android", "params" => params}) do
      %{
        "id" => id,
        "type" => "response",
        "result" => %{
          "action" => params["action"],
          "profile" => params["profile"],
          "lease_id" => params["lease_id"],
          "lease_seconds" => params["lease_seconds"],
          "forwarded" => true
        }
      }
    end

    defp reply(%{"id" => id, "method" => method, "params" => params})
         when method in ["process_list", "process_write", "process_tail", "computer_use"] do
      %{"id" => id, "type" => "response", "result" => %{"method" => method, "params" => params}}
    end

    defp reply(%{"id" => id, "method" => m}) do
      %{"id" => id, "type" => "error", "error" => "unsupported: " <> m}
    end
  end

  defmodule RuntimeProxyHandler do
    @behaviour SalixEnv.RuntimeProxy

    @impl true
    def handle(env_id, params, meta) do
      SystemsRuntime.Proc.send(SystemsRuntime.fetch_env!(:salix_env, :runtime_proxy_test_pid), {
        :runtime_proxy_called,
        env_id,
        params,
        meta
      })

      if params["route_path"] == "/tool/slow" do
        test_pid = SystemsRuntime.fetch_env!(:salix_env, :runtime_proxy_test_pid)
        SystemsRuntime.Proc.send(test_pid, {:runtime_proxy_blocked, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :release_runtime_proxy -> :ok
        end

        SystemsRuntime.Proc.send(test_pid, {:runtime_proxy_completed, SystemsRuntime.Proc.self()})
      end

      {:ok, %{"status" => 204}}
    end
  end

  defmodule TupleHttpFailingS3 do
    @behaviour SalixStore.S3

    def put(key, body, opts \\ []) do
      if key == SystemsRuntime.get_env(:salix_web, :connector_socket_test_fail_put_key) do
        {:error, {:http, 429, "slow down"}}
      else
        SalixStore.S3.Fake.put(key, body, opts)
      end
    end

    def put_stream(key, stream, opts \\ []), do: SalixStore.S3.Fake.put_stream(key, stream, opts)
    def multipart_create(key, opts \\ []), do: SalixStore.S3.Fake.multipart_create(key, opts)

    def multipart_upload_part(key, upload_id, part_number, body),
      do: SalixStore.S3.Fake.multipart_upload_part(key, upload_id, part_number, body)

    def multipart_complete(key, upload_id, parts),
      do: SalixStore.S3.Fake.multipart_complete(key, upload_id, parts)

    def multipart_abort(key, upload_id), do: SalixStore.S3.Fake.multipart_abort(key, upload_id)
    def get(key, opts \\ []), do: SalixStore.S3.Fake.get(key, opts)
    def stream(key, opts \\ []), do: SalixStore.S3.Fake.stream(key, opts)
    def head(key), do: SalixStore.S3.Fake.head(key)
    def delete(key, opts \\ []), do: SalixStore.S3.Fake.delete(key, opts)
    def list(key, opts \\ []), do: SalixStore.S3.Fake.list(key, opts)
  end

  defmodule MeetingReadStreamProbe do
    @moduledoc false
    @behaviour SalixMeet.Ports.AgentRuntime

    def ensure_agent(_request), do: :ok
    def verify_agent(_request), do: :ok
    def prepare_workspace_write(_agent_id, _path, _data), do: {:ok, %{}}
    def stat_workspace(_agent_id, _path), do: {:error, :not_found}
    def read_workspace(_agent_id, _path), do: {:error, :not_found}
    def commit_event(_request), do: {:ok, :created}

    def stream_workspace_write(_agent_id, env_id, _dst_path, src_path) do
      message = SalixEnv.Protocol.request("read_stream", %{"path" => src_path})

      case SalixEnv.Connector.Live.read_stream(env_id, message, 5_000) do
        {:ok, stream, _size} ->
          _ = Enum.to_list(stream)
          {:ok, %{}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def stream_meeting_artifact_write(
          _agent_id,
          env_id,
          _dst_path,
          meeting_id,
          source_ref,
          source_size
        ) do
      message =
        SalixEnv.Protocol.request("meeting_artifact_read", %{
          "meeting_id" => meeting_id,
          "source_ref" => source_ref,
          "expected_size" => source_size,
          "max_bytes" => 30 * 1024 * 1024
        })

      case SalixEnv.Connector.Live.read_stream(env_id, message, 5_000) do
        {:ok, stream, _size} ->
          _ = Enum.to_list(stream)
          {:ok, %{}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule BlockingMeetingRuntime do
    @moduledoc false

    def handle_connector_event(_env_id, params, _meta) do
      test_pid = SystemsRuntime.fetch_env!(:salix_web, :connector_meeting_runtime_test_pid)

      SystemsRuntime.Proc.send(
        test_pid,
        {:meeting_handler_started, params["sequence"], SystemsRuntime.Proc.self()}
      )

      SystemsRuntime.Proc.receive do
        :release -> {:ok, %{"accepted" => true}}
      end
    end
  end

  defmodule CommitThenBlockMeetingRuntime do
    @moduledoc false

    def handle_connector_event(env_id, params, meta) do
      result = SalixWeb.MeetingRuntime.handle_connector_event(env_id, params, meta)

      if params["block_after_commit"] == true do
        test_pid = SystemsRuntime.fetch_env!(:salix_web, :connector_meeting_runtime_test_pid)

        SystemsRuntime.Proc.send(
          test_pid,
          {:meeting_event_committed_before_reply, SystemsRuntime.Proc.self(), result}
        )

        SystemsRuntime.Proc.receive do
          :release_reply -> :ok
        end
      end

      result
    end
  end

  defmodule CommitThenDelayMeetingRuntime do
    @moduledoc false

    def handle_connector_event(env_id, params, meta) do
      result = SalixWeb.MeetingRuntime.handle_connector_event(env_id, params, meta)
      SystemsClock.sleep(params["delay_after_commit_ms"] || 0)
      result
    end
  end

  defmodule FakeLLM do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)
      SystemsClock.sleep(500)

      resp = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "MOCK SUMMARY"}}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp))
    end
  end

  defmodule RecordingFeishuDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.FeishuDirectDelivery

    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def records, do: Agent.get(__MODULE__, &Map.values/1)

    @impl true
    def post_text(connect, target, text, mentions, operation_ref) do
      record(operation_ref, %{
        "kind" => "text",
        "connect_id" => connect["connect_id"],
        "target" => target,
        "text" => text,
        "mentions" => mentions
      })
    end

    @impl true
    def post_file(agent_id, connect, target, path, blob_ref, operation_ref) do
      record(operation_ref, %{
        "kind" => "file",
        "agent_id" => agent_id,
        "connect_id" => connect["connect_id"],
        "target" => target,
        "path" => path,
        "blob_ref" => blob_ref
      })
    end

    defp record(operation_ref, attrs) do
      Agent.get_and_update(__MODULE__, fn records ->
        record =
          Map.merge(attrs, %{"operation_ref" => operation_ref, "message_id" => operation_ref})

        stored = Map.get(records, operation_ref, record)
        {{:ok, %{"message_id" => stored["message_id"]}}, Map.put(records, operation_ref, stored)}
      end)
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    # Pin the real dispatcher (SalixWeb.Application sets it at boot, but a
    # sibling app's test in the shared umbrella VM may have cleared it).
    prev_dispatch = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, SalixWeb.EnvDispatch)

    prev_runtime_proxy = SystemsRuntime.get_env(:salix_env, :runtime_proxy_handler)
    prev_runtime_proxy_test_pid = SystemsRuntime.get_env(:salix_env, :runtime_proxy_test_pid)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)

      if prev_dispatch,
        do: SystemsRuntime.put_env(:salix_agent, :env_dispatch, prev_dispatch),
        else: SystemsRuntime.delete_env(:salix_agent, :env_dispatch)

      if prev_runtime_proxy,
        do: SystemsRuntime.put_env(:salix_env, :runtime_proxy_handler, prev_runtime_proxy),
        else: SystemsRuntime.delete_env(:salix_env, :runtime_proxy_handler)

      if prev_runtime_proxy_test_pid,
        do:
          SystemsRuntime.put_env(:salix_env, :runtime_proxy_test_pid, prev_runtime_proxy_test_pid),
        else: SystemsRuntime.delete_env(:salix_env, :runtime_proxy_test_pid)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Connector socket"})
    Process.put(:test_tenant_id, tenant["tenant_id"])

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Test WS"}, tenant_id())
    group_id = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(%{"group_id" => group_id, "name" => "A"}, tenant_id())

    # /v1/connect requires a connector credential; group scope comes only from
    # that credential, not from query parameters.
    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "name" => "laptop",
        "alias" => "laptop"
      })

    Process.put(:test_device_id, token["device_id"])

    {:ok, group_id: group_id, agent_id: agent["agent_id"], connector_token: token["token"]}
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  defp ws_base do
    String.replace(SalixWeb.Application.base_url(), "http://", "ws://")
  end

  # Kill the client when the test ends so no long-lived WebSocket leaks into the
  # shared Bandit server and perturbs later streaming tests. on_exit closures
  # capture `pid` by value, so no live collector is needed; LIFO ordering runs
  # this before the backend-restore on_exit registered in setup.
  defp track(pid) do
    ExUnit.Callbacks.on_exit(fn ->
      if SystemsRuntime.Proc.alive?(pid), do: SystemsRuntime.Proc.exit(pid, :kill)
    end)

    pid
  end

  defp connect(group_id, name, token) do
    {:ok, pid} = FakeConnector.start(ws_base(), group_id, name, token, SystemsRuntime.Proc.self())
    track(pid)

    env_id =
      SystemsClock.vreceive do
        {:connected, env_id} -> env_id
      after
        3000 -> flunk("connector never received the connected frame")
      end

    {pid, env_id}
  end

  defp connect_cloud_vm!(group_id, agent_id, opts \\ []) do
    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "name" => "Cloud Workspace",
        "alias" => "cloud-vm"
      })

    query = %{"name" => "cloud-vm", "alias" => "cloud-vm", "os" => "linux"}
    query = Map.merge(query, Keyword.get(opts, :query, %{}))

    {:ok, pid} =
      FakeConnector.start_query(
        ws_base(),
        query,
        token["token"],
        SystemsRuntime.Proc.self(),
        opts[:label]
      )

    track(pid)
    settle_receive({:connected, connector_run_id})

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "type" => "metadata",
        "capabilities" => %{
          "environments" => [
            %{
              "environment_provider" => "cloud-vm",
              "environment_runtime_id" => "workspace",
              "alias" => "cloud-vm",
              "name" => "Cloud Workspace"
            }
          ]
        }
      }
    })

    assert eventually(fn ->
             match?({:ok, _id}, visible_environment_id(agent_id, "cloud-vm"))
           end)

    assert {:ok, _record, :created} =
             GroupCompute.ensure_group_workload(%{
               "tenant_id" => tenant_id(),
               "group_id" => group_id,
               "provider" => "cloudflare",
               "provider_resource_id" => "sandbox-stream-op",
               "provider_resource_name" =>
                 SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group_id),
               "env_id" => connector_run_id,
               "device_id" => token["device_id"],
               "connector_id" => token["connector_id"],
               "status" => "ready",
               "ready_at" => SystemsClock.system_time(:millisecond),
               "active_operation_count" => 0,
               "active_operations" => %{}
             })

    {pid, connector_run_id, token}
  end

  defp run_concurrently(items, fun) do
    parent = SystemsRuntime.Proc.self()

    tasks =
      Enum.map(items, fn item ->
        SystemsRuntime.Task.async(fn ->
          SystemsRuntime.Proc.send(parent, {:concurrent_ready, SystemsRuntime.Proc.self()})

          SystemsRuntime.Proc.receive do
            :concurrent_go -> fun.(item)
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        settle_receive({:concurrent_ready, pid})
        pid
      end)

    Enum.each(pids, &send(&1, :concurrent_go))
    Enum.map(tasks, &settled_await/1)
  end

  defp command_environment_id!(connector_run_id) do
    env = environment_for_run!(connector_run_id)

    case env["environment_id"] do
      id when is_binary(id) and id != "" -> id
      _ -> flunk("connector #{connector_run_id} did not project a command environment")
    end
  end

  defp visible_environment_id!(agent_id, alias_name) do
    case visible_environment_id(agent_id, alias_name) do
      {:ok, id} -> id
      _ -> flunk("agent #{agent_id} cannot see environment alias #{alias_name}")
    end
  end

  defp visible_environment_id(agent_id, alias_name) do
    with {:ok, envs} <- EnvDispatch.list_envs(agent_id),
         %{"environment_id" => id} when is_binary(id) and id != "" <-
           Enum.find(envs, &(&1["alias"] == alias_name)) do
      {:ok, id}
    else
      _ -> {:error, :not_found}
    end
  end

  defp environment_for_run!(connector_run_id) do
    {:ok, _transport_id, device} =
      SalixEnv.Registry.get_by_connector_run_id(connector_run_id)

    {:ok, environment} =
      SalixEnv.Control.get_environment(
        device["device_id"],
        device["group_id"],
        device["tenant_id"]
      )

    environment
  end

  test "connector registers, serves exec via EnvDispatch, and disconnect cleans up",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {pid, env_id} = connect(group_id, "laptop", token)
    environment = environment_for_run!(env_id)
    environment_id = environment["environment_id"]

    # Durable record is connected and visible on /v1/admin/runtime/environments.
    assert {:ok, %{"status" => "connected", "name" => "laptop"}} =
             SalixEnv.Control.get_environment(environment["device_id"], group_id, tenant_id())

    # env.exec through the production dispatch path, resolving the stable command environment.
    assert {:ok, %{"exit_code" => 0, "stdout" => "ran: uname -a"}} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "uname -a",
               %{}
             )

    assert {:ok, %{"env" => %{"GH_TOKEN" => "tok-live"}}} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "gh auth status",
               %{
                 "env" => %{"GH_TOKEN" => "tok-live"}
               }
             )

    # A generic file-op RPC also round trips.
    assert {:ok, %{"content" => "file@/etc/hostname"}} =
             EnvDispatch.request(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "read",
               %{"path" => "/etc/hostname"}
             )

    # Disconnect → durable record flips and dispatch reports it.
    SystemsRuntime.Proc.trap_exit(true)
    SystemsRuntime.Proc.exit(pid, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(environment["device_id"], group_id, tenant_id())
             )
           end)

    assert {:error, :no_environment} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "noop",
               %{}
             )
  end

  test "the limits a LAN gateway advertises reach discovery probes and binary requests",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    alias SalixAgent.Tools.LanGateway

    device_id = Process.get(:test_device_id)
    {pid, _connector_run_id} = connect(group_id, "board", token)

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "type" => "metadata",
        "capabilities" => %{
          "lan_gateway" => %{
            "methods" => ["http_request", "lan_discover", "udp_request"],
            "max_bytes" => 65_536,
            "max_timeout_seconds" => 30,
            "response_chunks" => %{"max_total_bytes" => 4_194_304, "chunk_bytes" => 32_768},
            "discover_probes" => %{
              "max_probes" => 4,
              "max_payload_bytes" => 256,
              "max_answer_bytes" => 1024,
              "max_total_answer_bytes" => 4096
            }
          }
        }
      }
    })

    assert eventually(fn ->
             match?(
               {:ok, %{"capabilities" => %{"lan_gateway" => %{"methods" => [_ | _]}}}},
               EnvDispatch.get_device(agent_id, device_id)
             )
           end)

    ctx = %{agent_id: agent_id, group_id: group_id}

    assert %{"probed" => ["gree", "miio"], "probes_truncated" => false} =
             LanGateway.lan_discover(%{"device_id" => device_id}, ctx) |> Jason.decode!()

    assert_received {:lan_gateway_request, "lan_discover",
                     %{"udp_probes" => [%{"id" => "gree"}, %{"id" => "miio"}]}}

    url = "http://192.168.5.33/snapshot"

    assert {content, [_event]} =
             LanGateway.lan_request(
               %{"device_id" => device_id, "url" => url, "response" => "binary"},
               ctx
             )

    assert_received {:lan_gateway_request, "http_request",
                     %{"response_mode" => "chunks", "max_bytes" => 4_194_304}}

    assert [%{"type" => "text", "text" => summary}] = Jason.decode!(content)
    size = byte_size("body@" <> url)
    assert %{"status" => 200, "size_bytes" => ^size} = Jason.decode!(summary)
  end

  test "android admission is fail-closed, forwards once enabled, and revokes immediately",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {pid, connector_run_id} = connect(group_id, "android-host", token)

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "type" => "metadata",
        "capabilities" => %{
          "android_device_tool" => true,
          "android" => %{
            "protocol_version" => 2,
            "profiles" => ["api30-phone", "api35-phone-google-apis"],
            "profile_details" => [
              %{"id" => "api30-phone", "status" => "installed"},
              %{"id" => "api35-phone-google-apis", "status" => "installed"}
            ],
            "default_profile" => "api35-phone-google-apis"
          },
          "environments" => [
            %{
              "environment_id" => "android-host",
              "environment_provider" => "connected",
              "environment_runtime_id" => "host",
              "alias" => "android-host",
              "name" => "Android host",
              "capabilities" => %{
                "android_device_tool" => true,
                "android" => %{
                  "protocol_version" => 2,
                  "profiles" => ["api30-phone", "api35-phone-google-apis"],
                  "profile_details" => [
                    %{"id" => "api30-phone", "status" => "installed"},
                    %{"id" => "api35-phone-google-apis", "status" => "installed"}
                  ],
                  "default_profile" => "api35-phone-google-apis"
                }
              }
            }
          ]
        }
      }
    })

    assert eventually(fn ->
             case EnvDispatch.list_envs(agent_id) do
               {:ok, envs} ->
                 Enum.any?(envs, fn env ->
                   env["alias"] == "android-host" and
                     get_in(env, ["capabilities", "android_device_tool"]) == true and
                     get_in(env, ["capabilities", "android", "profile_details"]) == [
                       %{"id" => "api30-phone", "status" => "installed"},
                       %{"id" => "api35-phone-google-apis", "status" => "installed"}
                     ]
                 end)

               _ ->
                 false
             end
           end)

    android_environment_id =
      SalixStore.RuntimeIds.device_environment_id(device_id, "connected", "host")

    action = %{
      "environment" => android_environment_id,
      "action" => "status",
      "lease_id" => "lease-e2e",
      "args" => %{
        "action" => "tap",
        "lease_id" => "nested-lease-must-not-win",
        "lease_seconds" => 60
      }
    }

    assert {:error, :android_not_authorized} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               action
             )

    policy = %{
      "version" => 2,
      "enabled" => true,
      "allowed_modes" => ["connected"],
      "allowed_profiles" => ["api30-phone", "api35-phone-google-apis"],
      "max_concurrent_leases" => 1,
      "max_lease_seconds" => 3600
    }

    assert {:ok, _} = Tenants.update_config(tenant_id(), "android_control", policy)

    assert {:error, :android_plugin_disabled} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               action
             )

    assert {:ok, _} = Plugins.enable_group(tenant_id(), group_id, "android-control")

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => group_id, "name" => "Router", "role" => "router"},
        tenant_id()
      )

    assert {:error, :android_not_authorized} =
             EnvDispatch.android(
               router["agent_id"],
               %{device_id: device_id, environment_id: android_environment_id},
               action
             )

    assert {:ok,
            %{
              "action" => "status",
              "lease_id" => "lease-e2e",
              "lease_seconds" => 900,
              "forwarded" => true
            }} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               action
             )

    assert {:ok, %{"lease_seconds" => 60}} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               Map.put(action, "lease_seconds", 60)
             )

    assert {:ok, %{"profile" => "api35-phone-google-apis", "action" => "start"}} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               %{"action" => "start"}
             )

    assert {:ok, %{"profile" => "api30-phone", "action" => "start"}} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               %{"action" => "start", "profile" => "api30-phone"}
             )

    assert {:error, :android_profile_required} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               %{"action" => "observe", "lease_id" => "lease-e2e"}
             )

    assert {:ok, _} =
             Tenants.update_config(
               tenant_id(),
               "android_control",
               Map.put(policy, "allowed_profiles", ["api30-phone"])
             )

    assert {:error, :android_profile_not_allowed} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               %{"action" => "start"}
             )

    assert {:error, :android_profile_not_allowed} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               %{
                 "action" => "end",
                 "profile" => "api35-phone-google-apis",
                 "lease_id" => "lease-e2e"
               }
             )

    assert SalixEnv.Bridge.local?(connector_run_id)

    assert {:ok, _} =
             Tenants.update_config(tenant_id(), "android_control", %{policy | "enabled" => false})

    assert {:error, :android_not_authorized} =
             EnvDispatch.android(
               agent_id,
               %{device_id: device_id, environment_id: android_environment_id},
               action
             )
  end

  test "connector-originated runtime_proxy requests call the configured handler",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "laptop", token)

    SystemsRuntime.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    SystemsRuntime.put_env(:salix_env, :runtime_proxy_test_pid, SystemsRuntime.Proc.self())

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => "runtime-1",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{
          "capability_token" => "cap",
          "method" => "POST",
          "route_path" => "/tool/im_api.internal.send_message"
        }
      }
    })

    settle_receive(
      {:runtime_proxy_called, ^env_id,
       %{
         "capability_token" => "cap",
         "method" => "POST",
         "route_path" => "/tool/im_api.internal.send_message"
       }, %{"group_id" => ^group_id}}
    )

    settle_receive(
      {:connector_frame,
       %{
         "id" => "runtime-1",
         "type" => "response",
         "result" => %{"status" => 204}
       }}
    )
  end

  test "missing connector heartbeat replies close the socket and mark it disconnected",
       %{group_id: group_id, connector_token: token} do
    previous_interval = SystemsRuntime.get_env(:salix_web, :connector_heartbeat_ms)
    previous_timeout = SystemsRuntime.get_env(:salix_web, :connector_heartbeat_timeout_ms)
    SystemsRuntime.put_env(:salix_web, :connector_heartbeat_ms, 20)
    SystemsRuntime.put_env(:salix_web, :connector_heartbeat_timeout_ms, 60)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_heartbeat_ms, previous_interval)
      restore_app_env(:salix_web, :connector_heartbeat_timeout_ms, previous_timeout)
    end)

    {:ok, pid} =
      FakeConnector.start_query(
        ws_base(),
        %{"name" => "silent", "os" => "linux", "reply_heartbeat" => false},
        token,
        SystemsRuntime.Proc.self()
      )

    track(pid)

    env_id =
      SystemsClock.vreceive do
        {:connected, env_id} -> env_id
      after
        3_000 -> flunk("silent connector never received the connected frame")
      end

    {:ok, device} = environment_device_for_run(env_id)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(device["device_id"], group_id, tenant_id())
             )
           end)
  end

  test "metadata frame persists system info and its update time into the record",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "laptop", token)

    system_info = %{
      "hostname" => "laptop.local",
      "os_type" => "Linux",
      "os_release" => "6.8.0-generic",
      "arch" => "x86_64",
      "cpu_model" => "AMD Ryzen 9",
      "cpu_count" => 16,
      "memory_total" => 33_554_432_000
    }

    # The connector advertises host facts via the metadata frame (same shape the
    # real Python/Go connectors send on connect).
    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{"computer_use_tool" => false},
         "skills" => [],
         "system_info" => system_info
       }}
    )

    assert eventually(fn ->
             match?(
               {:ok, %{"system_info" => ^system_info}},
               environment_for_run_result(env_id)
             )
           end)

    env = environment_for_run!(env_id)
    assert is_integer(env["system_info_updated_at"])
    assert env["system_info"]["hostname"] == "laptop.local"
  end

  test "removing a device without its token stops the live socket and fences the credential",
       %{group_id: group_id, connector_token: token} do
    {_pid, run_id} = connect(group_id, "laptop", token)
    device_id = environment_for_run!(run_id)["device_id"]
    [{owner, :connector}] = Registry.lookup(SalixEnv.Bridges, run_id)
    ref = SystemsRuntime.Proc.monitor(owner)

    assert {:ok, _env} = SalixEnv.Control.remove_environment(device_id, group_id, tenant_id())
    settle_receive({:DOWN, ^ref, :process, ^owner, _})
    assert {:error, :not_found} = SalixEnv.Registry.get_device(tenant_id(), group_id, device_id)

    case FakeConnector.start(ws_base(), group_id, "laptop", token, SystemsRuntime.Proc.self()) do
      {:ok, pid} -> track(pid)
      {:error, _reason} -> :ok
    end

    settle_refute_receive({:connected, _run_id}, 500)
    assert {:error, :not_found} = SalixEnv.Registry.get_device(tenant_id(), group_id, device_id)
  end

  # Electron mints the device's next credential before the current one expires,
  # and the station presents it on its live socket. The connection is never out
  # of service, keeps its run, and ends when the credential it holds expires.
  test "a device connection that renews its credential serves across the old credential's expiry",
       %{group_id: group_id, agent_id: agent_id} do
    {:ok, first} = desktop_credential(group_id, 600)
    device_id = first["device_id"]
    {pid, run_id, connected} = connect_desktop(first["token"])
    target = %{device_id: device_id, environment_id: command_environment_id!(run_id)}
    assert_serving(agent_id, target, group_id, device_id, run_id)

    {:ok, second} = desktop_credential(group_id, 1_200, device_id)
    assert_serving(agent_id, target, group_id, device_id, run_id)

    assert connected["credential_renewal"] == true
    renew_credential(pid, "renew-1", second["token"])
    settle_receive({:connector_frame, %{"id" => "renew-1", "type" => "response"}})

    SystemsClock.run_for(601_000)
    assert_serving(agent_id, target, group_id, device_id, run_id)

    # Electron revokes the replaced credential once it expired: the run holds the new one.
    :ok =
      SalixEnv.ConnectorTokens.revoke_group_connector_token(group_id, tenant_id(), first["token"])

    assert_serving(agent_id, target, group_id, device_id, run_id)

    SystemsClock.run_for(600_000)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Registry.get_device(tenant_id(), group_id, device_id)
             )
           end)
  end

  test "a connection renews only to its device's newest credential, and revoking that one ends it",
       %{group_id: group_id, agent_id: agent_id} do
    {:ok, first} = desktop_credential(group_id, 600)
    device_id = first["device_id"]
    {pid, run_id, _connected} = connect_desktop(first["token"])
    target = %{device_id: device_id, environment_id: command_environment_id!(run_id)}
    {:ok, other_device} = desktop_credential(group_id, 600)
    {:ok, superseded} = desktop_credential(group_id, 600, device_id)
    {:ok, newest} = desktop_credential(group_id, 600, device_id)

    renew_credential(pid, "renew-other", other_device["token"])
    settle_receive({:connector_frame, %{"id" => "renew-other", "type" => "error"}})
    renew_credential(pid, "renew-superseded", superseded["token"])
    settle_receive({:connector_frame, %{"id" => "renew-superseded", "type" => "error"}})
    assert_serving(agent_id, target, group_id, device_id, run_id)

    renew_credential(pid, "renew-newest", newest["token"])
    settle_receive({:connector_frame, %{"id" => "renew-newest", "type" => "response"}})
    [{socket, :connector}] = Registry.lookup(SalixEnv.Bridges, run_id)
    ref = SystemsRuntime.Proc.monitor(socket)

    :ok =
      SalixEnv.ConnectorTokens.revoke_group_connector_token(
        group_id,
        tenant_id(),
        newest["token"]
      )

    settle_receive({:DOWN, ^ref, :process, ^socket, _reason})
  end

  test "a newer credential takes service from the live connection of one that never expires",
       %{group_id: group_id, agent_id: agent_id} do
    {:ok, lasting} = desktop_credential(group_id, nil)
    device_id = lasting["device_id"]
    {_pid, run_id, _connected} = connect_desktop(lasting["token"])
    target = %{device_id: device_id, environment_id: command_environment_id!(run_id)}
    assert_serving(agent_id, target, group_id, device_id, run_id)

    {:ok, _newer} = desktop_credential(group_id, 600, device_id)
    assert {:error, :disconnected} = EnvDispatch.exec(agent_id, target, "date", %{})
  end

  test "a sent Cloud VM exec with an unknown result is not replayed on same-process reconnect",
       %{group_id: group_id, agent_id: agent_id} do
    query = %{
      "name" => "cloud-vm",
      "alias" => "cloud-vm",
      "os" => "linux",
      "process_instance_id" => "same-exec-process"
    }

    {first, first_run, token} = connect_cloud_vm!(group_id, agent_id, query: query, label: :first)
    first_record = environment_for_run!(first_run)
    assert first_record["process_instance_id"] == "same-exec-process"
    device = first_record["device_id"]
    target = %{device_id: device, environment_id: command_environment_id!(first_run)}

    call =
      SystemsRuntime.Task.async(fn -> EnvDispatch.exec(agent_id, target, "hold-exec", %{}) end)

    settle_receive({:held_exec_request, :first, _request})
    disconnect_connector!(first, first_run)

    {:ok, replacement} =
      FakeConnector.start_query(
        ws_base(),
        query,
        token["token"],
        SystemsRuntime.Proc.self(),
        :replacement
      )

    track(replacement)
    settle_receive({:connected, next_run})
    assert environment_for_run!(next_run)["device_id"] == device
    assert environment_for_run!(next_run)["process_instance_id"] == "same-exec-process"
    settle_refute_receive({:held_exec_request, :replacement, _request}, 200)
    assert {:error, :disconnected} = settled_await(call)
  end

  test "all environment operations use only the selected device after discovery", %{
    group_id: group_id,
    agent_id: agent_id,
    connector_token: token
  } do
    {_pid, run_id} = connect(group_id, "laptop", token)
    device = environment_for_run!(run_id)
    target = %{device_id: device["device_id"], environment_id: device["environment_id"]}
    key = Keys.ctl_group_device(tenant_id(), group_id, device["device_id"])
    run_key = Keys.connector_run(run_id)

    operations = [
      fn ->
        assert {:ok, %{"exit_code" => 0}} = EnvDispatch.exec(agent_id, target, "echo exact", %{})
      end,
      fn ->
        assert {:ok, %{"content" => "file@/exact"}} =
                 EnvDispatch.request(agent_id, target, "read", %{"path" => "/exact"})
      end,
      fn ->
        assert {:ok, %{"method" => "process_list"}} = EnvDispatch.process_list(agent_id, target)
      end,
      fn ->
        assert {:ok, %{"params" => %{"data" => "input"}}} =
                 EnvDispatch.process_write(agent_id, target, "shell", "input", %{})
      end,
      fn ->
        assert {:ok, %{"params" => %{"from_offset" => 12}}} =
                 EnvDispatch.process_tail(agent_id, target, "shell", %{"from_offset" => 12})
      end,
      fn ->
        assert {:ok, %{"method" => "computer_use"}} =
                 EnvDispatch.computer_use(agent_id, target, %{"action" => "snapshot"})
      end,
      fn ->
        assert {:ok, stream, _} = EnvDispatch.read_stream(agent_id, target, "/exact-stream")
        assert IO.iodata_to_binary(Enum.to_list(stream)) == "stream@/exact-stream"
      end,
      fn ->
        assert {:ok, %{"size" => 5}} =
                 EnvDispatch.write_stream(agent_id, target, "/exact-write", ["bytes"])
      end
    ]

    # Discovery and even the Agent control record may be unavailable; trusted
    # caller identity supplies scope, and every operation still reaches A.
    :ok = S3.Fake.blackhole({:fail, 503, :list, :any})
    :ok = S3.Fake.blackhole({:fail, 503, :get, Keys.ctl_agent(agent_id)})

    for operation <- operations do
      :ok = S3.Fake.reset_read_log()
      operation.()

      assert S3.Fake.read_log(SystemsRuntime.Proc.self()) == [
               {:get, key},
               {:get, run_key},
               {:get, key}
             ]
    end
  end

  test "exact environment targets preserve workspace, tenant, permission and offline rejection",
       %{
         group_id: group_id,
         agent_id: agent_id,
         connector_token: token
       } do
    {pid, run_id} = connect(group_id, "laptop", token)
    device = environment_for_run!(run_id)
    target = %{device_id: device["device_id"], environment_id: device["environment_id"]}

    {:ok, other_token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "name" => "other"
      })

    {_other_pid, other_run} = connect(group_id, "other", other_token["token"])
    other_env = command_environment_id!(other_run)
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Other workspace"}, tenant_id())

    {:ok, group_agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Other"},
        tenant_id()
      )

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Other tenant"})

    {:ok, tenant_group} =
      Salix.Control.Groups.create(%{"name" => "Other tenant workspace"}, tenant["tenant_id"])

    {:ok, tenant_agent} =
      SalixAgent.Control.create(
        %{"group_id" => tenant_group["group_id"], "name" => "Other tenant agent"},
        tenant["tenant_id"]
      )

    assert {:ok, %{"exit_code" => 0}} = EnvDispatch.exec(agent_id, target, "echo allowed", %{})

    for {caller, ref} <- [
          {group_agent["agent_id"], target},
          {tenant_agent["agent_id"], target},
          {agent_id, %{target | environment_id: other_env}},
          {agent_id, target.environment_id},
          {"invalid-agent", target}
        ] do
      :ok = S3.Fake.reset_read_log()
      assert {:error, :no_environment} = EnvDispatch.exec(caller, ref, "must not run", %{})
      refute Enum.any?(S3.Fake.read_log(SystemsRuntime.Proc.self()), &match?({:list, _, _}, &1))

      refute Enum.any?(
               S3.Fake.read_log(SystemsRuntime.Proc.self()),
               &match?({:get, "ctl/connector_runs/" <> _}, &1)
             )
    end

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame, %{"type" => "metadata", "capabilities" => %{"scope" => "local_file_read"}}}
    )

    assert eventually(fn ->
             case EnvDispatch.get_device(agent_id, target.device_id) do
               {:ok, current} -> hd(current["environments"])["status"] == "permission_required"
               _ -> false
             end
           end)

    assert {:error, {:permission_required, _}} =
             EnvDispatch.exec(agent_id, target, "must not run", %{})

    # Device discovery keeps the same target in read-only mode. Reading it
    # does not require granting the command and write capabilities.
    assert {:ok, stream, _} = EnvDispatch.read_stream(agent_id, target, "/read-only")
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "stream@/read-only"

    assert {:error, {:permission_required, _}} =
             EnvDispatch.write_stream(agent_id, target, "/read-only", ["changed"])

    # A foreign stable ID must not select A even when A's alias happens to
    # equal that ID. ID input is never retried as a name selector.
    assert {:ok, _} = SalixEnv.Registry.update_meta(run_id, &Map.put(&1, "alias", other_env))

    assert {:error, :no_environment} =
             EnvDispatch.exec(
               agent_id,
               %{target | environment_id: other_env},
               "must not run",
               %{}
             )

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame, %{"type" => "metadata", "capabilities" => %{"scope" => ""}}}
    )

    assert eventually(fn ->
             match?(
               {:ok, %{"exit_code" => 0}},
               EnvDispatch.exec(agent_id, target, "echo enabled", %{})
             )
           end)

    SystemsRuntime.Proc.exit(pid, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               EnvDispatch.get_device(agent_id, target.device_id)
             )
           end)

    assert {:error, :no_environment} = EnvDispatch.exec(agent_id, target, "must not run", %{})
  end

  test "stable environment id resolves to the current connector run after reconnect",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {first_pid, first_run_id} = connect(group_id, "laptop", token)
    first = environment_for_run!(first_run_id)
    environment_id = first["environment_id"]

    SystemsRuntime.Proc.exit(first_pid, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(first["device_id"], group_id, tenant_id())
             )
           end)

    {_second_pid, second_run_id} = connect(group_id, "laptop", token)
    assert first_run_id != second_run_id
    assert command_environment_id!(second_run_id) == environment_id

    assert {:ok, envs} = EnvDispatch.list_envs(agent_id)
    laptop_envs = Enum.filter(envs, &(&1["alias"] == "laptop"))
    assert [%{"environment_id" => ^environment_id, "status" => "connected"}] = laptop_envs

    assert {:ok, %{"exit_code" => 0, "stdout" => "ran: echo reconnected"}} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "echo reconnected",
               %{}
             )
  end

  test "operator runtime probe selects the private exact target and publishes canonical readiness",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "laptop", token)
    env = environment_for_run!(env_id)
    identity_material = "/private/bin/codex"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(env["device_id"], "codex", runtime_id)
    checked_at = SystemsClock.system_time(:millisecond)

    ready_runtime = %{
      "kind" => "external",
      "provider" => "codex",
      "command" => identity_material,
      "identity_material" => identity_material,
      "version" => "codex 1",
      "model" => "old-model",
      "model_provider" => "openai",
      "version_detected" => true,
      "auth_ready" => true,
      "native_server_startable" => true,
      "ready" => true,
      "readiness_checked_at" => checked_at,
      "readiness_valid_until" => checked_at + 600_000
    }

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{"runtime_probe" => true, "agent_runtimes" => [ready_runtime]}
       }}
    )

    assert eventually(fn ->
             case environment_for_run_result(env_id) do
               {:ok, %{"device_runtimes" => runtimes}} ->
                 Enum.any?(runtimes, &(&1["provider"] == "codex" and &1["status"] == "ready"))

               _ ->
                 false
             end
           end)

    tenant_id = tenant_id()

    task =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.probe_runtime(
          env["device_id"],
          device_runtime_id,
          group_id,
          tenant_id
        )
      end)

    settle_receive({:runtime_probe_request, ^pid, request_id, params})
    assert params == %{"provider" => "codex", "identity_material" => identity_material}

    unavailable_runtime =
      ready_runtime
      |> Map.put("auth_ready", false)
      |> Map.put("ready", false)
      |> Map.put("readiness_issue", "authentication_required")
      |> Map.put("readiness_checked_at", checked_at + 1)

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{"runtime_probe" => true, "agent_runtimes" => [unavailable_runtime]}
       }}
    )

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => request_id,
         "type" => "response",
         "result" => %{"runtimes" => [unavailable_runtime]}
       }}
    )

    assert {:ok, summary} = settled_await(task)
    assert summary["device_runtime_id"] == device_runtime_id
    refute Map.has_key?(summary, "identity_material")

    assert eventually(fn ->
             case environment_for_run_result(env_id) do
               {:ok, %{"device_runtimes" => runtimes}} ->
                 Enum.any?(
                   runtimes,
                   &(&1["device_runtime_id"] == device_runtime_id and
                       &1["status"] == "unavailable")
                 )

               _ ->
                 false
             end
           end)

    assert {:error, :not_found} =
             SalixEnv.Control.probe_runtime(
               env["device_id"],
               String.duplicate("0", 64),
               group_id,
               tenant_id()
             )
  end

  test "generic private input binds the current connected Pi target and rejects a changed inventory",
       %{group_id: group_id, connector_token: token} do
    {pid, run_id} = connect(group_id, "runtime-auth-private-pi", token)
    env = environment_for_run!(run_id)
    identity = "/private/bin/pi-input"

    runtime_id =
      RuntimeIds.device_runtime_id(env["device_id"], "pi", RuntimeIds.runtime_id(identity))

    now = SystemsClock.system_time(:millisecond)

    runtime = %{
      "kind" => "external",
      "provider" => "pi",
      "identity_material" => identity,
      "version_detected" => true,
      "native_server_startable" => true,
      "ready" => false,
      "auth_ready" => false,
      "readiness_checked_at" => now,
      "readiness_valid_until" => now + 600_000,
      "auth" => %{
        "schema_version" => 1,
        "status" => "configured",
        "requires_openai_auth" => false,
        "observed_at" => now,
        "backend" => "openrouter"
      }
    }

    publish = fn value ->
      SystemsRuntime.Proc.send(
        pid,
        {:send_frame,
         %{
           "type" => "metadata",
           "capabilities" => %{"runtime_auth_v1" => true, "agent_runtimes" => [value]}
         }}
      )
    end

    publish.(runtime)

    assert eventually(fn ->
             get_in(environment_device_for_run!(run_id), [
               "meta",
               "capabilities",
               "runtime_auth_v1"
             ]) == true
           end)

    attrs = %{
      actor_id: "current-admin",
      project_id: "project",
      tenant_id: tenant_id(),
      group_id: group_id,
      device_id: env["device_id"],
      runtime_id: runtime_id,
      backend: "openrouter",
      form: "api_key"
    }

    task = SystemsRuntime.Task.async(fn -> SalixEnv.Control.runtime_auth(:input_begin, attrs) end)
    settle_receive({:runtime_auth_request, ^pid, id, "runtime_auth_input_begin", params})
    target = params["target"]
    assert target["provider"] == "pi"
    assert target["identity_material"] == identity
    assert target["actor_id"] == "current-admin"

    context =
      target
      |> Map.delete("identity_material")
      |> Map.update!("generation", &to_string/1)
      |> Map.merge(%{
        "target_kind" => "connected_runtime",
        "workload_id" => "",
        "allocation_id" => "",
        "allocation_generation" => "",
        "native_generation" => "",
        "auth_epoch" => "",
        "backend" => "openrouter",
        "method" => "credential_import",
        "form" => "api_key",
        "schema_version" => 1,
        "sequence" => 1,
        "attempt_id" => "private-attempt",
        "expires_at" => now + 900_000
      })

    offer = %{
      "context" => context,
      "public_key" => Base.encode64(<<4, 0::512>>),
      "phase" => "awaiting_user",
      "save_result" => "not_committed"
    }

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame, %{"id" => id, "type" => "response", "result" => offer}}
    )

    assert {:ok, ^offer} = settled_await(task)

    submit_attrs =
      attrs
      |> Map.drop([:backend, :form])
      |> Map.merge(%{attempt_id: "private-attempt", envelope: "synthetic-envelope"})

    rejected =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth(:input_submit, submit_attrs)
      end)

    settle_receive({:runtime_auth_request, ^pid, rejected_id, "runtime_auth_input_submit", _})

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame, %{"id" => rejected_id, "type" => "error", "error" => "invalid_format"}}
    )

    assert {:error, :runtime_auth_failed} = settled_await(rejected)

    malformed =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth(:input_submit, submit_attrs)
      end)

    settle_receive({:runtime_auth_request, ^pid, malformed_id, "runtime_auth_input_submit", _})

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => malformed_id,
         "type" => "response",
         "result" => %{
           "save_result" => "not_committed",
           "issue" => "invalid_format",
           "unexpected" => true
         }
       }}
    )

    assert {:error, :invalid_runtime_auth_response} = settled_await(malformed)

    verify =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth(:verify, Map.delete(attrs, :form))
      end)

    settle_receive({:runtime_auth_request, ^pid, verify_id, "runtime_auth_verify", _params})
    changed = Map.put(runtime, "identity_material", "/private/bin/replaced-pi")
    publish.(changed)

    assert eventually(fn ->
             hd(environment_device_for_run!(run_id)["meta"]["agent_runtimes"])[
               "identity_material"
             ] == "/private/bin/replaced-pi"
           end)

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => verify_id,
         "type" => "response",
         "result" => %{"status" => "authenticated", "issue" => ""}
       }}
    )

    assert {:error, :runtime_auth_target_changed} = settled_await(verify)
    settle_refute_receive({:runtime_auth_request, ^pid, _, _, _})
    claude_identity = "/private/bin/claude-login"

    claude_runtime_id =
      RuntimeIds.device_runtime_id(
        env["device_id"],
        "claude",
        RuntimeIds.runtime_id(claude_identity)
      )

    publish.(%{
      runtime
      | "provider" => "claude",
        "identity_material" => claude_identity,
        "auth" => %{
          "schema_version" => 1,
          "status" => "unauthenticated",
          "requires_openai_auth" => false,
          "observed_at" => now,
          "backend" => "anthropic"
        }
    })

    assert eventually(fn ->
             hd(environment_device_for_run!(run_id)["meta"]["agent_runtimes"])["provider"] ==
               "claude"
           end)

    login_attrs = %{
      attrs
      | runtime_id: claude_runtime_id,
        backend: "anthropic"
    }

    login_attrs = Map.put(login_attrs, :flow, "authorization_code")

    login =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth(:login_start, login_attrs)
      end)

    settle_receive(
      {:runtime_auth_request, ^pid, login_id, "runtime_auth_login_start", login_params}
    )

    login_context =
      login_params["target"]
      |> Map.delete("identity_material")
      |> Map.update!("generation", &to_string/1)
      |> Map.merge(%{
        "target_kind" => "connected_runtime",
        "workload_id" => "",
        "allocation_id" => "",
        "allocation_generation" => "",
        "native_generation" => "native",
        "auth_epoch" => "1",
        "backend" => "anthropic",
        "method" => "native_login",
        "form" => "authorization_code",
        "schema_version" => 1,
        "sequence" => 1,
        "attempt_id" => "claude-attempt",
        "expires_at" => now + 900_000
      })
      |> Map.put("actor_id", "different-admin")

    SystemsRuntime.Proc.send(
      pid,
      {:send_frame,
       %{
         "id" => login_id,
         "type" => "response",
         "result" => %{
           "context" => login_context,
           "public_key" => Base.encode64(<<4, 0::512>>),
           "phase" => "awaiting_user",
           "save_result" => "not_committed",
           "verification_url" =>
             "https://claude.com/cai/oauth/authorize?code=true&client_id=client&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=challenge&code_challenge_method=S256&state=state"
         }
       }}
    )

    assert {:error, :invalid_runtime_auth_response} = settled_await(login)
  end

  test "runtime auth control dispatches only the current exact private target",
       %{group_id: group_id, connector_token: token} do
    attach_liveness_telemetry([[:salix, :operation, :stop]])

    {pid, connector_run_id} = connect(group_id, "runtime-auth-control", token)
    env = environment_for_run!(connector_run_id)
    identity_material = "/private/bin/codex-auth-control"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(env["device_id"], "codex", runtime_id)
    observed_at = SystemsClock.system_time(:millisecond)

    auth = %{
      "schema_version" => 1,
      "status" => "unauthenticated",
      "mode" => "chatgpt",
      "requires_openai_auth" => true,
      "observed_at" => observed_at
    }

    runtime = %{
      "kind" => "external",
      "provider" => "codex",
      "command" => "/private/command-must-not-be-dispatched",
      "identity_material" => identity_material,
      "version_detected" => true,
      "auth_ready" => false,
      "native_server_startable" => true,
      "ready" => false,
      "readiness_issue" => "authentication_required",
      "readiness_checked_at" => observed_at,
      "readiness_valid_until" => observed_at + 600_000,
      "auth" => auth
    }

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "type" => "metadata",
        "capabilities" => %{
          "runtime_probe" => true,
          "runtime_auth_v1" => true,
          "agent_runtimes" => [runtime]
        }
      }
    })

    assert eventually(fn ->
             match?(
               {:ok, %{"capabilities" => %{"runtime_auth_v1" => true}}},
               SalixEnv.Control.get_environment(
                 env["device_id"],
                 group_id,
                 tenant_id()
               )
             )
           end)

    tenant_id = tenant_id()

    read_task =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth_read(
          env["device_id"],
          device_runtime_id,
          group_id,
          tenant_id
        )
      end)

    settle_receive({:runtime_auth_request, ^pid, read_id, "runtime_auth_read", read_params})

    assert read_params == %{
             "provider" => "codex",
             "identity_material" => identity_material
           }

    refute Map.has_key?(read_params, "command")
    refute Map.has_key?(read_params, "path")

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => read_id,
        "type" => "response",
        "result" => %{
          "auth" => auth,
          "attempt_id" => "rta_read",
          "flow" => "device_code",
          "expires_at" => observed_at + 900_000
        }
      }
    })

    assert {:ok, %{"auth" => ^auth, "attempt_id" => "rta_read"}} = settled_await(read_task)

    settle_receive(
      {:liveness_telemetry, [:salix, :operation, :stop], %{duration: read_duration},
       %{
         component: "salix_env",
         operation: "runtime_auth_read",
         surface: "system",
         outcome: "ok"
       }}
    )

    assert is_integer(read_duration) and read_duration >= 0

    start_task =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_start(
          env["device_id"],
          device_runtime_id,
          "device_code",
          group_id,
          tenant_id
        )
      end)

    settle_receive(
      {:runtime_auth_request, ^pid, start_id, "runtime_auth_login_start", start_params}
    )

    assert start_params == %{
             "provider" => "codex",
             "identity_material" => identity_material,
             "flow" => "device_code"
           }

    ceremony = %{
      "attempt_id" => "rta_start",
      "flow" => "device_code",
      "verification_url" => "https://auth.openai.com/codex/device",
      "user_code" => "ABCD-EFGH",
      "expires_at" => observed_at + 900_000,
      "reused" => false,
      "auth" => Map.put(auth, "status", "pending")
    }

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{"id" => start_id, "type" => "response", "result" => ceremony}
    })

    assert {:ok, ^ceremony} = settled_await(start_task)

    settle_receive(
      {:liveness_telemetry, [:salix, :operation, :stop], %{duration: start_duration},
       %{
         component: "salix_env",
         operation: "runtime_auth_login_start",
         surface: "system",
         outcome: "ok"
       }}
    )

    assert is_integer(start_duration) and start_duration >= 0

    cancel_task =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_cancel(
          env["device_id"],
          device_runtime_id,
          "rta_start",
          group_id,
          tenant_id
        )
      end)

    settle_receive(
      {:runtime_auth_request, ^pid, cancel_id, "runtime_auth_login_cancel", cancel_params}
    )

    assert cancel_params == %{
             "provider" => "codex",
             "identity_material" => identity_material,
             "attempt_id" => "rta_start"
           }

    cancel_result = %{
      "attempt_id" => "rta_start",
      "canceled" => true,
      "auth" => auth
    }

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{"id" => cancel_id, "type" => "response", "result" => cancel_result}
    })

    assert {:ok, ^cancel_result} = settled_await(cancel_task)

    settle_receive(
      {:liveness_telemetry, [:salix, :operation, :stop], %{duration: cancel_duration},
       %{
         component: "salix_env",
         operation: "runtime_auth_login_cancel",
         surface: "system",
         outcome: "ok"
       }}
    )

    assert is_integer(cancel_duration) and cancel_duration >= 0

    mismatched_cancel_task =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_cancel(
          env["device_id"],
          device_runtime_id,
          "rta_expected",
          group_id,
          tenant_id
        )
      end)

    settle_receive(
      {:runtime_auth_request, ^pid, mismatched_cancel_id, "runtime_auth_login_cancel", _params}
    )

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => mismatched_cancel_id,
        "type" => "response",
        "result" => %{
          "attempt_id" => "rta_other",
          "canceled" => true,
          "auth" => auth
        }
      }
    })

    assert {:error, :invalid_runtime_auth_response} = settled_await(mismatched_cancel_task)

    settle_receive(
      {:liveness_telemetry, [:salix, :operation, :stop], _measurements,
       %{
         component: "salix_env",
         operation: "runtime_auth_login_cancel",
         surface: "system",
         outcome: "error"
       }}
    )

    bft_read_task =
      SystemsRuntime.Task.async(fn ->
        SystemsObservability.Context.with_surface("bft", fn ->
          SalixEnv.Control.runtime_auth_read(
            env["device_id"],
            device_runtime_id,
            group_id,
            tenant_id
          )
        end)
      end)

    settle_receive({:runtime_auth_request, ^pid, bft_read_id, "runtime_auth_read", _params})

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => bft_read_id,
        "type" => "response",
        "result" => %{"auth" => auth}
      }
    })

    assert {:ok, %{"auth" => ^auth}} = settled_await(bft_read_task)

    settle_receive(
      {:liveness_telemetry, [:salix, :operation, :stop], _measurements,
       %{
         component: "salix_env",
         operation: "runtime_auth_read",
         surface: "bft",
         outcome: "ok"
       }}
    )

    {:ok, api_key} =
      Salix.Control.Tenants.create_api_key(tenant_id, %{"name" => "runtime auth routes"})

    auth_path =
      "/v1/runtime/groups/#{group_id}/environments/#{env["device_id"]}/runtimes/#{device_runtime_id}/auth"

    unauthorized =
      :get
      |> Plug.Test.conn(auth_path)
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))

    assert unauthorized.status == 401
    assert Plug.Conn.get_resp_header(unauthorized, "cache-control") == ["no-store"]

    http_read_task =
      SystemsRuntime.Task.async(fn ->
        :get
        |> Plug.Test.conn(auth_path)
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
        |> SalixWeb.Router.call(SalixWeb.Router.init([]))
      end)

    settle_receive({:runtime_auth_request, ^pid, http_read_id, "runtime_auth_read", _params})

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => http_read_id,
        "type" => "response",
        "result" => %{
          "auth" => auth,
          "attempt_id" => "rta_http_read",
          "flow" => "device_code",
          "expires_at" => observed_at + 900_000
        }
      }
    })

    http_read = settled_await(http_read_task)
    assert http_read.status == 200
    assert Plug.Conn.get_resp_header(http_read, "cache-control") == ["no-store"]
    assert Jason.decode!(http_read.resp_body) == %{"auth" => auth}

    settle_receive(
      {:liveness_telemetry, [:salix, :operation, :stop], _measurements,
       %{
         component: "salix_env",
         operation: "runtime_auth_read",
         surface: "salix",
         outcome: "ok"
       }}
    )

    capacity_task =
      SystemsRuntime.Task.async(fn ->
        :get
        |> Plug.Test.conn(auth_path)
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
        |> SalixWeb.Router.call(SalixWeb.Router.init([]))
      end)

    settle_receive({:runtime_auth_request, ^pid, capacity_id, "runtime_auth_read", _params})

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => capacity_id,
        "type" => "error",
        "error" => "runtime auth capacity exhausted"
      }
    })

    capacity_response = settled_await(capacity_task)
    assert capacity_response.status == 503
    assert Plug.Conn.get_resp_header(capacity_response, "cache-control") == ["no-store"]
    assert Jason.decode!(capacity_response.resp_body) == %{"error" => "unavailable"}

    settle_receive(
      {:liveness_telemetry, [:salix, :operation, :stop], _measurements,
       %{
         component: "salix_env",
         operation: "runtime_auth_read",
         surface: "salix",
         outcome: "unavailable"
       }}
    )

    http_start_task =
      SystemsRuntime.Task.async(fn ->
        :post
        |> Plug.Test.conn(auth_path <> "/login", Jason.encode!(%{"flow" => "device_code"}))
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> SalixWeb.Router.call(SalixWeb.Router.init([]))
      end)

    settle_receive(
      {:runtime_auth_request, ^pid, http_start_id, "runtime_auth_login_start", _params}
    )

    http_ceremony = Map.put(ceremony, "attempt_id", "rta_http_start")

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{"id" => http_start_id, "type" => "response", "result" => http_ceremony}
    })

    http_start = settled_await(http_start_task)
    assert http_start.status == 200
    assert Plug.Conn.get_resp_header(http_start, "cache-control") == ["no-store"]
    assert Jason.decode!(http_start.resp_body) == http_ceremony

    telemetry_handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    test_pid = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        telemetry_handler,
        [:comma_system, :http, :stop],
        fn _event, _measurements, metadata, _config ->
          if metadata.method == "DELETE",
            do: SystemsRuntime.Proc.send(test_pid, {:runtime_auth_cancel_http, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(telemetry_handler) end)

    http_cancel_task =
      SystemsRuntime.Task.async(fn ->
        :delete
        |> Plug.Test.conn(
          auth_path <> "/login",
          Jason.encode!(%{"attempt_id" => "rta_http_start"})
        )
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> SalixWeb.Router.call(SalixWeb.Router.init([]))
      end)

    settle_receive(
      {:runtime_auth_request, ^pid, http_cancel_id, "runtime_auth_login_cancel", _params}
    )

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => http_cancel_id,
        "type" => "response",
        "result" => %{
          "attempt_id" => "rta_http_start",
          "canceled" => true,
          "auth" => auth
        }
      }
    })

    http_cancel = settled_await(http_cancel_task)
    assert http_cancel.status == 200
    assert Plug.Conn.get_resp_header(http_cancel, "cache-control") == ["no-store"]
    assert http_cancel.request_path == auth_path <> "/login"

    settle_receive({:runtime_auth_cancel_http, cancel_http_metadata})

    assert cancel_http_metadata.route ==
             "/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/auth/login"

    refute inspect(cancel_http_metadata) =~ "rta_http_start"
    refute http_cancel.request_path =~ "rta_http_start"
    assert Jason.decode!(http_cancel.resp_body) == %{"auth" => auth, "canceled" => true}

    assert {:error, :not_found} =
             SalixEnv.Control.runtime_auth_read(
               env["device_id"],
               String.duplicate("0", 64),
               group_id,
               tenant_id
             )

    assert {:error, :invalid_runtime_auth_flow} =
             SalixEnv.Control.runtime_auth_login_start(
               env["device_id"],
               device_runtime_id,
               "/bin/sh -c evil",
               group_id,
               tenant_id
             )

    assert {:error, :invalid_runtime_auth_attempt_id} =
             SalixEnv.Control.runtime_auth_login_cancel(
               env["device_id"],
               device_runtime_id,
               "unsafe\nvalue",
               group_id,
               tenant_id
             )
  end

  test "runtime auth rejects delayed success after runtime removal or connector replacement",
       %{group_id: group_id, connector_token: token} do
    {first_pid, first_run_id} = connect(group_id, "runtime-auth-inflight-fence", token)
    first = environment_for_run!(first_run_id)
    identity_material = "/private/bin/codex-inflight-fence"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(first["device_id"], "codex", runtime_id)
    observed_at = SystemsClock.system_time(:millisecond)
    tenant_id = tenant_id()

    auth = %{
      "schema_version" => 1,
      "status" => "pending",
      "mode" => "chatgpt",
      "requires_openai_auth" => true,
      "observed_at" => observed_at
    }

    runtime = %{
      "kind" => "external",
      "provider" => "codex",
      "command" => identity_material,
      "identity_material" => identity_material,
      "version_detected" => true,
      "auth_ready" => false,
      "native_server_startable" => true,
      "ready" => false,
      "readiness_checked_at" => observed_at,
      "readiness_valid_until" => observed_at + 600_000,
      "auth" => auth
    }

    publish_runtimes = fn runtimes ->
      SystemsRuntime.Proc.send(first_pid, {
        :send_frame,
        %{
          "type" => "metadata",
          "capabilities" => %{
            "runtime_auth_v1" => true,
            "agent_runtimes" => runtimes
          }
        }
      })
    end

    send_success = fn request_id, attempt_id ->
      SystemsRuntime.Proc.send(first_pid, {
        :send_frame,
        %{
          "id" => request_id,
          "type" => "response",
          "result" => %{
            "attempt_id" => attempt_id,
            "flow" => "device_code",
            "verification_url" => "https://auth.openai.com/codex/device",
            "user_code" => "STALE-CODE",
            "expires_at" => observed_at + 900_000,
            "reused" => false,
            "auth" => auth
          }
        }
      })
    end

    publish_runtimes.([runtime])

    assert eventually(fn ->
             match?(
               {:ok, %{"capabilities" => %{"runtime_auth_v1" => true}}},
               SalixEnv.Control.get_environment(
                 first["device_id"],
                 group_id,
                 tenant_id
               )
             )
           end)

    start_task =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_start(
          first["device_id"],
          device_runtime_id,
          "device_code",
          group_id,
          tenant_id
        )
      end)

    settle_receive(
      {:runtime_auth_request, ^first_pid, request_id, "runtime_auth_login_start", _params}
    )

    publish_runtimes.([])

    assert eventually(fn ->
             case SalixEnv.Registry.get_device(
                    tenant_id,
                    group_id,
                    first["device_id"]
                  ) do
               {:ok, current} ->
                 current["connector_run_id"] == first_run_id and
                   get_in(current, ["meta", "agent_runtimes"]) == []

               _other ->
                 false
             end
           end)

    send_success.(request_id, "rta_removed")

    assert {:error, :runtime_auth_target_changed} = settled_await(start_task)

    publish_runtimes.([runtime])

    assert eventually(fn ->
             case SalixEnv.Control.get_environment(
                    first["device_id"],
                    group_id,
                    tenant_id
                  ) do
               {:ok, current} ->
                 get_in(current, ["capabilities", "runtime_auth_v1"]) == true and
                   Enum.any?(
                     current["device_runtimes"],
                     &(&1["device_runtime_id"] == device_runtime_id)
                   )

               _other ->
                 false
             end
           end)

    replacement_task =
      SystemsRuntime.Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_start(
          first["device_id"],
          device_runtime_id,
          "device_code",
          group_id,
          tenant_id
        )
      end)

    settle_receive(
      {:runtime_auth_request, ^first_pid, replacement_request_id, "runtime_auth_login_start",
       _params}
    )

    {_second_pid, second_run_id} = connect(group_id, "runtime-auth-inflight-fence", token)

    assert second_run_id != first_run_id

    assert eventually(fn ->
             case SalixEnv.Registry.get_device(
                    tenant_id,
                    group_id,
                    first["device_id"]
                  ) do
               {:ok, current} -> current["connector_run_id"] == second_run_id
               _other -> false
             end
           end)

    send_success.(replacement_request_id, "rta_stale")

    assert {:error, :runtime_auth_target_changed} = settled_await(replacement_task)
  end

  test "write_stream uses connector frames without transfer callback",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {_pid, env_id} = connect(group_id, "laptop", token)
    environment_id = command_environment_id!(env_id)
    body = SystemsRuntime.Proc.random_bytes(96 * 1024)
    size = byte_size(body)

    assert {:ok, %{"ok" => true, "size" => ^size}} =
             EnvDispatch.write_stream(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "/tmp/from-vfs.bin",
               [body]
             )

    settle_receive({:write_stream_request, "/tmp/from-vfs.bin", false})
    settle_receive({:write_stream_body, "/tmp/from-vfs.bin", ^body})
  end

  test "meeting event replay after a lost WebSocket reply returns a duplicate result",
       %{group_id: group_id, connector_token: token} do
    previous_handler = SystemsRuntime.get_env(:salix_web, :connector_meeting_runtime_handler)
    previous_test_pid = SystemsRuntime.get_env(:salix_web, :connector_meeting_runtime_test_pid)

    SystemsRuntime.put_env(
      :salix_web,
      :connector_meeting_runtime_handler,
      __MODULE__.CommitThenBlockMeetingRuntime
    )

    SystemsRuntime.put_env(
      :salix_web,
      :connector_meeting_runtime_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_meeting_runtime_handler, previous_handler)
      restore_app_env(:salix_web, :connector_meeting_runtime_test_pid, previous_test_pid)
    end)

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id(), group_id)
    meeting_id = "mtg-socket-replay-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             SalixMeet.Store.create_once(meeting_id,
               state: %{
                 "tenant_id" => tenant_id(),
                 "group_id" => group_id,
                 "meeting_agent_id" => meeting_agent["meeting_agent_id"],
                 "meeting_session_id" => meeting_agent["meeting_session_id"],
                 "runtime_token" => "runtime-secret",
                 "status" => "active"
               }
             )

    event = %{
      "type" => "joiner_event",
      "event_id" => "socket-lost-ack-1",
      "meeting_id" => meeting_id,
      "runtime_token" => "runtime-secret",
      "joiner_event" => %{
        "type" => "caption",
        "speaker" => "Ann",
        "text" => "only once",
        "timestamp" => 1
      }
    }

    {first_pid, _first_env_id} = connect(group_id, "meeting-replay-first", token)

    SystemsRuntime.Proc.send(first_pid, {
      :send_frame,
      %{
        "id" => "meeting-replay-first",
        "type" => "request",
        "method" => "meeting_runtime_event",
        "params" => %{"event" => event, "block_after_commit" => true}
      }
    })

    settle_receive(
      {:meeting_event_committed_before_reply, first_worker, {:ok, %{"status" => "created"}}}
    )

    first_monitor = SystemsRuntime.Proc.monitor(first_pid)
    SystemsRuntime.Proc.exit(first_pid, :kill)
    settle_receive({:DOWN, ^first_monitor, :process, ^first_pid, _reason})
    SystemsRuntime.Proc.send(first_worker, :release_reply)

    {second_pid, _second_env_id} = connect(group_id, "meeting-replay-second", token)

    SystemsRuntime.Proc.send(second_pid, {
      :send_frame,
      %{
        "id" => "meeting-replay-second",
        "type" => "request",
        "method" => "meeting_runtime_event",
        "params" => %{"event" => event}
      }
    })

    settle_receive(
      {:connector_frame,
       %{
         "id" => "meeting-replay-second",
         "type" => "response",
         "result" => %{"status" => "duplicate"}
       }}
    )
  end

  test "read_stream uses connector frames without transfer callback",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    attach_liveness_telemetry([[:salix, :connector, :read_stream]])

    {_pid, env_id} = connect(group_id, "laptop", token)
    environment_id = command_environment_id!(env_id)

    assert {:ok, stream, nil} =
             EnvDispatch.read_stream(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "/tmp/to-vfs.bin"
             )

    settle_receive(
      {:liveness_telemetry, [:salix, :connector, :read_stream], %{},
       %{outcome: :accepted, transport: :websocket}}
    )

    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "stream@/tmp/to-vfs.bin"

    settle_receive(
      {:liveness_telemetry, [:salix, :connector, :read_stream], %{},
       %{outcome: :completed, transport: :websocket}}
    )

    settle_receive({:read_stream_request, "/tmp/to-vfs.bin", false})
  end

  test "nine concurrent cloud-vm env.copy reads install one complete skill package",
       %{group_id: group_id, agent_id: agent_id} do
    {_pid, run_id, cloud_token} = connect_cloud_vm!(group_id, agent_id)
    environment_id = command_environment_id!(run_id)
    device_id = cloud_token["device_id"]

    skill_id = "concurrent-install"

    ctx =
      %{
        agent_id: agent_id,
        tenant_id: tenant_id(),
        group_id: group_id,
        session_id: SalixStore.Ids.new_session_id(),
        role: "worker",
        runtime_kind: :internal
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    assert {:ok, create_event} =
             SkillStore.prepare_group_create(ctx, %{
               "skill_id" => skill_id,
               "name" => "Concurrent Install",
               "description" => "Nine-file Cloud VM install regression"
             })

    assert {:ok, %{}} =
             SkillStore.commit_operation("create-concurrent-install", %{}, [create_event])

    package_paths = [
      "SKILL.md",
      "references/api.md",
      "references/examples.md",
      "references/format.md",
      "references/troubleshooting.md",
      "scripts/check.sh",
      "scripts/install.sh",
      "scripts/run.sh",
      "scripts/verify.sh"
    ]

    prepared =
      run_concurrently(package_paths, fn relative_path ->
        source_path = "/tmp/install-package/" <> relative_path

        assert {result, [event]} =
                 Peers.copy(
                   %{
                     "src_device_id" => device_id,
                     "src_environment" => environment_id,
                     "src_path" => source_path,
                     "dst_environment" => "vfs",
                     "dst_path" => SkillProjection.skill_path(skill_id, relative_path)
                   },
                   ctx
                 )

        assert %{"copied" => true} = Jason.decode!(result)
        {relative_path, source_path, event}
      end)

    events = Enum.map(prepared, &elem(&1, 2))

    assert {:ok, %{}} =
             SkillStore.commit_operation("install-concurrent-package", %{}, events)

    assert {:ok, catalog} = SkillStore.read_scope(:group, group_id)
    files = catalog.skills[skill_id]["files"]
    assert Map.keys(files) |> Enum.sort() == Enum.sort(package_paths)

    Enum.each(prepared, fn {relative_path, source_path, _event} ->
      assert {:ok, "stream@" <> ^source_path} =
               SkillStore.read_entry(agent_id, files[relative_path])
    end)

    assert {:ok, %{"active_operation_count" => 0, "active_operations" => %{}}} =
             SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
  end

  test "two near-deadline artifact streams still finalize, ACK, and replay over the real WebSocket",
       %{group_id: group_id, connector_token: token} do
    assert {:ok, router} =
             SalixAgent.Control.create(
               %{"group_id" => group_id, "name" => "Router", "role" => "router"},
               tenant_id()
             )

    assert {:ok, _group} =
             Salix.Control.Groups.update(
               group_id,
               %{"router_agent_id" => router["agent_id"]},
               tenant_id()
             )

    {pid, _env_id} = connect(group_id, "meeting-deadline-nesting", token)

    previous_runtime = SystemsRuntime.get_env(:salix_meet, :agent_runtime_mod)
    previous_provider = SystemsRuntime.get_env(:salix_meet, :provider_mod)
    previous_handler = SystemsRuntime.get_env(:salix_web, :connector_meeting_runtime_handler)
    previous_feishu_delivery = SystemsRuntime.get_env(:salix_im, :feishu_direct_delivery_mod)
    previous_contract = SystemsRuntime.get_env(:salix_env, :meeting_artifact_timeout_contract)
    previous_protocol_timeouts = SystemsRuntime.get_env(:salix_env, :protocol_timeouts)

    previous_parent_floor =
      SystemsRuntime.get_env(:salix_web, :connector_meeting_event_task_timeout_ms)

    SystemsRuntime.put_env(:salix_meet, :agent_runtime_mod, Salix.Bindings.MeetingAgentRuntime)
    SystemsRuntime.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)

    SystemsRuntime.put_env(
      :salix_web,
      :connector_meeting_runtime_handler,
      __MODULE__.CommitThenDelayMeetingRuntime
    )

    SystemsRuntime.put_env(:salix_env, :protocol_timeouts, %{"meeting_artifact_read" => 200})

    SystemsRuntime.put_env(:salix_env, :meeting_artifact_timeout_contract, %{
      setup_ms: 50,
      frame_ms: 10,
      request_slop_ms: 300,
      finalize_ms: 100,
      server_slop_ms: 100
    })

    SystemsRuntime.put_env(:salix_web, :connector_meeting_event_task_timeout_ms, 100)
    start_supervised!(RecordingFeishuDelivery)
    SystemsRuntime.put_env(:salix_im, :feishu_direct_delivery_mod, RecordingFeishuDelivery)

    on_exit(fn ->
      restore_app_env(:salix_meet, :agent_runtime_mod, previous_runtime)
      restore_app_env(:salix_meet, :provider_mod, previous_provider)
      restore_app_env(:salix_web, :connector_meeting_runtime_handler, previous_handler)
      restore_app_env(:salix_im, :feishu_direct_delivery_mod, previous_feishu_delivery)
      restore_app_env(:salix_env, :meeting_artifact_timeout_contract, previous_contract)
      restore_app_env(:salix_env, :protocol_timeouts, previous_protocol_timeouts)

      restore_app_env(
        :salix_web,
        :connector_meeting_event_task_timeout_ms,
        previous_parent_floor
      )
    end)

    assert {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id(), group_id)
    meeting_id = "mtg-deadline-nesting-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    connect_id = "feishu-artifact-e2e"
    summary = %{"title" => "Artifact E2E", "key_points" => ["Two files committed"]}

    connect = %{
      "tenant_id" => tenant_id(),
      "group_id" => group_id,
      "connect_id" => connect_id,
      "provider" => "feishu",
      "status" => "connected",
      "app_id" => "cli_artifact_e2e",
      "app_secret" => "secret",
      "bot_open_id" => "ou_bot",
      "created_at" => SystemsClock.system_time(:second),
      "updated_at" => SystemsClock.system_time(:second)
    }

    assert {:ok, _} =
             S3.put(Keys.ctl_im_connect(group_id, connect_id), Jason.encode!(connect),
               if_none_match: "*"
             )

    owner_snapshot =
      SalixMeet.OwnerAttributionSnapshot.build(summary, summary, completed_at: 123)

    assert {:ok, _doc, _etag} =
             SalixMeet.Store.create_once(meeting_id,
               state: %{
                 "tenant_id" => tenant_id(),
                 "group_id" => group_id,
                 "meeting_agent_id" => meeting_agent["meeting_agent_id"],
                 "meeting_session_id" => meeting_agent["meeting_session_id"],
                 "runtime_token" => "deadline-secret",
                 "status" => "active",
                 "artifact_root" => SalixMeet.RuntimeEvents.artifact_root(meeting_id),
                 "provider" => "feishu",
                 "connect_id" => connect_id,
                 "title" => "Artifact E2E",
                 "summary" => summary,
                 "feishu_ref" => %{
                   "chat_id" => "oc_artifact_e2e",
                   "chat_type" => "group",
                   "thread_id" => "omt_artifact_e2e",
                   "root_message_id" => "om_artifact_root",
                   "trigger_message_id" => "om_artifact_trigger"
                 },
                 "delivery" => %{"owner_attribution" => owner_snapshot}
               }
             )

    transcript_ref = "slow-400-transcript"
    audio_ref = "slow-400-audio"

    event = %{
      "type" => "meeting_runtime_update",
      "event_id" => "deadline-nesting-event",
      "meeting_id" => meeting_id,
      "runtime_token" => "deadline-secret",
      "status" => "done",
      "summary" => summary,
      "artifacts" => [
        %{
          "kind" => "transcript",
          "filename" => "transcript.txt",
          "source_ref" => transcript_ref,
          "source_size" => byte_size("meeting-artifact@" <> transcript_ref)
        },
        %{
          "kind" => "audio",
          "filename" => "audio.ogg",
          "source_ref" => audio_ref,
          "source_size" => byte_size("meeting-artifact@" <> audio_ref)
        },
        %{
          "kind" => "audio",
          "filename" => "audio-over-limit.ogg",
          "source_error" => "artifact_count_limit"
        }
      ]
    }

    params = %{"event" => event, "delay_after_commit_ms" => 150}
    assert SalixWeb.ConnectorSocket.meeting_event_timeout_ms(params) == 1_200

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => "meeting-deadline-first",
        "type" => "request",
        "method" => "meeting_runtime_event",
        "params" => params
      }
    })

    transcript_size = byte_size("meeting-artifact@" <> transcript_ref)
    audio_size = byte_size("meeting-artifact@" <> audio_ref)

    settle_receive(
      {:meeting_artifact_read_request, ^meeting_id, ^transcript_ref, ^transcript_size, _max,
       false}
    )

    settle_receive(
      {:meeting_artifact_read_request, ^meeting_id, ^audio_ref, ^audio_size, _max, false}
    )

    settle_receive(
      {:connector_frame,
       %{
         "id" => "meeting-deadline-first",
         "type" => "response",
         "result" => %{"status" => "created"}
       }}
    )

    root = SalixMeet.RuntimeEvents.artifact_root(meeting_id)
    agent_id = meeting_agent["meeting_agent_id"]

    assert {:ok, "meeting-artifact@" <> ^transcript_ref} =
             SalixAgent.AgentWorkspace.read(agent_id, root <> "/transcript.txt")

    assert {:ok, "meeting-artifact@" <> ^audio_ref} =
             SalixAgent.AgentWorkspace.read(agent_id, root <> "/audio.ogg")

    assert {:ok, meeting_doc, _etag} = SalixMeet.Store.get(meeting_id)
    assert get_in(meeting_doc, ["state", "status"]) == "done"

    assert get_in(meeting_doc, ["state", "artifacts"]) |> Map.keys() |> Enum.sort() ==
             ["audio", "transcript"]

    delivery_result =
      SalixMeet.Delivery.deliver_one(meeting_id,
        node: "connector-terminal-artifact-e2e"
      )

    assert delivery_result == :published, inspect(SalixMeet.Store.get(meeting_id))

    assert {:ok, published_meeting, _etag} = SalixMeet.Store.get(meeting_id)
    assert get_in(published_meeting, ["state", "delivery", "feishu_summary"]) == "sent"
    assert get_in(published_meeting, ["state", "delivery", "feishu_transcript"]) == "sent"
    assert get_in(published_meeting, ["state", "delivery", "feishu_audio"]) == "sent"

    deliveries = RecordingFeishuDelivery.records()
    delivery_count = length(deliveries)
    assert delivery_count == 4

    assert Enum.all?(deliveries, fn delivery ->
             get_in(delivery, ["target", "chat_id"]) == "oc_artifact_e2e" and
               get_in(delivery, ["target", "root_message_id"]) ==
                 "om_artifact_root" and
               get_in(delivery, ["target", "message_thread_id"]) ==
                 "omt_artifact_e2e"
           end)

    assert Enum.count(deliveries, &(&1["agent_id"] == agent_id)) == 2

    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => "meeting-deadline-replay",
        "type" => "request",
        "method" => "meeting_runtime_event",
        "params" => params
      }
    })

    settle_receive(
      {:connector_frame,
       %{
         "id" => "meeting-deadline-replay",
         "type" => "response",
         "result" => %{"status" => "duplicate"}
       }}
    )

    settle_refute_receive({:meeting_artifact_read_request, ^meeting_id, _, _, _, _}, 100)
    assert length(RecordingFeishuDelivery.records()) == delivery_count
  end

  test "agent discovers a device, reads its environments, and executes without rediscovery",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {_pid, _env_id} = connect(group_id, "laptop", token)
    ctx = %{agent_id: agent_id, session_id: SalixStore.Ids.new_session_id()}

    :ok = S3.Fake.reset_read_log()

    assert %{"devices" => [%{"device_id" => ^device_id}], "next_cursor" => nil} =
             Jason.decode!(Peers.list_devices(%{"limit" => 1}, ctx))

    assert [{:list, _, [max_keys: 1]}] =
             Enum.filter(S3.Fake.read_log(SystemsRuntime.Proc.self()), &match?({:list, _, _}, &1))

    :ok = S3.Fake.reset_read_log()
    device = Jason.decode!(Peers.get_device(%{"device_id" => device_id}, ctx))
    refute Enum.any?(S3.Fake.read_log(SystemsRuntime.Proc.self()), &match?({:list, _, _}, &1))
    environment_id = hd(device["environments"])["environment_id"]

    assert {:error, :no_environment} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: device_id, environment_id: device["alias"]},
               "must not execute by alias",
               %{}
             )

    assert {:error, :no_environment} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: "another-device", environment_id: environment_id},
               "must not execute on another device",
               %{}
             )

    :ok = S3.Fake.reset_read_log()
    # env.exec tool returns the connector's result JSON.
    result =
      Jason.decode!(
        Peers.exec(
          %{
            "device_id" => device_id,
            "environment" => environment_id,
            "command" => "echo hi",
            "description" => "probe"
          },
          ctx
        )
      )

    assert result["stdout"] == "ran: echo hi"
    refute Enum.any?(S3.Fake.read_log(SystemsRuntime.Proc.self()), &match?({:list, _, _}, &1))
  end

  test "group-scoped connector token authenticates registration and is group-visible",
       %{group_id: group_id, agent_id: agent_id} do
    {:ok, sibling} =
      SalixAgent.Control.create(%{"group_id" => group_id, "name" => "Sibling"}, tenant_id())

    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "name" => "Group Laptop",
        "alias" => "shared"
      })

    device_id = token["device_id"]

    {:ok, pid} =
      FakeConnector.start_query(
        ws_base(),
        %{"os" => "linux"},
        token["token"],
        SystemsRuntime.Proc.self()
      )

    track(pid)

    env_id =
      SystemsClock.vreceive do
        {:connected, env_id} -> env_id
      after
        3000 -> flunk("connector never received the connected frame")
      end

    assert {:ok,
            %{
              "status" => "connected",
              "meta" => %{
                "group_id" => ^group_id,
                "alias" => "shared",
                "name" => "Group Laptop"
              }
            }} = environment_device_for_run(env_id)

    {:ok, registry_record} = environment_device_for_run(env_id)
    refute Map.has_key?(registry_record["meta"], "agent_id")

    environment = environment_for_run!(env_id)
    refute Map.has_key?(environment, "agent_id")

    {:ok, envs} = EnvDispatch.list_envs(agent_id)
    assert Enum.any?(envs, &(&1["alias"] == "shared"))

    {:ok, sibling_envs} = EnvDispatch.list_envs(sibling["agent_id"])
    assert Enum.any?(sibling_envs, &(&1["alias"] == "shared"))
    environment_id = visible_environment_id!(sibling["agent_id"], "shared")

    assert {:ok, %{"content" => "file@/tmp/x"}} =
             EnvDispatch.request(
               sibling["agent_id"],
               %{device_id: device_id, environment_id: environment_id},
               "read",
               %{
                 "path" => "/tmp/x"
               }
             )
  end

  defp attach_liveness_telemetry(events) do
    handler_id = {__MODULE__, SystemsRuntime.Proc.self(), SystemsRuntime.Proc.make_ref()}
    test_pid = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_liveness_telemetry/4,
        test_pid
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_liveness_telemetry(event, measurements, metadata, pid) do
    SystemsRuntime.Proc.send(pid, {:liveness_telemetry, event, measurements, metadata})
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp disconnect_connector!(connector, connector_run_id) do
    [{socket, :connector}] = Registry.lookup(SalixEnv.Bridges, connector_run_id)
    client_monitor = SystemsRuntime.Proc.monitor(connector)
    socket_monitor = SystemsRuntime.Proc.monitor(socket)
    SystemsRuntime.Proc.exit(connector, :kill)
    settle_receive({:DOWN, ^client_monitor, :process, ^connector, _reason})
    # The client DOWN alone says nothing about server teardown. Wait until
    # the socket has submitted its disconnect before inspecting/resuming the
    # queue or allowing the next test to replace its global executor.
    settle_receive({:DOWN, ^socket_monitor, :process, ^socket, _reason})
  end

  defp restore_app_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_app_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  # A desktop's credential, as Electron Main mints it: short-lived, for one
  # owner, and on the same stable device once it has one. A nil lifetime
  # mints one that never expires.
  defp desktop_credential(group_id, ttl_seconds, device_id \\ nil) do
    attrs = %{
      "name" => "desktop",
      "alias" => "desktop",
      "meta" => %{"owner_user_id" => "usr_desktop"}
    }

    attrs = if ttl_seconds, do: Map.put(attrs, "expires_in_seconds", ttl_seconds), else: attrs
    attrs = if device_id, do: Map.put(attrs, "stable_device_id", device_id), else: attrs
    SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), attrs)
  end

  defp connect_desktop(token) do
    query = %{
      "name" => "desktop",
      "alias" => "desktop",
      "os" => "darwin",
      "report_connected" => true
    }

    {:ok, pid} = FakeConnector.start_query(ws_base(), query, token, SystemsRuntime.Proc.self())
    track(pid)
    settle_receive({:connected_frame, %{"connector_run_id" => run_id} = connected})
    {pid, run_id, connected}
  end

  defp renew_credential(pid, id, token) do
    SystemsRuntime.Proc.send(pid, {
      :send_frame,
      %{
        "id" => id,
        "type" => "request",
        "method" => "connector_credential_renew",
        "params" => %{"token" => token}
      }
    })
  end

  defp assert_serving(agent_id, target, group_id, device_id, run_id) do
    assert {:ok, %{"stdout" => "ran: date"}} = EnvDispatch.exec(agent_id, target, "date", %{})

    assert {:ok, %{"status" => "connected", "connector_run_id" => ^run_id}} =
             SalixEnv.Registry.get_device(tenant_id(), group_id, device_id)
  end

  defp environment_device_for_run(connector_run_id) do
    case SalixEnv.Registry.get_by_connector_run_id(connector_run_id) do
      {:ok, _transport_id, device} -> {:ok, device}
      {:error, _} = error -> error
    end
  end

  defp environment_device_for_run!(connector_run_id) do
    {:ok, device} = environment_device_for_run(connector_run_id)
    device
  end

  defp environment_for_run_result(connector_run_id) do
    with {:ok, device} <- environment_device_for_run(connector_run_id) do
      SalixEnv.Control.get_environment(
        device["device_id"],
        device["group_id"],
        device["tenant_id"]
      )
    end
  end
end
