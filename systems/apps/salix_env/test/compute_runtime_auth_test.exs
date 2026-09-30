defmodule SalixEnv.ComputeRuntimeAuthTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SalixEnv.ComputeRuntimeAuth
  alias SalixStore.{AgentVMM, Compute, Repo}

  defmodule Dispatcher do
    def call(runtime_instance_id, connection_epoch, request, timeout) do
      send(
        Application.fetch_env!(:salix_store, :compute_runtime_auth_test_pid),
        {:migration_timeout, timeout}
      )

      call(runtime_instance_id, connection_epoch, request)
    end

    def call(runtime_instance_id, connection_epoch, request) do
      pid = Application.fetch_env!(:salix_store, :compute_runtime_auth_test_pid)
      send(pid, {:compute_runtime_auth_request, runtime_instance_id, connection_epoch, request})

      case Application.get_env(:salix_store, :compute_runtime_auth_test_mode, :ready) do
        :stale_after_native_result ->
          SalixStore.Repo.update_all(
            SalixStore.Compute.RuntimeInstance,
            set: [connection_epoch: "10", caught_up_epoch: "10"]
          )

          {:ok, ready_result()}

        :stale_product_after_native_result ->
          current = Application.fetch_env!(:salix_env, :compute_runtime_auth_test_agent)

          Application.put_env(
            :salix_env,
            :compute_runtime_auth_test_agent,
            put_in(current, ["runtime_config", "binding_revision"], 2)
          )

          {:ok, ready_result()}

        :blocking_read ->
          send(pid, {:compute_runtime_auth_dispatch_blocked, self()})

          receive do
            :continue_compute_runtime_auth -> {:ok, ready_result()}
          end

        mode when mode in [:private, :private_wrong_actor, :private_stale_allocation] ->
          offer = private_offer(request)

          if mode == :private_stale_allocation,
            do:
              SalixStore.Repo.update_all(SalixStore.AgentVMM.Session,
                set: [allocation_generation: 2]
              )

          offer =
            if mode == :private_wrong_actor,
              do: put_in(offer, ["context", "actor_id"], "other"),
              else: offer

          {:ok, offer}

        :private_receipt ->
          {:ok, %{"save_result" => "committed", "issue" => ""}}

        mode when mode in [:claude_login, :claude_login_wrong_actor] ->
          offer = claude_login_offer(request)

          if mode == :claude_login_wrong_actor,
            do: {:ok, put_in(offer, ["context", "actor_id"], "other-admin")},
            else: {:ok, offer}

        :status ->
          {:ok,
           %{
             "provider" => request["params"]["target"]["provider"],
             "auth" => ready_result()["auth"],
             "native_ready" => true,
             "dispatch_ready" => true,
             "methods" => [],
             "attempt" => nil
           }}

        :quiet ->
          {:ok, %{"quiet" => true}}

        :quiet_stale ->
          SalixStore.Repo.update_all(
            SalixStore.Compute.RuntimeInstance,
            set: [connection_epoch: "10", caught_up_epoch: "10"]
          )

          {:ok, %{"quiet" => true}}

        :leaky ->
          {:ok, Map.put(ready_result(), "token", "must-not-cross")}

        :acquire_like_native_failure ->
          {:error,
           {:gateway_error,
            %{
              "code" => "lifecycle_conflict",
              "stage" => "execution_acquire",
              "resource" => "runtime",
              "message" => "Runtime operation was rejected."
            }}}

        :native_rejection ->
          {:error, :runtime_auth_failed}

        :ambiguous_timeout ->
          {:error, :runtime_auth_timeout}

        :ready ->
          {:ok, ready_result()}
      end
    end

    defp private_offer(request) do
      params = request["params"]

      context =
        params["target"]
        |> Map.merge(%{
          "target_kind" => "compute_workload",
          "device_id" => "",
          "runtime_id" => "",
          "generation" => Integer.to_string(params["target"]["generation"]),
          "backend" => params["backend"],
          "form" => params["form"],
          "method" => "credential_import",
          "attempt_id" => "attempt",
          "native_generation" => "native",
          "auth_epoch" => "1",
          "sequence" => 1,
          "schema_version" => 1,
          "expires_at" => System.system_time(:millisecond) + 900_000
        })

      %{
        "context" => context,
        "public_key" => Base.encode64(<<4, 0::512>>),
        "phase" => "awaiting_user",
        "save_result" => "not_committed"
      }
    end

    defp claude_login_offer(request) do
      params = request["params"]

      context =
        params["target"]
        |> Map.merge(%{
          "target_kind" => "compute_workload",
          "device_id" => "",
          "runtime_id" => "",
          "generation" => Integer.to_string(params["target"]["generation"]),
          "backend" => "anthropic",
          "method" => "native_login",
          "form" => "authorization_code",
          "attempt_id" => "attempt",
          "native_generation" => "native",
          "auth_epoch" => "1",
          "sequence" => 1,
          "schema_version" => 1,
          "expires_at" => System.system_time(:millisecond) + 900_000
        })

      %{
        "context" => context,
        "public_key" => Base.encode64(<<4, 0::512>>),
        "phase" => "awaiting_user",
        "save_result" => "not_committed",
        "verification_url" =>
          "https://claude.com/cai/oauth/authorize?code=true&client_id=client&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=challenge&code_challenge_method=S256&state=state"
      }
    end

    defp ready_result do
      %{
        "auth" => %{
          "schema_version" => 1,
          "status" => "authenticated",
          "requires_openai_auth" => true,
          "observed_at" => System.system_time(:millisecond),
          "mode" => "chatgpt"
        },
        "native_ready" => true,
        "ready" => true
      }
    end
  end

  defmodule AgentControl do
    def get(agent_id, tenant_id) do
      case Application.fetch_env!(:salix_env, :compute_runtime_auth_test_agent) do
        %{"agent_id" => ^agent_id, "tenant_id" => ^tenant_id} = agent -> {:ok, agent}
        _ -> {:error, :not_found}
      end
    end
  end

  defmodule Reconciler do
    import Ecto.Query

    def reconcile_workload(workload_id, generation, opts) do
      pid = Application.fetch_env!(:salix_store, :compute_runtime_auth_test_pid)
      send(pid, {:compute_runtime_auth_wake, workload_id, generation, opts})

      allocation = SalixStore.Repo.get!(SalixStore.Compute.Allocation, "allocation")

      SalixStore.Repo.update_all(
        from(a in SalixStore.Compute.Allocation, where: a.id == "allocation"),
        set: [
          provider_observation:
            allocation.provider_observation
            |> Map.put("current_container", %{
              "id" => "container",
              "instance_id" => "container-instance"
            })
            |> Map.put("container_status", "running")
        ]
      )

      if allocation.provider_observation["container_status"] == "running" do
        SalixStore.Repo.update_all(SalixStore.Compute.RuntimeInstance,
          set: [status: "connected", readiness: "ready", caught_up_epoch: "9"]
        )
      end

      {:ok, %{outcome: :pending}}
    end
  end

  setup do
    Repo.query!("TRUNCATE runtime_subscription_bindings, subscription_accounts")

    Repo.query!(
      "TRUNCATE agent_vmm_sessions, external_worker_operations, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    previous = %{
      dispatcher: Application.get_env(:salix_store, :compute_runtime_rpc_dispatcher),
      pid: Application.get_env(:salix_store, :compute_runtime_auth_test_pid),
      mode: Application.get_env(:salix_store, :compute_runtime_auth_test_mode),
      reconciler: Application.get_env(:salix_env, :compute_external_worker_reconciler),
      wake_timeout: Application.get_env(:salix_env, :compute_external_worker_wake_timeout_ms),
      agent_control: Application.get_env(:salix_env, :compute_runtime_auth_agent_control),
      agent: Application.get_env(:salix_env, :compute_runtime_auth_test_agent)
    }

    Application.put_env(:salix_store, :compute_runtime_rpc_dispatcher, Dispatcher)
    Application.put_env(:salix_env, :compute_external_worker_reconciler, Reconciler)
    Application.put_env(:salix_env, :compute_external_worker_wake_timeout_ms, 2_000)
    Application.put_env(:salix_store, :compute_runtime_auth_test_pid, self())
    Application.put_env(:salix_env, :compute_runtime_auth_agent_control, AgentControl)
    Application.put_env(:salix_env, :compute_runtime_auth_test_agent, external_worker())

    on_exit(fn ->
      restore(:compute_runtime_rpc_dispatcher, previous.dispatcher)
      restore(:compute_runtime_auth_test_pid, previous.pid)
      restore(:compute_runtime_auth_test_mode, previous.mode)
      restore_env(:compute_external_worker_reconciler, previous.reconciler)
      restore_env(:compute_external_worker_wake_timeout_ms, previous.wake_timeout)
      restore_env(:compute_runtime_auth_agent_control, previous.agent_control)
      restore_env(:compute_runtime_auth_test_agent, previous.agent)
    end)

    {:ok, _registration} =
      AgentVMM.create_registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "project",
        device_id: "device",
        enrollment_token: String.duplicate("e", 32)
      })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "pool",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec", "runtime_process"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    Repo.update_all(from(e in Compute.Environment, where: e.id == ^environment.id),
      set: [observed_state: "ready"]
    )

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: "registration"
      })

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [
        status: "available",
        observation: %{"connection_epoch" => "9", "gateway_instance_id" => "gateway"}
      ]
    )

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, allocation.revision, 1, "ready", "succeeded")

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.merge(%{
            "runtime_container_instance_id" => "container-instance",
            "runtime_execution_epoch" => "9",
            "runtime_verified_host_epoch" => "9"
          })
          |> Map.put("current_container", %{
            "id" => "container",
            "instance_id" => "container-instance"
          })
          |> Map.put("container_status", "running")
      ]
    )

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        template_key: "external.codex",
        capability_requirements: ["runtime_exec", "runtime_process"],
        generation: 1
      })

    now = DateTime.utc_now()

    Repo.insert!(%Compute.ExternalWorkerOperation{
      id: "external-worker-operation",
      tenant_id: "tenant",
      group_id: "project",
      operation_hash: "external-worker-operation",
      tool_call_id: "external-worker-tool-call",
      environment_id: environment.id,
      provider: "codex",
      template_key: "external.codex",
      allocation_id: allocation.id,
      workload_id: workload.id,
      worker_id: "agent-worker",
      state: "worker_ready",
      attempt_count: 0,
      last_error: %{},
      revision: 1,
      created_at: now,
      updated_at: now
    })

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "runtime:workload",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "9"
      })

    {:ok, runtime} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "9")

    Repo.insert!(%AgentVMM.Session{
      id: "session",
      registration_id: "registration",
      runtime_instance_id: runtime.id,
      allocation_id: allocation.id,
      allocation_generation: allocation.generation,
      connection_epoch: "9",
      gateway_instance_id: "gateway",
      status: "ready",
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      updated_at: DateTime.utc_now()
    })

    %{runtime: runtime}
  end

  @tag :compute_subscription
  test "typed static binding compares snapshots and preserves a saved choice when delivery fails" do
    alias SalixAgent.{AccountPool, SubscriptionStore}
    alias SalixStore.ComputeRuntimeAuth, as: StoreRuntimeAuth
    alias SalixWeb.{ComputeSubscriptionAuth, SubscriptionBinding}

    tenant = SalixStore.Ids.new_tenant_id()
    Repo.update_all(Compute.Environment, set: [tenant_id: tenant])
    Repo.update_all(Compute.Workload, set: [template_key: "external.pi"])

    {:ok, account} =
      AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "name" => "Static gateway",
        "connection" => %{
          "endpoint" => "https://models.example.test/v1",
          "protocol" => "anthropic_messages",
          "auth_scheme" => "bearer"
        },
        "credentials" => %{"api_key" => "static-secret"}
      })

    assert {:ok, %{binding: binding, delivery: {:error, :subscription_distribution_failed}}} =
             ComputeSubscriptionAuth.bind(
               tenant,
               "project",
               "workload",
               account["id"],
               account["version"],
               nil
             )

    assert {:ok, %{binding: ^binding, status: "pending"}} =
             ComputeSubscriptionAuth.status(tenant, "workload")

    assert {:ok, typed} = SubscriptionBinding.issue(binding["id"], "pi", nil)
    assert typed["credential_kind"] == "provider_api_key"
    assert typed["subscription_account_id"] == account["id"]
    assert typed["connection"]["endpoint"] == "https://models.example.test/v1"
    assert typed["api_key"] == "static-secret"
    assert typed["account_version"] == account["version"]
    assert is_integer(typed["delivery_revision"])
    refute Map.has_key?(typed, "expires_at")
    refute Map.has_key?(typed, "access_token")

    assert {:error, :subscription_access_unavailable} =
             SubscriptionBinding.issue(binding["id"], "codex", nil)

    attrs = %{
      tenant_id: tenant,
      project_id: "project",
      workload_id: "workload",
      runtime_instance_id: "runtime:workload",
      generation: 1,
      connection_epoch: "9",
      provider: "codex"
    }

    assert {:ok, %{provider: "pi"}} = StoreRuntimeAuth.subscription_target(attrs)

    assert {:ok, disabled_account} =
             AccountPool.update(tenant, account["id"], %{
               "version" => account["version"],
               "disabled" => true
             })

    assert {:ok,
            %{
              "revoked" => true,
              "delivery_revision" => revoked_revision,
              "subscription_account_id" => account_id
            }} = SubscriptionBinding.delivery_access(binding["id"], "pi", nil)

    assert is_integer(revoked_revision)
    assert account_id == account["id"]

    assert {:ok, %{binding: %{"enabled" => true}}} =
             ComputeSubscriptionAuth.status(tenant, "workload")

    assert {:ok, enabled_account} =
             AccountPool.update(tenant, account["id"], %{
               "version" => disabled_account["version"],
               "disabled" => false
             })

    assert {:ok, renamed} =
             AccountPool.update(tenant, account["id"], %{
               "version" => enabled_account["version"],
               "name" => "Renamed gateway"
             })

    assert {:error, :conflict} =
             ComputeSubscriptionAuth.bind(
               tenant,
               "project",
               "workload",
               account["id"],
               account["version"],
               binding
             )

    assert {:ok, %{binding: ^binding, delivery: {:error, :subscription_distribution_failed}}} =
             ComputeSubscriptionAuth.bind(
               tenant,
               "project",
               "workload",
               account["id"],
               renamed["version"],
               binding
             )

    stale = Map.put(binding, "id", binding["id"] + 1)
    assert {:error, :conflict} = ComputeSubscriptionAuth.unbind(tenant, "workload", stale)

    assert {:ok,
            %{
              binding: %{"id" => id, "account_id" => account_id, "enabled" => false},
              delivery: {:error, :subscription_distribution_failed}
            }} = ComputeSubscriptionAuth.unbind(tenant, "workload", binding)

    assert id == binding["id"]
    assert account_id == account["id"]

    {:ok, openai_account} =
      AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "name" => "OpenAI-compatible",
        "connection" => %{
          "endpoint" => "https://openai.example.test/v1",
          "protocol" => "openai_responses",
          "auth_scheme" => "bearer"
        },
        "credentials" => %{"api_key" => "other-secret"}
      })

    Repo.update_all(Compute.Workload, set: [template_key: "external.claude"])

    assert {:error, :unsupported_binding} =
             ComputeSubscriptionAuth.bind(
               tenant,
               "project",
               "workload",
               openai_account["id"],
               openai_account["version"],
               nil
             )

    assert {:ok, %{provider: "claude"}} = StoreRuntimeAuth.subscription_target(attrs)

    Repo.query!("DELETE FROM subscription_accounts WHERE tenant_id=$1 AND id=$2", [
      tenant,
      account["id"]
    ])

    assert {:ok, %{binding: %{"enabled" => false} = disabled}} =
             ComputeSubscriptionAuth.status(tenant, "workload")

    assert {:ok, %{binding: ^disabled, delivery: {:error, :subscription_distribution_failed}}} =
             ComputeSubscriptionAuth.unbind(tenant, "workload", disabled)

    assert {:error, :not_found} = AccountPool.list_bindings(tenant, account["id"])

    assert {:error, :subscription_access_unavailable} =
             SubscriptionBinding.issue(binding["id"], "pi", nil)

    assert {:ok, %{rows: [[false]]}} =
             SubscriptionStore.query(
               "SELECT enabled FROM runtime_subscription_bindings WHERE id=$1",
               [binding["id"]]
             )
  end

  @tag :compute_subscription
  test "production binding path serializes concurrent fixed selections" do
    alias SalixAgent.AccountPool
    alias SalixWeb.ComputeSubscriptionAuth

    tenant = SalixStore.Ids.new_tenant_id()
    Repo.update_all(Compute.Environment, set: [tenant_id: tenant])
    Repo.update_all(Compute.Workload, set: [template_key: "external.pi"])

    accounts =
      for name <- ["First", "Second"] do
        {:ok, account} =
          AccountPool.create(tenant, %{
            "credential_kind" => "provider_api_key",
            "name" => name,
            "connection" => %{
              "endpoint" => "https://models.example.test/v1",
              "protocol" => "anthropic_messages",
              "auth_scheme" => "bearer"
            },
            "credentials" => %{"api_key" => "secret-#{name}"}
          })

        account
      end

    results =
      accounts
      |> Task.async_stream(
        fn account ->
          ComputeSubscriptionAuth.bind(
            tenant,
            "project",
            "workload",
            account["id"],
            account["version"],
            nil
          )
        end,
        ordered: false,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %{binding: _}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 1

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM runtime_subscription_bindings WHERE tenant_id=$1 AND workload_id='workload'",
               [tenant]
             )
  end

  @tag :compute_subscription
  test "Workload subscription survives carrier replacement and removes binding only after revoked ACK" do
    alias SalixAgent.{SubscriptionStore, AccountPool}
    alias SalixWeb.{ComputeSubscriptionAuth, ComputeRuntimeSocket, ComputeRuntimeRPC}

    if Process.whereis(SalixWeb.ComputeRuntimeRPCPG) == nil do
      start_supervised!(%{
        id: SalixWeb.ComputeRuntimeRPCPG,
        start: {:pg, :start_link, [SalixWeb.ComputeRuntimeRPCPG]}
      })
    end

    if Process.whereis(SalixWeb.ConnectorRequestTaskSupervisor) == nil do
      start_supervised!(
        {Task.Supervisor, name: SalixWeb.ConnectorRequestTaskSupervisor, max_children: 2}
      )
    end

    if Process.whereis(SalixAgent.SubscriptionWorker) == nil do
      start_supervised!(SalixAgent.SubscriptionWorker)
    end

    tenant = SalixStore.Ids.new_tenant_id()
    Repo.update_all(Compute.Environment, set: [tenant_id: tenant])
    account = SubscriptionStore.id()

    {:ok, sealed} =
      SubscriptionStore.seal(tenant, account, %{
        "access_token" => "synthetic-access",
        "refresh_token" => "never-distribute",
        "account_id" => "workspace-account",
        "expired" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
      })

    {:ok, account_record} =
      SubscriptionStore.create(tenant, %{
        "id" => account,
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "status" => "active",
        "disabled" => false,
        "credentials" => sealed
      })

    state = %ComputeRuntimeSocket{
      status: :ready,
      tenant_id: tenant,
      workload_id: "workload",
      runtime_instance_id: "runtime:workload",
      generation: 1,
      connection_epoch: "9",
      runtime_kind: "external_worker",
      features: ["runtime.auth.v1", "runtime.subscription.v1"]
    }

    :ok = ComputeRuntimeRPC.join(state.runtime_instance_id, state.connection_epoch)

    task =
      Task.async(fn ->
        ComputeSubscriptionAuth.bind(
          tenant,
          "project",
          "workload",
          account,
          account_record["version"],
          nil
        )
      end)

    assert_receive {:compute_runtime_rpc, ref, caller, request}, 2_000
    assert request["method"] == "runtime_subscription_sync"
    refute inspect(request) =~ "synthetic-access"

    {:push, {:text, frame}, pending} =
      ComputeRuntimeSocket.handle_info({:compute_runtime_rpc, ref, caller, request}, state)

    sync = Jason.decode!(frame)

    fixture =
      "../../../connector/salix-connect/testdata/runtime-auth/hpke-js.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    params = %{"public_key" => fixture["Public"], "nonce" => String.duplicate("a", 32)}

    pull = %{
      "type" => "request",
      "id" => "pull",
      "method" => "runtime_subscription_access",
      "params" => params
    }

    {:ok, pending} =
      ComputeRuntimeSocket.handle_in({Jason.encode!(pull), [opcode: :text]}, pending)

    assert_receive {task_ref, {:ok, envelope}}, 3_000

    {:push, {:text, reply}, pending} =
      ComputeRuntimeSocket.handle_info({task_ref, {:ok, envelope}}, pending)

    refute reply =~ "synthetic-access"
    refute reply =~ "never-distribute"
    assert %{"result" => %{"enc" => _, "ciphertext" => _}} = Jason.decode!(reply)

    [[revision]] =
      Repo.query!(
        "SELECT revision FROM runtime_subscription_bindings WHERE tenant_id=$1 AND workload_id='workload'",
        [tenant]
      ).rows

    ack = %{
      "type" => "response",
      "id" => sync["id"],
      "result" => %{"delivery_revision" => revision, "revoked" => false}
    }

    {:ok, _} = ComputeRuntimeSocket.handle_in({Jason.encode!(ack), [opcode: :text]}, pending)
    assert {:ok, %{binding: binding, delivery: {:ok, _}}} = Task.await(task)

    assert {:ok, %{binding: ^binding, status: "ready"}} =
             ComputeSubscriptionAuth.status(tenant, "workload")

    Repo.update_all(Compute.RuntimeInstance, set: [connection_epoch: "10", caught_up_epoch: "10"])
    # Runtime execution changes independently of the Host connection epoch.
    allocation = Repo.get!(Compute.Allocation, "allocation")

    Repo.update_all(Compute.Allocation,
      set: [
        provider_observation:
          Map.put(allocation.provider_observation, "runtime_execution_epoch", "10")
      ]
    )

    assert {:error, :subscription_access_unavailable} =
             ComputeSubscriptionAuth.access(state, params)

    current = %{state | connection_epoch: "10"}

    assert {:error, :subscription_access_unavailable} =
             ComputeSubscriptionAuth.access(%{current | tenant_id: "other"}, params)

    assert {:ok, _} = ComputeSubscriptionAuth.access(current, params)

    Repo.query!(
      "UPDATE runtime_subscription_bindings SET failures=3,status='delivery_failed' WHERE tenant_id=$1 AND workload_id='workload'",
      [tenant]
    )

    assert {:ok, _} = ComputeSubscriptionAuth.access(current, Map.put(params, "background", true))

    assert {:ok, %{failures: 3, status: "delivery_failed"}} =
             ComputeSubscriptionAuth.status(tenant, "workload")

    # A replacement WebSocket can preserve the runtime execution epoch. Its
    # admission must still wake a binding that exhausted transport retries.
    :ok = ComputeSubscriptionAuth.reconnect(current)

    assert {:ok, %{failures: 0, status: "pending"}} =
             ComputeSubscriptionAuth.status(tenant, "workload")

    assert {:ok, _} = ComputeSubscriptionAuth.access(current, params)
    assert {:ok, %{failures: 0}} = ComputeSubscriptionAuth.status(tenant, "workload")
    :ok = ComputeRuntimeRPC.join(current.runtime_instance_id, current.connection_epoch)

    unbind =
      Task.async(fn -> ComputeSubscriptionAuth.unbind(tenant, "workload", binding) end)

    assert_receive {:compute_runtime_rpc, ref, caller, _request}, 2_000

    assert {:ok, %{binding: %{"account_id" => ^account, "enabled" => false}}} =
             ComputeSubscriptionAuth.status(tenant, "workload")

    {:ok, _} = ComputeSubscriptionAuth.access(current, params)

    [[revoked_revision, true]] =
      Repo.query!(
        "SELECT revision,last_delivery_revoked FROM runtime_subscription_bindings WHERE tenant_id=$1 AND workload_id='workload'",
        [tenant]
      ).rows

    # A stale ordinary ACK cannot delete the disabled relationship.
    send(
      caller,
      {:compute_runtime_rpc_reply, ref,
       {:ok, %{"delivery_revision" => revision, "revoked" => false}}}
    )

    assert {:ok, %{delivery: {:ok, _}}} = Task.await(unbind)
    assert {:ok, _} = ComputeSubscriptionAuth.status(tenant, "workload")
    retry = Task.async(fn -> ComputeSubscriptionAuth.deliver(tenant, "workload") end)
    assert_receive {:compute_runtime_rpc, ref, caller, _request}, 2_000

    send(
      caller,
      {:compute_runtime_rpc_reply, ref,
       {:ok, %{"delivery_revision" => revoked_revision, "revoked" => true}}}
    )

    assert {:ok, _} = Task.await(retry)
    assert {:error, :not_found} = ComputeSubscriptionAuth.status(tenant, "workload")
    worker = Application.get_env(:salix_agent, :subscription_worker)
    Application.put_env(:salix_agent, :subscription_worker, :absent_subscription_worker)

    try do
      assert {:ok, %{"bound" => false}} = ComputeSubscriptionAuth.access(current, params)
    after
      if worker,
        do: Application.put_env(:salix_agent, :subscription_worker, worker),
        else: Application.delete_env(:salix_agent, :subscription_worker)
    end

    assert {:ok, record} = SubscriptionStore.get(tenant, account)

    assert {:ok, _} =
             AccountPool.update(tenant, account, %{
               "version" => record["version"],
               "disabled" => true
             })
  end

  test "authorizes and returns only the exact provider-native readiness projection" do
    assert {:ok, %{"ready" => true, "native_ready" => true, "auth" => auth}} =
             ComputeRuntimeAuth.call(:read, target())

    assert auth["status"] == "authenticated"

    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", request}
    assert request["method"] == "runtime_auth_read"

    assert request["params"]["target"] == %{
             "tenant_id" => "tenant",
             "project_id" => "project",
             "workload_id" => "workload",
             "runtime_instance_id" => "runtime:workload",
             "generation" => 1,
             "connection_epoch" => "9",
             "provider" => "codex"
           }

    refute Map.has_key?(request["params"], "token")
  end

  test "a synchronous auth read does not acquire a Host execution right" do
    assert {:ok, %{"ready" => true}} = ComputeRuntimeAuth.call(:read, target())
    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", _request}
    refute_receive {:compute_runtime_auth_host_request, _, _, _}
  end

  test "a concurrent read cannot release an auth ceremony execution right" do
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :blocking_read)

    read = Task.async(fn -> ComputeRuntimeAuth.call(:read, target()) end)

    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", _}
    assert_receive {:compute_runtime_auth_dispatch_blocked, dispatcher}

    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :private)

    attrs = Map.merge(target(), %{actor_id: "admin", backend: "chatgpt", form: "codex_auth_file"})
    assert {:ok, _offer} = ComputeRuntimeAuth.call(:input_begin, attrs)

    send(dispatcher, :continue_compute_runtime_auth)
    assert {:ok, %{"ready" => true}} = Task.await(read)
    refute_receive {:compute_runtime_auth_host_request, _, _, _}
  end

  test "auth remains repairable while business readiness is false and after the allocation request deadline" do
    Repo.update_all(Compute.Workload, set: [observed_state: "pending"])

    assert {:ok, %{"ready" => true}} = ComputeRuntimeAuth.call(:read, target())
    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", _request}

    Repo.update_all(Compute.Workload, set: [desired_state: "stopped"])
    Repo.update_all(Compute.Allocation, set: [status: "draining"])
    assert {:error, :runtime_auth_target_changed} = ComputeRuntimeAuth.call(:read, target())
    refute_receive {:compute_runtime_auth_request, _, _, _}
    Repo.update_all(Compute.Workload, set: [desired_state: "ready"])
    Repo.update_all(Compute.Allocation, set: [status: "ready"])

    assert {:ok, %{"ready" => true}} = ComputeRuntimeAuth.call(:read, target())
    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", _request}
  end

  test "migration rejects stale carriers and releases its transfer lease" do
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :quiet_stale)

    attrs =
      Map.merge(target(), %{
        action: "import",
        migration: %{"operation_id" => "move-1", "data" => "chunk"}
      })

    assert {:error, :runtime_rpc_target_changed} =
             SalixWeb.ExternalRuntime.ExternalWorkerDriver.migration_for_compute_target(
               target(),
               "import",
               attrs.migration
             )

    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", request}
    assert request["method"] == "session_migration_import"
    assert request["params"]["target"]["workload_id"] == "workload"
    assert_receive {:migration_timeout, 1_800_000}

    assert {:error, :invalid_runtime_auth_request} =
             SalixStore.ComputeRuntimeAuth.call(:migration, attrs)

    assert {:error, :invalid_runtime_auth_request} =
             ComputeRuntimeAuth.call_for_external_worker(:migration, external_worker(), attrs)
  end

  test "quiet is an internal exact-target operation and rejects epoch drift" do
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :quiet)

    assert {:ok, %{"quiet" => true}} = SalixEnv.ComputeRuntimeControl.quiet(target())
    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", request}
    assert request["method"] == "agent_runtime_quiet"
    assert request["params"]["target"]["workload_id"] == "workload"

    assert {:error, :invalid_runtime_auth_request} =
             ComputeRuntimeAuth.call_for_external_worker(:quiet, external_worker(), target())

    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :quiet_stale)

    assert {:error, :runtime_control_target_changed} =
             SalixEnv.ComputeRuntimeControl.quiet(target())

    assert {:error, :invalid_runtime_auth_request} = ComputeRuntimeAuth.call(:quiet, target())
  end

  test "authorizes a product external-worker Agent only for its exact compute target" do
    assert {:ok, %{"ready" => true, "auth" => %{"status" => "authenticated"}}} =
             ComputeRuntimeAuth.call_for_external_worker(:read, external_worker(), %{
               group_id: "project",
               workload_id: "workload",
               generation: "1",
               provider: "codex"
             })

    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", request}
    assert request["params"]["target"]["workload_id"] == "workload"
    refute Map.has_key?(request["params"], "device_runtime_id")

    assert {:ok, %{"ready" => true}} =
             ComputeRuntimeAuth.call_for_external_worker(:read, external_worker(), %{
               group_id: "project",
               workload_id: "workload",
               runtime_instance_id: "caller-controlled-runtime",
               generation: 1,
               connection_epoch: "caller-controlled-epoch",
               provider: "codex"
             })

    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", request}
    assert request["params"]["target"]["runtime_instance_id"] == "runtime:workload"
    assert request["params"]["target"]["connection_epoch"] == "9"
  end

  test "a native dispatch failure is not replayed as an acquisition retry" do
    Application.put_env(
      :salix_store,
      :compute_runtime_auth_test_mode,
      :acquire_like_native_failure
    )

    assert {:error, {:gateway_error, %{"code" => "lifecycle_conflict"}}} =
             ComputeRuntimeAuth.call_for_external_worker(:login_start, external_worker(), %{
               flow: "device_code",
               group_id: "project",
               workload_id: "workload",
               generation: "derive",
               provider: "codex"
             })

    assert_receive {:compute_runtime_auth_request, _, _, _}
    refute_receive {:compute_runtime_auth_request, _, _, _}
    refute_receive {:compute_runtime_auth_wake, _, _, _}
  end

  test "a failed credential input begin releases its execution right" do
    Application.put_env(
      :salix_store,
      :compute_runtime_auth_test_mode,
      :native_rejection
    )

    assert {:error, :runtime_auth_failed} =
             ComputeRuntimeAuth.call(
               :input_begin,
               Map.merge(target(), %{
                 actor_id: "admin",
                 backend: "chatgpt",
                 form: "codex_auth_file"
               })
             )

    assert_receive {:compute_runtime_auth_request, _, _, _}
    refute_receive {:compute_runtime_auth_request, _, _, _}
  end

  test "an ambiguous start timeout retains its execution right" do
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :ambiguous_timeout)

    assert {:error, :runtime_auth_timeout} =
             ComputeRuntimeAuth.call_for_external_worker(:login_start, external_worker(), %{
               flow: "device_code",
               group_id: "project",
               workload_id: "workload",
               generation: "derive",
               provider: "codex"
             })

    assert_receive {:compute_runtime_auth_request, _, _, _}
    refute_receive {:compute_runtime_auth_request, _, _, _}
  end

  test "status dispatches without acquiring a Host execution right" do
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :status)

    assert {:ok, %{"provider" => "codex"}} =
             ComputeRuntimeAuth.call_for_external_worker(:status, external_worker(), %{
               actor_id: "router:agent:session",
               group_id: "project",
               workload_id: "workload",
               generation: "derive",
               provider: "codex"
             })

    assert_receive {:compute_runtime_auth_request, _, _, request}
    assert request["method"] == "runtime_auth_status"
    refute_receive {:compute_runtime_auth_host_request, _, _, _}
  end

  test "authorizes Router status through the current external-worker binding" do
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :status)

    handler_id = "compute-runtime-auth-status-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :operation, :stop],
        &__MODULE__.handle_runtime_auth_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{"provider" => "codex", "dispatch_ready" => true}} =
             ComputeRuntimeAuth.call_for_external_worker(:status, external_worker(), %{
               actor_id: "router:agent:session",
               group_id: "project",
               workload_id: "workload",
               generation: "derive",
               provider: "codex"
             })

    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", request}
    assert request["method"] == "runtime_auth_status"
    assert request["params"]["target"]["workload_id"] == "workload"

    assert_receive {:runtime_auth_telemetry, [:salix, :operation, :stop], %{duration: duration},
                    %{
                      component: "salix_env",
                      operation: "runtime_auth_status",
                      surface: "system",
                      outcome: "ok"
                    }}

    assert is_integer(duration) and duration >= 0
  end

  def handle_runtime_auth_telemetry(event, measurements, metadata, pid) do
    send(pid, {:runtime_auth_telemetry, event, measurements, metadata})
  end

  test "keeps an external worker authorized across a completed environment allocation generation" do
    Repo.update_all(Compute.Environment, set: [generation: 2])
    Repo.update_all(Compute.Allocation, set: [generation: 2])
    Repo.update_all(AgentVMM.Session, set: [allocation_generation: 2])

    assert {:ok, %{"ready" => true}} =
             ComputeRuntimeAuth.call_for_external_worker(:read, external_worker(), %{
               group_id: "project",
               workload_id: "workload",
               generation: 1,
               provider: "codex"
             })

    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", _request}
  end

  test "a second Agent bound to the same Workload is authorized by its current applied binding" do
    second = Map.put(external_worker(), "agent_id", "agent-worker-two")
    Application.put_env(:salix_env, :compute_runtime_auth_test_agent, second)

    assert {:ok, %{"ready" => true}} =
             ComputeRuntimeAuth.call_for_external_worker(:read, second, %{
               group_id: "project",
               workload_id: "workload",
               generation: 1,
               provider: "codex"
             })

    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", _request}
  end

  test "Pi rejects login while Claude admits only its authorization-code ceremony" do
    for provider <- ["pi", "claude"] do
      Repo.update_all(Compute.Workload, set: [template_key: "external.#{provider}"])

      worker =
        put_in(external_worker(), ["runtime_config", "runtime_spec", "provider"], provider)

      Application.put_env(:salix_env, :compute_runtime_auth_test_agent, worker)

      attrs = %{
        group_id: "project",
        workload_id: "workload",
        generation: 1,
        provider: provider
      }

      assert {:ok, %{"ready" => true}} =
               ComputeRuntimeAuth.call_for_external_worker(:read, worker, attrs)

      assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", request}
      assert request["method"] == "runtime_auth_read"
      assert request["params"]["target"]["provider"] == provider

      if provider == "pi" do
        for operation <- [:login_start, :login_cancel] do
          assert {:error, :runtime_auth_target_changed} =
                   ComputeRuntimeAuth.call_for_external_worker(operation, worker, attrs)
        end
      else
        Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :claude_login)

        assert {:ok, %{"context" => %{"provider" => "claude", "method" => "native_login"}}} =
                 ComputeRuntimeAuth.call_for_external_worker(
                   :login_start,
                   worker,
                   Map.merge(attrs, %{
                     actor_id: "admin",
                     backend: "anthropic",
                     flow: "authorization_code"
                   })
                 )

        assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", login_request}
        assert login_request["method"] == "runtime_auth_login_start"
        assert login_request["params"]["backend"] == "anthropic"
        assert login_request["params"]["flow"] == "authorization_code"

        Application.put_env(
          :salix_store,
          :compute_runtime_auth_test_mode,
          :claude_login_wrong_actor
        )

        assert {:error, :runtime_auth_target_changed} =
                 ComputeRuntimeAuth.call_for_external_worker(
                   :login_start,
                   worker,
                   Map.merge(attrs, %{
                     actor_id: "admin",
                     backend: "anthropic",
                     flow: "authorization_code"
                   })
                 )

        assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", _request}

        assert {:error, :invalid_runtime_auth_attempt_id} =
                 ComputeRuntimeAuth.call_for_external_worker(:login_cancel, worker, attrs)
      end

      refute_received {:compute_runtime_auth_request, _, _, _}
    end
  end

  test "login waits for the connector after waking a sleeping external Workload" do
    Repo.update_all(Compute.Workload, set: [template_key: "external.claude"])

    worker =
      put_in(external_worker(), ["runtime_config", "runtime_spec", "provider"], "claude")

    Application.put_env(:salix_env, :compute_runtime_auth_test_agent, worker)
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :claude_login)

    allocation = Repo.get!(Compute.Allocation, "allocation")

    Repo.update_all(Compute.Allocation,
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.put("current_container", %{
            "id" => "container",
            "instance_id" => "container-instance"
          })
          |> Map.put("container_status", "stopped")
      ]
    )

    Repo.update_all(Compute.RuntimeInstance,
      set: [status: "disconnected", readiness: "pending"]
    )

    assert {:ok, %{"context" => %{"provider" => "claude"}}} =
             ComputeRuntimeAuth.call_for_external_worker(:login_start, worker, %{
               actor_id: "admin",
               backend: "anthropic",
               flow: "authorization_code",
               group_id: "project",
               workload_id: "workload",
               generation: "derive",
               provider: "claude"
             })

    assert_receive {:compute_runtime_auth_wake, "workload", 1, opts}
    assert opts[:external_demand]
    assert_receive {:compute_runtime_auth_request, "runtime:workload", "9", _request}
    refute_receive {:compute_runtime_auth_request, _, _, _}
  end

  test "rejects stale or non-compute product targets before native dispatch" do
    assert {:error, :runtime_auth_target_changed} =
             ComputeRuntimeAuth.call_for_external_worker(:read, external_worker(), %{
               group_id: "project",
               workload_id: "stale-workload",
               generation: 1,
               provider: "codex"
             })

    assert {:error, :runtime_auth_target_changed} =
             ComputeRuntimeAuth.call_for_external_worker(
               :read,
               put_in(external_worker(), ["runtime_config", "kind"], "connected_runtime"),
               target()
             )

    assert {:error, :runtime_auth_target_changed} =
             ComputeRuntimeAuth.call_for_external_worker(
               :read,
               Map.put(external_worker(), "agent_id", "another-worker"),
               %{
                 group_id: "project",
                 workload_id: "workload",
                 generation: 1,
                 provider: "codex"
               }
             )

    refute_received {:compute_runtime_auth_request, _, _, _}
  end

  test "rejects a native success after the exact runtime epoch changed" do
    Application.put_env(
      :salix_store,
      :compute_runtime_auth_test_mode,
      :stale_after_native_result
    )

    assert {:error, :runtime_auth_target_changed} =
             ComputeRuntimeAuth.call(:read, target())
  end

  test "rejects a native success after the external-worker binding changed" do
    Application.put_env(
      :salix_store,
      :compute_runtime_auth_test_mode,
      :stale_product_after_native_result
    )

    assert {:error, :runtime_auth_target_changed} =
             ComputeRuntimeAuth.call_for_external_worker(:read, external_worker(), %{
               group_id: "project",
               workload_id: "workload",
               generation: 1,
               provider: "codex"
             })
  end

  test "rejects a provider payload outside the credential-free contract" do
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :leaky)

    assert {:error, :invalid_runtime_auth_response} =
             ComputeRuntimeAuth.call(:read, target())
  end

  test "private offer binds the server-resolved allocation and actor, and rejects drift" do
    attrs = Map.merge(target(), %{actor_id: "admin", backend: "chatgpt", form: "codex_auth_file"})
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :private)
    assert {:ok, offer} = ComputeRuntimeAuth.call(:input_begin, attrs)
    assert_receive {:compute_runtime_auth_request, _, _, request}
    session = Repo.get!(AgentVMM.Session, "session")

    assert request["params"]["target"]["allocation_generation"] ==
             Integer.to_string(session.allocation_generation)

    assert offer["context"]["allocation_id"] == session.allocation_id
    assert offer["context"]["actor_id"] == "admin"

    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :private_wrong_actor)
    assert {:error, :runtime_auth_target_changed} = ComputeRuntimeAuth.call(:input_begin, attrs)
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :private_stale_allocation)
    assert {:error, :runtime_auth_target_changed} = ComputeRuntimeAuth.call(:input_begin, attrs)
  end

  test "private ciphertext uses live dispatch and rejects oversized input before dispatch" do
    Application.put_env(:salix_store, :compute_runtime_auth_test_mode, :private_receipt)

    attrs =
      Map.merge(target(), %{
        actor_id: "admin",
        attempt_id: "attempt",
        envelope: "synthetic-encrypted-envelope"
      })

    assert {:ok, %{"save_result" => "committed"}} = ComputeRuntimeAuth.call(:input_submit, attrs)
    assert_receive {:compute_runtime_auth_request, _, _, request}
    assert request["method"] == "runtime_auth_input_submit"
    assert request["params"]["envelope"] == attrs.envelope
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM compute_runtime_inputs")

    assert {:error, :invalid_runtime_auth_request} =
             ComputeRuntimeAuth.call(:input_submit, %{
               attrs
               | envelope: String.duplicate("x", 96 * 1024 + 1)
             })

    refute_received {:compute_runtime_auth_request, _, _, _}
  end

  defp target do
    %{
      tenant_id: "tenant",
      project_id: "project",
      workload_id: "workload",
      runtime_instance_id: "runtime:workload",
      generation: 1,
      connection_epoch: "9",
      provider: "codex"
    }
  end

  defp external_worker do
    %{
      "agent_id" => "agent-worker",
      "tenant_id" => "tenant",
      "group_id" => "project",
      "role" => "worker",
      "runtime_config" => %{
        "kind" => "compute_workload",
        "workload_id" => "workload",
        "runtime_spec" => %{"provider" => "codex"},
        "owner_scope" => %{"type" => "project", "id" => "project"},
        "binding_revision" => 1
      }
    }
  end

  defp restore(key, nil), do: Application.delete_env(:salix_store, key)
  defp restore(key, value), do: Application.put_env(:salix_store, key, value)

  defp restore_env(key, nil), do: Application.delete_env(:salix_env, key)
  defp restore_env(key, value), do: Application.put_env(:salix_env, key, value)
end
