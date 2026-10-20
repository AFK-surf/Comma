defmodule BridgeForTeamsWeb.RuntimeAuthControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  alias BridgeForTeams.Memberships
  alias BridgeForTeamsWeb.DashboardEndpoint

  defmodule ConnectedClient do
    def device_managed_auth_operation(_tenant, _group, _device, _runtime, :read, %{}) do
      {:ok,
       %{
         "source" =>
           SystemsRuntime.get_env(
             :bridge_for_teams_core,
             :runtime_auth_managed_source,
             "self_configured"
           )
       }}
    end

    def runtime_auth(operation, attrs) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:bridge_for_teams_core, :runtime_auth_http_test_pid),
        {:connected_auth_request, operation, attrs}
      )

      case operation do
        :input_submit -> {:error, :runtime_auth_submit_outcome_unknown}
        _other -> {:ok, %{"status" => "authenticated", "issue" => ""}}
      end
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
      "target" => input_begin()["target"],
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

  test "organization-managed authentication blocks private credential mutation", ctx do
    use_connected_client()
    SystemsRuntime.put_env(:bridge_for_teams_core, :runtime_auth_managed_source, "organization")

    on_exit(fn ->
      SystemsRuntime.delete_env(:bridge_for_teams_core, :runtime_auth_managed_source)
    end)

    conn = request(ctx, ctx.admin, input_begin())

    assert conn.status == 409
    assert get_in(Jason.decode!(conn.resp_body), ["error", "code"]) == "managed_auth_conflict"
    settle_refute_receive({:connected_auth_request, _, _})
  end

  test "a lost submit response stays unknown and is dispatched only once", ctx do
    use_connected_client()

    body = %{
      "action" => "input_submit",
      "target" => input_begin()["target"],
      "attempt_id" => "attempt",
      "envelope" => "synthetic-ciphertext"
    }

    conn = request(ctx, ctx.admin, body)
    assert conn.status == 200, conn.resp_body

    assert get_in(Jason.decode!(conn.resp_body), ["data", "runtime_auth", "save_result"]) ==
             "unknown"

    refute conn.resp_body =~ "synthetic-ciphertext"
    settle_receive({:connected_auth_request, :input_submit, _attrs})
    settle_refute_receive({:connected_auth_request, _, _})
  end

  test "connected administrator action derives its product scope from the authenticated project",
       ctx do
    use_connected_client()

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
    settle_receive({:connected_auth_request, :verify, attrs})

    assert attrs == %{
             actor_id: ctx.admin.id,
             tenant_id: ctx.org.salix_tenant_id,
             project_id: ctx.project.id,
             group_id: ctx.project.salix_group_id,
             device_id: "device",
             runtime_id: "runtime",
             backend: "openrouter"
           }

    assert request(ctx, ctx.admin, put_in(body, ["target", "provider"], "codex")).status == 400
    {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.admin.id, "member")
    {:ok, _} = Memberships.put_project_member(ctx.project.id, ctx.admin.id, "user")
    assert request(ctx, ctx.admin, body).status == 403
    settle_refute_receive({:connected_auth_request, _, _})
  end

  defp use_connected_client do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, ConnectedClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :runtime_auth_http_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)

      SystemsRuntime.delete_env(:bridge_for_teams_core, :runtime_auth_http_test_pid)
    end)
  end

  defp input_begin do
    %{
      "action" => "input_begin",
      "target" => %{
        "kind" => "connected_runtime",
        "device_id" => "device",
        "runtime_id" => "runtime"
      },
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
end
