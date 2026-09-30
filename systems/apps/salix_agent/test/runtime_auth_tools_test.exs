defmodule SalixAgent.RuntimeAuthToolsTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{
    CapabilityRequests,
    InternalSessionActor,
    InternalSessionFleet,
    InternalSessionStore
  }

  alias SalixAgent.Tools.RuntimeAuth
  alias SalixStore.{Ids, Keys, S3}

  defmodule Adapter do
    def call_for_external_worker(operation, worker, attrs) do
      send(Application.fetch_env!(:salix_agent, :runtime_auth_tools_test_pid), {
        :runtime_auth_call,
        operation,
        worker,
        attrs
      })

      {:ok, Application.fetch_env!(:salix_agent, :runtime_auth_tools_status)}
    end
  end

  defmodule Requests do
    @behaviour SalixAgent.CapabilityRequestStore

    @impl true
    def create_capability_request(attrs) do
      send(Application.fetch_env!(:salix_agent, :runtime_auth_tools_test_pid), {
        :runtime_auth_request,
        attrs
      })

      {:ok, Map.put(attrs, "request_id", "cap-runtime-auth")}
    end

    @impl true
    def cancel_capability_request(_, _, _, _), do: {:ok, :not_found}
  end

  @env_keys [
    :runtime_auth_adapter,
    :runtime_auth_management_url_fn,
    :runtime_auth_tools_status,
    :runtime_auth_tools_test_pid,
    :capability_request_store_mod
  ]

  setup do
    previous_store = Application.get_env(:salix_store, :s3_backend)
    previous = Map.new(@env_keys, &{&1, Application.get_env(:salix_agent, &1)})
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case start_supervised(SalixStore.S3.Fake) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> SalixStore.S3.Fake.reset()
    end

    Application.put_env(:salix_agent, :runtime_auth_adapter, Adapter)
    Application.put_env(:salix_agent, :capability_request_store_mod, Requests)
    Application.put_env(:salix_agent, :runtime_auth_tools_test_pid, self())

    Application.put_env(:salix_agent, :runtime_auth_management_url_fn, fn _, project, workload ->
      {:ok, "https://teams.example/runtime-auth/projects/#{project}?target=#{workload}"}
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    # Runtime auth can inspect a persisted binding after its provisioning target
    # is no longer discoverable; this is not a new Worker creation request.
    worker =
      SalixAgent.TestSupport.create_legacy_control_agent_in_group!(tenant, group, %{
        "role" => "worker",
        "runtime_config" => %{
          "kind" => "compute_workload",
          "workload_id" => "workload-runtime-auth",
          "runtime_spec" => %{"provider" => "claude"},
          "owner_scope" => %{"type" => "project", "id" => "project-runtime-auth"},
          "binding_revision" => 7
        }
      })

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, previous_store)

      Enum.each(previous, fn {key, value} ->
        restore(:salix_agent, key, value)
      end)
    end)

    %{
      router: router,
      worker: worker,
      ctx: %{
        agent_id: router["agent_id"],
        tenant_id: tenant,
        group_id: group,
        session_id: router["router_session_id"],
        tool_call_id: "tool-runtime-auth"
      },
      target: %{
        "kind" => "compute_workload",
        "workload_id" => "workload-runtime-auth",
        "agent_id" => worker["agent_id"]
      }
    }
  end

  test "status resolves one current visible binding and returns no secret fields", ctx do
    put_status(status())

    result =
      RuntimeAuth.call(%{"action" => "status", "target" => ctx.target}, ctx.ctx)
      |> Jason.decode!()

    assert result["provider"] == "claude"
    assert result["auth"]["status"] == "configured"
    assert_receive {:runtime_auth_call, :status, worker, attrs}
    assert worker["agent_id"] == ctx.worker["agent_id"]
    assert attrs.generation == "derive"
    assert attrs.provider == "claude"
    refute inspect(result) =~ "synthetic-secret"
  end

  test "start creates a bounded credential-free human request and async wait", ctx do
    put_status(status())

    {encoded, events} =
      RuntimeAuth.call(
        %{
          "action" => "start",
          "target" => ctx.target,
          "method" => "credential_import",
          "backend" => "openrouter"
        },
        ctx.ctx
      )

    result = Jason.decode!(encoded)
    assert result["status"] == "requires_admin"
    assert result["management_url"] =~ "/runtime-auth/projects/project-runtime-auth"

    assert URI.decode_query(URI.parse(result["management_url"]).query)["request"] ==
             "cap-runtime-auth"

    assert Enum.map(events, & &1["type"]) == ["async_tool_call_started", "wait_set"]

    assert_receive {:runtime_auth_request, request}
    payload = get_in(request, ["request_payload", "runtime_auth"])
    assert payload["action"] == "start"
    assert payload["target"]["binding_revision"] == 7
    assert payload["target"]["agent_id"] == ctx.worker["agent_id"]
    assert request["request_type"] == "runtime_auth"
    assert request["expires_at"] <= System.system_time(:second) + 900
    refute inspect(request) =~ "synthetic-secret"
  end

  test "rejects hidden payload fields and a stale or unadvertised operation", ctx do
    put_status(status())

    assert_raise RuntimeError, ~r/invalid_runtime_auth_request/, fn ->
      RuntimeAuth.call(
        %{"action" => "status", "target" => ctx.target, "token" => "synthetic-secret"},
        ctx.ctx
      )
    end

    assert_raise RuntimeError, ~r/unsupported_runtime_auth_method/, fn ->
      RuntimeAuth.call(
        %{
          "action" => "start",
          "target" => ctx.target,
          "method" => "native_login",
          "backend" => "openrouter"
        },
        ctx.ctx
      )
    end

    assert_raise RuntimeError, ~r/invalid_runtime_auth/, fn ->
      RuntimeAuth.call(
        %{
          "action" => "status",
          "target" => Map.delete(ctx.target, "agent_id")
        },
        ctx.ctx
      )
    end

    refute_received {:runtime_auth_request, _}
  end

  test "completion rechecks the exact binding and authenticated evidence", ctx do
    put_status(%{
      status()
      | "auth" => %{"schema_version" => 1, "status" => "authenticated", "backend" => "openrouter"}
    })

    request = completion_request(ctx)

    assert {:ok, response} =
             RuntimeAuth.validate_completion(request, "authenticated", "admin-user")

    assert response["outcome"] == "authenticated"
    assert response["target"] == ctx.target

    stale = put_in(request, ["request_payload", "runtime_auth", "target", "binding_revision"], 6)

    assert {:error, :runtime_auth_target_changed} =
             RuntimeAuth.validate_completion(stale, "authenticated", "admin-user")

    put_status(status())

    assert {:error, :runtime_auth_target_changed} =
             RuntimeAuth.validate_completion(request, "authenticated", "admin-user")
  end

  test "cancel completion accepts the target's retired private attempt", ctx do
    put_status(status())

    request =
      ctx
      |> completion_request()
      |> put_in(["request_payload", "runtime_auth", "action"], "cancel")

    assert {:ok, %{"outcome" => "canceled"}} =
             RuntimeAuth.validate_completion(request, "canceled", "admin-user")
  end

  test "durable request completion settles the exact async tool call once", ctx do
    put_status(%{
      status()
      | "auth" => %{"schema_version" => 1, "status" => "authenticated", "backend" => "openrouter"}
    })

    session_id = ctx.ctx.session_id
    tool_call_id = "tool-runtime-auth-durable"

    assert {:ok, _} =
             InternalSessionStore.prepare_commit(ctx.router["agent_id"], session_id, [
               %{
                 "type" => "session_created",
                 "session_id" => session_id,
                 "name" => "Runtime auth"
               },
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => session_id,
                 "tool_call_id" => tool_call_id,
                 "tool_name" => "runtime.auth",
                 "status" => "running",
                 "completion_mode" => "external_callback",
                 "started_at" => 1_000
               }
             ])

    assert {:ok, _} =
             InternalSessionFleet.ensure_started(ctx.router["agent_id"], session_id,
               process_on_init: false
             )

    [{pid, _}] =
      Registry.lookup(
        SalixAgent.Registry,
        InternalSessionActor.key(ctx.router["agent_id"], session_id)
      )

    :sys.replace_state(pid, fn state -> %{state | pending_llm: %{test_hold: true}} end)

    request = completion_request(ctx)

    assert {:ok, created} =
             CapabilityRequests.create_capability_request(%{
               "source_agent_id" => ctx.router["agent_id"],
               "source_session_id" => session_id,
               "tool_call_id" => tool_call_id,
               "request_type" => "runtime_auth",
               "request_payload" => request["request_payload"],
               "expires_at" => request["expires_at"]
             })

    assert {:ok, completed} =
             CapabilityRequests.complete_runtime_auth(
               ctx.ctx.group_id,
               created["request_id"],
               %{"outcome" => "authenticated", "actor_id" => "admin-user"},
               ctx.ctx.tenant_id
             )

    assert completed["status"] == "completed"
    assert completed["response_payload"]["outcome"] == "authenticated"

    settled =
      eventually(fn ->
        with {:ok, session} <-
               InternalSessionStore.read(ctx.router["agent_id"], session_id),
             {:ok, %{"status" => "completed"}} <-
               SalixAgent.InternalSession.lookup_async_call(session, tool_call_id) do
          Enum.count(
            SalixAgent.InternalSession.get(session, :input_queue),
            &(get_in(&1, ["payload", "source_tool_call_id"]) == tool_call_id and
                get_in(&1, ["payload", "type"]) == "tool_call_completed")
          ) == 1
        else
          _ -> false
        end
      end)

    assert settled

    assert {:error, :runtime_auth_target_changed} =
             CapabilityRequests.complete_runtime_auth(
               ctx.ctx.group_id,
               created["request_id"],
               %{"outcome" => "authenticated", "actor_id" => "admin-user"},
               ctx.ctx.tenant_id
             )

    assert {:ok, session} = InternalSessionStore.read(ctx.router["agent_id"], session_id)

    assert Enum.count(
             SalixAgent.InternalSession.get(session, :async_results),
             &(&1["tool_call_id"] == tool_call_id)
           ) == 1

    assert Enum.count(
             SalixAgent.InternalSession.get(session, :input_queue),
             &(get_in(&1, ["payload", "source_tool_call_id"]) == tool_call_id)
           ) == 1
  end

  test "runtime auth request reads one storage page and follows its opaque cursor", ctx do
    Enum.each(1..50, fn index ->
      request_id = "other-#{String.pad_leading(Integer.to_string(index), 3, "0")}"

      assert {:ok, _} =
               S3.put(
                 Keys.ctl_capability_request(ctx.ctx.group_id, request_id),
                 Jason.encode!(%{
                   "request_id" => request_id,
                   "tenant_id" => ctx.ctx.tenant_id,
                   "request_type" => "location",
                   "status" => "pending",
                   "updated_at" => index
                 })
               )
    end)

    runtime_request = %{
      "request_id" => "runtime-zzz",
      "tenant_id" => ctx.ctx.tenant_id,
      "request_type" => "runtime_auth",
      "status" => "pending",
      "updated_at" => 51
    }

    assert {:ok, _} =
             S3.put(
               Keys.ctl_capability_request(ctx.ctx.group_id, runtime_request["request_id"]),
               Jason.encode!(runtime_request)
             )

    assert {:ok, %{"requests" => [], "next_cursor" => cursor}} =
             CapabilityRequests.list_runtime_auth_page(
               ctx.ctx.group_id,
               ctx.ctx.tenant_id,
               limit: 50
             )

    assert is_binary(cursor)

    assert {:ok, %{"requests" => [^runtime_request], "next_cursor" => nil}} =
             CapabilityRequests.list_runtime_auth_page(
               ctx.ctx.group_id,
               ctx.ctx.tenant_id,
               limit: 50,
               cursor: cursor
             )

    assert {:error, {:bad_request, "invalid limit"}} =
             CapabilityRequests.list_runtime_auth_page(
               ctx.ctx.group_id,
               ctx.ctx.tenant_id,
               limit: 51
             )
  end

  defp status do
    %{
      "provider" => "claude",
      "auth" => %{"schema_version" => 1, "status" => "configured", "backend" => "openrouter"},
      "native_ready" => true,
      "dispatch_ready" => false,
      "methods" => [
        %{
          "method" => "credential_import",
          "backend" => "openrouter",
          "form" => "api_key",
          "schema_version" => 1
        },
        %{
          "method" => "verify",
          "backend" => "openrouter",
          "form" => "api_key",
          "schema_version" => 1
        }
      ],
      "attempt" => nil
    }
  end

  defp put_status(value), do: Application.put_env(:salix_agent, :runtime_auth_tools_status, value)

  defp completion_request(ctx) do
    %{
      "status" => "pending",
      "request_type" => "runtime_auth",
      "tenant_id" => ctx.ctx.tenant_id,
      "group_id" => ctx.ctx.group_id,
      "expires_at" => System.system_time(:second) + 60,
      "request_payload" => %{
        "runtime_auth" => %{
          "action" => "verify",
          "management_url" => "https://teams.example/runtime-auth/projects/project-runtime-auth",
          "target" => %{
            "kind" => "compute_workload",
            "workload_id" => "workload-runtime-auth",
            "project_id" => "project-runtime-auth",
            "agent_id" => ctx.worker["agent_id"],
            "binding_revision" => 7
          }
        }
      }
    }
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
