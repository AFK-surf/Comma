defmodule SalixWeb.ConnectorSocketTest do
  @moduledoc """
  End-to-end remote connector over a real WebSocket: a `websockex` client
  connects to the live `/v1/connect` Bandit endpoint (the same wire protocol the
  Go Connector speaks), and we drive RPCs through the full production path —
  `SalixWeb.EnvDispatch` → `SalixEnv.Connector.Live` → `SalixEnv.Bridge` →
  the socket — including the agent's `env.exec`/`env.list` tools, durable
  `/v1/admin/runtime/environments` registration, and disconnect cleanup.
  """
  use ExUnit.Case, async: false

  alias SalixWeb.{CloudVM, ConnectorDisconnectQueue, EnvDispatch}
  alias SalixStore.Compute, as: GroupCompute

  alias SalixAgent.ExternalAgentRuntime, as: ExternalRuntime
  alias SalixAgent.{SkillProjection, SkillStore}
  alias Salix.Control.{Plugins, Tenants}
  alias SalixStore.RuntimeIds
  alias SalixAgent.Tools.Peers
  alias SalixStore.{Keys, S3}

  @tag :subscription_runtime
  test "automatic Cloud VM binding rotates exhausted accounts only after idle acknowledgement",
       %{group_id: group, connector_token: token} do
    alias SalixAgent.SubscriptionStore, as: Store
    alias SalixWeb.{SubscriptionRuntimeAuth, CloudVM.Runtimes}

    worker = Process.whereis(SalixWeb.SubscriptionRuntimeWorker)
    :ok = :sys.suspend(worker)
    on_exit(fn -> if Process.alive?(worker), do: :sys.resume(worker) end)
    tenant = tenant_id()
    {pid, run} = connect(group, "quota-rotation", token)
    device = environment_for_run!(run)["device_id"]
    identity = "/private/salix/runtimes/quota-test/bin/codex"
    runtime = RuntimeIds.device_runtime_id(device, "codex", RuntimeIds.runtime_id(identity))
    now = System.system_time(:millisecond)

    auth = %{
      "schema_version" => 1,
      "status" => "authenticated",
      "requires_openai_auth" => true,
      "observed_at" => now
    }

    send(
      pid,
      {:send_frame,
       %{
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
               "auth_ready" => true,
               "native_server_startable" => true,
               "ready" => true,
               "auth" => auth,
               "readiness_checked_at" => now,
               "readiness_valid_until" => now + 600_000
             }
           ]
         }
       }}
    )

    assert eventually(fn ->
             match?(
               {:ok, _},
               SalixEnv.Control.subscription_runtime_target(device, runtime, group, tenant)
             )
           end)

    {:ok, _, _} =
      GroupCompute.ensure_group_workload(%{
        "tenant_id" => tenant,
        "group_id" => group,
        "device_id" => device,
        "env_id" => run,
        "connector_id" => SalixWeb.ComputeProviders.Cloudflare.cloudvm_connector_id(group),
        "provider" => "cloudflare",
        "provider_resource_name" => "quota-rotation",
        "runtime_targets" => %{
          "quota-test" => %{
            "provider" => "codex",
            "state" => "installed",
            "requested_at" => now
          }
        }
      })

    for account <- ~w(00-current 10-spare) do
      {:ok, sealed} =
        Store.seal(tenant, account, %{
          "access_token" => "access-secret",
          "account_id" => account,
          "expired" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
        })

      {:ok, _} =
        Store.create(tenant, %{
          "id" => account,
          "credential_kind" => "subscription_oauth",
          "provider" => "codex",
          "status" => "active",
          "disabled" => false,
          "credentials" => sealed
        })
    end

    reconcile = fn ->
      Task.async(fn ->
        {:ok, rec} = GroupCompute.group_workload(group)
        Runtimes.reconcile(rec, [])
      end)
    end

    ack = fn id ->
      send(pid, {:send_frame, %{"id" => id, "type" => "response", "result" => %{"auth" => auth}}})
    end

    task = reconcile.()

    assert_receive {:runtime_auth_request, ^pid, initial, "runtime_auth_subscription", params},
                   2_000

    assert params["subscription_account_id"] == "00-current"
    ack.(initial)
    Task.await(task)

    quota = %{
      "windows" => [
        %{
          "period" => "week",
          "remaining_percent" => 0,
          "reset_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
        }
      ]
    }

    {:ok, current} = Store.get(tenant, "00-current")
    {:ok, _} = Store.update(tenant, Map.put(current, "quota", quota), current["version"])

    # No replacement: retain the binding, rather than revoke into an empty pool.
    {:ok, spare} = Store.get(tenant, "10-spare")
    {:ok, spare} = Store.update(tenant, Map.put(spare, "disabled", true), spare["version"])
    Task.await(reconcile.())
    refute_receive {:runtime_auth_request, ^pid, _, "runtime_auth_subscription", _}, 50
    {:ok, _} = Store.update(tenant, Map.put(spare, "disabled", false), spare["version"])

    # Manual bindings never rotate, even when their account is exhausted.
    {:ok, _, _} =
      GroupCompute.update_group_workload(
        group,
        &put_in(&1, ["runtime_targets", "quota-test", "account_mode"], "manual")
      )

    Task.await(reconcile.())
    refute_receive {:runtime_auth_request, ^pid, _, "runtime_auth_subscription", _}, 50

    {:ok, _, _} =
      GroupCompute.update_group_workload(
        group,
        &put_in(&1, ["runtime_targets", "quota-test", "account_mode"], "auto")
      )

    # A busy/old Connector must not leave enabled=false for the revoke sweeper.
    task = reconcile.()
    assert_receive {:runtime_auth_request, ^pid, busy, "runtime_auth_subscription", params}, 2_000
    assert params["revoked"] and params["require_idle"]
    send(pid, {:send_frame, %{"id" => busy, "type" => "error", "error" => "runtime_busy"}})
    Task.await(task)

    assert {:ok, %{rows: [[true, "00-current"]]}} =
             Store.query(
               "SELECT enabled,account_id FROM runtime_subscription_bindings WHERE tenant_id=$1 AND device_runtime_id=$2",
               [tenant, runtime]
             )

    task = reconcile.()

    assert_receive {:runtime_auth_request, ^pid, revoke, "runtime_auth_subscription", params},
                   2_000

    assert params["revoked"] and params["require_idle"]
    ack.(revoke)

    assert_receive {:runtime_auth_request, ^pid, replacement, "runtime_auth_subscription",
                    params},
                   2_000

    assert params["subscription_account_id"] == "10-spare"
    refute params["revoked"]
    ack.(replacement)
    Task.await(task)

    assert {:ok, %{account_id: "10-spare", status: "ready"}} =
             SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    Task.await(reconcile.())
    refute_receive {:runtime_auth_request, ^pid, _, "runtime_auth_subscription", _}, 50
  end

  @tag :subscription_runtime
  test "subscription binding supplies only the scoped account and revokes disabled credentials",
       %{group_id: group, connector_token: token} do
    alias SalixAgent.{SubscriptionStore, AccountPool}
    alias SalixWeb.SubscriptionRuntimeAuth

    # This test drives each retry explicitly. The scheduled worker can otherwise
    # claim the reconnect before we observe it and wait for an unhandled ACK.
    worker = Process.whereis(SalixWeb.SubscriptionRuntimeWorker)
    :ok = :sys.suspend(worker)
    on_exit(fn -> if Process.alive?(worker), do: :sys.resume(worker) end)

    tenant = tenant_id()
    {pid, run} = connect(group, "subscription-worker", token)
    device = environment_for_run!(run)["device_id"]
    identity = "/private/bin/subscription-codex"
    runtime = RuntimeIds.device_runtime_id(device, "codex", RuntimeIds.runtime_id(identity))
    now = System.system_time(:millisecond)

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

    send(pid, {:send_frame, metadata})

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
        "expired" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
      })

    {:ok, saved_account} =
      SubscriptionStore.create(tenant, %{
        "id" => account,
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "status" => "active",
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
      Task.async(fn ->
        request.(:put, Map.put(attrs, "account_cursor", String.duplicate("x", 257)))
      end)

    assert_receive {:runtime_auth_request, ^pid, id, "runtime_auth_subscription", params}, 2_000
    assert params["access_token"] == "access-secret"
    refute inspect(params) =~ "never-leaves"

    send(
      pid,
      {:send_frame,
       %{
         "id" => id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "authenticated"}}
       }}
    )

    assert_receive {:runtime_probe_request, ^pid, probe_id, probe_params}, 2_000
    assert probe_params == %{"provider" => "codex", "identity_material" => identity}

    ready_runtime =
      metadata["capabilities"]["agent_runtimes"]
      |> hd()
      |> Map.merge(%{
        "auth_ready" => true,
        "ready" => true,
        "auth" => %{snapshot | "status" => "authenticated"}
      })

    send(
      pid,
      {:send_frame, put_in(metadata, ["capabilities", "agent_runtimes"], [ready_runtime])}
    )

    send(
      pid,
      {:send_frame,
       %{"id" => probe_id, "type" => "response", "result" => %{"runtimes" => [ready_runtime]}}}
    )

    bound = Task.await(task)
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
        "expired" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
      })

    {:ok, replacement} =
      SubscriptionStore.create(tenant, %{
        "id" => replacement_id,
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "status" => "active",
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
            Task.async(fn ->
              request.(:put, %{
                "account_id" => selected["id"],
                "expected_account_version" => selected["version"],
                "expected_binding" => previous["binding"]
              })
            end)

          assert_receive {:runtime_auth_request, ^pid, switch_id, "runtime_auth_subscription",
                          delivery},
                         2_000

          assert delivery["access_token"] == secret
          assert delivery["subscription_account_id"] == selected["id"]
          refute delivery["revoked"]

          send(
            pid,
            {:send_frame,
             %{
               "id" => switch_id,
               "type" => "response",
               "result" => %{"auth" => %{snapshot | "status" => "authenticated"}}
             }}
          )

          assert_receive {:runtime_probe_request, ^pid, check_id, _}, 2_000

          send(
            pid,
            {:send_frame,
             %{
               "id" => check_id,
               "type" => "response",
               "result" => %{"runtimes" => [ready_runtime]}
             }}
          )

          response = Task.await(switch)
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

    refute_receive {:runtime_auth_request, ^pid, _, "runtime_auth_subscription", _}, 100

    # A -> B -> A does not revive an old page's authority to unbind.
    assert request.(:delete, %{"expected_binding" => original_binding}).status == 409

    send(
      pid,
      {:send_frame,
       %{
         "id" => "pull",
         "type" => "request",
         "method" => "runtime_subscription_access",
         "params" => %{"identity_material" => identity, "account_id" => "attacker-selected"}
       }}
    )

    assert_receive {:connector_frame,
                    %{"id" => "pull", "type" => "response", "result" => access}},
                   2_000

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

    Process.exit(pid, :kill)

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
    send(pid, {:send_frame, metadata})

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
      Task.async(fn -> SalixWeb.SubscriptionRuntimeWorker.handle_info(:deliver, nil) end)

    assert_receive {:runtime_auth_request, ^pid, background_id, "runtime_auth_subscription",
                    background_access},
                   2_000

    assert background_access["subscription_account_id"] == account

    send(
      pid,
      {:send_frame,
       %{
         "id" => background_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "authenticated"}}
       }}
    )

    assert {:noreply, _} = Task.await(background)

    send(
      pid,
      {:send_frame,
       %{
         "id" => "restored",
         "type" => "request",
         "method" => "runtime_subscription_access",
         "params" => %{"identity_material" => identity}
       }}
    )

    assert_receive {:connector_frame,
                    %{"id" => "restored", "type" => "response", "result" => restored}},
                   2_000

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

    send(
      pid,
      {:send_frame,
       %{
         "id" => "disabled",
         "type" => "request",
         "method" => "runtime_subscription_access",
         "params" => %{"identity_material" => identity}
       }}
    )

    assert_receive {:connector_frame, %{"id" => "disabled", "type" => "error"}}, 2_000

    revoke =
      Task.async(fn -> SubscriptionRuntimeAuth.deliver([tenant, group, device, runtime]) end)

    assert_receive {:runtime_auth_request, ^pid, revoke_id, "runtime_auth_subscription",
                    revocation},
                   2_000

    assert revocation["revoked"] == true
    refute Map.has_key?(revocation, "access_token")

    send(
      pid,
      {:send_frame,
       %{
         "id" => revoke_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "error"}}
       }}
    )

    assert {:ok, _} = Task.await(revoke)

    unbind =
      Task.async(fn ->
        request.(:delete, %{
          "expected_binding" => bound_auth["binding"],
          "account_cursor" => String.duplicate("x", 257)
        })
      end)

    assert_receive {:runtime_auth_request, ^pid, unbind_id, "runtime_auth_subscription",
                    %{"revoked" => true}},
                   2_000

    send(
      pid,
      {:send_frame,
       %{
         "id" => unbind_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "error"}}
       }}
    )

    assert_receive {:runtime_probe_request, ^pid, restore_probe_id, _}, 2_000

    send(
      pid,
      {:send_frame,
       %{
         "id" => restore_probe_id,
         "type" => "response",
         "result" => %{"runtimes" => [ready_runtime]}
       }}
    )

    assert %{status: 200, resp_body: unbound_body} = Task.await(unbind)
    assert Jason.decode!(unbound_body)["state"] == "unbound"
    assert Jason.decode!(unbound_body)["accounts_unavailable"]
    assert {:error, :not_found} = SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    send(
      pid,
      {:send_frame,
       %{
         "id" => "unbound",
         "type" => "request",
         "method" => "runtime_subscription_access",
         "params" => %{"identity_material" => identity}
       }}
    )

    assert_receive {:connector_frame, %{"id" => "unbound", "result" => %{"bound" => false}}},
                   2_000

    # Pause real unbind after its durable disable, before it can issue revocation.
    # An older ordinary login ACK must not remove the revocation obligation.
    {:ok, record} = SubscriptionStore.get(tenant, account)

    assert {:ok, _} =
             AccountPool.update(tenant, account, %{
               "version" => record["version"],
               "disabled" => false
             })

    delivery =
      Task.async(fn ->
        SubscriptionRuntimeAuth.distribute(tenant, group, device, runtime, account)
      end)

    assert_receive {:runtime_auth_request, ^pid, old_id, "runtime_auth_subscription", old_access},
                   2_000

    refute old_access["revoked"]

    handler = {__MODULE__, :subscription_unbind_ack, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, test_pid ->
          if Process.get(:pause_subscription_unbind) &&
               String.contains?(meta.query, "SET enabled=false") do
            send(test_pid, {:subscription_unbind_paused, self()})

            receive do
              :continue_subscription_unbind -> :ok
            after
              5_000 -> raise "unbind barrier timed out"
            end
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    unbind =
      Task.async(fn ->
        Process.put(:pause_subscription_unbind, true)
        SubscriptionRuntimeAuth.unbind(tenant, group, device, runtime)
      end)

    assert_receive {:subscription_unbind_paused, unbind_pid}, 2_000

    send(
      pid,
      {:send_frame,
       %{
         "id" => old_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "authenticated"}}
       }}
    )

    assert {:ok, _} = Task.await(delivery)

    assert {:ok, %{account_id: ^account}} =
             SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    send(unbind_pid, :continue_subscription_unbind)

    assert_receive {:runtime_auth_request, ^pid, final_id, "runtime_auth_subscription",
                    final_revocation},
                   2_000

    assert final_revocation["revoked"] == true
    assert final_revocation["delivery_revision"] > old_access["delivery_revision"]
    assert {:ok, _} = SubscriptionRuntimeAuth.status(tenant, group, device, runtime)

    send(
      pid,
      {:send_frame,
       %{
         "id" => final_id,
         "type" => "response",
         "result" => %{"auth" => %{snapshot | "status" => "error"}}
       }}
    )

    assert {:ok, _} = Task.await(unbind)
    assert {:error, :not_found} = SubscriptionRuntimeAuth.status(tenant, group, device, runtime)
    :telemetry.detach(handler)
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
    ref = Process.monitor(owner)
    SalixCluster.NodeLifecycle.mark_draining()
    on_exit(fn -> SalixCluster.NodeLifecycle.clear_draining() end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = SalixWeb.ConnectorDrain.drain()
      end)

    assert log =~ "reason=connector_draining"
    assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1_000
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

  test "device tools retain persisted disable rules across the tool rename", %{
    group_id: group_id,
    agent_id: agent_id,
    connector_token: token
  } do
    {_pid, run_id} = connect(group_id, "policy-device", token)
    device_id = environment_for_run!(run_id)["device_id"]

    for {current, previous, args} <- [
          {"device.get", "env.get", %{"device_id" => device_id}},
          {"device.list", "env.list", %{}}
        ] do
      for name <- [current, previous], runtime_kind <- [:internal, :external] do
        assert {:ok, _} = SalixAgent.Control.configure(agent_id, %{"disabled_tools" => [name]})
        assert {:ok, stored} = SalixAgent.Control.get_record(agent_id)
        assert stored["disabled_tools"] == [previous]
        assert {:ok, config} = SalixAgent.AgentRuntimeConfig.resolve(agent_id)
        ctx = config |> Map.put(:agent_id, agent_id) |> Map.put(:runtime_kind, runtime_kind)
        disclosure = SalixAgent.ToolDisclosure.materialize_static(config.role, runtime_kind, ctx)
        ctx = Map.put(ctx, :tool_disclosure, disclosure)

        [result] =
          SalixAgent.Tools.execute(
            [%{"id" => "disabled-device", "name" => current, "args" => args}],
            ctx
          )

        assert result.status == "guidance",
               "#{name} no longer denied #{current} on #{runtime_kind}: #{inspect(result)}"
      end

      assert {:ok, _} = SalixAgent.Control.configure(agent_id, %{"disabled_tools" => []})
      assert {:ok, config} = SalixAgent.AgentRuntimeConfig.resolve(agent_id)
      ctx = Map.put(config, :agent_id, agent_id)

      ctx =
        Map.put(
          ctx,
          :tool_disclosure,
          SalixAgent.ToolDisclosure.materialize_static(config.role, :internal, ctx)
        )

      [result] =
        SalixAgent.Tools.execute(
          [%{"id" => "enabled-device", "name" => current, "args" => args}],
          ctx
        )

      assert result.status == "completed"
    end
  end

  test "operation stream surfaces one concrete durable-finish failure" do
    test_pid = self()

    stream = %EnvDispatch.OperationStream{
      stream: ["bytes"],
      on_finish: fn state, result ->
        send(test_pid, {:operation_finished, state, result})
        {:error, {:http, 503, "storage unavailable"}}
      end
    }

    assert_raise EnvDispatch.OperationFinishError,
                 ~r/cloud VM operation completion was not persisted.*503/,
                 fn -> Enum.to_list(stream) end

    assert_receive {:operation_finished, "completed", %{ok: true}}
    refute_receive {:operation_finished, _, _}
  end

  test "two streamed artifacts retain nested child, server, and callback budgets" do
    artifacts = [
      %{"source_ref" => "mart_audio", "source_size" => 30 * 1024 * 1024},
      %{"source_ref" => "mart_transcript", "source_size" => 2 * 1024 * 1024},
      %{"kind" => "audio", "source_error" => "artifact_count_limit"}
    ]

    params = %{"event" => %{"artifacts" => artifacts}}

    child_total =
      artifacts
      |> Enum.filter(&is_binary(&1["source_ref"]))
      |> Enum.map(fn artifact ->
        SalixEnv.Protocol.meeting_artifact_request_timeout(%{
          "expected_size" => artifact["source_size"]
        })
      end)
      |> Enum.sum()

    server_parent = SalixWeb.ConnectorSocket.meeting_event_timeout_ms(params)
    assert child_total == 300_000
    assert server_parent == 360_000
    assert child_total + 30_000 < server_parent
    assert server_parent < 390_000
  end

  test "a consumer close racing an in-flight frame completion returns the only error ACK" do
    token = make_ref()
    timer = Process.send_after(self(), :unused_stream_timeout, 60_000)
    id = "cancelled-stream"
    stream = %{"channel" => "data", "seq" => 7, "data" => Base.encode64("bytes")}

    task = %{
      timer: timer,
      starter_monitor: nil,
      monitor: nil,
      admission: nil,
      id: id,
      sender: self(),
      stream: stream
    }

    state = %SalixWeb.ConnectorSocket.State{
      stream_tasks: %{token => task},
      read_streams: %{},
      read_stream_cancellations: %{id => System.monotonic_time(:millisecond)}
    }

    assert {:push, {:text, encoded}, next_state} =
             SalixWeb.ConnectorSocket.handle_info(
               {:read_stream_frame_complete, token, {:error, :closed}},
               state
             )

    assert %{
             "id" => ^id,
             "type" => "stream",
             "stream" => %{"channel" => "ack", "seq" => 7},
             "error" => "server stream consumer closed"
           } = Jason.decode!(encoded)

    assert next_state.stream_tasks == %{}
    assert next_state.read_stream_cancellations == %{}
  end

  test "pending RPC and write-stream owners emit accepted and terminal lifecycles" do
    attach_liveness_telemetry([
      [:salix, :connector, :pending_rpc],
      [:salix, :connector, :write_stream]
    ])

    state = %SalixWeb.ConnectorSocket.State{}
    rpc_ref = make_ref()
    rpc_id = "telemetry-pending-rpc"
    rpc = rpc_frame(rpc_id, "read", %{"path" => "/telemetry"})

    assert {:push, {:text, _encoded}, state} =
             SalixWeb.ConnectorSocket.handle_info({:env_rpc, rpc_ref, self(), rpc}, state)

    assert_receive {:liveness_telemetry, [:salix, :connector, :pending_rpc], %{},
                    %{outcome: :accepted}}

    assert {:ok, state} =
             SalixWeb.ConnectorSocket.handle_in(
               {Jason.encode!(%{
                  "id" => rpc_id,
                  "type" => "response",
                  "result" => %{"ok" => true}
                }), [opcode: :text]},
               state
             )

    assert_receive {:env_rpc_reply, ^rpc_ref, {:ok, %{"ok" => true}}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :pending_rpc], %{},
                    %{outcome: :completed}}

    stream_ref = make_ref()
    stream_id = "telemetry-write-stream"

    stream_request =
      "write_stream"
      |> SalixEnv.Protocol.request(%{"path" => "/telemetry-write"})
      |> Map.put("id", stream_id)

    assert {:push, {:text, _encoded}, state} =
             SalixWeb.ConnectorSocket.handle_info(
               {:env_write_stream, :begin, stream_ref, self(), stream_request},
               state
             )

    assert_receive {:liveness_telemetry, [:salix, :connector, :write_stream], %{},
                    %{outcome: :accepted}}

    assert {:ok, state} =
             SalixWeb.ConnectorSocket.handle_in(
               {Jason.encode!(%{
                  "id" => stream_id,
                  "type" => "response",
                  "result" => %{"status" => "ready"}
                }), [opcode: :text]},
               state
             )

    assert_receive {:env_write_stream_reply, ^stream_ref, {:ok, %{"id" => ^stream_id}}}

    finish_ref = make_ref()

    assert {:push, {:text, _encoded}, state} =
             SalixWeb.ConnectorSocket.handle_info(
               {:env_write_stream, :eof, finish_ref, self(), stream_id},
               state
             )

    assert {:ok, _state} =
             SalixWeb.ConnectorSocket.handle_in(
               {Jason.encode!(%{
                  "id" => stream_id,
                  "type" => "stream",
                  "stream" => %{"channel" => "done", "eof" => true}
                }), [opcode: :text]},
               state
             )

    assert_receive {:env_write_stream_reply, ^finish_ref, {:ok, %{"ok" => true}}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :write_stream], %{},
                    %{outcome: :completed}}
  end

  test "external-event coordinator emits queue and completion transitions" do
    attach_liveness_telemetry([
      [:salix, :connector, :external_event],
      [:salix, :connector, :external_event_queue]
    ])

    test_pid = self()
    lane = {tenant_id(), "telemetry-group", "telemetry-device"}
    first_id = "telemetry-external-event-1"
    second_id = "telemetry-external-event-2"

    execute = fn params ->
      if params["event_id"] == first_id do
        send(test_pid, {:telemetry_external_event_started, self()})

        receive do
          :release_telemetry_external_event -> :ok
        end
      end

      {:ok, %{"event_id" => params["event_id"]}}
    end

    assert {:wait, first_ref} =
             SalixWeb.ConnectorExternalEventCoordinator.submit(
               self(),
               lane,
               1,
               first_id,
               %{"event_id" => first_id},
               execute
             )

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event], %{},
                    %{outcome: :accepted}}

    assert_receive {:telemetry_external_event_started, first_task}

    assert {:reply, %{"error_code" => "external_runtime_event_queued"}} =
             SalixWeb.ConnectorExternalEventCoordinator.submit(
               self(),
               lane,
               1,
               second_id,
               %{"event_id" => second_id},
               execute
             )

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event_queue], %{value: 1},
                    %{}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event], %{},
                    %{outcome: :queued}}

    send(first_task, :release_telemetry_external_event)

    assert_receive {:connector_external_event_reply, ^first_ref,
                    %{"id" => ^first_id, "type" => "response"}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event], %{},
                    %{outcome: :completed}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event_queue], %{value: 0},
                    %{}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event], %{},
                    %{outcome: :accepted}}

    assert eventually(fn ->
             state = :sys.get_state(SalixWeb.ConnectorExternalEventCoordinator)
             not Map.has_key?(state.events, {lane, second_id})
           end)
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
          reply_heartbeat: Map.get(query, "reply_heartbeat", true)
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
          send(state.test, {:connected, msg["connector_run_id"]})
          {:ok, state}

        "heartbeat" ->
          if state.reply_heartbeat do
            {:reply, {:text, Jason.encode!(%{"type" => "heartbeat"})}, state}
          else
            {:ok, state}
          end

        type when type in ["response", "error"] ->
          send(state.test, {:connector_frame, msg})
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
      send(state.test, {:read_stream_request, p["path"], Map.has_key?(msg, "transfer")})

      if p["path"] == "/blocked-stream" do
        frame = read_stream_frame(id, 1)
        {:reply, {:text, Jason.encode!(frame)}, put_in(state, [:reads, id], true)}
      else
        body = "stream@" <> p["path"]

        send(self(), {
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
      send(
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

      Process.send_after(self(), {:send_frame, frame}, meeting_artifact_delay_ms(p["source_ref"]))

      reply = %{"id" => id, "type" => "response", "result" => %{"size" => byte_size(body)}}
      {:reply, {:text, Jason.encode!(reply)}, state}
    end

    defp handle_request(%{"id" => id, "method" => "write_stream", "params" => p} = msg, state) do
      send(state.test, {:write_stream_request, p["path"], Map.has_key?(msg, "transfer")})

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
      send(state.test, {:runtime_probe_request, self(), id, params})
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
      send(state.test, {:runtime_auth_request, self(), id, method, params})
      {:ok, state}
    end

    defp handle_request(
           %{"id" => id, "method" => "exec", "params" => %{"command" => "hold-exec"}},
           state
         ) do
      send(state.test, {:held_exec_request, state.label, id})
      {:ok, state}
    end

    defp handle_request(%{"id" => id, "method" => "hold_rpc", "params" => params}, state) do
      send(state.test, {:held_rpc_request, id, params})
      {:ok, state}
    end

    defp handle_request(msg, state) do
      case msg do
        %{"id" => id, "method" => "agent_runtime_input", "params" => params} ->
          send(state.test, {:agent_runtime_input, state.label, params})

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
          send(state.test, {:read_request, state.label, path})
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
          send(
            state.test,
            {:read_stream_error_ack, id, stream["seq"], stream_error}
          )

          {:ok, update_in(state, [:reads], &Map.delete(&1, id))}

        state.reads[id] && stream["channel"] == "ack" ->
          next_seq = stream["seq"] + 1

          if next_seq <= 65 do
            if next_seq == 65, do: send(state.test, {:read_stream_backpressured, id})
            {:reply, {:text, Jason.encode!(read_stream_frame(id, next_seq))}, state}
          else
            send(state.test, {:read_stream_unexpected_ack, stream["seq"]})
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
              send(state.test, {:write_stream_body, write.path, body})

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
      send(Application.fetch_env!(:salix_env, :runtime_proxy_test_pid), {
        :runtime_proxy_called,
        env_id,
        params,
        meta
      })

      if params["route_path"] == "/tool/slow" do
        test_pid = Application.fetch_env!(:salix_env, :runtime_proxy_test_pid)
        send(test_pid, {:runtime_proxy_blocked, self()})

        receive do
          :release_runtime_proxy -> :ok
        end

        send(test_pid, {:runtime_proxy_completed, self()})
      end

      {:ok, %{"status" => 204}}
    end
  end

  defmodule OrderedExternalRuntimeHandler do
    def handle_connector_events(connector_run_id, params_list, meta) do
      test_pid = Application.fetch_env!(:salix_web, :connector_external_runtime_test_pid)

      send(
        test_pid,
        {:external_runtime_event_batch_started, Enum.map(params_list, & &1["sequence"])}
      )

      Enum.map(params_list, &handle_connector_event(connector_run_id, &1, meta))
    end

    def handle_connector_event(_connector_run_id, params, _meta) do
      test_pid = Application.fetch_env!(:salix_web, :connector_external_runtime_test_pid)
      sequence = params["sequence"]
      send(test_pid, {:external_runtime_event_started, sequence, self()})

      if params["block"] do
        receive do
          :release_external_runtime_event -> :ok
        end
      end

      result =
        cond do
          params["reject"] -> {:error, :injected_retryable_failure}
          params["terminal"] -> {:error, :external_session_read_only}
          params["missing"] -> {:error, :not_found}
          true -> {:ok, %{"sequence" => sequence}}
        end

      send(test_pid, {:external_runtime_event_completed, sequence})
      result
    end
  end

  defmodule LegacyExternalRuntimeHandler do
    @moduledoc false

    def handle_connector_event(connector_run_id, params, _meta) do
      test_pid = Application.fetch_env!(:salix_web, :connector_external_runtime_test_pid)
      event_id = params["event_id"]

      send(
        test_pid,
        {:legacy_external_runtime_event_started, event_id, connector_run_id, params, self()}
      )

      result =
        case params["outcome"] do
          "block" ->
            receive do
              {:complete_legacy_external_runtime_event, ^event_id, result} -> result
            end

          "terminal" ->
            {:error, :external_session_read_only}

          "transient" ->
            {:error, :not_running}

          "record_conflict" ->
            {:error, :external_session_record_conflict}

          _ ->
            {:ok, %{"event_id" => event_id, "sequence" => params["sequence"]}}
        end

      send(test_pid, {:legacy_external_runtime_event_completed, event_id, result})
      result
    end
  end

  defmodule TupleHttpFailingS3 do
    @behaviour SalixStore.S3

    def put(key, body, opts \\ []) do
      if key == Application.get_env(:salix_web, :connector_socket_test_fail_put_key) do
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
      test_pid = Application.fetch_env!(:salix_web, :connector_meeting_runtime_test_pid)
      send(test_pid, {:meeting_handler_started, params["sequence"], self()})

      receive do
        :release -> {:ok, %{"accepted" => true}}
      end
    end
  end

  defmodule CommitThenBlockMeetingRuntime do
    @moduledoc false

    def handle_connector_event(env_id, params, meta) do
      result = SalixWeb.MeetingRuntime.handle_connector_event(env_id, params, meta)

      if params["block_after_commit"] == true do
        test_pid = Application.fetch_env!(:salix_web, :connector_meeting_runtime_test_pid)
        send(test_pid, {:meeting_event_committed_before_reply, self(), result})

        receive do
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
      Process.sleep(params["delay_after_commit_ms"] || 0)
      result
    end
  end

  defmodule FakeLLM do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)
      Process.sleep(500)

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
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    # Pin the real dispatcher (SalixWeb.Application sets it at boot, but a
    # sibling app's test in the shared umbrella VM may have cleared it).
    prev_dispatch = Application.get_env(:salix_agent, :env_dispatch)
    Application.put_env(:salix_agent, :env_dispatch, SalixWeb.EnvDispatch)

    prev_runtime_proxy = Application.get_env(:salix_env, :runtime_proxy_handler)
    prev_runtime_proxy_test_pid = Application.get_env(:salix_env, :runtime_proxy_test_pid)

    prev_external_runtime_handler =
      Application.get_env(:salix_web, :connector_external_runtime_handler)

    prev_external_runtime_test_pid =
      Application.get_env(:salix_web, :connector_external_runtime_test_pid)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)

      if prev_dispatch,
        do: Application.put_env(:salix_agent, :env_dispatch, prev_dispatch),
        else: Application.delete_env(:salix_agent, :env_dispatch)

      if prev_runtime_proxy,
        do: Application.put_env(:salix_env, :runtime_proxy_handler, prev_runtime_proxy),
        else: Application.delete_env(:salix_env, :runtime_proxy_handler)

      if prev_runtime_proxy_test_pid,
        do: Application.put_env(:salix_env, :runtime_proxy_test_pid, prev_runtime_proxy_test_pid),
        else: Application.delete_env(:salix_env, :runtime_proxy_test_pid)

      restore_app_env(
        :salix_web,
        :connector_external_runtime_handler,
        prev_external_runtime_handler
      )

      restore_app_env(
        :salix_web,
        :connector_external_runtime_test_pid,
        prev_external_runtime_test_pid
      )
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
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp connect(group_id, name, token) do
    {:ok, pid} = FakeConnector.start(ws_base(), group_id, name, token, self())
    track(pid)

    env_id =
      receive do
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
    {:ok, pid} = FakeConnector.start_query(ws_base(), query, token["token"], self(), opts[:label])
    track(pid)
    assert_receive {:connected, connector_run_id}, 3_000

    send(pid, {
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
               "ready_at" => System.system_time(:millisecond),
               "active_operation_count" => 0,
               "active_operations" => %{}
             })

    {pid, connector_run_id, token}
  end

  defp run_concurrently(items, fun) do
    parent = self()

    tasks =
      Enum.map(items, fn item ->
        Task.async(fn ->
          send(parent, {:concurrent_ready, self()})

          receive do
            :concurrent_go -> fun.(item)
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:concurrent_ready, pid}, 1_000
        pid
      end)

    Enum.each(pids, &send(&1, :concurrent_go))
    Enum.map(tasks, &Task.await(&1, 10_000))
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

  test "real /v1/connect keeps a partitioned legacy predecessor retryable through migration",
       %{group_id: group_id} do
    raw_token = "salix_conn_ws_legacy_migration_partitioned"
    token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
    device_id = SalixStore.Ids.new_device_id()
    connector_id = "conn_ws_legacy_migration_partitioned"

    legacy_record = %{
      "token_hash" => token_hash,
      "tenant_id" => tenant_id(),
      "group_id" => group_id,
      "device_id" => device_id,
      "connector_id" => connector_id,
      "name" => "Legacy WebSocket predecessor",
      "alias" => "Legacy WebSocket predecessor",
      "meta" => %{"owner_user_id" => "usr_ws_legacy"},
      "created_at" => System.system_time(:second),
      "expires_at" => nil
    }

    assert {:ok, _} =
             S3.put(
               Keys.ctl_connector_token(token_hash),
               Jason.encode!(legacy_record),
               if_none_match: "*"
             )

    assert {:ok, legacy_pid} =
             FakeConnector.start_query(
               ws_base(),
               %{"name" => "legacy-ws-predecessor", "os" => "linux"},
               raw_token,
               self()
             )

    track(legacy_pid)

    legacy_run_id =
      receive do
        {:connected, connector_run_id} -> connector_run_id
      after
        3_000 -> flunk("legacy connector never crossed the live /v1/connect boundary")
      end

    assert {:ok, legacy_transport, connected} =
             SalixEnv.Registry.get_by_connector_run_id(legacy_run_id)

    assert connected["device_id"] == device_id
    assert connected["connector_id"] == connector_id

    # The single-node Bandit harness cannot sever the local BEAM node while
    # keeping its WebSocket process alive. Rewrite only the persisted owner
    # node to deterministically model that same post-connect partition: the
    # real socket remains registered locally while stop_owner_on/2 observes
    # the durable target as unreachable.
    device_key = Keys.ctl_group_device(tenant_id(), group_id, device_id)
    assert {:ok, %{body: body, etag: etag}} = S3.get(device_key)

    partitioned =
      body
      |> Jason.decode!()
      |> Map.put("node", "partitioned-ws-owner@unreachable")

    assert {:ok, _} = S3.put(device_key, Jason.encode!(partitioned), if_match: etag)

    assert {:ok, successor_credential} =
             SalixEnv.ConnectorTokens.create_group_connector_token(
               group_id,
               tenant_id(),
               %{
                 "scope" => "local_file_read",
                 "stable_device_id" => device_id,
                 "meta" => %{"owner_user_id" => "usr_ws_legacy"}
               }
             )

    {successor_pid, successor_run_id} =
      connect(
        group_id,
        "scoped-ws-successor",
        successor_credential["token"]
      )

    assert Process.alive?(successor_pid)

    assert {:ok, migrated} = SalixEnv.Registry.get_device(tenant_id(), group_id, device_id)
    assert migrated["connector_run_id"] == successor_run_id

    pending_key = "legacy:" <> connector_id
    assert [legacy_target] = migrated["pending_connector_revocations"][pending_key]
    assert legacy_target["connector_run_id"] == legacy_run_id
    assert legacy_target["transport_id"] == legacy_transport
    assert legacy_target["node"] == "partitioned-ws-owner@unreachable"

    assert {:error, {:owner_stop_unconfirmed, _reason}} =
             SalixEnv.ConnectorTokens.revoke_group_connector_token(
               group_id,
               tenant_id(),
               raw_token
             )

    assert {:ok, _token_object} = S3.get(Keys.ctl_connector_token(token_hash))

    assert {:ok, retryable} = SalixEnv.Registry.get_device(tenant_id(), group_id, device_id)
    assert [^legacy_target] = retryable["pending_connector_revocations"][pending_key]
    assert connector_id in retryable["revoked_legacy_connector_ids"]

    # The actual pre-generation socket is still physically alive while the
    # partition prevents confirmation. This is exactly why DELETE must remain
    # retryable rather than dropping the token/target operation handle.
    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())

    send(legacy_pid, {
      :send_frame,
      %{
        "id" => "legacy-after-partitioned-delete",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/legacy-still-live"}
      }
    })

    assert_receive {:runtime_proxy_called, ^legacy_run_id, _params, _meta}, 1_000

    # Simulate the remote owner finally reporting exact termination, then
    # confirm that the same DELETE operation can finish and drop its token.
    legacy_monitor = Process.monitor(legacy_pid)
    Process.exit(legacy_pid, :kill)
    assert_receive {:DOWN, ^legacy_monitor, :process, ^legacy_pid, :killed}, 1_000
    assert eventually(fn -> not SalixEnv.Bridge.local?(legacy_transport) end)

    assert :ok =
             SalixEnv.Registry.confirm_legacy_connector_owner_stop(
               tenant_id(),
               group_id,
               device_id,
               connector_id,
               legacy_target
             )

    assert :ok =
             SalixEnv.ConnectorTokens.revoke_group_connector_token(
               group_id,
               tenant_id(),
               raw_token
             )

    assert {:error, :not_found} = S3.get(Keys.ctl_connector_token(token_hash))
    assert Process.alive?(successor_pid)
  end

  test "real /v1/connect compensates a device CAS paused across credential expiry",
       %{group_id: group_id} do
    # Keep the predecessor's own mandatory token-expiry timer outside this
    # scenario. Sharing the candidate's two-second token made that independent
    # socket shutdown race the assertion about candidate compensation.
    assert {:ok, predecessor_credential} =
             SalixEnv.ConnectorTokens.create_group_connector_token(
               group_id,
               tenant_id(),
               %{
                 "scope" => "local_file_read",
                 "expires_in_seconds" => 300,
                 "meta" => %{"owner_user_id" => "usr_ws_expiry"}
               }
             )

    {predecessor_pid, predecessor_run_id} =
      connect(group_id, "expiry-ws-predecessor", predecessor_credential["token"])

    assert {:ok, minted} =
             SalixEnv.ConnectorTokens.create_group_connector_token(
               group_id,
               tenant_id(),
               %{
                 "scope" => "local_file_read",
                 "expires_in_seconds" => 2,
                 "stable_device_id" => predecessor_credential["device_id"],
                 "meta" => %{"owner_user_id" => "usr_ws_expiry"}
               }
             )

    assert minted["device_id"] == predecessor_credential["device_id"]
    assert minted["credential_generation"] > predecessor_credential["credential_generation"]

    device_key = Keys.ctl_group_device(tenant_id(), group_id, minted["device_id"])
    :ok = SalixStore.S3.Fake.set_fault({:pause, :put, device_key})
    test_pid = self()

    paused_upgrade =
      Task.async(fn ->
        FakeConnector.start_query(
          ws_base(),
          %{"name" => "expiry-ws-candidate", "os" => "linux"},
          minted["token"],
          test_pid
        )
      end)

    assert eventually(fn -> SalixStore.S3.Fake.paused?() end)
    assert eventually(fn -> System.system_time(:second) >= minted["expires_at"] end, 150)
    assert :ok = SalixStore.S3.Fake.release_pause()

    assert {:error, _upgrade_error} = Task.await(paused_upgrade, 5_000)
    refute_receive {:connected, _late_run_id}, 100

    assert {:ok, compensated} =
             SalixEnv.Registry.get_device(tenant_id(), group_id, minted["device_id"])

    assert compensated["status"] == "disconnected"
    refute Map.has_key?(compensated, "connector_run_id")

    # The post-CAS expiry path compensates only its exact candidate and never
    # issues predecessor retirement. The old socket remains physically alive
    # (but exact-run authorization prevents scoped read_ref service).
    assert Process.alive?(predecessor_pid)

    assert {:error, :disconnected} =
             SalixEnv.Connector.Live.request(
               predecessor_run_id,
               "read_ref",
               %{"local_file_ref" => "lfi1_expired_candidate"}
             )
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
    Process.flag(:trap_exit, true)
    Process.exit(pid, :kill)

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

  test "android admission is fail-closed, forwards once enabled, and revokes immediately",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {pid, connector_run_id} = connect(group_id, "android-host", token)

    send(pid, {
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

    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())

    send(pid, {
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

    assert_receive {:runtime_proxy_called, ^env_id,
                    %{
                      "capability_token" => "cap",
                      "method" => "POST",
                      "route_path" => "/tool/im_api.internal.send_message"
                    }, %{"group_id" => ^group_id}},
                   1000

    assert_receive {:connector_frame,
                    %{
                      "id" => "runtime-1",
                      "type" => "response",
                      "result" => %{"status" => 204}
                    }},
                   1000
  end

  test "archive repair connection rejects connector-originated tool requests" do
    state = %SalixWeb.ConnectorSocket.State{archive_repair: true}

    frame =
      Jason.encode!(%{
        "id" => "repair-runtime-proxy",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "POST", "route_path" => "/tool/im_api.internal.send_message"}
      })

    assert {:push, {:text, reply}, ^state} =
             SalixWeb.ConnectorSocket.handle_in({frame, [opcode: :text]}, state)

    assert %{"type" => "error", "id" => "repair-runtime-proxy"} = Jason.decode!(reply)
  end

  test "archive repair settles stale runtime events through the normal authorization boundary",
       %{group_id: group_id} do
    device_id = "archive-repair-#{group_id}"

    {:ok, run, record} =
      SalixEnv.Registry.connect(Atom.to_string(node()), %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id,
        "device_id" => device_id,
        "connector_id" => device_id,
        "managed_compute" => true
      })

    pid =
      start_supervised!(
        {SalixWeb.CloudVM.ConnectorSession,
         transport: self(),
         env_id: run,
         connector_run_id: run,
         connection_generation: record["connection_generation"],
         tenant_id: tenant_id(),
         group_id: group_id,
         device_id: device_id,
         connector_id: device_id,
         managed_compute: true,
         archive_repair: true}
      )

    assert_receive {:connector_push, ^pid, _connected}
    event_id = SalixStore.ULID.generate()

    event = %{
      "event_id" => event_id,
      "capability_token" => "expired-runtime-capability",
      "event" => %{
        "provider" => "codex",
        "type" => "status",
        "name" => "connector/reconnected",
        "state" => "settled",
        "created_at" => System.system_time(:second)
      }
    }

    send(
      pid,
      {:connector_frame, self(),
       Jason.encode!(%{
         "id" => "repair-events",
         "type" => "request",
         "method" => "external_runtime_events",
         "params" => %{"events" => [event]}
       })}
    )

    assert_receive {:connector_push, ^pid, batch_reply}, 1_000

    assert %{
             "type" => "response",
             "result" => %{
               "accepted_event_ids" => [],
               "permanently_rejected_events" => [
                 %{"event_id" => ^event_id, "error_code" => "unauthorized"}
               ]
             }
           } = Jason.decode!(batch_reply)

    send(
      pid,
      {:connector_frame, self(),
       Jason.encode!(%{
         "id" => event_id,
         "type" => "request",
         "method" => "external_runtime_event",
         "params" => event
       })}
    )

    assert_receive {:connector_push, ^pid, legacy_reply}, 1_000

    assert %{
             "type" => "response",
             "result" => %{
               "accepted" => false,
               "disposition" => "permanently_rejected",
               "error_code" => "unauthorized"
             }
           } = Jason.decode!(legacy_reply)
  end

  test "control task supervisor pause cannot block the real WebSocket reader",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "control-reader", token)
    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())
    :sys.suspend(SalixWeb.ConnectorControlTaskSupervisor)

    on_exit(fn ->
      if supervisor = Process.whereis(SalixWeb.ConnectorControlTaskSupervisor) do
        if Process.alive?(supervisor) do
          try do
            :sys.resume(SalixWeb.ConnectorControlTaskSupervisor)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    send(pid, {
      :send_frame,
      %{"type" => "metadata", "capabilities" => %{"paused_control" => true}}
    })

    send(pid, {
      :send_frame,
      %{
        "id" => "control-reader-runtime",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/health"}
      }
    })

    assert_receive {:runtime_proxy_called, ^env_id, _params, _meta}, 1_000

    assert_receive {:connector_frame, %{"id" => "control-reader-runtime", "type" => "response"}},
                   1_000

    :sys.resume(SalixWeb.ConnectorControlTaskSupervisor)
  end

  test "timed out control starter cannot execute stale metadata after supervisor resumes",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "control-stale-start", token)
    previous_executor = Application.get_env(:salix_web, :connector_control_executor)
    previous_timeout = Application.get_env(:salix_web, :connector_control_task_timeout_ms)
    previous_retry = Application.get_env(:salix_web, :connector_control_retry_ms)
    test_pid = self()

    Application.put_env(:salix_web, :connector_control_task_timeout_ms, 20)
    Application.put_env(:salix_web, :connector_control_retry_ms, 200)

    Application.put_env(:salix_web, :connector_control_executor, fn operation ->
      send(test_pid, {:authorized_control_operation, operation})
      :ok
    end)

    :sys.suspend(SalixWeb.ConnectorControlTaskSupervisor)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_control_executor, previous_executor)
      restore_app_env(:salix_web, :connector_control_task_timeout_ms, previous_timeout)
      restore_app_env(:salix_web, :connector_control_retry_ms, previous_retry)

      if supervisor = Process.whereis(SalixWeb.ConnectorControlTaskSupervisor) do
        if Process.alive?(supervisor) do
          try do
            :sys.resume(supervisor)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    send(pid, {
      :send_frame,
      %{"type" => "metadata", "capabilities" => %{"version" => "old"}}
    })

    send(pid, {
      :send_frame,
      %{"type" => "metadata", "capabilities" => %{"version" => "new"}}
    })

    Process.sleep(60)
    :sys.resume(SalixWeb.ConnectorControlTaskSupervisor)

    refute_receive {:authorized_control_operation, _operation}, 100

    assert_receive {:authorized_control_operation,
                    %{
                      connector_run_id: ^env_id,
                      patch: %{"capabilities" => %{"version" => "new"}}
                    }},
                   500

    refute_receive {:authorized_control_operation, _operation}, 100
  end

  test "global control overload retries without crashing the socket actor",
       %{group_id: group_id, connector_token: first_token} do
    previous_limit = Application.get_env(:salix_web, :connector_control_task_limit)
    previous_retry = Application.get_env(:salix_web, :connector_control_retry_ms)
    previous_executor = Application.get_env(:salix_web, :connector_control_executor)
    Application.put_env(:salix_web, :connector_control_task_limit, 1)
    Application.put_env(:salix_web, :connector_control_retry_ms, 20)
    test_pid = self()

    Application.put_env(:salix_web, :connector_control_executor, fn operation ->
      send(test_pid, {:control_overload_operation, operation})
      :ok
    end)

    {:ok, second_token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "name" => "second-control-connector",
        "alias" => "second-control-connector"
      })

    {first, _first_env_id} = connect(group_id, "first-control-connector", first_token)
    {second, second_env_id} = connect(group_id, "second-control-connector", second_token["token"])
    [{second_actor, :connector}] = Registry.lookup(SalixEnv.Bridges, second_env_id)
    :sys.suspend(SalixWeb.ConnectorControlTaskSupervisor)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_control_task_limit, previous_limit)
      restore_app_env(:salix_web, :connector_control_retry_ms, previous_retry)
      restore_app_env(:salix_web, :connector_control_executor, previous_executor)

      if supervisor = Process.whereis(SalixWeb.ConnectorControlTaskSupervisor) do
        if Process.alive?(supervisor) do
          try do
            :sys.resume(supervisor)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    send(first, {:send_frame, %{"type" => "metadata", "capabilities" => %{"lane" => 1}}})
    assert eventually(fn -> SalixWeb.ConnectorTaskAdmission.count(:control) == 1 end)
    send(second, {:send_frame, %{"type" => "metadata", "capabilities" => %{"lane" => 2}}})
    Process.sleep(80)
    assert Process.alive?(second_actor)

    :sys.resume(SalixWeb.ConnectorControlTaskSupervisor)

    assert_receive {:control_overload_operation, %{patch: %{"capabilities" => %{"lane" => 1}}}},
                   500

    assert_receive {:control_overload_operation, %{patch: %{"capabilities" => %{"lane" => 2}}}},
                   500
  end

  test "request task supervisor pause cannot block or defeat timeout on the real WebSocket",
       %{
         group_id: group_id,
         agent_id: agent_id,
         connector_token: token
       } do
    device_id = Process.get(:test_device_id)
    {pid, env_id} = connect(group_id, "request-supervisor-paused", token)
    environment_id = command_environment_id!(env_id)
    previous_timeout = Application.get_env(:salix_web, :connector_request_task_timeout_ms)
    Application.put_env(:salix_web, :connector_request_task_timeout_ms, 50)
    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())
    :sys.suspend(SalixWeb.ConnectorRequestTaskSupervisor)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_request_task_timeout_ms, previous_timeout)

      if supervisor = Process.whereis(SalixWeb.ConnectorRequestTaskSupervisor) do
        if Process.alive?(supervisor) do
          try do
            :sys.resume(supervisor)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    send(pid, {
      :send_frame,
      %{
        "id" => "paused-request-supervisor",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/health"}
      }
    })

    assert {:ok, %{"content" => "file@/still-responsive"}} =
             EnvDispatch.request(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "read",
               %{
                 "path" => "/still-responsive"
               }
             )

    assert_receive {:connector_frame,
                    %{
                      "id" => "paused-request-supervisor",
                      "type" => "error",
                      "error" => "server request timed out"
                    }},
                   500

    :sys.resume(SalixWeb.ConnectorRequestTaskSupervisor)
    refute_receive {:runtime_proxy_called, ^env_id, _params, _meta}, 250
  end

  test "partial metadata frames coalesce by field through the real WebSocket",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "metadata-coalesce", token)
    previous_executor = Application.get_env(:salix_web, :connector_control_executor)
    test_pid = self()

    Application.put_env(:salix_web, :connector_control_executor, fn operation ->
      send(test_pid, {:metadata_control_operation, operation, self()})

      if operation[:patch] == %{
           "capabilities" => %{"initial" => true},
           "runtime_auth_generation" => nil,
           "runtime_session_snapshot_generation" => nil
         } do
        receive do
          :release_metadata_control -> :ok
        end
      end

      SalixEnv.Registry.update_meta(
        operation.connector_run_id,
        &Map.merge(&1, operation.patch),
        connection_generation: operation.generation,
        owner_node: operation.owner_node
      )
    end)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_control_executor, previous_executor)
    end)

    send(pid, {
      :send_frame,
      %{"type" => "metadata", "capabilities" => %{"initial" => true}}
    })

    assert_receive {:metadata_control_operation,
                    %{
                      connector_run_id: ^env_id,
                      patch: %{
                        "capabilities" => %{"initial" => true},
                        "runtime_auth_generation" => nil,
                        "runtime_session_snapshot_generation" => nil
                      }
                    }, first_worker},
                   1_000

    send(pid, {
      :send_frame,
      %{"type" => "metadata", "capabilities" => %{"exec" => true}}
    })

    send(pid, {
      :send_frame,
      %{"type" => "metadata", "system_info" => %{"os_type" => "linux"}}
    })

    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())

    send(pid, {
      :send_frame,
      %{
        "id" => "metadata-coalesce-probe",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/health"}
      }
    })

    assert_receive {:runtime_proxy_called, ^env_id, _params, _meta}, 1_000

    refute_receive {:metadata_control_operation, %{connector_run_id: ^env_id}, _worker}, 100

    send(first_worker, :release_metadata_control)

    assert_receive {:metadata_control_operation,
                    %{
                      connector_run_id: ^env_id,
                      patch: %{
                        "capabilities" => %{"exec" => true},
                        "runtime_auth_generation" => nil,
                        "runtime_session_snapshot_generation" => nil,
                        "system_info" => %{"os_type" => "linux"},
                        "system_info_updated_at" => _timestamp
                      }
                    }, _worker},
                   1_000

    assert eventually(fn ->
             match?(
               {:ok,
                %{
                  "capabilities" => %{"exec" => true},
                  "system_info" => %{"os_type" => "linux"}
                }},
               environment_for_run_result(env_id)
             )
           end)
  end

  test "runtime metadata publishes durable readiness and one shared notification",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "runtime-ready-notification", token)
    device = environment_for_run!(env_id)

    notifications =
      start_supervised!(
        {Postgrex.Notifications, SalixStore.Repo.config() |> Keyword.delete(:name)}
      )

    channel = SalixStore.SessionWorkNotifications.channel()
    assert {:ok, ref} = Postgrex.Notifications.listen(notifications, channel)
    payload = SalixStore.SessionWorkNotifications.runtime_ready_payload()
    now = System.system_time(:millisecond)

    runtime = %{
      "kind" => "external",
      "provider" => "pi",
      "identity_material" => "/private/pi-ready",
      "command" => "/private/pi-ready",
      "auth_ready" => true,
      "native_server_startable" => true,
      "version_detected" => true,
      "ready" => true,
      "readiness_checked_at" => now,
      "readiness_valid_until" => now + 300_000
    }

    frame = %{"type" => "metadata", "capabilities" => %{"agent_runtimes" => [runtime]}}
    send(pid, {:send_frame, frame})
    assert_receive {:notification, ^notifications, ^ref, ^channel, ^payload}, 5_000

    assert %{rows: [[deadline]]} =
             SalixStore.Repo.query!(
               "SELECT ready_until_ms FROM device_runtime_locators WHERE group_id = $1 AND device_id = $2",
               [group_id, device["device_id"]]
             )

    assert deadline > now

    send(pid, {:send_frame, frame})
    refute_receive {:notification, ^notifications, ^ref, ^channel, ^payload}, 100

    send(pid, {:send_frame, put_in(frame, ["capabilities", "agent_runtimes"], [])})

    assert eventually(fn ->
             %{rows: [[deadline]]} =
               SalixStore.Repo.query!(
                 "SELECT ready_until_ms FROM device_runtime_locators WHERE group_id = $1 AND device_id = $2",
                 [group_id, device["device_id"]]
               )

             is_nil(deadline)
           end)

    send(pid, {:send_frame, frame})
    assert_receive {:notification, ^notifications, ^ref, ^channel, ^payload}, 5_000
  end

  test "external runtime events preserve arrival order and batch ACKs are per item",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "laptop", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.OrderedExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    send(pid, {
      :send_frame,
      %{
        "id" => "event-1",
        "type" => "request",
        "method" => "external_runtime_event",
        "params" => %{"event_id" => "event-1", "sequence" => 1, "block" => true}
      }
    })

    send(pid, {
      :send_frame,
      %{
        "id" => "event-2",
        "type" => "request",
        "method" => "external_runtime_event",
        "params" => %{"event_id" => "event-2", "sequence" => 2}
      }
    })

    assert_receive {:connector_frame,
                    %{
                      "id" => "event-2",
                      "type" => "error",
                      "error_code" => "external_runtime_event_queued"
                    }},
                   1_000

    assert_receive {:external_runtime_event_started, 1, first_task}, 1_000
    refute_receive {:external_runtime_event_started, 2, _task}, 100
    send(first_task, :release_external_runtime_event)

    assert_receive {:connector_frame,
                    %{"id" => "event-1", "type" => "response", "result" => %{"sequence" => 1}}},
                   1_000

    assert_receive {:external_runtime_event_started, 2, _second_task}, 1_000
    assert_receive {:external_runtime_event_completed, 2}, 1_000

    send(pid, {
      :send_frame,
      %{
        "id" => "event-2",
        "type" => "request",
        "method" => "external_runtime_event",
        "params" => %{"event_id" => "event-2", "sequence" => 2}
      }
    })

    assert_receive {:connector_frame,
                    %{"id" => "event-2", "type" => "response", "result" => %{"sequence" => 2}}},
                   1_000

    attach_liveness_telemetry([
      [:salix, :connector, :external_event],
      [:salix, :operation, :stop]
    ])

    send(pid, {
      :send_frame,
      %{
        "id" => "batch-1",
        "type" => "request",
        "method" => "external_runtime_events",
        "params" => %{
          "events" => [
            %{"event_id" => "event-3", "sequence" => 3},
            %{"event_id" => "event-4", "sequence" => 4, "reject" => true},
            %{"event_id" => "event-5", "sequence" => 5},
            %{"event_id" => "event-6", "sequence" => 6, "terminal" => true},
            %{"event_id" => "event-7", "sequence" => 7, "missing" => true}
          ]
        }
      }
    })

    assert_receive {:external_runtime_event_batch_started, [3, 4, 5, 6, 7]}, 1_000
    assert_receive {:external_runtime_event_started, 3, _task}, 1_000
    assert_receive {:external_runtime_event_started, 4, _task}, 1_000
    assert_receive {:external_runtime_event_started, 5, _task}, 1_000
    assert_receive {:external_runtime_event_started, 6, _task}, 1_000
    assert_receive {:external_runtime_event_started, 7, _task}, 1_000

    assert_receive {:connector_frame,
                    %{
                      "id" => "batch-1",
                      "type" => "response",
                      "result" => %{
                        "accepted_event_ids" => ["event-3", "event-5"],
                        "permanently_rejected_events" => [
                          %{
                            "event_id" => "event-6",
                            "error_code" => "external_session_read_only"
                          },
                          %{
                            "event_id" => "event-7",
                            "error_code" => "not_found"
                          }
                        ]
                      }
                    }},
                   1_000

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event], %{},
                    %{outcome: :completed}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event], %{},
                    %{outcome: :completed}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event], %{},
                    %{outcome: :terminal}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event], %{},
                    %{outcome: :terminal}}

    assert_receive {:liveness_telemetry, [:salix, :connector, :external_event], %{},
                    %{outcome: :retry}}

    assert_receive {:liveness_telemetry, [:salix, :operation, :stop], %{duration: duration},
                    %{
                      component: "salix_agent",
                      operation: "external_runtime_event_batch",
                      surface: "system",
                      outcome: "ok"
                    }}

    assert is_integer(duration) and duration >= 0
  end

  test "the first external runtime batch uses the batch handler before its facade is loaded",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "first-batch", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      SalixWeb.ExternalRuntime
    )

    # Plain facade modules are not loaded by application startup. Reproduce a
    # fresh node even when another test happened to touch this module first.
    :code.purge(SalixWeb.ExternalRuntime)
    :code.delete(SalixWeb.ExternalRuntime)
    :code.purge(SalixWeb.ExternalRuntime)
    refute function_exported?(SalixWeb.ExternalRuntime, :handle_connector_events, 3)

    :ok = S3.Fake.reset_read_log()
    capability_token = "missing-capability"

    events =
      Enum.map(1..5, fn sequence ->
        %{
          "capability_token" => capability_token,
          "event_id" => SalixStore.ULID.generate(),
          "event" => %{
            "provider" => "codex",
            "type" => "message",
            "role" => "assistant",
            "content" => "first batch #{sequence}",
            "created_at" => System.system_time(:second)
          }
        }
      end)

    send(pid, {
      :send_frame,
      %{
        "id" => "first-batch",
        "type" => "request",
        "method" => "external_runtime_events",
        "params" => %{"events" => events}
      }
    })

    assert_receive {:connector_frame,
                    %{
                      "id" => "first-batch",
                      "type" => "response",
                      "result" => %{
                        "accepted_event_ids" => [],
                        "permanently_rejected_events" => rejected
                      }
                    }},
                   1_000

    assert Enum.map(rejected, & &1["event_id"]) == Enum.map(events, & &1["event_id"])
    assert Enum.all?(rejected, &(&1["error_code"] == "unauthorized"))

    capability_reads =
      Enum.count(S3.Fake.read_log(), fn
        {:get, "ctl/runtime_capabilities/" <> _hash} -> true
        _ -> false
      end)

    assert capability_reads == 1,
           "first batch fell back to one capability lookup per event: #{capability_reads}"
  end

  test "legacy connector four-in-flight events detach queued waiters before its client deadline",
       %{group_id: group_id, connector_token: token} do
    previous_response_timeout =
      Application.get_env(:salix_web, :connector_external_event_response_timeout_ms)

    previous_absolute_timeout =
      Application.get_env(:salix_web, :connector_external_event_absolute_timeout_ms)

    previous_queue_limit =
      Application.get_env(:salix_web, :connector_external_event_queue_limit)

    Application.put_env(:salix_web, :connector_external_event_response_timeout_ms, 75)
    Application.put_env(:salix_web, :connector_external_event_absolute_timeout_ms, 1_000)
    Application.put_env(:salix_web, :connector_external_event_queue_limit, 3)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_response_timeout_ms,
        previous_response_timeout
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_absolute_timeout_ms,
        previous_absolute_timeout
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_queue_limit,
        previous_queue_limit
      )
    end)

    {pid, _env_id} = connect(group_id, "legacy-four-events", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    first =
      external_event_frame("legacy-event-1", %{
        "event_id" => "legacy-event-1",
        "sequence" => 1,
        "outcome" => "block"
      })

    started_at = System.monotonic_time(:millisecond)
    send(pid, {:send_frame, first})

    assert_receive {:legacy_external_runtime_event_started, "legacy-event-1", _run_id, _params,
                    first_worker},
                   1_000

    on_exit(fn ->
      send(
        first_worker,
        {:complete_legacy_external_runtime_event, "legacy-event-1",
         {:ok, %{"event_id" => "legacy-event-1", "sequence" => 1}}}
      )
    end)

    Enum.each(2..4, fn sequence ->
      id = "legacy-event-#{sequence}"

      send(
        pid,
        {:send_frame, external_event_frame(id, %{"event_id" => id, "sequence" => sequence})}
      )
    end)

    # The unchanged connector can have four requests in flight. Frames behind
    # the active one must not remain live socket waiters: each is detached into
    # the bounded event queue and immediately told to retry.
    Enum.each(2..4, fn sequence ->
      id = "legacy-event-#{sequence}"

      assert_receive {:connector_frame,
                      %{
                        "id" => ^id,
                        "type" => "error",
                        "error_code" => "external_runtime_event_queued"
                      }},
                     300
    end)

    # All three detached slots are occupied. An exact retry of queued event 2
    # must collapse before capacity accounting instead of taking a fourth slot.
    send(
      pid,
      {:send_frame,
       external_event_frame("legacy-event-2", %{
         "event_id" => "legacy-event-2",
         "sequence" => 2
       })}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-event-2",
                      "type" => "error",
                      "error_code" => "external_runtime_event_queued"
                    }},
                   300

    Enum.each(2..4, fn sequence ->
      id = "legacy-event-#{sequence}"

      refute_receive {:legacy_external_runtime_event_started, ^id, _run_id, _params, _worker},
                     0
    end)

    # Scaled equivalent of Salix replying before the legacy client's five
    # second waiter. The dependency keeps running after this waiter is gone.
    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-event-1",
                      "type" => "error",
                      "error_code" => "external_runtime_event_retry"
                    }},
                   300

    assert System.monotonic_time(:millisecond) - started_at < 1_000

    send(
      first_worker,
      {:complete_legacy_external_runtime_event, "legacy-event-1",
       {:ok, %{"event_id" => "legacy-event-1", "sequence" => 1}}}
    )

    assert_receive {:legacy_external_runtime_event_completed, "legacy-event-1", {:ok, _}},
                   300

    Enum.each(2..4, fn sequence ->
      id = "legacy-event-#{sequence}"

      assert_receive {:legacy_external_runtime_event_started, ^id, _run_id,
                      %{"sequence" => ^sequence}, _worker},
                     300

      assert_receive {:legacy_external_runtime_event_completed, ^id,
                      {:ok, %{"sequence" => ^sequence}}},
                     300
    end)

    refute_receive {:legacy_external_runtime_event_started, "legacy-event-2", _run_id, _params,
                    _duplicate_worker},
                   75
  end

  test "exact external-event retries share admission and receive a cached late ACK",
       %{group_id: group_id, connector_token: token} do
    previous_response_timeout =
      Application.get_env(:salix_web, :connector_external_event_response_timeout_ms)

    previous_absolute_timeout =
      Application.get_env(:salix_web, :connector_external_event_absolute_timeout_ms)

    Application.put_env(:salix_web, :connector_external_event_response_timeout_ms, 50)
    Application.put_env(:salix_web, :connector_external_event_absolute_timeout_ms, 1_000)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_response_timeout_ms,
        previous_response_timeout
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_absolute_timeout_ms,
        previous_absolute_timeout
      )
    end)

    {pid, _env_id} = connect(group_id, "legacy-event-retries", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    frame =
      external_event_frame("legacy-retry-event", %{
        "event_id" => "legacy-retry-event",
        "sequence" => 1,
        "outcome" => "block"
      })

    send(pid, {:send_frame, frame})

    assert_receive {:legacy_external_runtime_event_started, "legacy-retry-event", _run_id,
                    _params, worker},
                   1_000

    on_exit(fn ->
      send(
        worker,
        {:complete_legacy_external_runtime_event, "legacy-retry-event",
         {:ok, %{"event_id" => "legacy-retry-event", "sequence" => 1}}}
      )
    end)

    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-retry-event",
                      "type" => "error",
                      "error_code" => "external_runtime_event_retry"
                    }},
                   300

    send(pid, {:send_frame, frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-retry-event",
                      "type" => "error",
                      "error_code" => "external_runtime_event_retry"
                    }},
                   300

    conflicting = put_in(frame, ["params", "sequence"], 99)
    send(pid, {:send_frame, conflicting})

    # A conflict is deterministic poison for the legacy client, which retries
    # every wire error forever. It therefore uses the normal response envelope.
    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-retry-event",
                      "type" => "response",
                      "result" => %{
                        "accepted" => false,
                        "disposition" => "permanently_rejected",
                        "error_code" => "external_runtime_event_id_conflict"
                      }
                    }},
                   300

    refute_receive {:legacy_external_runtime_event_started, "legacy-retry-event", _run_id,
                    _params, _other_worker},
                   0

    send(
      worker,
      {:complete_legacy_external_runtime_event, "legacy-retry-event",
       {:ok, %{"event_id" => "legacy-retry-event", "sequence" => 1}}}
    )

    assert_receive {:legacy_external_runtime_event_completed, "legacy-retry-event", {:ok, _}},
                   300

    # Completion after the response deadline is cached; it is never pushed to
    # a waiter that the connector already abandoned.
    refute_receive {:connector_frame, %{"id" => "legacy-retry-event", "type" => "response"}},
                   75

    await_external_event_completion(worker)
    send(pid, {:send_frame, frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-retry-event",
                      "type" => "response",
                      "result" => %{
                        "event_id" => "legacy-retry-event",
                        "sequence" => 1
                      }
                    }},
                   300

    refute_receive {:legacy_external_runtime_event_started, "legacy-retry-event", _run_id,
                    _params, _worker},
                   75
  end

  test "deterministic external-event poison receives a normal terminal ACK and advances",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "legacy-terminal-event", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    send(
      pid,
      {:send_frame,
       external_event_frame("legacy-terminal-event", %{
         "event_id" => "legacy-terminal-event",
         "outcome" => "terminal"
       })}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-terminal-event",
                      "type" => "response",
                      "result" => %{
                        "accepted" => false,
                        "disposition" => "permanently_rejected",
                        "error_code" => "external_session_read_only"
                      }
                    }},
                   300

    send(
      pid,
      {:send_frame,
       external_event_frame("legacy-record-conflict", %{
         "event_id" => "legacy-record-conflict",
         "outcome" => "record_conflict"
       })}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-record-conflict",
                      "type" => "response",
                      "result" => %{
                        "accepted" => false,
                        "disposition" => "permanently_rejected",
                        "error_code" => "external_session_record_conflict"
                      }
                    }},
                   300

    send(
      pid,
      {:send_frame,
       external_event_frame("legacy-event-after-poison", %{
         "event_id" => "legacy-event-after-poison",
         "sequence" => 2
       })}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-event-after-poison",
                      "type" => "response",
                      "result" => %{
                        "event_id" => "legacy-event-after-poison",
                        "sequence" => 2
                      }
                    }},
                   300
  end

  test "external-event envelope id must match its durable event id before admission",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "external-event-id-mismatch", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    send(
      pid,
      {:send_frame,
       external_event_frame("wire-envelope-id", %{
         "event_id" => "durable-event-id",
         "sequence" => 1
       })}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "wire-envelope-id",
                      "type" => "response",
                      "result" => %{
                        "accepted" => false,
                        "disposition" => "permanently_rejected",
                        "error_code" => "external_runtime_event_id_mismatch"
                      }
                    }},
                   300

    refute_receive {:legacy_external_runtime_event_started, _event_id, _run_id, _params, _worker},
                   0
  end

  test "transient actor unavailability remains a retryable external-event wire error",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "legacy-transient-event", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    frame =
      external_event_frame("legacy-transient-event", %{
        "event_id" => "legacy-transient-event",
        "outcome" => "transient"
      })

    Enum.each(1..2, fn _attempt ->
      send(pid, {:send_frame, frame})

      assert_receive {:legacy_external_runtime_event_started, "legacy-transient-event", _run_id,
                      _params, _worker},
                     300

      assert_receive {:legacy_external_runtime_event_completed, "legacy-transient-event",
                      {:error, :not_running}},
                     300

      assert_receive {:connector_frame,
                      %{
                        "id" => "legacy-transient-event",
                        "type" => "error",
                        "error_code" => "external_runtime_event_retry"
                      }},
                     300
    end)
  end

  test "external-event admission and cached completion survive connector reconnect",
       %{group_id: group_id, connector_token: token} do
    previous_response_timeout =
      Application.get_env(:salix_web, :connector_external_event_response_timeout_ms)

    previous_absolute_timeout =
      Application.get_env(:salix_web, :connector_external_event_absolute_timeout_ms)

    Application.put_env(:salix_web, :connector_external_event_response_timeout_ms, 100)
    Application.put_env(:salix_web, :connector_external_event_absolute_timeout_ms, 1_500)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_response_timeout_ms,
        previous_response_timeout
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_absolute_timeout_ms,
        previous_absolute_timeout
      )
    end)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    frame =
      external_event_frame("legacy-reconnect-event", %{
        "event_id" => "legacy-reconnect-event",
        "sequence" => 1,
        "outcome" => "block"
      })

    {first_pid, first_run_id} = connect(group_id, "legacy-event-first-run", token)
    first_environment = environment_for_run!(first_run_id)
    send(first_pid, {:send_frame, frame})

    assert_receive {:legacy_external_runtime_event_started, "legacy-reconnect-event",
                    ^first_run_id, _params, worker},
                   1_000

    on_exit(fn ->
      send(
        worker,
        {:complete_legacy_external_runtime_event, "legacy-reconnect-event",
         {:ok, %{"event_id" => "legacy-reconnect-event", "sequence" => 1}}}
      )
    end)

    Process.exit(first_pid, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(
                 first_environment["device_id"],
                 group_id,
                 tenant_id()
               )
             )
           end)

    {second_pid, second_run_id} = connect(group_id, "legacy-event-second-run", token)
    assert second_run_id != first_run_id
    send(second_pid, {:send_frame, frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-reconnect-event",
                      "type" => "error",
                      "error_code" => "external_runtime_event_retry"
                    }},
                   300

    refute_receive {:legacy_external_runtime_event_started, "legacy-reconnect-event", _run_id,
                    _params, _other_worker},
                   0

    send(
      worker,
      {:complete_legacy_external_runtime_event, "legacy-reconnect-event",
       {:ok, %{"event_id" => "legacy-reconnect-event", "sequence" => 1}}}
    )

    assert_receive {:legacy_external_runtime_event_completed, "legacy-reconnect-event", {:ok, _}},
                   300

    await_external_event_completion(worker)
    send(second_pid, {:send_frame, frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "legacy-reconnect-event",
                      "type" => "response",
                      "result" => %{
                        "event_id" => "legacy-reconnect-event",
                        "sequence" => 1
                      }
                    }},
                   300
  end

  test "queued external-event retry after reconnect refreshes its socket generation",
       %{group_id: group_id, connector_token: token} do
    previous_response_timeout =
      Application.get_env(:salix_web, :connector_external_event_response_timeout_ms)

    previous_absolute_timeout =
      Application.get_env(:salix_web, :connector_external_event_absolute_timeout_ms)

    Application.put_env(:salix_web, :connector_external_event_response_timeout_ms, 500)
    Application.put_env(:salix_web, :connector_external_event_absolute_timeout_ms, 2_000)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_response_timeout_ms,
        previous_response_timeout
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_absolute_timeout_ms,
        previous_absolute_timeout
      )
    end)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    active_frame =
      external_event_frame("queued-reconnect-active", %{
        "event_id" => "queued-reconnect-active",
        "outcome" => "block"
      })

    queued_frame =
      external_event_frame("queued-reconnect-detached", %{
        "event_id" => "queued-reconnect-detached",
        "sequence" => 2
      })

    {first_pid, first_run_id} = connect(group_id, "queued-reconnect-first", token)
    first_environment = environment_for_run!(first_run_id)
    send(first_pid, {:send_frame, active_frame})

    assert_receive {:legacy_external_runtime_event_started, "queued-reconnect-active",
                    ^first_run_id, _params, active_worker},
                   1_000

    on_exit(fn ->
      send(
        active_worker,
        {:complete_legacy_external_runtime_event, "queued-reconnect-active",
         {:ok, %{"event_id" => "queued-reconnect-active"}}}
      )
    end)

    send(first_pid, {:send_frame, queued_frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "queued-reconnect-detached",
                      "type" => "error",
                      "error_code" => "external_runtime_event_queued"
                    }},
                   300

    Process.exit(first_pid, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(
                 first_environment["device_id"],
                 group_id,
                 tenant_id()
               )
             )
           end)

    {second_pid, second_run_id} = connect(group_id, "queued-reconnect-second", token)
    assert second_run_id != first_run_id
    send(second_pid, {:send_frame, queued_frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "queued-reconnect-detached",
                      "type" => "error",
                      "error_code" => "external_runtime_event_queued"
                    }},
                   300

    send(
      active_worker,
      {:complete_legacy_external_runtime_event, "queued-reconnect-active",
       {:ok, %{"event_id" => "queued-reconnect-active"}}}
    )

    assert_receive {:legacy_external_runtime_event_started, "queued-reconnect-detached",
                    ^second_run_id, _params, queued_worker},
                   1_000

    assert_receive {:legacy_external_runtime_event_completed, "queued-reconnect-detached",
                    {:ok, _}},
                   300

    await_external_event_completion(queued_worker)
    send(second_pid, {:send_frame, queued_frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "queued-reconnect-detached",
                      "type" => "response",
                      "result" => %{"event_id" => "queued-reconnect-detached", "sequence" => 2}
                    }},
                   300
  end

  test "reconnect refreshes queued generation without a pre-head retry and stale auth is not cached",
       %{group_id: group_id, connector_token: token} do
    previous_response_timeout =
      Application.get_env(:salix_web, :connector_external_event_response_timeout_ms)

    previous_absolute_timeout =
      Application.get_env(:salix_web, :connector_external_event_absolute_timeout_ms)

    Application.put_env(:salix_web, :connector_external_event_response_timeout_ms, 500)
    Application.put_env(:salix_web, :connector_external_event_absolute_timeout_ms, 2_000)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_response_timeout_ms,
        previous_response_timeout
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_absolute_timeout_ms,
        previous_absolute_timeout
      )
    end)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    active_frame =
      external_event_frame("generation-active", %{
        "event_id" => "generation-active",
        "outcome" => "block"
      })

    queued_frame =
      external_event_frame("generation-queued", %{
        "event_id" => "generation-queued",
        "sequence" => 2
      })

    {first, first_run_id} = connect(group_id, "generation-first", token)
    send(first, {:send_frame, active_frame})

    assert_receive {:legacy_external_runtime_event_started, "generation-active", ^first_run_id,
                    _params, first_worker},
                   1_000

    send(first, {:send_frame, queued_frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "generation-queued",
                      "type" => "error",
                      "error_code" => "external_runtime_event_queued"
                    }},
                   300

    Process.exit(first, :kill)
    {second, second_run_id} = connect(group_id, "generation-second", token)
    assert second_run_id != first_run_id

    # The active task validates after its transport generation was superseded.
    # Its authorization error is retryable and must not poison the completion cache.
    send(
      first_worker,
      {:complete_legacy_external_runtime_event, "generation-active",
       {:error, :stale_external_runtime_session}}
    )

    assert_receive {:legacy_external_runtime_event_completed, "generation-active",
                    {:error, :stale_external_runtime_session}},
                   300

    # No retry of the queued event was sent on the new socket. Registration of
    # the socket generation alone refreshes the lane before it reaches the head.
    assert_receive {:legacy_external_runtime_event_started, "generation-queued", ^second_run_id,
                    _params, _queued_worker},
                   1_000

    assert_receive {:legacy_external_runtime_event_completed, "generation-queued", {:ok, _}},
                   300

    send(second, {:send_frame, active_frame})

    assert_receive {:legacy_external_runtime_event_started, "generation-active", ^second_run_id,
                    _params, second_worker},
                   1_000

    send(
      second_worker,
      {:complete_legacy_external_runtime_event, "generation-active",
       {:ok, %{"event_id" => "generation-active"}}}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "generation-active",
                      "type" => "response",
                      "result" => %{"event_id" => "generation-active"}
                    }},
                   300
  end

  test "external-event absolute deadline kills a stalled task and releases admission",
       %{group_id: group_id, connector_token: token} do
    previous_response_timeout =
      Application.get_env(:salix_web, :connector_external_event_response_timeout_ms)

    previous_absolute_timeout =
      Application.get_env(:salix_web, :connector_external_event_absolute_timeout_ms)

    Application.put_env(:salix_web, :connector_external_event_response_timeout_ms, 40)
    Application.put_env(:salix_web, :connector_external_event_absolute_timeout_ms, 120)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_response_timeout_ms,
        previous_response_timeout
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_absolute_timeout_ms,
        previous_absolute_timeout
      )
    end)

    {pid, _run_id} = connect(group_id, "external-event-absolute-deadline", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    frame =
      external_event_frame("absolute-deadline-event", %{
        "event_id" => "absolute-deadline-event",
        "outcome" => "block"
      })

    send(pid, {:send_frame, frame})

    assert_receive {:legacy_external_runtime_event_started, "absolute-deadline-event", _run_id,
                    _params, first_worker},
                   1_000

    first_monitor = Process.monitor(first_worker)

    assert_receive {:connector_frame,
                    %{
                      "id" => "absolute-deadline-event",
                      "type" => "error",
                      "error_code" => "external_runtime_event_retry"
                    }},
                   300

    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, :killed}, 500
    assert eventually(fn -> SalixWeb.ConnectorTaskAdmission.count(:external_event) == 0 end)

    send(pid, {:send_frame, frame})

    assert_receive {:legacy_external_runtime_event_started, "absolute-deadline-event", _run_id,
                    _params, second_worker},
                   300

    assert second_worker != first_worker

    send(
      second_worker,
      {:complete_legacy_external_runtime_event, "absolute-deadline-event",
       {:ok, %{"event_id" => "absolute-deadline-event"}}}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "absolute-deadline-event",
                      "type" => "response",
                      "result" => %{"event_id" => "absolute-deadline-event"}
                    }},
                   300

    assert eventually(fn -> SalixWeb.ConnectorTaskAdmission.count(:external_event) == 0 end)
  end

  test "external-event completion cache prunes its bounded order index" do
    previous_limit =
      Application.get_env(:salix_web, :connector_external_event_completion_cache_limit)

    previous_ttl =
      Application.get_env(:salix_web, :connector_external_event_completion_cache_ttl_ms)

    Application.put_env(:salix_web, :connector_external_event_completion_cache_limit, 2)
    Application.put_env(:salix_web, :connector_external_event_completion_cache_ttl_ms, 30)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_completion_cache_limit,
        previous_limit
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_completion_cache_ttl_ms,
        previous_ttl
      )
    end)

    Enum.each(1..3, fn sequence ->
      id = "completion-cache-order-#{sequence}"

      assert {:wait, waiter_ref} =
               SalixWeb.ConnectorExternalEventCoordinator.submit(
                 self(),
                 "completion-cache-order-lane-#{sequence}",
                 id,
                 %{"event_id" => id, "sequence" => sequence},
                 fn -> {:ok, %{"sequence" => sequence}} end
               )

      assert_receive {:connector_external_event_reply, ^waiter_ref,
                      %{"id" => ^id, "type" => "response"}},
                     300
    end)

    state = :sys.get_state(SalixWeb.ConnectorExternalEventCoordinator)
    assert map_size(state.completed) == 2
    assert :queue.len(state.completed_order) == map_size(state.completed)

    Process.sleep(40)

    assert {:wait, waiter_ref} =
             SalixWeb.ConnectorExternalEventCoordinator.submit(
               self(),
               "completion-cache-order-trigger-lane",
               "completion-cache-order-trigger",
               %{"event_id" => "completion-cache-order-trigger"},
               fn -> {:ok, %{}} end
             )

    assert_receive {:connector_external_event_reply, ^waiter_ref,
                    %{"id" => "completion-cache-order-trigger", "type" => "response"}},
                   300

    state = :sys.get_state(SalixWeb.ConnectorExternalEventCoordinator)
    assert map_size(state.completed) == 1
    assert :queue.len(state.completed_order) == 1
  end

  test "external-event retained and active caps isolate tenants and bound the singleton" do
    previous_global =
      Application.get_env(:salix_web, :connector_external_event_global_retained_limit)

    previous_tenant =
      Application.get_env(:salix_web, :connector_external_event_tenant_retained_limit)

    previous_active =
      Application.get_env(:salix_web, :connector_external_event_tenant_active_limit)

    Application.put_env(:salix_web, :connector_external_event_global_retained_limit, 3)
    Application.put_env(:salix_web, :connector_external_event_tenant_retained_limit, 2)
    Application.put_env(:salix_web, :connector_external_event_tenant_active_limit, 1)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_global_retained_limit,
        previous_global
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_tenant_retained_limit,
        previous_tenant
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_tenant_active_limit,
        previous_active
      )
    end)

    test_pid = self()

    execute = fn params ->
      event_id = params["event_id"]
      send(test_pid, {:bounded_event_started, event_id, self()})

      receive do
        {:release_bounded_event, ^event_id} ->
          {:ok, %{"event_id" => event_id}}
      end
    end

    assert {:wait, _} =
             SalixWeb.ConnectorExternalEventCoordinator.submit(
               self(),
               {"tenant-a", "group-a", "device-a1"},
               1,
               "tenant-a-active",
               %{"event_id" => "tenant-a-active"},
               execute
             )

    assert_receive {:bounded_event_started, "tenant-a-active", tenant_a_worker}, 300

    assert {:reply,
            %{
              "id" => "tenant-a-queued",
              "type" => "error",
              "error_code" => "external_runtime_event_retry"
            }} =
             SalixWeb.ConnectorExternalEventCoordinator.submit(
               self(),
               {"tenant-a", "group-a", "device-a2"},
               1,
               "tenant-a-queued",
               %{"event_id" => "tenant-a-queued"},
               execute
             )

    # Tenant A reached only its active cap; tenant B still starts immediately.
    assert {:wait, _} =
             SalixWeb.ConnectorExternalEventCoordinator.submit(
               self(),
               {"tenant-b", "group-b", "device-b1"},
               1,
               "tenant-b-active",
               %{"event_id" => "tenant-b-active"},
               execute
             )

    assert_receive {:bounded_event_started, "tenant-b-active", tenant_b_worker}, 300

    # The three retained events consume the finite singleton-wide budget.
    assert {:reply,
            %{
              "id" => "tenant-c-overflow",
              "type" => "error",
              "error_code" => "external_runtime_event_retry"
            }} =
             SalixWeb.ConnectorExternalEventCoordinator.submit(
               self(),
               {"tenant-c", "group-c", "device-c1"},
               1,
               "tenant-c-overflow",
               %{"event_id" => "tenant-c-overflow"},
               execute
             )

    state = :sys.get_state(SalixWeb.ConnectorExternalEventCoordinator)
    assert state.retained_count == 3
    assert state.tenant_counts["tenant-a"] == 2
    assert state.tenant_active_counts["tenant-a"] == 1
    assert state.tenant_active_counts["tenant-b"] == 1

    send(tenant_a_worker, {:release_bounded_event, "tenant-a-active"})
    assert_receive {:bounded_event_started, "tenant-a-queued", tenant_a_queued_worker}, 300
    send(tenant_a_queued_worker, {:release_bounded_event, "tenant-a-queued"})
    send(tenant_b_worker, {:release_bounded_event, "tenant-b-active"})

    assert eventually(fn ->
             state = :sys.get_state(SalixWeb.ConnectorExternalEventCoordinator)

             state.retained_count == 0 and state.tenant_counts == %{} and
               state.tenant_active_counts == %{}
           end)
  end

  test "external admission invalid config falls back and owner death cannot orphan tracked work" do
    previous_limit = Application.get_env(:salix_web, :connector_external_event_task_limit)
    Application.put_env(:salix_web, :connector_external_event_task_limit, :invalid)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_external_event_task_limit, previous_limit)
    end)

    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, lease} = SalixWeb.ConnectorTaskAdmission.acquire(:external_event, owner)
    task = spawn(fn -> Process.sleep(:infinity) end)
    task_monitor = Process.monitor(task)

    assert :ok = SalixWeb.ConnectorTaskAdmission.track(lease, task)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :killed}, 300
    assert eventually(fn -> SalixWeb.ConnectorTaskAdmission.count(:external_event) == 0 end)

    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, lease} = SalixWeb.ConnectorTaskAdmission.acquire(:external_event, owner)
    Process.exit(owner, :kill)
    assert eventually(fn -> not Process.alive?(lease) end)

    task = spawn(fn -> Process.sleep(:infinity) end)
    task_monitor = Process.monitor(task)

    assert {:error, :lease_closed} = SalixWeb.ConnectorTaskAdmission.track(lease, task)
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :killed}, 300
    assert SalixWeb.ConnectorTaskAdmission.count(:external_event) == 0
  end

  test "external-event owner timeout returns retry without comparing caller monotonic epochs",
       %{group_id: group_id, connector_token: token} do
    previous_timeout =
      Application.get_env(:salix_web, :connector_external_event_owner_call_timeout_ms)

    Application.put_env(:salix_web, :connector_external_event_owner_call_timeout_ms, 40)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_owner_call_timeout_ms,
        previous_timeout
      )
    end)

    {connector, _run_id} = connect(group_id, "coordinator-owner-timeout", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    coordinator = Process.whereis(SalixWeb.ConnectorExternalEventCoordinator)
    :ok = :sys.suspend(coordinator)
    resumed = :atomics.new(1, [])

    on_exit(fn ->
      if Process.alive?(coordinator) and :atomics.get(resumed, 1) == 0 do
        try do
          :sys.resume(coordinator)
        catch
          _, _ -> :ok
        end
      end
    end)

    started_at = System.monotonic_time(:millisecond)

    send(
      connector,
      {:send_frame,
       external_event_frame("coordinator-timeout-event", %{
         "event_id" => "coordinator-timeout-event"
       })}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "coordinator-timeout-event",
                      "type" => "error",
                      "error_code" => "external_runtime_event_retry"
                    }},
                   300

    assert System.monotonic_time(:millisecond) - started_at < 500

    # The caller's 40 ms deadline has already elapsed. The Ring owner must not
    # compare a caller-node monotonic timestamp against its own clock; it may
    # process this late bounded mailbox entry under the ordinary retained/event
    # deadlines after it resumes.
    :ok = :sys.resume(coordinator)
    :ok = :atomics.put(resumed, 1, 1)

    assert_receive {:legacy_external_runtime_event_started, "coordinator-timeout-event", _run_id,
                    _params, worker},
                   300

    assert_receive {:legacy_external_runtime_event_completed, "coordinator-timeout-event",
                    {:ok, %{"event_id" => "coordinator-timeout-event"}}},
                   300

    refute_receive {:connector_frame,
                    %{
                      "id" => "coordinator-timeout-event",
                      "type" => "response"
                    }},
                   75

    await_external_event_completion(worker)

    send(
      connector,
      {:send_frame,
       external_event_frame("coordinator-timeout-event", %{
         "event_id" => "coordinator-timeout-event"
       })}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "coordinator-timeout-event",
                      "type" => "response",
                      "result" => %{"event_id" => "coordinator-timeout-event"}
                    }},
                   300
  end

  test "saturated external-event lane leaves generic and core socket admission available",
       %{group_id: group_id, connector_token: token} do
    previous_event_limit =
      Application.get_env(:salix_web, :connector_external_event_task_limit)

    previous_request_limit = Application.get_env(:salix_web, :connector_request_task_limit)

    previous_response_timeout =
      Application.get_env(:salix_web, :connector_external_event_response_timeout_ms)

    Application.put_env(:salix_web, :connector_external_event_task_limit, 1)
    Application.put_env(:salix_web, :connector_request_task_limit, 1)
    Application.put_env(:salix_web, :connector_external_event_response_timeout_ms, 500)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_task_limit,
        previous_event_limit
      )

      restore_app_env(:salix_web, :connector_request_task_limit, previous_request_limit)

      restore_app_env(
        :salix_web,
        :connector_external_event_response_timeout_ms,
        previous_response_timeout
      )
    end)

    {pid, _env_id} = connect(group_id, "isolated-event-admission", token)

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())
    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())

    send(
      pid,
      {:send_frame,
       external_event_frame("saturated-event-1", %{
         "event_id" => "saturated-event-1",
         "outcome" => "block"
       })}
    )

    assert_receive {:legacy_external_runtime_event_started, "saturated-event-1", _run_id, _params,
                    worker},
                   1_000

    on_exit(fn ->
      send(
        worker,
        {:complete_legacy_external_runtime_event, "saturated-event-1",
         {:ok, %{"event_id" => "saturated-event-1"}}}
      )
    end)

    send(
      pid,
      {:send_frame,
       external_event_frame("saturated-event-2", %{"event_id" => "saturated-event-2"})}
    )

    send(pid, {
      :send_frame,
      %{
        "id" => "generic-while-event-saturated",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/health"}
      }
    })

    assert_receive {:connector_frame,
                    %{
                      "id" => "generic-while-event-saturated",
                      "type" => "response",
                      "result" => %{"status" => 204}
                    }},
                   300

    assert_receive {:connector_frame,
                    %{
                      "id" => "saturated-event-2",
                      "type" => "error",
                      "error_code" => "external_runtime_event_queued"
                    }},
                   300

    send(pid, {
      :send_frame,
      %{
        "id" => "core-while-event-saturated",
        "type" => "request",
        "method" => "meeting_runtime_capabilities",
        "params" => %{}
      }
    })

    assert_receive {:connector_frame,
                    %{"id" => "core-while-event-saturated", "type" => "response"}},
                   300
  end

  test "global external-event saturation retains an idle device event for detached delivery",
       %{group_id: group_id, connector_token: first_token} do
    previous_event_limit =
      Application.get_env(:salix_web, :connector_external_event_task_limit)

    previous_response_timeout =
      Application.get_env(:salix_web, :connector_external_event_response_timeout_ms)

    Application.put_env(:salix_web, :connector_external_event_task_limit, 1)
    Application.put_env(:salix_web, :connector_external_event_response_timeout_ms, 500)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_external_event_task_limit,
        previous_event_limit
      )

      restore_app_env(
        :salix_web,
        :connector_external_event_response_timeout_ms,
        previous_response_timeout
      )
    end)

    {:ok, second_token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "name" => "second-external-event-device",
        "alias" => "second-external-event-device"
      })

    {first, _first_run_id} = connect(group_id, "first-external-event-device", first_token)

    {second, second_run_id} =
      connect(group_id, "second-external-event-device", second_token["token"])

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.LegacyExternalRuntimeHandler
    )

    Application.put_env(:salix_web, :connector_external_runtime_test_pid, self())

    send(
      first,
      {:send_frame,
       external_event_frame("global-saturation-owner", %{
         "event_id" => "global-saturation-owner",
         "outcome" => "block"
       })}
    )

    assert_receive {:legacy_external_runtime_event_started, "global-saturation-owner", _run_id,
                    _params, owner_worker},
                   1_000

    on_exit(fn ->
      send(
        owner_worker,
        {:complete_legacy_external_runtime_event, "global-saturation-owner",
         {:ok, %{"event_id" => "global-saturation-owner"}}}
      )
    end)

    detached_frame =
      external_event_frame("global-saturation-detached", %{
        "event_id" => "global-saturation-detached",
        "sequence" => 2
      })

    send(second, {:send_frame, detached_frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "global-saturation-detached",
                      "type" => "error",
                      "error_code" => "external_runtime_event_retry"
                    }},
                   300

    refute_receive {:legacy_external_runtime_event_started, "global-saturation-detached", _run_id,
                    _params, _worker},
                   0

    send(
      owner_worker,
      {:complete_legacy_external_runtime_event, "global-saturation-owner",
       {:ok, %{"event_id" => "global-saturation-owner"}}}
    )

    # No Connector rescan is needed to admit the detached event: release of
    # the saturated global lane wakes the retained first frame directly.
    assert_receive {:legacy_external_runtime_event_started, "global-saturation-detached",
                    ^second_run_id, _params, detached_worker},
                   1_000

    assert_receive {:legacy_external_runtime_event_completed, "global-saturation-detached",
                    {:ok, _}},
                   300

    await_external_event_completion(detached_worker)
    send(second, {:send_frame, detached_frame})

    assert_receive {:connector_frame,
                    %{
                      "id" => "global-saturation-detached",
                      "type" => "response",
                      "result" => %{"event_id" => "global-saturation-detached", "sequence" => 2}
                    }},
                   300
  end

  test "outbound RPC timeout removes pending ownership and ignores a late connector reply",
       %{group_id: group_id, connector_token: token} do
    {connector, connector_run_id} = connect(group_id, "timed-out-outbound-rpc", token)
    test_pid = self()

    caller =
      spawn(fn ->
        result =
          SalixEnv.Connector.Live.dispatch(
            connector_run_id,
            rpc_frame("timed-out-outbound-rpc", "hold_rpc", %{"call" => 1}),
            50
          )

        send(test_pid, {:timed_out_outbound_rpc_result, self(), result})

        receive do
          {:env_rpc_reply, _ref, reply} ->
            send(test_pid, {:late_outbound_rpc_delivered, self(), reply})
        after
          150 ->
            send(test_pid, {:late_outbound_rpc_ignored, self()})
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    assert_receive {:held_rpc_request, "timed-out-outbound-rpc", %{"call" => 1}}, 300

    assert_receive {:timed_out_outbound_rpc_result, ^caller, {:error, :timeout}}, 300

    send(connector, {
      :send_frame,
      %{
        "id" => "timed-out-outbound-rpc",
        "type" => "response",
        "result" => %{"late" => true}
      }
    })

    assert_receive {:late_outbound_rpc_ignored, ^caller}, 300
    refute_receive {:late_outbound_rpc_delivered, ^caller, _reply}, 0
  end

  test "outbound RPC absolute timeout removes its caller monitor",
       %{group_id: group_id, connector_token: token} do
    previous_timeout =
      Application.get_env(:salix_web, :connector_pending_rpc_absolute_timeout_ms)

    Application.put_env(:salix_web, :connector_pending_rpc_absolute_timeout_ms, 60)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_pending_rpc_absolute_timeout_ms,
        previous_timeout
      )
    end)

    {_connector, connector_run_id} = connect(group_id, "absolute-outbound-rpc", token)
    [{socket_actor, :connector}] = Registry.lookup(SalixEnv.Bridges, connector_run_id)
    test_pid = self()

    caller =
      spawn(fn ->
        result =
          SalixEnv.Connector.Live.dispatch(
            connector_run_id,
            rpc_frame("absolute-outbound-rpc", "hold_rpc", %{"call" => 1}),
            :infinity
          )

        send(test_pid, {:absolute_outbound_rpc_result, self(), result})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    assert_receive {:held_rpc_request, "absolute-outbound-rpc", %{"call" => 1}}, 300

    assert eventually(fn ->
             case Process.info(socket_actor, :monitors) do
               {:monitors, monitors} -> {:process, caller} in monitors
               nil -> false
             end
           end)

    assert_receive {:absolute_outbound_rpc_result, ^caller, {:error, :timeout}}, 300

    assert eventually(fn ->
             case Process.info(socket_actor, :monitors) do
               {:monitors, monitors} -> {:process, caller} not in monitors
               nil -> false
             end
           end)
  end

  test "outbound pending cap rejects without pushing and caller exit releases its slot",
       %{group_id: group_id, connector_token: token} do
    previous_pending_limit =
      Application.get_env(:salix_web, :connector_socket_pending_rpc_limit)

    Application.put_env(:salix_web, :connector_socket_pending_rpc_limit, 1)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_socket_pending_rpc_limit,
        previous_pending_limit
      )
    end)

    {_connector, connector_run_id} = connect(group_id, "bounded-outbound-rpc", token)
    test_pid = self()

    owner =
      spawn(fn ->
        result =
          SalixEnv.Connector.Live.dispatch(
            connector_run_id,
            rpc_frame("pending-owner", "hold_rpc", %{"call" => 1}),
            :infinity
          )

        send(test_pid, {:pending_owner_unexpected_result, self(), result})
      end)

    owner_monitor = Process.monitor(owner)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    assert_receive {:held_rpc_request, "pending-owner", %{"call" => 1}}, 300

    assert {:error, :connector_pending_capacity_exhausted} =
             SalixEnv.Connector.Live.dispatch(
               connector_run_id,
               rpc_frame("pending-over-limit", "hold_rpc", %{"call" => 2}),
               300
             )

    refute_receive {:held_rpc_request, "pending-over-limit", _params}, 0

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 300
    Process.sleep(25)

    assert {:ok, %{"content" => "file@/after-caller-exit"}} =
             SalixEnv.Connector.Live.dispatch(
               connector_run_id,
               rpc_frame("pending-after-exit", "read", %{"path" => "/after-caller-exit"}),
               500
             )

    assert_receive {:read_request, _label, "/after-caller-exit"}, 300
    refute_receive {:pending_owner_unexpected_result, ^owner, _result}, 0
  end

  test "killed request tasks release socket capacity",
       %{group_id: group_id, connector_token: token} do
    previous_limit = Application.get_env(:salix_web, :connector_socket_request_task_limit)
    Application.put_env(:salix_web, :connector_socket_request_task_limit, 1)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_socket_request_task_limit, previous_limit)
    end)

    {pid, _env_id} = connect(group_id, "laptop", token)
    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())

    send(pid, {
      :send_frame,
      %{
        "id" => "request-killed",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "POST", "route_path" => "/tool/slow"}
      }
    })

    assert_receive {:runtime_proxy_blocked, request_task}, 1_000
    Process.exit(request_task, :kill)

    assert_receive {:connector_frame, %{"id" => "request-killed", "type" => "error"}}, 1_000

    send(pid, {
      :send_frame,
      %{
        "id" => "request-after-kill",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/tools"}
      }
    })

    assert_receive {:connector_frame, %{"id" => "request-after-kill", "type" => "response"}},
                   1_000
  end

  test "socket teardown cancels connector-originated request tasks",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "laptop", token)
    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())

    send(pid, {
      :send_frame,
      %{
        "id" => "request-during-disconnect",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "POST", "route_path" => "/tool/slow"}
      }
    })

    assert_receive {:runtime_proxy_blocked, request_task}, 1_000
    monitor = Process.monitor(request_task)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^request_task, _reason}, 1_000
  end

  test "an abnormal socket actor death kills its authorized request worker",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "actor-crash", token)
    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())

    send(pid, {
      :send_frame,
      %{
        "id" => "actor-crash-request",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "POST", "route_path" => "/tool/slow"}
      }
    })

    assert_receive {:runtime_proxy_blocked, request_worker}, 1_000
    [{socket_actor, :connector}] = Registry.lookup(SalixEnv.Bridges, env_id)
    worker_monitor = Process.monitor(request_worker)
    Process.exit(socket_actor, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^request_worker, _reason}, 500
    send(request_worker, :release_runtime_proxy)
    refute_receive {:runtime_proxy_completed, ^request_worker}, 100

    {replacement, replacement_env_id} = connect(group_id, "actor-crash-replacement", token)

    send(replacement, {
      :send_frame,
      %{
        "id" => "after-actor-crash",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/health"}
      }
    })

    assert_receive {:runtime_proxy_called, ^replacement_env_id, _params, _meta}, 1_000
    assert_receive {:connector_frame, %{"id" => "after-actor-crash", "type" => "response"}}, 1_000
  end

  test "request admission stays globally bounded while its task supervisor is suspended",
       %{group_id: group_id, connector_token: first_token} do
    previous_limit = Application.get_env(:salix_web, :connector_request_task_limit)
    Application.put_env(:salix_web, :connector_request_task_limit, 4)
    assert eventually(fn -> SalixWeb.ConnectorTaskAdmission.count(:request) == 0 end)

    {:ok, second_token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "name" => "second-admission-connector",
        "alias" => "second-admission-connector"
      })

    {first, _first_env_id} = connect(group_id, "first-admission-connector", first_token)

    {second, _second_env_id} =
      connect(group_id, "second-admission-connector", second_token["token"])

    :sys.suspend(SalixWeb.ConnectorRequestTaskSupervisor)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_request_task_limit, previous_limit)

      if supervisor = Process.whereis(SalixWeb.ConnectorRequestTaskSupervisor) do
        if Process.alive?(supervisor) do
          try do
            :sys.resume(supervisor)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    Enum.each(1..4, fn index ->
      send(first, {
        :send_frame,
        %{
          "id" => "globally-blocked-#{index}",
          "type" => "request",
          "method" => "runtime_proxy",
          "params" => %{"method" => "GET", "route_path" => "/health"}
        }
      })
    end)

    assert eventually(fn -> SalixWeb.ConnectorTaskAdmission.count(:request) == 4 end)

    send(second, {
      :send_frame,
      %{
        "id" => "global-request-overload",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/health"}
      }
    })

    assert_receive {:connector_frame,
                    %{
                      "id" => "global-request-overload",
                      "type" => "error",
                      "error" => "server request capacity exhausted"
                    }},
                   300

    Process.exit(first, :kill)
    Process.exit(second, :kill)
    assert eventually(fn -> SalixWeb.ConnectorTaskAdmission.count(:request) == 0 end)
    :sys.resume(SalixWeb.ConnectorRequestTaskSupervisor)
  end

  test "blocked runtime_proxy work does not block an unrelated RPC on the same socket",
       %{
         group_id: group_id,
         agent_id: agent_id,
         connector_token: token
       } do
    device_id = Process.get(:test_device_id)
    previous_limit = Application.get_env(:salix_web, :connector_socket_request_task_limit)
    Application.put_env(:salix_web, :connector_socket_request_task_limit, 1)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_socket_request_task_limit, previous_limit)
    end)

    {pid, env_id} = connect(group_id, "laptop", token)
    environment_id = command_environment_id!(env_id)

    Application.put_env(:salix_env, :runtime_proxy_handler, __MODULE__.RuntimeProxyHandler)
    Application.put_env(:salix_env, :runtime_proxy_test_pid, self())

    send(pid, {
      :send_frame,
      %{
        "id" => "runtime-slow",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{
          "capability_token" => "cap",
          "method" => "POST",
          "route_path" => "/tool/slow"
        }
      }
    })

    assert_receive {:runtime_proxy_blocked, blocker}, 1_000

    send(pid, {
      :send_frame,
      %{
        "id" => "runtime-over-limit",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/tools"}
      }
    })

    assert_receive {:connector_frame,
                    %{
                      "id" => "runtime-over-limit",
                      "type" => "error",
                      "error" => "server request capacity exhausted"
                    }},
                   300

    quick =
      Task.async(fn ->
        EnvDispatch.request(
          agent_id,
          %{device_id: device_id, environment_id: environment_id},
          "read",
          %{"path" => "/unrelated"}
        )
      end)

    assert_receive {:read_request, _label, "/unrelated"}, 300

    assert {:ok, %{"content" => "file@/unrelated"}} = Task.await(quick, 1_000)
    refute_received {:connector_frame, %{"id" => "runtime-slow"}}

    send(blocker, :release_runtime_proxy)

    assert_receive {:connector_frame,
                    %{
                      "id" => "runtime-slow",
                      "type" => "response",
                      "result" => %{"status" => 204}
                    }},
                   1_000
  end

  test "request task saturation returns an explicit overload error",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "laptop", token)
    blockers = saturate_task_supervisor(SalixWeb.ConnectorRequestTaskSupervisor)

    on_exit(fn ->
      Enum.each(blockers, fn blocker ->
        if Process.alive?(blocker), do: Process.exit(blocker, :kill)
      end)
    end)

    send(pid, {
      :send_frame,
      %{
        "id" => "runtime-overloaded",
        "type" => "request",
        "method" => "runtime_proxy",
        "params" => %{"method" => "GET", "route_path" => "/tools"}
      }
    })

    assert_receive {:connector_frame,
                    %{
                      "id" => "runtime-overloaded",
                      "type" => "error",
                      "error" => "server request capacity exhausted"
                    }},
                   300

    Enum.each(blockers, &send(&1, :release_task))
  end

  test "missing connector heartbeat replies close the socket and mark it disconnected",
       %{group_id: group_id, connector_token: token} do
    previous_interval = Application.get_env(:salix_web, :connector_heartbeat_ms)
    previous_timeout = Application.get_env(:salix_web, :connector_heartbeat_timeout_ms)
    Application.put_env(:salix_web, :connector_heartbeat_ms, 20)
    Application.put_env(:salix_web, :connector_heartbeat_timeout_ms, 60)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_heartbeat_ms, previous_interval)
      restore_app_env(:salix_web, :connector_heartbeat_timeout_ms, previous_timeout)
    end)

    {:ok, pid} =
      FakeConnector.start_query(
        ws_base(),
        %{"name" => "silent", "os" => "linux", "reply_heartbeat" => false},
        token,
        self()
      )

    track(pid)

    env_id =
      receive do
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

  test "agent_runtime_input sends only the standard external runtime input",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    session_id = SalixStore.Ids.new_session_id()
    {_pid, env_id} = connect(group_id, "laptop", token)
    environment_id = command_environment_id!(env_id)

    dispatch_id = "batch-#{SalixStore.ULID.generate()}"

    assert {:ok, %{"accepted" => true, "dispatch_id" => ^dispatch_id}} =
             EnvDispatch.request(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "agent_runtime_input",
               %{
                 "kind" => "external",
                 "provider" => "codex",
                 "session_id" => session_id,
                 "dispatch_id" => dispatch_id,
                 "runtime_capability_token" => "cap-wire",
                 "runtime_config" => %{"command" => "/usr/bin/codex"},
                 "system_prompt" => "work",
                 "input_messages" => [%{"role" => "user", "content" => "run"}]
               }
             )

    assert_receive {:agent_runtime_input, nil, params}, 1_000
    assert params["kind"] == "external"
    assert params["provider"] == "codex"
    assert params["session_id"] == session_id
    assert params["dispatch_id"] == dispatch_id
    assert params["runtime_capability_token"] == "cap-wire"
    refute Map.has_key?(params, "runtime_payload")
    assert params["runtime_config"] == %{"command" => "/usr/bin/codex"}
    assert params["system_prompt"] == "work"
    assert params["input_messages"] == [%{"role" => "user", "content" => "run"}]
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
    send(
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

  test "metadata frame persists only bounded connector health",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "laptop", token)

    health = %{
      "schema_version" => 1,
      "observed_at" => 1_780_000_000_000,
      "process_started_at" => 1_779_999_000_000,
      "request_inflight" => 1,
      "request_capacity" => 16,
      "runtime_proxy_inflight" => 0,
      "runtime_proxy_capacity" => 16,
      "managed_processes" => 2,
      "resumable_runtime_sessions" => 607,
      "recoverable_runtime_sessions" => 3,
      "pending_input_batches" => 1,
      "pending_runtime_events" => 0,
      "raw_path" => "/private/runtime"
    }

    send(pid, {:send_frame, %{"type" => "metadata", "connector_health" => health}})

    assert eventually(fn ->
             match?(
               {:ok, %{"connector_health" => %{"observed_at" => 1_780_000_000_000}}},
               environment_for_run_result(env_id)
             )
           end)

    env = environment_for_run!(env_id)
    refute Map.has_key?(env["connector_health"], "raw_path")
    assert is_integer(env["connector_health_updated_at"])

    legacy_health =
      health
      |> Map.delete("resumable_runtime_sessions")
      |> Map.put("observed_at", 1_780_000_000_001)

    send(pid, {:send_frame, %{"type" => "metadata", "connector_health" => legacy_health}})

    assert eventually(fn ->
             get_in(environment_for_run!(env_id), ["connector_health", "observed_at"]) ==
               1_780_000_000_001
           end)

    send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "connector_health" => Map.delete(legacy_health, "request_capacity")
       }}
    )

    Process.sleep(25)

    assert environment_for_run!(env_id)["connector_health"] ==
             Map.delete(legacy_health, "raw_path")
  end

  test "connector credential restores stable device identity while each connect gets a fresh run",
       %{group_id: group_id, connector_token: token} do
    {first_pid, first_run_id} = connect(group_id, "laptop", token)
    first = environment_for_run!(first_run_id)
    {_second_pid, second_run_id} = connect(group_id, "laptop", token)

    assert first_run_id != second_run_id

    second = environment_for_run!(second_run_id)
    assert second["connector_run_id"] == second_run_id
    assert first["device_id"] == second["device_id"]
    assert first["connector_id"] == second["connector_id"]

    Process.exit(first_pid, :kill)
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
    call = Task.async(fn -> EnvDispatch.exec(agent_id, target, "hold-exec", %{}) end)
    assert_receive {:held_exec_request, :first, _request}, 3_000
    disconnect_connector!(first, first_run)

    {:ok, replacement} =
      FakeConnector.start_query(ws_base(), query, token["token"], self(), :replacement)

    track(replacement)
    assert_receive {:connected, next_run}, 3_000
    assert environment_for_run!(next_run)["device_id"] == device
    assert environment_for_run!(next_run)["process_instance_id"] == "same-exec-process"
    refute_receive {:held_exec_request, :replacement, _request}, 200
    assert {:error, :disconnected} = Task.await(call, 3_000)
  end

  test "known environment dispatch survives an unrelated device record read failure",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {_pid, run_id} = connect(group_id, "laptop", token)
    environment_id = command_environment_id!(run_id)

    {:ok, other_token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "name" => "unrelated"
      })

    {_other_pid, other_run_id} = connect(group_id, "unrelated", other_token["token"])
    other = environment_for_run!(other_run_id)
    other_key = Keys.ctl_group_device(tenant_id(), group_id, other["device_id"])

    assert {:ok, %{"exit_code" => 0}} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "echo target",
               %{}
             )

    :ok = S3.Fake.set_fault_for(self(), {:fail, 503, :get, other_key})

    assert {:ok, %{"exit_code" => 0, "stdout" => "ran: echo isolated"}} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "echo isolated",
               %{}
             )
  end

  test "known environment dispatch reads stay bounded as unrelated devices grow",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {_pid, run_id} = connect(group_id, "laptop", token)
    environment_id = command_environment_id!(run_id)
    prefix = Keys.ctl_group_devices_prefix(tenant_id(), group_id)

    :ok = S3.Fake.reset_read_log()

    assert {:ok, %{"exit_code" => 0}} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "echo before",
               %{}
             )

    before_reads = S3.Fake.read_log(self())

    for index <- 1..3 do
      name = "unrelated-#{index}"

      {:ok, other_token} =
        SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
          "name" => name
        })

      connect(group_id, name, other_token["token"])
    end

    :ok = S3.Fake.reset_read_log()

    assert {:ok, %{"exit_code" => 0}} =
             EnvDispatch.exec(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "echo after",
               %{}
             )

    after_reads = S3.Fake.read_log(self())
    assert length(before_reads) == 3
    assert length(after_reads) == 3
    refute Enum.any?(after_reads, &match?({:list, ^prefix, _}, &1))
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
      assert S3.Fake.read_log(self()) == [{:get, key}, {:get, run_key}, {:get, key}]
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
      refute Enum.any?(S3.Fake.read_log(self()), &match?({:list, _, _}, &1))
      refute Enum.any?(S3.Fake.read_log(self()), &match?({:get, "ctl/connector_runs/" <> _}, &1))
    end

    send(
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

    send(pid, {:send_frame, %{"type" => "metadata", "capabilities" => %{"scope" => ""}}})

    assert eventually(fn ->
             match?(
               {:ok, %{"exit_code" => 0}},
               EnvDispatch.exec(agent_id, target, "echo enabled", %{})
             )
           end)

    Process.exit(pid, :kill)

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

    Process.exit(first_pid, :kill)

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

  test "codex runtime identity uses connector-owned identity material",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "laptop", token)
    env = environment_for_run!(env_id)

    identity_material = "~/.local/bin/codex"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(env["device_id"], "codex", runtime_id)

    send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{
           "agent_runtimes" => [
             %{
               "kind" => "external",
               "provider" => "codex",
               "command" => "/usr/local/bin/codex",
               "identity_material" => "  #{identity_material}  "
             }
           ]
         }
       }}
    )

    assert eventually(fn ->
             case {environment_for_run_result(env_id), environment_device_for_run(env_id)} do
               {{:ok, %{"device_runtimes" => runtimes}}, {:ok, device}} ->
                 runtime = Enum.find(runtimes, &(&1["provider"] == "codex")) || %{}

                 raw_runtime =
                   device
                   |> get_in(["meta", "agent_runtimes"])
                   |> List.wrap()
                   |> Enum.find(&(&1["provider"] == "codex"))

                 is_map(raw_runtime) and runtime["runtime_id"] == runtime_id and
                   runtime["device_runtime_id"] == device_runtime_id and
                   not Map.has_key?(runtime, "identity_material") and
                   not Map.has_key?(runtime, "command") and
                   raw_runtime["identity_material"] == identity_material and
                   raw_runtime["command"] == "/usr/local/bin/codex"

               _ ->
                 false
             end
           end)
  end

  test "runtime session snapshots are validated atomically and retained after disconnect",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "session-snapshot", token)
    env = environment_for_run!(env_id)
    identity_material = "/private/bin/codex"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(env["device_id"], "codex", runtime_id)
    session_ids = ["ses1_0000000000000000001", "ses1_0000000000000000002"]

    snapshot = %{
      "schema_version" => 1,
      "observed_at" => 1_780_000_000_000,
      "session_count" => 2,
      "session_ids" => session_ids,
      "truncated" => false
    }

    runtime = %{
      "kind" => "external",
      "provider" => "codex",
      "command" => identity_material,
      "identity_material" => identity_material,
      "version" => "before-invalid-frame",
      "session_snapshot" => snapshot
    }

    send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{"runtime_probe" => true, "agent_runtimes" => [runtime]}
       }}
    )

    assert eventually(fn ->
             match?(
               {:ok,
                %{
                  "meta" => %{
                    "agent_runtimes" => [
                      %{
                        "device_runtime_id" => ^device_runtime_id,
                        "session_snapshot" => ^snapshot
                      }
                    ]
                  }
                }},
               environment_device_for_run(env_id)
             )
           end)

    :ok = S3.Fake.reset_read_log()

    assert {:ok, sessions} =
             SalixEnv.Control.runtime_sessions(
               env["device_id"],
               device_runtime_id,
               group_id,
               tenant_id()
             )

    reads = S3.Fake.read_log()
    refute Enum.any?(reads, &match?({:list, _, _}, &1))

    refute Enum.any?(reads, fn
             {:get, key} -> String.contains?(key, ["agents/", "/sessions/", "runtime_work"])
             _ -> false
           end)

    assert sessions == %{
             "connector_status" => "connected",
             "device_id" => env["device_id"],
             "device_runtime_id" => device_runtime_id,
             "observation_status" => "current",
             "observed_at" => snapshot["observed_at"],
             "session_count" => 2,
             "session_ids" => session_ids,
             "truncated" => false
           }

    sixty_five_ids =
      Enum.map(1..65, &("ses1_" <> String.pad_leading(Integer.to_string(&1), 19, "0")))

    invalid_snapshots = [
      Map.put(snapshot, "schema_version", 2),
      Map.put(snapshot, "observed_at", 0),
      Map.put(snapshot, "session_ids", Enum.reverse(session_ids)),
      Map.put(snapshot, "session_ids", [hd(session_ids), hd(session_ids)]),
      Map.put(snapshot, "session_ids", ["native-thread-id", List.last(session_ids)]),
      Map.put(snapshot, "session_count", 1),
      Map.put(snapshot, "truncated", true),
      snapshot
      |> Map.put("session_count", 65)
      |> Map.put("session_ids", sixty_five_ids),
      Map.put(snapshot, "native_thread_id", "secret")
    ]

    Enum.with_index(invalid_snapshots, fn invalid_snapshot, index ->
      invalid =
        runtime
        |> Map.put("version", "poisoned-#{index}")
        |> Map.put("session_snapshot", invalid_snapshot)

      send(
        pid,
        {:send_frame,
         %{
           "type" => "metadata",
           "capabilities" => %{"runtime_probe" => true, "agent_runtimes" => [invalid]}
         }}
      )

      Process.sleep(25)

      assert hd(environment_device_for_run!(env_id)["meta"]["agent_runtimes"])["version"] ==
               "before-invalid-frame"
    end)

    over_global_limit =
      Enum.map(0..4, fn runtime_index ->
        count = if runtime_index == 4, do: 1, else: 64

        ids =
          Enum.map(1..count, fn session_index ->
            value = runtime_index * 100 + session_index
            "ses1_" <> String.pad_leading(Integer.to_string(value), 19, "0")
          end)

        runtime
        |> Map.put("identity_material", "/private/bin/codex-#{runtime_index}")
        |> Map.put("command", "/private/bin/codex-#{runtime_index}")
        |> Map.put("session_snapshot", %{
          "schema_version" => 1,
          "observed_at" => snapshot["observed_at"],
          "session_count" => count,
          "session_ids" => ids,
          "truncated" => false
        })
      end)

    send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{
           "runtime_probe" => true,
           "agent_runtimes" => over_global_limit
         }
       }}
    )

    Process.sleep(25)
    retained = environment_device_for_run!(env_id)
    assert hd(retained["meta"]["agent_runtimes"])["version"] == "before-invalid-frame"
    assert hd(retained["meta"]["agent_runtimes"])["session_snapshot"] == snapshot

    invalid_runtime_frames = [
      [42],
      [Map.put(runtime, "identity_material", 42)],
      [Map.put(runtime, "command", 42)],
      [Map.put(runtime, "readiness_message", %{"secret" => "nested"})],
      [Map.put(runtime, "readiness_message", String.duplicate("x", 301))],
      [Map.put(runtime, "readiness_message", "unsafe\nmessage")],
      [runtime, runtime],
      Enum.map(0..32, fn index ->
        runtime
        |> Map.delete("session_snapshot")
        |> Map.put("identity_material", "/private/bin/codex-bound-#{index}")
      end),
      %{"not" => "a list"}
    ]

    Enum.with_index(invalid_runtime_frames, fn invalid_runtimes, index ->
      send(
        pid,
        {:send_frame,
         %{
           "type" => "metadata",
           "capabilities" => %{
             "invalid_runtime_frame" => index,
             "agent_runtimes" => invalid_runtimes
           }
         }}
      )

      Process.sleep(25)
      current = environment_device_for_run!(env_id)
      assert hd(current["meta"]["agent_runtimes"])["version"] == "before-invalid-frame"
      assert hd(current["meta"]["agent_runtimes"])["session_snapshot"] == snapshot
      refute get_in(current, ["meta", "capabilities", "invalid_runtime_frame"]) == index
      assert Process.alive?(pid)
    end)

    assert {:ok, raw_device} = environment_device_for_run(env_id)
    refute Map.has_key?(get_in(raw_device, ["meta", "capabilities"]), "agent_runtimes")

    Process.exit(pid, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(env["device_id"], group_id, tenant_id())
             )
           end)

    assert {:ok, disconnected} =
             SalixEnv.Control.runtime_sessions(
               env["device_id"],
               device_runtime_id,
               group_id,
               tenant_id()
             )

    assert disconnected["observation_status"] == "last_observed"
    assert disconnected["session_ids"] == session_ids

    {legacy_pid, legacy_env_id} = connect(group_id, "session-snapshot", token)

    send(
      legacy_pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{"legacy_runtime_observability" => true}
       }}
    )

    assert eventually(fn ->
             case environment_device_for_run(legacy_env_id) do
               {:ok,
                %{
                  "meta" => %{
                    "capabilities" => %{"legacy_runtime_observability" => true}
                  }
                }} ->
                 true

               _ ->
                 false
             end
           end)

    assert {:ok, not_reported} =
             SalixEnv.Control.runtime_sessions(
               env["device_id"],
               device_runtime_id,
               group_id,
               tenant_id()
             )

    assert not_reported["connector_status"] == "connected"
    assert not_reported["observation_status"] == "not_reported"
    assert not_reported["session_ids"] == []
    Process.exit(legacy_pid, :kill)
  end

  test "operator runtime probe selects the private exact target and publishes canonical readiness",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "laptop", token)
    env = environment_for_run!(env_id)
    identity_material = "/private/bin/codex"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(env["device_id"], "codex", runtime_id)
    checked_at = System.system_time(:millisecond)

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

    send(
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
      Task.async(fn ->
        SalixEnv.Control.probe_runtime(
          env["device_id"],
          device_runtime_id,
          group_id,
          tenant_id
        )
      end)

    assert_receive {:runtime_probe_request, ^pid, request_id, params}
    assert params == %{"provider" => "codex", "identity_material" => identity_material}

    unavailable_runtime =
      ready_runtime
      |> Map.put("auth_ready", false)
      |> Map.put("ready", false)
      |> Map.put("readiness_issue", "authentication_required")
      |> Map.put("readiness_checked_at", checked_at + 1)

    send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{"runtime_probe" => true, "agent_runtimes" => [unavailable_runtime]}
       }}
    )

    send(
      pid,
      {:send_frame,
       %{
         "id" => request_id,
         "type" => "response",
         "result" => %{"runtimes" => [unavailable_runtime]}
       }}
    )

    assert {:ok, summary} = Task.await(task)
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

  test "external runtime admission refreshes one stale target before resolving",
       %{group_id: group_id, connector_token: token} do
    {pid, env_id} = connect(group_id, "stale-runtime", token)
    env = environment_for_run!(env_id)
    identity_material = "/private/bin/codex-stale"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(env["device_id"], "codex", runtime_id)
    checked_at = System.system_time(:millisecond)

    stale_runtime = %{
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
      "readiness_checked_at" => checked_at - 600_001,
      "readiness_valid_until" => checked_at - 1
    }

    send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{"runtime_probe" => true, "agent_runtimes" => [stale_runtime]}
       }}
    )

    assert eventually(fn ->
             case environment_for_run_result(env_id) do
               {:ok, %{"device_runtimes" => runtimes}} ->
                 Enum.any?(
                   runtimes,
                   &(&1["device_runtime_id"] == device_runtime_id and &1["status"] == "stale")
                 )

               _ ->
                 false
             end
           end)

    tenant_id = tenant_id()

    task =
      Task.async(fn ->
        SalixEnv.Control.resolve_external_runtime_binding(
          %{"provider" => "codex", "device_runtime_id" => device_runtime_id},
          tenant_id,
          group_id
        )
      end)

    assert_receive {:runtime_probe_request, ^pid, request_id, params}
    assert params == %{"provider" => "codex", "identity_material" => identity_material}

    ready_runtime =
      stale_runtime
      |> Map.put("model", "fresh-model")
      |> Map.put("readiness_checked_at", checked_at)
      |> Map.put("readiness_valid_until", checked_at + 600_000)

    send(
      pid,
      {:send_frame,
       %{
         "type" => "metadata",
         "capabilities" => %{"runtime_probe" => true, "agent_runtimes" => [ready_runtime]}
       }}
    )

    send(
      pid,
      {:send_frame,
       %{
         "id" => request_id,
         "type" => "response",
         "result" => %{"runtimes" => [ready_runtime]}
       }}
    )

    assert {:ok, binding} = Task.await(task)
    assert binding["device_runtime_id"] == device_runtime_id
    assert binding["runtime"]["readiness_checked_at"] == checked_at
    assert binding["model"] == "fresh-model"
  end

  test "runtime auth metadata is strict, atomic, public, and legacy compatible",
       %{group_id: group_id, connector_token: token} do
    {pid, connector_run_id} = connect(group_id, "runtime-auth-metadata", token)
    env = environment_for_run!(connector_run_id)
    identity_material = "/private/bin/codex-auth"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(env["device_id"], "codex", runtime_id)

    auth = %{
      "schema_version" => 1,
      "status" => "unauthenticated",
      "mode" => "chatgpt",
      "requires_openai_auth" => true,
      "observed_at" => 1_787_020_000_000
    }

    runtime = %{
      "kind" => "external",
      "provider" => "codex",
      "command" => identity_material,
      "identity_material" => identity_material,
      "version" => "before-invalid-auth",
      "version_detected" => true,
      "auth_ready" => false,
      "native_server_startable" => true,
      "ready" => false,
      "readiness_issue" => "authentication_required",
      "readiness_checked_at" => auth["observed_at"],
      "readiness_valid_until" => auth["observed_at"] + 600_000,
      "auth" => auth
    }

    send(pid, {
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
             case SalixEnv.Control.get_environment(
                    env["device_id"],
                    group_id,
                    tenant_id()
                  ) do
               {:ok, public} ->
                 projected =
                   Enum.find(
                     public["device_runtimes"],
                     &(&1["device_runtime_id"] == device_runtime_id)
                   )

                 public["capabilities"]["runtime_auth_v1"] == true and
                   projected["auth"] == auth

               _ ->
                 false
             end
           end)

    invalid_auth_snapshots = [
      Map.put(auth, "schema_version", 2),
      Map.put(auth, "status", "signed_in_with_secret"),
      Map.put(auth, "mode", "browser"),
      Map.put(auth, "requires_openai_auth", "true"),
      Map.put(auth, "observed_at", 0),
      Map.put(auth, "issue", "raw provider error"),
      Map.put(auth, "verification_url", "https://auth.example.test/device"),
      Map.put(auth, "user_code", "ABCD-EFGH"),
      Map.put(auth, "token", "private-token"),
      Map.put(auth, "command", "/tmp/evil"),
      Map.put(auth, "path", "/private/home"),
      Map.put(auth, "native_login_id", "native-secret")
    ]

    Enum.with_index(invalid_auth_snapshots, fn invalid_auth, index ->
      poisoned =
        runtime
        |> Map.put("version", "poisoned-auth-#{index}")
        |> Map.put("auth", invalid_auth)

      send(pid, {
        :send_frame,
        %{
          "type" => "metadata",
          "capabilities" => %{
            "runtime_auth_v1" => true,
            "invalid_auth_frame" => index,
            "agent_runtimes" => [poisoned]
          }
        }
      })

      Process.sleep(25)
      current = environment_device_for_run!(connector_run_id)
      assert hd(current["meta"]["agent_runtimes"])["version"] == "before-invalid-auth"
      refute get_in(current, ["meta", "capabilities", "invalid_auth_frame"]) == index
      assert Process.alive?(pid)
    end)

    legacy = runtime |> Map.delete("auth") |> Map.put("version", "legacy-auth-runtime")

    send(pid, {
      :send_frame,
      %{
        "type" => "metadata",
        "capabilities" => %{"runtime_probe" => true, "agent_runtimes" => [legacy]}
      }
    })

    assert eventually(fn ->
             case SalixEnv.Control.get_environment(
                    env["device_id"],
                    group_id,
                    tenant_id()
                  ) do
               {:ok, public} ->
                 projected =
                   Enum.find(
                     public["device_runtimes"],
                     &(&1["device_runtime_id"] == device_runtime_id)
                   )

                 projected["version"] == "legacy-auth-runtime" and
                   not Map.has_key?(projected, "auth") and
                   not Map.has_key?(public["capabilities"], "runtime_auth_v1")

               _ ->
                 false
             end
           end)
  end

  test "generic private input binds the current connected Pi target and rejects a changed inventory",
       %{group_id: group_id, connector_token: token} do
    {pid, run_id} = connect(group_id, "runtime-auth-private-pi", token)
    env = environment_for_run!(run_id)
    identity = "/private/bin/pi-input"

    runtime_id =
      RuntimeIds.device_runtime_id(env["device_id"], "pi", RuntimeIds.runtime_id(identity))

    now = System.system_time(:millisecond)

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
      send(
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

    task = Task.async(fn -> SalixEnv.Control.runtime_auth(:input_begin, attrs) end)
    assert_receive {:runtime_auth_request, ^pid, id, "runtime_auth_input_begin", params}, 1_000
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

    send(pid, {:send_frame, %{"id" => id, "type" => "response", "result" => offer}})
    assert {:ok, ^offer} = Task.await(task)

    submit_attrs =
      attrs
      |> Map.drop([:backend, :form])
      |> Map.merge(%{attempt_id: "private-attempt", envelope: "synthetic-envelope"})

    rejected = Task.async(fn -> SalixEnv.Control.runtime_auth(:input_submit, submit_attrs) end)

    assert_receive {:runtime_auth_request, ^pid, rejected_id, "runtime_auth_input_submit", _},
                   1_000

    send(
      pid,
      {:send_frame, %{"id" => rejected_id, "type" => "error", "error" => "invalid_format"}}
    )

    assert {:error, :runtime_auth_failed} = Task.await(rejected)

    malformed = Task.async(fn -> SalixEnv.Control.runtime_auth(:input_submit, submit_attrs) end)

    assert_receive {:runtime_auth_request, ^pid, malformed_id, "runtime_auth_input_submit", _},
                   1_000

    send(
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

    assert {:error, :invalid_runtime_auth_response} = Task.await(malformed)

    verify =
      Task.async(fn -> SalixEnv.Control.runtime_auth(:verify, Map.delete(attrs, :form)) end)

    assert_receive {:runtime_auth_request, ^pid, verify_id, "runtime_auth_verify", _params}, 1_000
    changed = Map.put(runtime, "identity_material", "/private/bin/replaced-pi")
    publish.(changed)

    assert eventually(fn ->
             hd(environment_device_for_run!(run_id)["meta"]["agent_runtimes"])[
               "identity_material"
             ] == "/private/bin/replaced-pi"
           end)

    send(
      pid,
      {:send_frame,
       %{
         "id" => verify_id,
         "type" => "response",
         "result" => %{"status" => "authenticated", "issue" => ""}
       }}
    )

    assert {:error, :runtime_auth_target_changed} = Task.await(verify)
    refute_receive {:runtime_auth_request, ^pid, _, _, _}

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
    login = Task.async(fn -> SalixEnv.Control.runtime_auth(:login_start, login_attrs) end)

    assert_receive {:runtime_auth_request, ^pid, login_id, "runtime_auth_login_start",
                    login_params},
                   1_000

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

    send(
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

    assert {:error, :invalid_runtime_auth_response} = Task.await(login)
  end

  test "runtime auth control dispatches only the current exact private target",
       %{group_id: group_id, connector_token: token} do
    attach_liveness_telemetry([[:salix, :operation, :stop]])

    {pid, connector_run_id} = connect(group_id, "runtime-auth-control", token)
    env = environment_for_run!(connector_run_id)
    identity_material = "/private/bin/codex-auth-control"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(env["device_id"], "codex", runtime_id)
    observed_at = System.system_time(:millisecond)

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

    send(pid, {
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
      Task.async(fn ->
        SalixEnv.Control.runtime_auth_read(
          env["device_id"],
          device_runtime_id,
          group_id,
          tenant_id
        )
      end)

    assert_receive {:runtime_auth_request, ^pid, read_id, "runtime_auth_read", read_params},
                   1_000

    assert read_params == %{
             "provider" => "codex",
             "identity_material" => identity_material
           }

    refute Map.has_key?(read_params, "command")
    refute Map.has_key?(read_params, "path")

    send(pid, {
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

    assert {:ok, %{"auth" => ^auth, "attempt_id" => "rta_read"}} = Task.await(read_task)

    assert_receive {:liveness_telemetry, [:salix, :operation, :stop], %{duration: read_duration},
                    %{
                      component: "salix_env",
                      operation: "runtime_auth_read",
                      surface: "system",
                      outcome: "ok"
                    }}

    assert is_integer(read_duration) and read_duration >= 0

    start_task =
      Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_start(
          env["device_id"],
          device_runtime_id,
          "device_code",
          group_id,
          tenant_id
        )
      end)

    assert_receive {:runtime_auth_request, ^pid, start_id, "runtime_auth_login_start",
                    start_params},
                   1_000

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

    send(pid, {
      :send_frame,
      %{"id" => start_id, "type" => "response", "result" => ceremony}
    })

    assert {:ok, ^ceremony} = Task.await(start_task)

    assert_receive {:liveness_telemetry, [:salix, :operation, :stop], %{duration: start_duration},
                    %{
                      component: "salix_env",
                      operation: "runtime_auth_login_start",
                      surface: "system",
                      outcome: "ok"
                    }}

    assert is_integer(start_duration) and start_duration >= 0

    cancel_task =
      Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_cancel(
          env["device_id"],
          device_runtime_id,
          "rta_start",
          group_id,
          tenant_id
        )
      end)

    assert_receive {:runtime_auth_request, ^pid, cancel_id, "runtime_auth_login_cancel",
                    cancel_params},
                   1_000

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

    send(pid, {
      :send_frame,
      %{"id" => cancel_id, "type" => "response", "result" => cancel_result}
    })

    assert {:ok, ^cancel_result} = Task.await(cancel_task)

    assert_receive {:liveness_telemetry, [:salix, :operation, :stop],
                    %{duration: cancel_duration},
                    %{
                      component: "salix_env",
                      operation: "runtime_auth_login_cancel",
                      surface: "system",
                      outcome: "ok"
                    }}

    assert is_integer(cancel_duration) and cancel_duration >= 0

    mismatched_cancel_task =
      Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_cancel(
          env["device_id"],
          device_runtime_id,
          "rta_expected",
          group_id,
          tenant_id
        )
      end)

    assert_receive {:runtime_auth_request, ^pid, mismatched_cancel_id,
                    "runtime_auth_login_cancel", _params},
                   1_000

    send(pid, {
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

    assert {:error, :invalid_runtime_auth_response} = Task.await(mismatched_cancel_task)

    assert_receive {:liveness_telemetry, [:salix, :operation, :stop], _measurements,
                    %{
                      component: "salix_env",
                      operation: "runtime_auth_login_cancel",
                      surface: "system",
                      outcome: "error"
                    }}

    bft_read_task =
      Task.async(fn ->
        SystemsObservability.Context.with_surface("bft", fn ->
          SalixEnv.Control.runtime_auth_read(
            env["device_id"],
            device_runtime_id,
            group_id,
            tenant_id
          )
        end)
      end)

    assert_receive {:runtime_auth_request, ^pid, bft_read_id, "runtime_auth_read", _params},
                   1_000

    send(pid, {
      :send_frame,
      %{
        "id" => bft_read_id,
        "type" => "response",
        "result" => %{"auth" => auth}
      }
    })

    assert {:ok, %{"auth" => ^auth}} = Task.await(bft_read_task)

    assert_receive {:liveness_telemetry, [:salix, :operation, :stop], _measurements,
                    %{
                      component: "salix_env",
                      operation: "runtime_auth_read",
                      surface: "bft",
                      outcome: "ok"
                    }}

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
      Task.async(fn ->
        :get
        |> Plug.Test.conn(auth_path)
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
        |> SalixWeb.Router.call(SalixWeb.Router.init([]))
      end)

    assert_receive {:runtime_auth_request, ^pid, http_read_id, "runtime_auth_read", _params},
                   1_000

    send(pid, {
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

    http_read = Task.await(http_read_task)
    assert http_read.status == 200
    assert Plug.Conn.get_resp_header(http_read, "cache-control") == ["no-store"]
    assert Jason.decode!(http_read.resp_body) == %{"auth" => auth}

    assert_receive {:liveness_telemetry, [:salix, :operation, :stop], _measurements,
                    %{
                      component: "salix_env",
                      operation: "runtime_auth_read",
                      surface: "salix",
                      outcome: "ok"
                    }}

    capacity_task =
      Task.async(fn ->
        :get
        |> Plug.Test.conn(auth_path)
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
        |> SalixWeb.Router.call(SalixWeb.Router.init([]))
      end)

    assert_receive {:runtime_auth_request, ^pid, capacity_id, "runtime_auth_read", _params},
                   1_000

    send(pid, {
      :send_frame,
      %{
        "id" => capacity_id,
        "type" => "error",
        "error" => "runtime auth capacity exhausted"
      }
    })

    capacity_response = Task.await(capacity_task)
    assert capacity_response.status == 503
    assert Plug.Conn.get_resp_header(capacity_response, "cache-control") == ["no-store"]
    assert Jason.decode!(capacity_response.resp_body) == %{"error" => "unavailable"}

    assert_receive {:liveness_telemetry, [:salix, :operation, :stop], _measurements,
                    %{
                      component: "salix_env",
                      operation: "runtime_auth_read",
                      surface: "salix",
                      outcome: "unavailable"
                    }}

    http_start_task =
      Task.async(fn ->
        :post
        |> Plug.Test.conn(auth_path <> "/login", Jason.encode!(%{"flow" => "device_code"}))
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> SalixWeb.Router.call(SalixWeb.Router.init([]))
      end)

    assert_receive {:runtime_auth_request, ^pid, http_start_id, "runtime_auth_login_start",
                    _params},
                   1_000

    http_ceremony = Map.put(ceremony, "attempt_id", "rta_http_start")

    send(pid, {
      :send_frame,
      %{"id" => http_start_id, "type" => "response", "result" => http_ceremony}
    })

    http_start = Task.await(http_start_task)
    assert http_start.status == 200
    assert Plug.Conn.get_resp_header(http_start, "cache-control") == ["no-store"]
    assert Jason.decode!(http_start.resp_body) == http_ceremony

    telemetry_handler = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        telemetry_handler,
        [:comma_system, :http, :stop],
        fn _event, _measurements, metadata, _config ->
          if metadata.method == "DELETE",
            do: send(test_pid, {:runtime_auth_cancel_http, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    http_cancel_task =
      Task.async(fn ->
        :delete
        |> Plug.Test.conn(
          auth_path <> "/login",
          Jason.encode!(%{"attempt_id" => "rta_http_start"})
        )
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> SalixWeb.Router.call(SalixWeb.Router.init([]))
      end)

    assert_receive {:runtime_auth_request, ^pid, http_cancel_id, "runtime_auth_login_cancel",
                    _params},
                   1_000

    send(pid, {
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

    http_cancel = Task.await(http_cancel_task)
    assert http_cancel.status == 200
    assert Plug.Conn.get_resp_header(http_cancel, "cache-control") == ["no-store"]
    assert http_cancel.request_path == auth_path <> "/login"

    assert_receive {:runtime_auth_cancel_http, cancel_http_metadata}

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

  test "runtime auth capability and snapshot are fenced to the reporting connector generation",
       %{group_id: group_id, connector_token: token} do
    {first_pid, first_run_id} = connect(group_id, "runtime-auth-generation", token)
    first = environment_for_run!(first_run_id)
    identity_material = "/private/bin/codex-generation"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(first["device_id"], "codex", runtime_id)

    send(first_pid, {
      :send_frame,
      %{
        "type" => "metadata",
        "capabilities" => %{
          "runtime_auth_v1" => true,
          "agent_runtimes" => [
            %{
              "kind" => "external",
              "provider" => "codex",
              "command" => identity_material,
              "identity_material" => identity_material,
              "version_detected" => true,
              "auth_ready" => false,
              "native_server_startable" => true,
              "ready" => false,
              "readiness_checked_at" => 1_787_020_000_000,
              "readiness_valid_until" => 1_787_020_600_000,
              "auth" => %{
                "schema_version" => 1,
                "status" => "unauthenticated",
                "requires_openai_auth" => true,
                "observed_at" => 1_787_020_000_000
              }
            }
          ]
        }
      }
    })

    assert eventually(fn ->
             match?(
               {:ok, %{"capabilities" => %{"runtime_auth_v1" => true}}},
               SalixEnv.Control.get_environment(
                 first["device_id"],
                 group_id,
                 tenant_id()
               )
             )
           end)

    Process.exit(first_pid, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(first["device_id"], group_id, tenant_id())
             )
           end)

    {_second_pid, second_run_id} = connect(group_id, "runtime-auth-generation", token)
    assert second_run_id != first_run_id

    assert eventually(fn ->
             case SalixEnv.Control.get_environment(
                    first["device_id"],
                    group_id,
                    tenant_id()
                  ) do
               {:ok, current} ->
                 runtime =
                   Enum.find(
                     current["device_runtimes"],
                     &(&1["device_runtime_id"] == device_runtime_id)
                   )

                 not Map.has_key?(current["capabilities"], "runtime_auth_v1") and
                   (is_nil(runtime) or not Map.has_key?(runtime, "auth"))

               _ ->
                 false
             end
           end)

    assert {:error, :runtime_auth_unsupported} =
             SalixEnv.Control.runtime_auth_read(
               first["device_id"],
               device_runtime_id,
               group_id,
               tenant_id()
             )
  end

  test "runtime auth rejects delayed success after runtime removal or connector replacement",
       %{group_id: group_id, connector_token: token} do
    {first_pid, first_run_id} = connect(group_id, "runtime-auth-inflight-fence", token)
    first = environment_for_run!(first_run_id)
    identity_material = "/private/bin/codex-inflight-fence"
    runtime_id = RuntimeIds.runtime_id(identity_material)
    device_runtime_id = RuntimeIds.device_runtime_id(first["device_id"], "codex", runtime_id)
    observed_at = System.system_time(:millisecond)
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
      send(first_pid, {
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
      send(first_pid, {
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
      Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_start(
          first["device_id"],
          device_runtime_id,
          "device_code",
          group_id,
          tenant_id
        )
      end)

    assert_receive {:runtime_auth_request, ^first_pid, request_id, "runtime_auth_login_start",
                    _params}

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

    assert {:error, :runtime_auth_target_changed} = Task.await(start_task)

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
      Task.async(fn ->
        SalixEnv.Control.runtime_auth_login_start(
          first["device_id"],
          device_runtime_id,
          "device_code",
          group_id,
          tenant_id
        )
      end)

    assert_receive {:runtime_auth_request, ^first_pid, replacement_request_id,
                    "runtime_auth_login_start", _params}

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

    assert {:error, :runtime_auth_target_changed} = Task.await(replacement_task)
  end

  test "write_stream uses connector frames without transfer callback",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {_pid, env_id} = connect(group_id, "laptop", token)
    environment_id = command_environment_id!(env_id)
    body = :crypto.strong_rand_bytes(96 * 1024)
    size = byte_size(body)

    assert {:ok, %{"ok" => true, "size" => ^size}} =
             EnvDispatch.write_stream(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "/tmp/from-vfs.bin",
               [body]
             )

    assert_receive {:write_stream_request, "/tmp/from-vfs.bin", false}
    assert_receive {:write_stream_body, "/tmp/from-vfs.bin", ^body}
  end

  test "write stream errors release begin, chunk, and finish over the real WebSocket",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {_pid, env_id} = connect(group_id, "write-errors", token)
    environment_id = command_environment_id!(env_id)

    Enum.each(["begin", "chunk", "finish"], fn phase ->
      assert {:error, reason} =
               EnvDispatch.write_stream(
                 agent_id,
                 %{device_id: device_id, environment_id: environment_id},
                 "/write-error-#{phase}",
                 ["payload"]
               )

      assert to_string(reason) =~ "disk full at #{phase}"
    end)
  end

  test "write stream timeout and abort close begin, chunk, and finish ownership",
       %{group_id: group_id, connector_token: token} do
    Enum.each([:begin, :chunk, :finish, :abort], fn phase ->
      {_connector, connector_run_id} =
        connect(group_id, "write-timeout-cancel-#{phase}", token)

      [{socket_actor, :connector}] = Registry.lookup(SalixEnv.Bridges, connector_run_id)
      socket_monitor = Process.monitor(socket_actor)
      id = "write-timeout-#{phase}"
      path = "/hold-write-#{phase}"

      message =
        "write_stream"
        |> SalixEnv.Protocol.request(%{"path" => path})
        |> Map.put("id", id)

      result =
        case phase do
          :begin ->
            SalixEnv.Bridge.begin_write_stream(connector_run_id, message, 30)

          :chunk ->
            assert {:ok, %{"id" => ^id}} =
                     SalixEnv.Bridge.begin_write_stream(connector_run_id, message, 300)

            SalixEnv.Bridge.write_stream_chunk(connector_run_id, id, "payload", 30)

          :finish ->
            assert {:ok, %{"id" => ^id}} =
                     SalixEnv.Bridge.begin_write_stream(connector_run_id, message, 300)

            SalixEnv.Bridge.finish_write_stream(connector_run_id, id, 30)

          :abort ->
            assert {:ok, %{"id" => ^id}} =
                     SalixEnv.Bridge.begin_write_stream(connector_run_id, message, 300)

            SalixEnv.Bridge.abort_write_stream(connector_run_id, id, :upstream_abandoned)
        end

      assert result == if(phase == :abort, do: :ok, else: {:error, :timeout})
      assert_receive {:DOWN, ^socket_monitor, :process, ^socket_actor, _reason}, 500
    end)
  end

  test "write stream idle deadline and cap bound abandoned connector requests",
       %{group_id: group_id, connector_token: token} do
    previous_limit = Application.get_env(:salix_web, :connector_socket_write_stream_limit)

    previous_timeout =
      Application.get_env(:salix_web, :connector_write_stream_idle_timeout_ms)

    Application.put_env(:salix_web, :connector_socket_write_stream_limit, 1)
    Application.put_env(:salix_web, :connector_write_stream_idle_timeout_ms, 60)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_socket_write_stream_limit, previous_limit)

      restore_app_env(
        :salix_web,
        :connector_write_stream_idle_timeout_ms,
        previous_timeout
      )
    end)

    {_connector, connector_run_id} = connect(group_id, "write-idle-bound", token)
    [{socket_actor, :connector}] = Registry.lookup(SalixEnv.Bridges, connector_run_id)
    socket_monitor = Process.monitor(socket_actor)

    held =
      SalixEnv.Protocol.request("write_stream", %{"path" => "/hold-write-begin"})
      |> Map.put("id", "write-absolute-held")

    task =
      Task.async(fn ->
        SalixEnv.Bridge.begin_write_stream(connector_run_id, held, :infinity)
      end)

    assert_receive {:write_stream_request, "/hold-write-begin", false}, 300

    overflow =
      SalixEnv.Protocol.request("write_stream", %{"path" => "/overflow-not-pushed"})
      |> Map.put("id", "write-absolute-overflow")

    assert {:error, :connector_write_stream_capacity_exhausted} =
             SalixEnv.Bridge.begin_write_stream(connector_run_id, overflow, 300)

    refute_receive {:write_stream_request, "/overflow-not-pushed", false}, 0
    assert {:error, :timeout} = Task.await(task, 500)
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket_actor, _reason}, 500
  end

  test "write stream idle watchdog refreshes across a long multi-chunk transfer",
       %{group_id: group_id, connector_token: token} do
    previous_timeout =
      Application.get_env(:salix_web, :connector_write_stream_idle_timeout_ms)

    Application.put_env(:salix_web, :connector_write_stream_idle_timeout_ms, 300)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_write_stream_idle_timeout_ms,
        previous_timeout
      )
    end)

    {_connector, connector_run_id} = connect(group_id, "write-idle-refresh", token)
    id = "write-idle-refresh"

    message =
      SalixEnv.Protocol.request("write_stream", %{"path" => "/idle-refresh"})
      |> Map.put("id", id)

    assert {:ok, %{"id" => ^id}} =
             SalixEnv.Bridge.begin_write_stream(connector_run_id, message, 500)

    Process.sleep(175)
    assert :ok = SalixEnv.Bridge.write_stream_chunk(connector_run_id, id, "one", 500)
    Process.sleep(175)
    assert :ok = SalixEnv.Bridge.write_stream_chunk(connector_run_id, id, "two", 500)
    Process.sleep(175)

    assert {:ok, %{"ok" => true, "size" => 6}} =
             SalixEnv.Bridge.finish_write_stream(connector_run_id, id, 500)
  end

  test "meeting event queue overload is explicit on the real WebSocket",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "meeting-overload", token)
    previous_handler = Application.get_env(:salix_web, :connector_meeting_runtime_handler)
    previous_test_pid = Application.get_env(:salix_web, :connector_meeting_runtime_test_pid)

    Application.put_env(
      :salix_web,
      :connector_meeting_runtime_handler,
      __MODULE__.BlockingMeetingRuntime
    )

    Application.put_env(:salix_web, :connector_meeting_runtime_test_pid, self())

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_meeting_runtime_handler, previous_handler)
      restore_app_env(:salix_web, :connector_meeting_runtime_test_pid, previous_test_pid)
    end)

    send(pid, {
      :send_frame,
      %{
        "id" => "meeting-overload-1",
        "type" => "request",
        "method" => "meeting_runtime_event",
        "params" => %{"sequence" => 1}
      }
    })

    assert_receive {:meeting_handler_started, 1, _first_worker}, 1_000

    Enum.each(2..66, fn sequence ->
      send(pid, {
        :send_frame,
        %{
          "id" => "meeting-overload-#{sequence}",
          "type" => "request",
          "method" => "meeting_runtime_event",
          "params" => %{"sequence" => sequence}
        }
      })
    end)

    assert_receive {:connector_frame,
                    %{
                      "id" => "meeting-overload-66",
                      "type" => "error",
                      "error" => "server request capacity exhausted"
                    }},
                   1_000

    Process.exit(pid, :kill)
  end

  test "an in-flight meeting event retry is rejected before it consumes FIFO capacity",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "meeting-admission-dedupe", token)
    previous_handler = Application.get_env(:salix_web, :connector_meeting_runtime_handler)
    previous_test_pid = Application.get_env(:salix_web, :connector_meeting_runtime_test_pid)

    Application.put_env(
      :salix_web,
      :connector_meeting_runtime_handler,
      __MODULE__.BlockingMeetingRuntime
    )

    Application.put_env(:salix_web, :connector_meeting_runtime_test_pid, self())

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_meeting_runtime_handler, previous_handler)
      restore_app_env(:salix_web, :connector_meeting_runtime_test_pid, previous_test_pid)
    end)

    send_meeting_event(pid, "meeting-dedupe-first", 1, "business-event-1")
    assert_receive {:meeting_handler_started, 1, first_worker}, 1_000

    send_meeting_event(pid, "meeting-dedupe-retry", 2, "business-event-1")

    assert_receive {:connector_frame,
                    %{
                      "id" => "meeting-dedupe-retry",
                      "type" => "error",
                      "error" => "meeting runtime event already queued"
                    }},
                   1_000

    send_meeting_event(pid, "meeting-dedupe-next", 3, "business-event-2")
    refute_receive {:meeting_handler_started, 2, _worker}, 100
    send(first_worker, :release)

    assert_receive {:connector_frame, %{"id" => "meeting-dedupe-first", "type" => "response"}},
                   1_000

    assert_receive {:meeting_handler_started, 3, second_worker}, 1_000

    # The first business identity leaves the admission set on completion, so a
    # later legitimate replay can enter behind the currently active event.
    send_meeting_event(pid, "meeting-dedupe-after-complete", 4, "business-event-1")
    refute_receive {:connector_frame, %{"id" => "meeting-dedupe-after-complete"}}, 100
    send(second_worker, :release)
    assert_receive {:meeting_handler_started, 4, third_worker}, 1_000
    send(third_worker, :release)
  end

  test "meeting event replay after a lost WebSocket reply returns a duplicate result",
       %{group_id: group_id, connector_token: token} do
    previous_handler = Application.get_env(:salix_web, :connector_meeting_runtime_handler)
    previous_test_pid = Application.get_env(:salix_web, :connector_meeting_runtime_test_pid)

    Application.put_env(
      :salix_web,
      :connector_meeting_runtime_handler,
      __MODULE__.CommitThenBlockMeetingRuntime
    )

    Application.put_env(:salix_web, :connector_meeting_runtime_test_pid, self())

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_meeting_runtime_handler, previous_handler)
      restore_app_env(:salix_web, :connector_meeting_runtime_test_pid, previous_test_pid)
    end)

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id(), group_id)
    meeting_id = "mtg-socket-replay-#{System.unique_integer([:positive])}"

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

    send(first_pid, {
      :send_frame,
      %{
        "id" => "meeting-replay-first",
        "type" => "request",
        "method" => "meeting_runtime_event",
        "params" => %{"event" => event, "block_after_commit" => true}
      }
    })

    assert_receive {:meeting_event_committed_before_reply, first_worker,
                    {:ok, %{"status" => "created"}}},
                   3_000

    first_monitor = Process.monitor(first_pid)
    Process.exit(first_pid, :kill)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, _reason}, 1_000
    send(first_worker, :release_reply)

    {second_pid, _second_env_id} = connect(group_id, "meeting-replay-second", token)

    send(second_pid, {
      :send_frame,
      %{
        "id" => "meeting-replay-second",
        "type" => "request",
        "method" => "meeting_runtime_event",
        "params" => %{"event" => event}
      }
    })

    assert_receive {:connector_frame,
                    %{
                      "id" => "meeting-replay-second",
                      "type" => "response",
                      "result" => %{"status" => "duplicate"}
                    }},
                   3_000
  end

  defp send_meeting_event(pid, request_id, sequence, event_id) do
    send(pid, {
      :send_frame,
      %{
        "id" => request_id,
        "type" => "request",
        "method" => "meeting_runtime_event",
        "params" => %{
          "sequence" => sequence,
          "event" => %{"event_id" => event_id}
        }
      }
    })
  end

  test "meeting task crash fails the active real WebSocket request and advances the next one",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "meeting-crash", token)
    previous_handler = Application.get_env(:salix_web, :connector_meeting_runtime_handler)
    previous_test_pid = Application.get_env(:salix_web, :connector_meeting_runtime_test_pid)

    Application.put_env(
      :salix_web,
      :connector_meeting_runtime_handler,
      __MODULE__.BlockingMeetingRuntime
    )

    Application.put_env(:salix_web, :connector_meeting_runtime_test_pid, self())

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_meeting_runtime_handler, previous_handler)
      restore_app_env(:salix_web, :connector_meeting_runtime_test_pid, previous_test_pid)
    end)

    Enum.each(1..2, fn sequence ->
      send(pid, {
        :send_frame,
        %{
          "id" => "meeting-e2e-#{sequence}",
          "type" => "request",
          "method" => "meeting_runtime_event",
          "params" => %{"sequence" => sequence}
        }
      })
    end)

    assert_receive {:meeting_handler_started, 1, first_worker}, 1_000
    refute_receive {:meeting_handler_started, 2, _worker}, 100
    Process.exit(first_worker, :kill)

    assert_receive {:connector_frame,
                    %{
                      "id" => "meeting-e2e-1",
                      "type" => "error",
                      "error" => first_error
                    }},
                   1_000

    assert first_error =~ "server request task exited"
    assert_receive {:meeting_handler_started, 2, second_worker}, 1_000
    send(second_worker, :release)

    assert_receive {:connector_frame, %{"id" => "meeting-e2e-2", "type" => "response"}},
                   1_000
  end

  test "completed and abandoned real WebSocket read streams release FrameStream processes",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {_pid, env_id} = connect(group_id, "frame-lifecycle", token)
    environment_id = command_environment_id!(env_id)
    baseline = frame_stream_process_count()

    Enum.each(1..20, fn index ->
      assert {:ok, stream, nil} =
               EnvDispatch.read_stream(
                 agent_id,
                 %{device_id: device_id, environment_id: environment_id},
                 "/completed-#{index}"
               )

      assert stream |> Enum.to_list() |> IO.iodata_to_binary() ==
               "stream@/completed-#{index}"
    end)

    assert eventually(fn -> frame_stream_process_count() == baseline end)

    previous_timeout =
      Application.get_env(:salix_web, :connector_read_stream_idle_timeout_ms)

    Application.put_env(:salix_web, :connector_read_stream_idle_timeout_ms, 30)

    on_exit(fn ->
      restore_app_env(
        :salix_web,
        :connector_read_stream_idle_timeout_ms,
        previous_timeout
      )
    end)

    Enum.each(1..5, fn _index ->
      assert {:ok, _abandoned, nil} =
               EnvDispatch.read_stream(
                 agent_id,
                 %{device_id: device_id, environment_id: environment_id},
                 "/blocked-stream"
               )
    end)

    assert eventually(fn -> frame_stream_process_count() == baseline end)

    assert {:ok, %{"content" => "file@/after-abandoned-streams"}} =
             EnvDispatch.request(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "read",
               %{
                 "path" => "/after-abandoned-streams"
               }
             )
  end

  test "a paused disconnect queue cannot block real WebSocket teardown",
       %{group_id: group_id, connector_token: token} do
    assert_disconnect_queue_idle!()
    {pid, env_id} = connect(group_id, "disconnect-paused", token)
    environment = environment_for_run!(env_id)
    queue = Process.whereis(ConnectorDisconnectQueue)
    :sys.suspend(queue)

    on_exit(fn ->
      if Process.alive?(queue) do
        try do
          :sys.resume(queue)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    Process.flag(:trap_exit, true)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 250

    assert {:ok, %{"status" => "connected"}} =
             SalixEnv.Control.get_environment(
               environment["device_id"],
               group_id,
               tenant_id()
             )

    :sys.resume(queue)

    assert eventually(
             fn ->
               match?(
                 {:ok, %{"status" => "disconnected"}},
                 SalixEnv.Control.get_environment(
                   environment["device_id"],
                   group_id,
                   tenant_id()
                 )
               )
             end,
             250
           )
  end

  test "disconnect persistence failure retries after a real WebSocket closes",
       %{group_id: group_id, connector_token: token} do
    assert_disconnect_queue_idle!()
    {pid, env_id} = connect(group_id, "disconnect-retry", token)
    environment = environment_for_run!(env_id)
    test_pid = self()
    previous_executor = Application.get_env(:salix_web, :connector_disconnect_executor)
    previous_retry = Application.get_env(:salix_web, :connector_disconnect_retry_ms)
    Application.put_env(:salix_web, :connector_disconnect_retry_ms, 20)

    attempts =
      start_supervised!({Agent, fn -> 0 end}, id: make_ref(), restart: :temporary)

    Application.put_env(:salix_web, :connector_disconnect_executor, fn operation ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      send(test_pid, {:disconnect_attempt, attempt})

      if attempt == 1 do
        {:error, :temporary_storage_failure}
      else
        SalixEnv.Registry.mark_disconnected(operation.connector_run_id,
          connection_generation: operation.generation,
          owner_node: operation.owner_node
        )
      end
    end)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_disconnect_executor, previous_executor)
      restore_app_env(:salix_web, :connector_disconnect_retry_ms, previous_retry)
    end)

    Process.flag(:trap_exit, true)
    Process.exit(pid, :kill)

    assert_receive {:disconnect_attempt, 1}, 1_000
    assert_receive {:disconnect_attempt, 2}, 1_000

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(
                 environment["device_id"],
                 group_id,
                 tenant_id()
               )
             )
           end)
  end

  test "disconnect queue crash kills active storage work and resubmits it after restart",
       %{group_id: group_id, connector_token: token} do
    assert_disconnect_queue_idle!()
    {pid, env_id} = connect(group_id, "disconnect-queue-crash", token)
    environment = environment_for_run!(env_id)
    test_pid = self()
    previous_executor = Application.get_env(:salix_web, :connector_disconnect_executor)

    attempts =
      start_supervised!({Agent, fn -> 0 end}, id: make_ref(), restart: :temporary)

    Application.put_env(:salix_web, :connector_disconnect_executor, fn operation ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      send(test_pid, {:blocking_disconnect_executor, attempt, self()})

      if attempt == 1 do
        receive do
          :release_disconnect_executor -> :ok
        end
      else
        SalixEnv.Registry.mark_disconnected(operation.connector_run_id,
          connection_generation: operation.generation,
          owner_node: operation.owner_node
        )
      end
    end)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_disconnect_executor, previous_executor)
    end)

    Process.exit(pid, :kill)
    assert_receive {:blocking_disconnect_executor, 1, executor}, 1_000
    executor_monitor = Process.monitor(executor)
    queue = Process.whereis(ConnectorDisconnectQueue)
    queue_monitor = Process.monitor(queue)
    Process.exit(queue, :kill)

    assert_receive {:DOWN, ^queue_monitor, :process, ^queue, :killed}, 500
    assert_receive {:DOWN, ^executor_monitor, :process, ^executor, _reason}, 500
    assert eventually(fn -> Process.whereis(ConnectorDisconnectQueue) not in [nil, queue] end)

    assert_receive {:blocking_disconnect_executor, 2, _executor}, 5_000

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(
                 environment["device_id"],
                 group_id,
                 tenant_id()
               )
             )
           end)
  end

  test "disconnect result waiting in its wrapper is resubmitted when the queue crashes",
       %{group_id: group_id, connector_token: token} do
    assert_disconnect_queue_idle!()
    {pid, env_id} = connect(group_id, "disconnect-result-queue-crash", token)
    environment = environment_for_run!(env_id)
    test_pid = self()
    previous_executor = Application.get_env(:salix_web, :connector_disconnect_executor)
    previous_retry = Application.get_env(:salix_web, :connector_disconnect_retry_ms)
    Application.put_env(:salix_web, :connector_disconnect_retry_ms, 20)

    attempts =
      start_supervised!({Agent, fn -> 0 end}, id: make_ref(), restart: :temporary)

    Application.put_env(:salix_web, :connector_disconnect_executor, fn operation ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      send(test_pid, {:result_race_disconnect_attempt, attempt, self()})

      if attempt == 1 do
        receive do
          :return_temporary_disconnect_failure -> {:error, :temporary_storage_failure}
        end
      else
        SalixEnv.Registry.mark_disconnected(operation.connector_run_id,
          connection_generation: operation.generation,
          owner_node: operation.owner_node
        )
      end
    end)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_disconnect_executor, previous_executor)
      restore_app_env(:salix_web, :connector_disconnect_retry_ms, previous_retry)
    end)

    Process.exit(pid, :kill)
    assert_receive {:result_race_disconnect_attempt, 1, executor}, 1_000
    queue = Process.whereis(ConnectorDisconnectQueue)
    admission_key = {ConnectorDisconnectQueue, :admission}
    assert {^queue, old_counter} = :persistent_term.get(admission_key)

    queue_state = :sys.get_state(queue)

    {_ref, active} =
      Enum.find(queue_state.active, fn {_ref, active} ->
        active.operation.connector_run_id == env_id
      end)

    wrapper = active.pid
    :erlang.suspend_process(wrapper)

    assert :erlang.trace_pattern(
             {ConnectorDisconnectQueue, :resubmit_after_restart, 3},
             true,
             [:local]
           ) == 1

    assert :erlang.trace(wrapper, true, [:call]) == 1

    on_exit(fn ->
      :erlang.trace_pattern(
        {ConnectorDisconnectQueue, :resubmit_after_restart, 3},
        false,
        [:local]
      )

      if Process.alive?(wrapper) do
        :erlang.trace(wrapper, false, [:call])

        try do
          :erlang.resume_process(wrapper)
        catch
          :error, _ -> :ok
        end
      end
    end)

    executor_monitor = Process.monitor(executor)
    send(executor, :return_temporary_disconnect_failure)
    assert_receive {:DOWN, ^executor_monitor, :process, ^executor, :normal}, 500

    assert eventually(fn ->
             Process.info(wrapper, :message_queue_len) == {:message_queue_len, 1}
           end)

    queue_monitor = Process.monitor(queue)
    Process.exit(queue, :kill)
    assert_receive {:DOWN, ^queue_monitor, :process, ^queue, :killed}, 500

    assert eventually(fn -> Process.whereis(ConnectorDisconnectQueue) not in [nil, queue] end)
    replacement_queue = Process.whereis(ConnectorDisconnectQueue)

    assert eventually(fn ->
             match?(
               {^replacement_queue, _counter},
               :persistent_term.get(admission_key, nil)
             )
           end)

    assert {^replacement_queue, replacement_counter} =
             :persistent_term.get(admission_key)

    on_exit(fn ->
      if Process.whereis(ConnectorDisconnectQueue) == replacement_queue do
        :persistent_term.put(admission_key, {replacement_queue, replacement_counter})
      end
    end)

    # A :kill bypasses terminate/2, so the dead generation's authority can
    # remain visible after the supervisor has registered its replacement but
    # before init/1 publishes the replacement authority. Recreate that exact
    # valid interleaving without relying on scheduler timing.
    :persistent_term.put(admission_key, {queue, old_counter})
    assert Process.whereis(ConnectorDisconnectQueue) == replacement_queue
    assert {^queue, ^old_counter} = :persistent_term.get(admission_key)

    wrapper_monitor = Process.monitor(wrapper)
    :erlang.resume_process(wrapper)

    assert_receive {:trace, ^wrapper, :call,
                    {ConnectorDisconnectQueue, :resubmit_after_restart, [^queue, _operation, 100]}},
                   1_000

    receive do
      {:trace, ^wrapper, :call,
       {ConnectorDisconnectQueue, :resubmit_after_restart, [^queue, _operation, 99]}} ->
        :ok

      {:DOWN, ^wrapper_monitor, :process, ^wrapper, reason} ->
        flunk("disconnect recovery exited against stale admission authority: #{inspect(reason)}")
    after
      1_000 ->
        flunk("disconnect recovery did not retry stale admission authority")
    end

    :persistent_term.put(admission_key, {replacement_queue, replacement_counter})

    assert eventually(fn ->
             case :persistent_term.get(admission_key, nil) do
               {^replacement_queue, _counter} -> true
               _other -> false
             end
           end)

    assert_receive {:result_race_disconnect_attempt, 2, _executor}, 5_000

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               SalixEnv.Control.get_environment(
                 environment["device_id"],
                 group_id,
                 tenant_id()
               )
             )
           end)
  end

  test "disconnect ingress remains bounded while the queue is suspended",
       %{group_id: group_id} do
    assert_disconnect_queue_idle!()
    previous_limit = Application.get_env(:salix_web, :connector_disconnect_queue_limit)
    Application.put_env(:salix_web, :connector_disconnect_queue_limit, 4)
    queue = Process.whereis(ConnectorDisconnectQueue)
    :sys.suspend(queue)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_disconnect_queue_limit, previous_limit)

      if Process.alive?(queue) do
        try do
          :sys.resume(queue)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    Enum.each(1..12, fn index ->
      {:ok, token} =
        SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
          "name" => "bounded-disconnect-#{index}",
          "alias" => "bounded-disconnect-#{index}"
        })

      {:ok, connector} =
        FakeConnector.start_query(
          ws_base(),
          %{"name" => "bounded-disconnect-#{index}", "os" => "linux"},
          token["token"],
          self()
        )

      assert_receive {:connected, env_id}, 1_000
      disconnect_connector!(connector, env_id)
    end)

    assert {:message_queue_len, queued} = Process.info(queue, :message_queue_len)
    assert queued <= 4
    :sys.resume(queue)
    assert_disconnect_queue_idle!()
  end

  test "disconnect capacity bounds active work plus suspended ingress",
       %{group_id: group_id} do
    assert_disconnect_queue_idle!()
    previous_limit = Application.get_env(:salix_web, :connector_disconnect_queue_limit)
    previous_executor = Application.get_env(:salix_web, :connector_disconnect_executor)
    Application.put_env(:salix_web, :connector_disconnect_queue_limit, 4)
    test_pid = self()

    Application.put_env(:salix_web, :connector_disconnect_executor, fn operation ->
      send(test_pid, {:capacity_disconnect_started, operation.connector_run_id, self()})
      owner = Process.monitor(test_pid)

      receive do
        :release_capacity_disconnect -> :ok
        {:DOWN, ^owner, :process, ^test_pid, _reason} -> :ok
      end
    end)

    queue = Process.whereis(ConnectorDisconnectQueue)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_disconnect_queue_limit, previous_limit)
      restore_app_env(:salix_web, :connector_disconnect_executor, previous_executor)
    end)

    disconnect = fn index ->
      {:ok, token} =
        SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
          "name" => "total-disconnect-capacity-#{index}",
          "alias" => "total-disconnect-capacity-#{index}"
        })

      {:ok, connector} =
        FakeConnector.start_query(
          ws_base(),
          %{"name" => "total-disconnect-capacity-#{index}", "os" => "linux"},
          token["token"],
          self()
        )

      assert_receive {:connected, env_id}, 1_000
      disconnect_connector!(connector, env_id)
      env_id
    end

    expected_env_ids = MapSet.new(Enum.map(1..4, disconnect))
    capacity_executors = capacity_disconnects_started(expected_env_ids, 5_000)
    assert capacity_executors |> Map.keys() |> MapSet.new() == expected_env_ids

    on_exit(fn ->
      release_capacity_disconnects!(queue, Map.values(capacity_executors))
    end)

    active = :sys.get_state(queue).active
    assert map_size(active) == 4
    :sys.suspend(queue)

    Enum.each(5..8, fn index ->
      ConnectorDisconnectQueue.submit(
        "overflow-disconnect-#{index}",
        index,
        node()
      )
    end)

    assert {:messages, messages} = Process.info(queue, :messages)

    queued_disconnects =
      Enum.count(messages, fn
        {:disconnect, %{connector_run_id: _run_id}} -> true
        _message -> false
      end)

    assert map_size(active) + queued_disconnects <= 4
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

    assert_receive {:liveness_telemetry, [:salix, :connector, :read_stream], %{},
                    %{outcome: :accepted, transport: :websocket}}

    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "stream@/tmp/to-vfs.bin"

    assert_receive {:liveness_telemetry, [:salix, :connector, :read_stream], %{},
                    %{outcome: :completed, transport: :websocket}}

    assert_receive {:read_stream_request, "/tmp/to-vfs.bin", false}
  end

  test "read streams enforce a finite socket cap and exact wire-id fence",
       %{group_id: group_id, connector_token: token} do
    previous_limit = Application.get_env(:salix_web, :connector_socket_read_stream_limit)
    previous_idle = Application.get_env(:salix_web, :connector_read_stream_idle_timeout_ms)

    Application.put_env(:salix_web, :connector_socket_read_stream_limit, 1)
    Application.put_env(:salix_web, :connector_read_stream_idle_timeout_ms, 5_000)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_socket_read_stream_limit, previous_limit)
      restore_app_env(:salix_web, :connector_read_stream_idle_timeout_ms, previous_idle)
    end)

    {_pid, connector_run_id} = connect(group_id, "read-cap", token)

    held =
      "read_stream"
      |> SalixEnv.Protocol.request(%{"path" => "/blocked-stream"})
      |> Map.put("id", "held-read-stream")

    assert {:ok, stream, nil} =
             SalixEnv.Connector.Live.read_stream(connector_run_id, held, 500)

    assert_receive {:read_stream_request, "/blocked-stream", false}, 300

    duplicate = put_in(held, ["params", "path"], "/duplicate-not-pushed")

    assert {:error, :connector_read_stream_id_conflict} =
             SalixEnv.Connector.Live.read_stream(connector_run_id, duplicate, 500)

    overflow =
      "read_stream"
      |> SalixEnv.Protocol.request(%{"path" => "/overflow-not-pushed"})
      |> Map.put("id", "overflow-read-stream")

    assert {:error, :connector_read_stream_capacity_exhausted} =
             SalixEnv.Connector.Live.read_stream(connector_run_id, overflow, 500)

    refute_receive {:read_stream_request, "/duplicate-not-pushed", false}, 0
    refute_receive {:read_stream_request, "/overflow-not-pushed", false}, 0

    assert "x" = Enum.at(stream, 0)
  end

  test "stale read cancel and absolute timeout cannot retire a replacement" do
    id = "reused-read-stream-id"
    first_ref = make_ref()
    first_message = rpc_frame(id, "read_stream", %{"path" => "/first"})

    assert {:push, {:text, _encoded}, first_state} =
             SalixWeb.ConnectorSocket.handle_info(
               {:env_read_stream, first_ref, self(), first_message},
               %SalixWeb.ConnectorSocket.State{}
             )

    assert_receive {:env_read_stream_reply, ^first_ref, {:ok, _first_stream, nil}}

    assert {:ok, completed_state} =
             SalixWeb.ConnectorSocket.handle_in(
               {Jason.encode!(%{"id" => id, "type" => "error", "error" => "first done"}),
                [opcode: :text]},
               first_state
             )

    second_ref = make_ref()
    second_message = rpc_frame(id, "read_stream", %{"path" => "/second"})

    assert {:push, {:text, _encoded}, second_state} =
             SalixWeb.ConnectorSocket.handle_info(
               {:env_read_stream, second_ref, self(), second_message},
               completed_state
             )

    assert_receive {:env_read_stream_reply, ^second_ref, {:ok, _second_stream, nil}}

    assert {:ok, after_stale_cancel} =
             SalixWeb.ConnectorSocket.handle_info(
               {:env_read_stream_cancel, first_ref, self()},
               second_state
             )

    assert %{^id => %{ref: ^second_ref, absolute_token: token}} =
             after_stale_cancel.read_streams

    assert {:ok, timed_out_state} =
             SalixWeb.ConnectorSocket.handle_info(
               {:connector_read_stream_absolute_timeout, id, second_ref, token},
               after_stale_cancel
             )

    assert timed_out_state.read_streams == %{}
    assert Map.has_key?(timed_out_state.read_stream_cancellations, id)
  end

  test "read_ref clamps its socket absolute timer to the 60-second protocol lease" do
    previous = Application.get_env(:salix_web, :connector_read_stream_absolute_timeout_ms)
    Application.put_env(:salix_web, :connector_read_stream_absolute_timeout_ms, 300_000)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_read_stream_absolute_timeout_ms, previous)
    end)

    id = "leased-read-ref"
    ref = make_ref()
    message = rpc_frame(id, "read_ref", %{"stream_lease_ms" => 60_000})

    assert {:push, {:text, _encoded}, state} =
             SalixWeb.ConnectorSocket.handle_info(
               {:env_read_stream, ref, self(), message},
               %SalixWeb.ConnectorSocket.State{}
             )

    assert_receive {:env_read_stream_reply, ^ref, {:ok, _stream, nil}}
    assert %{^id => %{absolute_timer: timer}} = state.read_streams
    remaining = Process.read_timer(timer)
    assert is_integer(remaining)
    assert remaining <= 60_000
    assert remaining > 55_000

    assert {:ok, _state} =
             SalixWeb.ConnectorSocket.handle_in(
               {Jason.encode!(%{"id" => id, "type" => "error", "error" => "done"}),
                [opcode: :text]},
               state
             )
  end

  test "read stream caller exit releases the exact admission",
       %{group_id: group_id, connector_token: token} do
    previous_limit = Application.get_env(:salix_web, :connector_socket_read_stream_limit)
    previous_idle = Application.get_env(:salix_web, :connector_read_stream_idle_timeout_ms)

    Application.put_env(:salix_web, :connector_socket_read_stream_limit, 1)
    Application.put_env(:salix_web, :connector_read_stream_idle_timeout_ms, 5_000)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_socket_read_stream_limit, previous_limit)
      restore_app_env(:salix_web, :connector_read_stream_idle_timeout_ms, previous_idle)
    end)

    {_pid, connector_run_id} = connect(group_id, "read-owner", token)
    parent = self()

    caller =
      spawn(fn ->
        message =
          "read_stream"
          |> SalixEnv.Protocol.request(%{"path" => "/blocked-stream"})
          |> Map.put("id", "owned-read-stream")

        send(
          parent,
          {:owned_read_result,
           SalixEnv.Connector.Live.read_stream(connector_run_id, message, 500)}
        )

        receive do
          :finish_owned_read -> :ok
        end
      end)

    assert_receive {:owned_read_result, {:ok, _stream, nil}}, 500
    assert_receive {:read_stream_request, "/blocked-stream", false}, 300

    monitor = Process.monitor(caller)
    send(caller, :finish_owned_read)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 300

    replacement =
      "read_stream"
      |> SalixEnv.Protocol.request(%{"path" => "/after-owner-down"})
      |> Map.put("id", "replacement-read-stream")

    assert eventually(fn ->
             match?(
               {:ok, _stream, nil},
               SalixEnv.Connector.Live.read_stream(connector_run_id, replacement, 500)
             )
           end)

    assert_receive {:read_stream_request, "/after-owner-down", false}, 300
  end

  test "a backpressured read stream does not block unrelated socket traffic",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    {_pid, env_id} = connect(group_id, "laptop", token)
    environment_id = command_environment_id!(env_id)

    assert {:ok, _unconsumed_stream, nil} =
             EnvDispatch.read_stream(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "/blocked-stream"
             )

    assert_receive {:read_stream_backpressured, _stream_id}, 1_000
    refute_receive {:read_stream_unexpected_ack, 65}, 30

    quick =
      Task.async(fn ->
        EnvDispatch.request(
          agent_id,
          %{device_id: device_id, environment_id: environment_id},
          "read",
          %{"path" => "/still-live"}
        )
      end)

    assert_receive {:read_request, _label, "/still-live"}, 300
    assert {:ok, %{"content" => "file@/still-live"}} = Task.await(quick, 1_000)
  end

  test "an abandoned read stream times out and releases the stream lane",
       %{group_id: group_id, agent_id: agent_id, connector_token: token} do
    device_id = Process.get(:test_device_id)
    previous_socket_limit = Application.get_env(:salix_web, :connector_socket_stream_task_limit)

    previous_idle_timeout =
      Application.get_env(:salix_web, :connector_read_stream_idle_timeout_ms)

    Application.put_env(:salix_web, :connector_socket_stream_task_limit, 1)
    Application.put_env(:salix_web, :connector_read_stream_idle_timeout_ms, 50)

    on_exit(fn ->
      restore_app_env(:salix_web, :connector_socket_stream_task_limit, previous_socket_limit)

      restore_app_env(
        :salix_web,
        :connector_read_stream_idle_timeout_ms,
        previous_idle_timeout
      )
    end)

    {_pid, env_id} = connect(group_id, "laptop", token)
    environment_id = command_environment_id!(env_id)

    assert {:ok, _unconsumed_stream, nil} =
             EnvDispatch.read_stream(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "/blocked-stream"
             )

    assert_receive {:read_stream_backpressured, _stream_id}, 1_000
    assert_receive {:read_stream_error_ack, _stream_id, 65, error}, 1_000
    # Both the FrameStream and socket lane own the same idle deadline. If
    # FrameStream expires before frame 65 reaches the socket, the cancellation
    # tombstone reports consumer-closed; an in-flight frame reports timeout.
    # Both must reject frame 65 and release the lane without a success ACK.
    assert error =~ "stream_idle_timeout" or error == "server stream consumer closed"
    refute_receive {:read_stream_unexpected_ack, 65}, 30

    assert {:ok, stream, nil} =
             EnvDispatch.read_stream(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "/after-timeout"
             )

    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "stream@/after-timeout"
  end

  test "cloud-vm read_stream keeps the VM operation active until bytes are consumed",
       %{group_id: group_id, agent_id: agent_id} do
    {_pid, run_id, cloud_token} = connect_cloud_vm!(group_id, agent_id)
    environment_id = command_environment_id!(run_id)
    device_id = cloud_token["device_id"]

    assert {:ok, stream, nil} =
             EnvDispatch.read_stream(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "/tmp/slow.bin"
             )

    assert {:ok, %{"active_operation_count" => 1}} =
             SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "stream@/tmp/slow.bin"

    assert eventually(fn ->
             case SalixWeb.ComputeProviders.Cloudflare.get_record(group_id) do
               {:ok, %{"active_operation_count" => 0}} -> true
               _ -> false
             end
           end)

    assert_receive {:read_stream_request, "/tmp/slow.bin", false}
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

  test "cloud-vm admission storage errors are not collapsed into no_environment",
       %{group_id: group_id, agent_id: agent_id} do
    {_pid, run_id, cloud_token} = connect_cloud_vm!(group_id, agent_id)
    environment_id = command_environment_id!(run_id)
    device_id = cloud_token["device_id"]
    {:ok, %{"workload_id" => workload}} = GroupCompute.group_workload(group_id)
    constraint = "reject_activity_#{System.unique_integer([:positive])}"
    escaped = String.replace(workload, "'", "''")

    SalixStore.Repo.query!(
      "ALTER TABLE compute_workloads ADD CONSTRAINT " <>
        constraint <>
        " CHECK (id <> '" <>
        escaped <>
        "' OR COALESCE(spec->'activity'->'active_operations', '{}'::jsonb) = '{}'::jsonb) NOT VALID"
    )

    on_exit(fn ->
      SalixStore.Repo.query!(
        "ALTER TABLE compute_workloads DROP CONSTRAINT IF EXISTS " <> constraint
      )
    end)

    assert {:error, :compute_storage_unavailable} =
             EnvDispatch.read_stream(
               agent_id,
               %{device_id: device_id, environment_id: environment_id},
               "/tmp/not-started.bin"
             )

    refute_receive {:read_stream_request, "/tmp/not-started.bin", false}
  end

  test "meeting_runtime_event streams an opaque artifact back from the origin connector without self-deadlocking",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "laptop", token)

    prev_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
    Application.put_env(:salix_meet, :agent_runtime_mod, __MODULE__.MeetingReadStreamProbe)

    on_exit(fn ->
      if prev_runtime,
        do: Application.put_env(:salix_meet, :agent_runtime_mod, prev_runtime),
        else: Application.delete_env(:salix_meet, :agent_runtime_mod)
    end)

    meeting_id = "mtg-#{System.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      SalixMeet.Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "runtime_token" => "rt-secret",
          "status" => "active"
        }
      )

    source_ref = "mart_test_opaque"

    send(
      pid,
      {:send_frame,
       %{
         "id" => "meeting-evt-1",
         "type" => "request",
         "method" => "meeting_runtime_event",
         "params" => %{
           "event" => %{
             "type" => "meeting_runtime_update",
             "meeting_id" => meeting_id,
             "runtime_token" => "rt-secret",
             "status" => "done",
             "artifacts" => [
               %{
                 "kind" => "audio",
                 "filename" => "audio.ogg",
                 "source_ref" => source_ref,
                 "source_size" => byte_size("meeting-artifact@" <> source_ref)
               }
             ]
           }
         }
       }}
    )

    assert eventually(fn ->
             {:ok, doc, _} = SalixMeet.Store.get(meeting_id)
             get_in(doc, ["state", "artifacts", "audio"]) != nil
           end)

    assert_receive {:connector_frame, %{"id" => "meeting-evt-1", "type" => "response"}}, 3_000

    expected_size = byte_size("meeting-artifact@" <> source_ref)
    max_size = 30 * 1024 * 1024

    assert_receive {:meeting_artifact_read_request, ^meeting_id, ^source_ref, ^expected_size,
                    ^max_size, false},
                   3_000
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

    previous_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
    previous_provider = Application.get_env(:salix_meet, :provider_mod)
    previous_handler = Application.get_env(:salix_web, :connector_meeting_runtime_handler)
    previous_feishu_delivery = Application.get_env(:salix_im, :feishu_direct_delivery_mod)
    previous_contract = Application.get_env(:salix_env, :meeting_artifact_timeout_contract)
    previous_protocol_timeouts = Application.get_env(:salix_env, :protocol_timeouts)

    previous_parent_floor =
      Application.get_env(:salix_web, :connector_meeting_event_task_timeout_ms)

    Application.put_env(:salix_meet, :agent_runtime_mod, Salix.Bindings.MeetingAgentRuntime)
    Application.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)

    Application.put_env(
      :salix_web,
      :connector_meeting_runtime_handler,
      __MODULE__.CommitThenDelayMeetingRuntime
    )

    Application.put_env(:salix_env, :protocol_timeouts, %{"meeting_artifact_read" => 200})

    Application.put_env(:salix_env, :meeting_artifact_timeout_contract, %{
      setup_ms: 50,
      frame_ms: 10,
      request_slop_ms: 300,
      finalize_ms: 100,
      server_slop_ms: 100
    })

    Application.put_env(:salix_web, :connector_meeting_event_task_timeout_ms, 100)
    start_supervised!(RecordingFeishuDelivery)
    Application.put_env(:salix_im, :feishu_direct_delivery_mod, RecordingFeishuDelivery)

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
    meeting_id = "mtg-deadline-nesting-#{System.unique_integer([:positive])}"
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
      "created_at" => System.system_time(:second),
      "updated_at" => System.system_time(:second)
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

    send(pid, {
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

    assert_receive {:meeting_artifact_read_request, ^meeting_id, ^transcript_ref,
                    ^transcript_size, _max, false},
                   1_000

    assert_receive {:meeting_artifact_read_request, ^meeting_id, ^audio_ref, ^audio_size, _max,
                    false},
                   1_000

    assert_receive {:connector_frame,
                    %{
                      "id" => "meeting-deadline-first",
                      "type" => "response",
                      "result" => %{"status" => "created"}
                    }},
                   2_000

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

    send(pid, {
      :send_frame,
      %{
        "id" => "meeting-deadline-replay",
        "type" => "request",
        "method" => "meeting_runtime_event",
        "params" => params
      }
    })

    assert_receive {:connector_frame,
                    %{
                      "id" => "meeting-deadline-replay",
                      "type" => "response",
                      "result" => %{"status" => "duplicate"}
                    }},
                   1_000

    refute_receive {:meeting_artifact_read_request, ^meeting_id, _, _, _, _}, 100

    assert length(RecordingFeishuDelivery.records()) == delivery_count
  end

  test "meeting_runtime_event rejects connector bytes beyond the authenticated declared size",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "meeting-size-guard", token)

    prev_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
    Application.put_env(:salix_meet, :agent_runtime_mod, Salix.Bindings.MeetingAgentRuntime)

    on_exit(fn ->
      if prev_runtime,
        do: Application.put_env(:salix_meet, :agent_runtime_mod, prev_runtime),
        else: Application.delete_env(:salix_meet, :agent_runtime_mod)
    end)

    meeting_id = "mtg-size-guard-#{System.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      SalixMeet.Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "runtime_token" => "rt-secret",
          "status" => "active"
        }
      )

    source_ref = "mart_size_lie"

    send(
      pid,
      {:send_frame,
       %{
         "id" => "meeting-size-lie",
         "type" => "request",
         "method" => "meeting_runtime_event",
         "params" => %{
           "event" => %{
             "type" => "meeting_runtime_update",
             "event_id" => "meeting-size-lie",
             "meeting_id" => meeting_id,
             "runtime_token" => "rt-secret",
             "status" => "done",
             "artifacts" => [
               %{
                 "kind" => "audio",
                 "filename" => "audio.ogg",
                 "source_ref" => source_ref,
                 "source_size" => 1
               }
             ]
           }
         }
       }}
    )

    assert_receive {:connector_frame,
                    %{"id" => "meeting-size-lie", "type" => "error", "error" => error}},
                   3_000

    assert error =~ "artifact_ingest_failed"

    assert_receive {:meeting_artifact_read_request, ^meeting_id, ^source_ref, 1, _max_size,
                    false},
                   3_000

    assert {:ok, doc, _} = SalixMeet.Store.get(meeting_id)
    assert doc["state"]["status"] == "active"
    refute Map.has_key?(doc["state"], "artifacts")
  end

  test "malformed and oversized artifact envelopes fail without taking down the connector socket",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "meeting-envelope-guard", token)
    meeting_id = "mtg-envelope-guard-#{System.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      SalixMeet.Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "runtime_token" => "rt-secret",
          "status" => "active"
        }
      )

    for {id, artifacts} <- [
          {"malformed-artifact", ["not-an-object"]},
          {"oversized-artifact",
           [
             %{
               "kind" => "audio",
               "source_ref" => "mart_untrusted",
               "source_size" => Integer.pow(2, 200)
             }
           ]}
        ] do
      send(
        pid,
        {:send_frame,
         %{
           "id" => id,
           "type" => "request",
           "method" => "meeting_runtime_event",
           "params" => %{
             "event" => %{
               "type" => "meeting_runtime_update",
               "event_id" => id,
               "meeting_id" => meeting_id,
               "runtime_token" => "rt-secret",
               "status" => "done",
               "artifacts" => artifacts
             }
           }
         }}
      )

      assert_receive {:connector_frame, %{"id" => ^id, "type" => "error"}}, 3_000
    end

    for {id, params} <- [
          {"malformed-params", "not-an-object"},
          {"malformed-event", %{"event" => "not-an-object"}},
          {"malformed-artifacts-container", %{"event" => %{"artifacts" => "not-a-list"}}}
        ] do
      send(
        pid,
        {:send_frame,
         %{
           "id" => id,
           "type" => "request",
           "method" => "meeting_runtime_event",
           "params" => params
         }}
      )

      assert_receive {:connector_frame, %{"id" => ^id, "type" => "error"}}, 3_000
    end

    send(
      pid,
      {:send_frame,
       %{
         "id" => "socket-still-alive",
         "type" => "request",
         "method" => "meeting_runtime_capabilities",
         "params" => %{"artifact_transport" => "opaque-v1"}
       }}
    )

    assert_receive {:connector_frame, %{"id" => "socket-still-alive", "type" => "response"}},
                   1_000
  end

  test "connector can negotiate opaque meeting artifact transport before stripping local paths",
       %{group_id: group_id, connector_token: token} do
    {pid, _env_id} = connect(group_id, "meeting-capabilities", token)

    send(
      pid,
      {:send_frame,
       %{
         "id" => "meeting-capabilities-1",
         "type" => "request",
         "method" => "meeting_runtime_capabilities",
         "params" => %{"artifact_transport" => "opaque-v1"}
       }}
    )

    assert_receive {:connector_frame,
                    %{
                      "id" => "meeting-capabilities-1",
                      "type" => "response",
                      "result" => %{"artifact_transport_versions" => ["opaque-v1"]}
                    }},
                   1_000
  end

  test "runtime_proxy POST /llm/chat runs off the socket and returns a completion", %{
    group_id: group_id,
    connector_token: token
  } do
    {pid, env_id} = connect(group_id, "laptop", token)

    port = start_bandit_retry!(fn p -> {Bandit, plug: FakeLLM, port: p} end)

    prev_tmpl = Application.get_env(:comma_core, :default_agent_template)
    prev_skip = Application.get_env(:salix_web, :connector_llm_skip_metering)

    Application.put_env(:comma_core, :default_agent_template, %{
      "template_id" => "comma-default",
      "model" => "test-model",
      "max_tokens" => 2048,
      "provider_config" => %{
        "protocol" => "chat_completions",
        "base_url" => "http://127.0.0.1:#{port}",
        "api_key" => "test-key"
      }
    })

    Application.put_env(:salix_web, :connector_llm_skip_metering, true)

    on_exit(fn ->
      if prev_tmpl,
        do: Application.put_env(:comma_core, :default_agent_template, prev_tmpl),
        else: Application.delete_env(:comma_core, :default_agent_template)

      if is_nil(prev_skip),
        do: Application.delete_env(:salix_web, :connector_llm_skip_metering),
        else: Application.put_env(:salix_web, :connector_llm_skip_metering, prev_skip)
    end)

    agent = %{
      "tenant_id" => tenant_id(),
      "group_id" => group_id,
      "agent_id" => "meeting-agent-#{group_id}"
    }

    {:ok, cap} =
      ExternalRuntime.mint_llm_capability(agent, SalixStore.Ids.new_session_id(), env_id)

    body = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "summarize"}]})

    llm_frame = %{
      "id" => "llm-1",
      "type" => "request",
      "method" => "runtime_proxy",
      "params" => %{
        "capability_token" => cap["token"],
        "method" => "POST",
        "route_path" => "/llm/chat",
        "body_base64" => Base.encode64(body)
      }
    }

    quick_frame = %{
      "id" => "quick-1",
      "type" => "request",
      "method" => "runtime_proxy",
      "params" => %{"capability_token" => "bogus", "method" => "GET", "route_path" => "/tools"}
    }

    send(pid, {:send_frame, llm_frame})
    send(pid, {:send_frame, quick_frame})

    assert_receive {:connector_frame,
                    %{"id" => "quick-1", "type" => "response", "result" => quick}},
                   300

    assert quick["status"] == 401

    assert_receive {:connector_frame,
                    %{"id" => "llm-1", "type" => "response", "result" => result}},
                   5_000

    assert result["status"] == 200
    decoded = result["body_base64"] |> Base.decode64!() |> Jason.decode!()
    assert get_in(decoded, ["choices", Access.at(0), "message", "content"]) == "MOCK SUMMARY"
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
             Enum.filter(S3.Fake.read_log(self()), &match?({:list, _, _}, &1))

    :ok = S3.Fake.reset_read_log()
    device = Jason.decode!(Peers.get_device(%{"device_id" => device_id}, ctx))
    refute Enum.any?(S3.Fake.read_log(self()), &match?({:list, _, _}, &1))
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
    refute Enum.any?(S3.Fake.read_log(self()), &match?({:list, _, _}, &1))
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
        self()
      )

    track(pid)

    env_id =
      receive do
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

  test "group-scoped connector token metadata is persisted into env record",
       %{group_id: group_id} do
    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id(), %{
        "name" => "Provisioned Mac",
        "alias" => "prod-mac",
        "meta" => %{
          "provision_request_id" => "req_123",
          "provisioner_id" => "prov_123",
          "capabilities" => %{"execution_boundary" => "spoofed"},
          "unexpected" => "ignored"
        }
      })

    expected_tenant_id = tenant_id()

    assert {:ok, ^expected_tenant_id, token_record} =
             SalixEnv.ConnectorTokens.validate_connector_token(token["token"])

    assert token_record["meta"]["provision_request_id"] == "req_123"

    {:ok, pid} =
      FakeConnector.start_query(
        ws_base(),
        %{"os" => "linux"},
        token["token"],
        self()
      )

    track(pid)

    env_id =
      receive do
        {:connected, env_id} -> env_id
      after
        3000 -> flunk("connector never received the connected frame")
      end

    assert {:ok,
            %{
              "status" => "connected",
              "meta" => %{
                "group_id" => ^group_id,
                "alias" => "prod-mac",
                "name" => "Provisioned Mac",
                "provision_request_id" => "req_123",
                "provisioner_id" => "prov_123"
              }
            }} = environment_device_for_run(env_id)

    {:ok, record} = environment_device_for_run(env_id)
    refute Map.has_key?(record["meta"], "agent_id")
    refute Map.has_key?(record["meta"], "capabilities")
    refute Map.has_key?(record["meta"], "unexpected")
  end

  defp external_event_frame(id, params) do
    %{
      "id" => id,
      "type" => "request",
      "method" => "external_runtime_event",
      "params" => params
    }
  end

  defp rpc_frame(id, method, params) do
    %{"id" => id, "type" => "request", "method" => method, "params" => params}
  end

  defp attach_liveness_telemetry(events) do
    handler_id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_liveness_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_liveness_telemetry(event, measurements, metadata, pid) do
    send(pid, {:liveness_telemetry, event, measurements, metadata})
  end

  defp await_external_event_completion(worker) do
    # The handler notification precedes coordinator completion. The worker exits
    # after its completion ACK, so a later socket retry can observe the cache.
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 300
    assert reason in [:normal, :noproc]
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp disconnect_connector!(connector, connector_run_id) do
    [{socket, :connector}] = Registry.lookup(SalixEnv.Bridges, connector_run_id)
    client_monitor = Process.monitor(connector)
    socket_monitor = Process.monitor(socket)
    Process.exit(connector, :kill)
    assert_receive {:DOWN, ^client_monitor, :process, ^connector, _reason}, 1_000
    # The client DOWN alone says nothing about server teardown. Wait until
    # the socket has submitted its disconnect before inspecting/resuming the
    # queue or allowing the next test to replace its global executor.
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, _reason}, 1_000
  end

  defp assert_disconnect_queue_idle! do
    assert eventually(
             fn ->
               case Process.whereis(ConnectorDisconnectQueue) do
                 queue when is_pid(queue) ->
                   state = :sys.get_state(queue)

                   state.active == %{} and state.pending == %{} and state.retries == %{} and
                     :queue.is_empty(state.queue) and
                     Process.info(queue, :message_queue_len) == {:message_queue_len, 0}

                 _not_started ->
                   false
               end
             end,
             250
           ),
           "disconnect queue did not settle before the test changed its global executor"
  end

  defp capacity_disconnects_started(expected_env_ids, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    receive_capacity_disconnects(expected_env_ids, %{}, deadline)
  end

  defp release_capacity_disconnects!(queue, executors) do
    if Process.alive?(queue) do
      try do
        :sys.resume(queue)
      catch
        :exit, _ -> :ok
      end

      drained? =
        eventually(
          fn ->
            if Process.alive?(queue) do
              Enum.each(executors, &send(&1, :release_capacity_disconnect))

              state = :sys.get_state(queue)

              state.active == %{} and state.pending == %{} and
                state.retries == %{} and :queue.is_empty(state.queue) and
                Process.info(queue, :message_queue_len) == {:message_queue_len, 0}
            else
              true
            end
          end,
          250
        )

      unless drained? do
        state = :sys.get_state(queue)

        executor_statuses =
          Enum.map(executors, fn executor ->
            {executor, Process.alive?(executor), Process.info(executor, :current_function)}
          end)

        flunk(
          "disconnect queue did not drain after the capacity test: " <>
            "active=#{map_size(state.active)} pending=#{map_size(state.pending)} " <>
            "retries=#{map_size(state.retries)} queued=#{:queue.len(state.queue)} " <>
            "messages=#{inspect(Process.info(queue, :messages))} " <>
            "executors=#{inspect(executor_statuses)}"
        )
      end
    end
  end

  defp receive_capacity_disconnects(expected_env_ids, received, deadline) do
    if received |> Map.keys() |> MapSet.new() |> MapSet.equal?(expected_env_ids) do
      received
    else
      remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:capacity_disconnect_started, env_id, executor} ->
          receive_capacity_disconnects(
            expected_env_ids,
            if(MapSet.member?(expected_env_ids, env_id),
              do: Map.put(received, env_id, executor),
              else: received
            ),
            deadline
          )
      after
        remaining_ms ->
          flunk(
            "disconnect executors did not start for " <>
              inspect(MapSet.difference(expected_env_ids, received |> Map.keys() |> MapSet.new()))
          )
      end
    end
  end

  defp frame_stream_process_count do
    Enum.count(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          List.keyfind(dictionary, :"$initial_call", 0) ==
            {:"$initial_call", {SalixEnv.FrameStream, :init, 1}}

        _ ->
          false
      end
    end)
  end

  defp saturate_task_supervisor(supervisor, blockers \\ []) do
    case Task.Supervisor.start_child(supervisor, fn ->
           receive do
             :release_task -> :ok
           end
         end) do
      {:ok, pid} -> saturate_task_supervisor(supervisor, [pid | blockers])
      {:error, :max_children} -> blockers
    end
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

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

  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      p = 40_000 + :erlang.phash2(make_ref(), 20_000)

      case ExUnit.Callbacks.start_supervised(spec_fun.(p), id: {:bandit_retry, p}) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end
end
