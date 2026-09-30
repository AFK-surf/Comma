defmodule BridgeForTeamsWeb.RuntimeAuthControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Memberships
  alias BridgeForTeamsWeb.DashboardEndpoint
  alias SalixStore.{AgentVMM, Compute, Repo}

  defmodule Dispatcher do
    def call(_runtime, _epoch, request) do
      send(
        Application.fetch_env!(:salix_store, :runtime_auth_http_test_pid),
        {:auth_request, request}
      )

      case request["method"] do
        "runtime_auth_status" ->
          {:ok,
           %{
             "provider" => "codex",
             "auth" => %{
               "schema_version" => 1,
               "status" => "unknown",
               "requires_openai_auth" => true,
               "observed_at" => System.system_time(:millisecond)
             },
             "native_ready" => false,
             "dispatch_ready" => false,
             "methods" => [],
             "attempt" => nil
           }}

        "runtime_auth_input_begin" ->
          context =
            request["params"]["target"]
            |> Map.update!("generation", &Integer.to_string/1)
            |> Map.merge(%{
              "target_kind" => "compute_workload",
              "device_id" => "",
              "runtime_id" => "",
              "backend" => request["params"]["backend"],
              "form" => request["params"]["form"],
              "method" => "credential_import",
              "attempt_id" => "attempt",
              "native_generation" => "native",
              "auth_epoch" => "1",
              "sequence" => 1,
              "schema_version" => 1,
              "expires_at" => System.system_time(:millisecond) + 900_000
            })

          {:ok,
           %{
             "context" => context,
             "public_key" => Base.encode64(<<4, 0::512>>),
             "phase" => "awaiting_user",
             "save_result" => "not_committed"
           }}

        "runtime_auth_login_start" ->
          {:ok,
           %{
             "auth" => %{
               "schema_version" => 1,
               "status" => "pending",
               "requires_openai_auth" => true,
               "observed_at" => System.system_time(:millisecond)
             },
             "attempt_id" => "native-attempt",
             "flow" => "device_code",
             "verification_url" => "https://auth.openai.com/codex/device",
             "user_code" => "ABCD-EFGH",
             "expires_at" => System.system_time(:millisecond) + 900_000,
             "reused" => false
           }}

        "runtime_auth_verify" ->
          {:ok, %{"status" => "authenticated", "issue" => ""}}

        "runtime_auth_input_submit" ->
          if request["params"]["envelope"] == "definitive-invalid-envelope",
            do: {:error, :invalid_runtime_auth_request},
            else: {:error, :runtime_rpc_timeout}

        "runtime_auth_input_cancel" ->
          {:ok, %{"save_result" => "not_committed", "issue" => "canceled"}}
      end
    end
  end

  defmodule ConnectedClient do
    def device_managed_auth_operation(_, _, _, _, :read, %{}),
      do: {:ok, %{"source" => "self_configured"}}

    def compute_managed_auth_operation(_tenant_id, _project_id, _workload_id, :read, %{}) do
      {:ok,
       %{
         "source" =>
           Application.get_env(
             :bridge_for_teams_core,
             :runtime_auth_managed_source,
             "self_configured"
           )
       }}
    end

    def runtime_auth(operation, attrs) do
      send(
        Application.fetch_env!(:bridge_for_teams_core, :runtime_auth_http_test_pid),
        {:connected_auth_request, operation, attrs}
      )

      {:ok, %{"status" => "authenticated", "issue" => ""}}
    end

    def list_runtime_auth_requests(group_id, tenant_id, opts) do
      send(
        Application.fetch_env!(:bridge_for_teams_core, :runtime_auth_http_test_pid),
        {:list_runtime_auth_requests, group_id, tenant_id, opts}
      )

      project_id = Application.fetch_env!(:bridge_for_teams_core, :runtime_auth_project_id)

      {:ok,
       %{
         "requests" => [
           %{
             "request_id" => "request-runtime-auth",
             "status" => "pending",
             "expires_at" => System.system_time(:second) + 60,
             "request_payload" => %{
               "runtime_auth" => %{
                 "action" => "verify",
                 "backend" => "openrouter",
                 "target" => %{
                   "kind" => "compute_workload",
                   "workload_id" => "workload-runtime-auth",
                   "project_id" => project_id
                 }
               }
             }
           }
         ],
         "next_cursor" => "runtime-auth-page-2"
       }}
    end

    def get_runtime_auth_request(group_id, request_id, tenant_id) do
      send(
        Application.fetch_env!(:bridge_for_teams_core, :runtime_auth_http_test_pid),
        {:get_runtime_auth_request, group_id, request_id, tenant_id}
      )

      project_id = Application.fetch_env!(:bridge_for_teams_core, :runtime_auth_project_id)

      {:ok,
       %{
         "request_id" => request_id,
         "status" => "pending",
         "request_payload" => %{
           "runtime_auth" => %{
             "action" => "verify",
             "backend" => "openrouter",
             "target" => %{
               "kind" => "compute_workload",
               "workload_id" => "workload-runtime-auth",
               "project_id" => project_id
             }
           }
         }
       }}
    end

    def complete_runtime_auth_request(group_id, request_id, attrs, tenant_id) do
      send(
        Application.fetch_env!(:bridge_for_teams_core, :runtime_auth_http_test_pid),
        {:complete_runtime_auth_request, group_id, request_id, attrs, tenant_id}
      )

      {:ok,
       %{
         "request_id" => request_id,
         "status" => "completed",
         "request_payload" => %{
           "runtime_auth" => %{
             "action" => "verify",
             "backend" => "openrouter",
             "target" => %{
               "kind" => "compute_workload",
               "workload_id" => "workload-runtime-auth",
               "project_id" =>
                 Application.fetch_env!(:bridge_for_teams_core, :runtime_auth_project_id)
             }
           }
         }
       }}
    end
  end

  setup do
    %{org: org, user: admin} = org_with_owner_fixture()
    project = bare_project_fixture(org)
    %{org: org, admin: admin, project: project}
  end

  test "private input requires the current project administrator", ctx do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(ctx.org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(ctx.project.id, member.id, "user")

    conn = request(ctx, member, input_begin())
    assert conn.status == 403
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "rejects browser identity, provider, transport and plaintext fields", ctx do
    for field <- ~w(actor_id tenant_id project_id provider generation connection_epoch token file) do
      conn = request(ctx, ctx.admin, Map.put(input_begin(), field, "untrusted-marker"))
      assert conn.status == 400, field
      refute conn.resp_body =~ "untrusted-marker"
    end
  end

  test "rejects oversized envelopes and target overrides before dispatch", ctx do
    submit = %{
      "action" => "input_submit",
      "target" => %{"kind" => "compute_workload", "workload_id" => "missing"},
      "attempt_id" => "attempt",
      "envelope" => String.duplicate("x", 96 * 1024 + 1)
    }

    assert request(ctx, ctx.admin, submit).status == 400

    for field <- ~w(provider actor_id generation runtime_instance_id) do
      body = put_in(input_begin(), ["target", field], "untrusted-marker")
      assert request(ctx, ctx.admin, body).status == 400
    end
  end

  test "an administrator cannot resolve another organization's project", ctx do
    outsider = user_fixture()
    conn = request(ctx, outsider, input_begin())
    assert conn.status == 403
  end

  test "authenticated browser identity and actual project reach the current carrier", ctx do
    workload = runtime_fixture(ctx)
    body = put_in(input_begin(), ["target", "workload_id"], workload.id)
    conn = request(ctx, ctx.admin, body)
    assert conn.status == 200, conn.resp_body
    assert_receive {:auth_request, wire}
    assert wire["params"]["target"]["actor_id"] == ctx.admin.id
    assert wire["params"]["target"]["project_id"] == ctx.project.id
    refute wire["params"]["target"]["project_id"] == ctx.project.salix_group_id
    assert wire["params"]["target"]["provider"] == "codex"

    status = request(ctx, ctx.admin, %{"action" => "status", "target" => body["target"]})
    assert status.status == 200, status.resp_body
    assert_receive {:auth_request, %{"method" => "runtime_auth_status"}}

    other_project = bare_project_fixture(ctx.org)
    conn = request(%{ctx | project: other_project}, ctx.admin, body)
    assert conn.status == 409
    refute_receive {:auth_request, _}

    {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.admin.id, "member")
    {:ok, _} = Memberships.put_project_member(ctx.project.id, ctx.admin.id, "user")
    assert request(ctx, ctx.admin, body).status == 403
    refute_receive {:auth_request, _}
  end

  test "organization-managed authentication blocks private credential mutation", ctx do
    workload = runtime_fixture(ctx)
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    Application.put_env(:bridge_for_teams_core, :salix_client, ConnectedClient)
    Application.put_env(:bridge_for_teams_core, :runtime_auth_managed_source, "organization")

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous_client),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)

      Application.delete_env(:bridge_for_teams_core, :runtime_auth_managed_source)
    end)

    body = put_in(input_begin(), ["target", "workload_id"], workload.id)
    conn = request(ctx, ctx.admin, body)

    assert conn.status == 409
    assert get_in(Jason.decode!(conn.resp_body), ["error", "code"]) == "managed_auth_conflict"
    refute_receive {:auth_request, _}
  end

  test "native login carries administrator and exact allocation scope", ctx do
    workload = runtime_fixture(ctx)

    conn =
      request(ctx, ctx.admin, %{
        "action" => "login_start",
        "target" => %{"kind" => "compute_workload", "workload_id" => workload.id},
        "backend" => "chatgpt",
        "flow" => "device_code"
      })

    assert conn.status == 200, conn.resp_body
    assert_receive {:auth_request, %{"method" => "runtime_auth_login_start", "params" => params}}
    assert params["target"]["actor_id"] == ctx.admin.id
    assert params["target"]["allocation_generation"] == "1"
    assert params["backend"] == "chatgpt"
  end

  test "a lost submit response stays unknown and is dispatched only once", ctx do
    workload = runtime_fixture(ctx)

    body = %{
      "action" => "input_submit",
      "target" => %{"kind" => "compute_workload", "workload_id" => workload.id},
      "attempt_id" => "attempt",
      "envelope" => "synthetic-ciphertext"
    }

    conn = request(ctx, ctx.admin, body)
    assert conn.status == 200, conn.resp_body

    assert get_in(Jason.decode!(conn.resp_body), ["data", "runtime_auth", "save_result"]) ==
             "unknown"

    refute conn.resp_body =~ "synthetic-ciphertext"
    assert_receive {:auth_request, %{"method" => "runtime_auth_input_submit"}}
    refute_receive {:auth_request, _}
  end

  test "a definitive submit rejection remains actionable", ctx do
    workload = runtime_fixture(ctx)

    conn =
      request(ctx, ctx.admin, %{
        "action" => "input_submit",
        "target" => %{"kind" => "compute_workload", "workload_id" => workload.id},
        "attempt_id" => "attempt",
        "envelope" => "definitive-invalid-envelope"
      })

    assert conn.status == 400, conn.resp_body
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_runtime_auth_request"
    assert_receive {:auth_request, %{"method" => "runtime_auth_input_submit"}}
    refute_receive {:auth_request, _}
  end

  test "explicit verification reaches the exact Pi target once and rechecks administrator access",
       ctx do
    workload = runtime_fixture(ctx, "pi")

    body = %{
      "action" => "verify",
      "target" => %{"kind" => "compute_workload", "workload_id" => workload.id},
      "backend" => "openrouter"
    }

    conn = request(ctx, ctx.admin, body)
    assert conn.status == 200, conn.resp_body

    assert get_in(Jason.decode!(conn.resp_body), ["data", "runtime_auth", "status"]) ==
             "authenticated"

    assert_receive {:auth_request, %{"method" => "runtime_auth_verify", "params" => params}}
    assert params["backend"] == "openrouter"
    assert params["target"]["provider"] == "pi"
    assert params["target"]["actor_id"] == ctx.admin.id
    refute_receive {:auth_request, _}

    for field <- ~w(api_key model max_tokens retry_count endpoint) do
      assert request(ctx, ctx.admin, Map.put(body, field, "untrusted-marker")).status == 400
    end

    refute_receive {:auth_request, _}
    {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.admin.id, "member")
    {:ok, _} = Memberships.put_project_member(ctx.project.id, ctx.admin.id, "user")
    assert request(ctx, ctx.admin, body).status == 403
    refute_receive {:auth_request, _}
  end

  test "Devices exposes unready Compute targets through browser-owned private controls", ctx do
    workload = runtime_fixture(ctx, "pi")

    {:ok, view, _html} =
      build_conn()
      |> log_in_user(ctx.admin)
      |> live("/orgs/#{ctx.org.slug}/projects/#{ctx.project.id}/devices")

    assert has_element?(view, "#runtime-auth-#{workload.id}", "pi")
    html = view |> element("#runtime-auth-#{workload.id} button", "管理") |> render_click()
    assert html =~ "runtime-auth-private-controls"

    assert has_element?(
             view,
             "#runtime-auth-private-controls[phx-hook=RuntimeAuth][phx-update=ignore]"
           )

    assert has_element?(view, "input[data-auth-secret][type=password]:not([name])")
    assert has_element?(view, "input[data-auth-file]:not([phx-change]):not([name])")
    render_click(view, "close_runtime_auth_panel", %{})
    refute has_element?(view, "#runtime-auth-private-controls")

    render_click(view, "manage_runtime_auth", %{
      "id" => workload.id,
      "request-id" => "forged-request"
    })

    refute has_element?(view, "#runtime-auth-private-controls")
    refute_receive {:auth_request, _}
  end

  test "connected administrator action derives its product scope from the authenticated project",
       ctx do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ConnectedClient)
    Application.put_env(:bridge_for_teams_core, :runtime_auth_http_test_pid, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)

      Application.delete_env(:bridge_for_teams_core, :runtime_auth_http_test_pid)
    end)

    body = %{
      "action" => "verify",
      "target" => %{
        "kind" => "connected_runtime",
        "device_id" => "device",
        "runtime_id" => "runtime"
      },
      "backend" => "openrouter"
    }

    conn = request(ctx, ctx.admin, body)
    assert conn.status == 200, conn.resp_body
    assert_receive {:connected_auth_request, :verify, attrs}

    assert attrs == %{
             actor_id: ctx.admin.id,
             tenant_id: ctx.org.salix_tenant_id,
             project_id: ctx.project.id,
             group_id: ctx.project.salix_group_id,
             device_id: "device",
             runtime_id: "runtime",
             backend: "openrouter"
           }

    assert request(ctx, ctx.admin, put_in(body, ["target", "provider"], "pi")).status == 400
    {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.admin.id, "member")
    {:ok, _} = Memberships.put_project_member(ctx.project.id, ctx.admin.id, "user")
    assert request(ctx, ctx.admin, body).status == 403
    refute_receive {:connected_auth_request, _, _}
  end

  test "Router request list and completion stay project-scoped and credential-free", ctx do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ConnectedClient)
    Application.put_env(:bridge_for_teams_core, :runtime_auth_http_test_pid, self())
    Application.put_env(:bridge_for_teams_core, :runtime_auth_project_id, ctx.project.id)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)

      Application.delete_env(:bridge_for_teams_core, :runtime_auth_http_test_pid)
      Application.delete_env(:bridge_for_teams_core, :runtime_auth_project_id)
    end)

    base = "/dashboard/orgs/#{ctx.org.slug}/projects/#{ctx.project.slug}/runtime-auth/requests"

    list = dashboard_request(:get, base, ctx.admin)
    assert list.status == 200
    refute list.resp_body =~ "api_key"

    assert get_in(Jason.decode!(list.resp_body), [
             "data",
             "runtime_auth_requests",
             Access.at(0),
             "request_id"
           ]) == "request-runtime-auth"

    assert get_in(Jason.decode!(list.resp_body), ["data", "next_cursor"]) ==
             "runtime-auth-page-2"

    assert_receive {:list_runtime_auth_requests, group_id, tenant_id, [cursor: nil, limit: 50]}

    assert group_id == ctx.project.salix_group_id
    assert tenant_id == ctx.org.salix_tenant_id

    assert dashboard_request(:get, base <> "?cursor=opaque-page", ctx.admin).status == 200

    assert_receive {:list_runtime_auth_requests, ^group_id, ^tenant_id,
                    [cursor: "opaque-page", limit: 50]}

    assert dashboard_request(
             :get,
             base <> "?cursor=" <> String.duplicate("x", 4_097),
             ctx.admin
           ).status == 400

    refute_receive {:list_runtime_auth_requests, _, _, _}

    complete =
      dashboard_request(
        :post,
        base <> "/request-runtime-auth/complete",
        ctx.admin,
        %{"outcome" => "authenticated"}
      )

    assert complete.status == 200, complete.resp_body
    assert_receive {:get_runtime_auth_request, ^group_id, "request-runtime-auth", ^tenant_id}

    assert_receive {:complete_runtime_auth_request, ^group_id, "request-runtime-auth", attrs,
                    ^tenant_id}

    assert attrs == %{"actor_id" => ctx.admin.id, "outcome" => "authenticated"}

    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(ctx.org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(ctx.project.id, member.id, "user")

    assert dashboard_request(:post, base <> "/request-runtime-auth/complete", member, %{
             "outcome" => "authenticated"
           }).status == 403

    refute_receive {:complete_runtime_auth_request, _, _, _, _}
  end

  test "credential-free Router management link resolves the visible project", ctx do
    conn =
      dashboard_request(
        :get,
        "/runtime-auth/projects/#{ctx.project.id}?target=workload-1&request=request-1",
        ctx.admin
      )

    assert redirected_to(conn) ==
             "/orgs/#{ctx.org.slug}/projects/#{ctx.project.id}/devices?runtime_auth_request=request-1&runtime_auth_target=workload-1"

    outsider = user_fixture()

    assert dashboard_request(:get, "/runtime-auth/projects/#{ctx.project.id}", outsider).status ==
             404
  end

  defp runtime_fixture(ctx, provider \\ "codex") do
    old_dispatcher = Application.get_env(:salix_store, :compute_runtime_rpc_dispatcher)
    Application.put_env(:salix_store, :compute_runtime_rpc_dispatcher, Dispatcher)
    Application.put_env(:salix_store, :runtime_auth_http_test_pid, self())

    on_exit(fn ->
      if old_dispatcher,
        do: Application.put_env(:salix_store, :compute_runtime_rpc_dispatcher, old_dispatcher),
        else: Application.delete_env(:salix_store, :compute_runtime_rpc_dispatcher)

      Application.delete_env(:salix_store, :runtime_auth_http_test_pid)
    end)

    suffix = Ecto.UUID.generate()

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "reg-#{suffix}",
        tenant_id: ctx.org.salix_tenant_id,
        group_id: ctx.project.salix_group_id,
        device_id: "dev-#{suffix}",
        enrollment_token: String.duplicate("e", 32)
      })

    registration
    |> Ecto.Changeset.change(status: "ready", desired_enabled: true)
    |> Repo.update!()

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool-#{suffix}",
        tenant_id: ctx.org.salix_tenant_id,
        name: "pool",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "env-#{suffix}",
        tenant_id: ctx.org.salix_tenant_id,
        owner_type: "project",
        owner_id: ctx.project.id,
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding-#{suffix}",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id
      })

    binding
    |> Ecto.Changeset.change(
      status: "available",
      observation: %{"connection_epoch" => "9", "gateway_instance_id" => "gateway"}
    )
    |> Repo.update!()

    {:ok, allocation} =
      Compute.allocate(%{
        id: "alloc-#{suffix}",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, allocation.revision, 1, "ready", "succeeded", %{
        "current_container" => %{
          "id" => "container-#{suffix}",
          "instance_id" => "instance-#{suffix}"
        },
        "container_status" => "running",
        "runtime_container_instance_id" => "instance-#{suffix}",
        "runtime_execution_epoch" => "9",
        "runtime_verified_host_epoch" => "9"
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload-#{suffix}",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        template_key: "external.#{provider}",
        capability_requirements: ["runtime_exec"],
        generation: 1
      })

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "runtime-#{suffix}",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "9"
      })

    {:ok, runtime} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "9")

    Repo.insert!(%AgentVMM.Session{
      id: "session-#{suffix}",
      registration_id: registration.id,
      runtime_instance_id: runtime.id,
      allocation_id: allocation.id,
      allocation_generation: allocation.generation,
      connection_epoch: "9",
      gateway_instance_id: "gateway",
      status: "ready",
      expires_at: DateTime.add(DateTime.utc_now(), 720, :second),
      updated_at: DateTime.utc_now()
    })

    workload
  end

  defp input_begin do
    %{
      "action" => "input_begin",
      "target" => %{"kind" => "compute_workload", "workload_id" => "missing"},
      "backend" => "openai",
      "form" => "codex_auth_file"
    }
  end

  defp request(ctx, user, body) do
    :post
    |> build_conn(
      "/dashboard/orgs/#{ctx.org.slug}/projects/#{ctx.project.slug}/runtime-auth",
      Jason.encode!(body)
    )
    |> log_in_user(user)
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> DashboardEndpoint.call([])
  end

  defp dashboard_request(method, path, user, body \\ nil) do
    conn =
      if body,
        do: build_conn(method, path, Jason.encode!(body)),
        else: build_conn(method, path)

    conn
    |> log_in_user(user)
    |> put_req_header(
      "accept",
      if(body || String.starts_with?(path, "/dashboard/"),
        do: "application/json",
        else: "text/html"
      )
    )
    |> then(fn conn ->
      if body, do: put_req_header(conn, "content-type", "application/json"), else: conn
    end)
    |> DashboardEndpoint.call([])
  end
end
