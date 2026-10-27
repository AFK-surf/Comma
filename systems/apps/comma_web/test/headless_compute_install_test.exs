defmodule CommaWeb.HeadlessComputeInstallTest do
  use SystemsClock.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias SalixStore.{AgentVMMInstallations, Repo}
  alias SalixStore.AgentVMMInstallations.{Headless, Operation}

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:multi_connection)
    previous = SystemsRuntime.get_env(:salix_web, :public_base_url)
    SystemsRuntime.put_env(:salix_web, :public_base_url, "https://api.example.test")

    Repo.query!(
      "TRUNCATE agent_vmm_install_operations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_web, :public_base_url, previous)
      CommaWeb.TestRepoSandbox.stop_owner(owner)
    end)

    suffix = SystemsRuntime.Proc.uuid()
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "headless-#{suffix}@example.test"})
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    workspace =
      Comma.Repo.insert!(%Comma.Data.Workspace{
        id: "wsp_#{suffix}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "1",
        salix_router_agent_id: SalixStore.Ids.new_agent_id(group),
        salix_worker_agent_id: SalixStore.Ids.new_agent_id(group),
        billing_owner_id: "billing-#{suffix}",
        name: "Linux",
        status: "active"
      })

    Comma.Repo.insert!(%Comma.Data.WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    %{user: user, session: session, workspace: workspace}
  end

  test "unavailable delivery creates no operation or environment", ctx do
    # This local test server has no release artifacts. A bad origin must also fail before request.
    for origin <- ["https://api.example.test", "http://untrusted.example.test"] do
      SystemsRuntime.put_env(:salix_web, :public_base_url, origin)

      response =
        conn(
          :post,
          "/v1/comma/workspaces/#{ctx.workspace.id}/compute-nodes/agent-vmm/install-commands",
          "{}"
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> ctx.session["token"])
        |> put_req_header("idempotency-key", "unavailable")
        |> CommaWeb.Router.call(CommaWeb.Router.init([]))

      assert response.status == 503, response.resp_body
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert Repo.aggregate(Operation, :count) == 0
      assert Repo.aggregate(SalixStore.Compute.Environment, :count) == 0
    end
  end

  test "headless delivery fixes the current principal and Group while preserving multiple Hosts",
       ctx do
    attrs = %{
      "request_id" => "linux-first",
      "group_id" => "foreign",
      "delivery_target_id" => "foreign"
    }

    assert {:ok, first} =
             Comma.Compute.request_agent_vmm_headless_install(
               ctx.user,
               ctx.session,
               ctx.workspace.id,
               attrs
             )

    persisted = Repo.get!(Operation, first.operation.id)
    assert persisted.group_id == ctx.workspace.salix_group_id
    assert persisted.delivery_target_type == "headless"
    assert persisted.delivery_target_id == ctx.session["id"]
    assert persisted.authorizing_subject_id == ctx.user["id"]

    assert {:error, :no_pending_operation} =
             AgentVMMInstallations.deliver_next("comma_main_device", ctx.session["id"])

    assert {:ok, replay} =
             Comma.Compute.request_agent_vmm_headless_install(
               ctx.user,
               ctx.session,
               ctx.workspace.id,
               attrs
             )

    assert replay.operation.id == first.operation.id
    assert replay.operation.environment_id == first.operation.environment_id

    assert {:ok, second} =
             Comma.Compute.request_agent_vmm_headless_install(
               ctx.user,
               ctx.session,
               ctx.workspace.id,
               %{"request_id" => "linux-second"}
             )

    refute second.operation.id == first.operation.id
    assert Repo.aggregate(Operation, :count) == 2

    assert {:ok, command} = Headless.command(replay, "https://api.example.test")
    assert command.expires_at == DateTime.to_iso8601(replay.expires_at)
    assert command.operation.id == first.operation.id
    refute Map.has_key?(command.operation, :one_time_secret)

    {:ok, outsider} =
      Comma.Accounts.create_user(%{"email" => "outside-#{ctx.workspace.id}@example.test"})

    {:ok, outsider_session} = Comma.Accounts.create_session(outsider["id"])

    assert {:error, _} =
             Comma.Compute.request_agent_vmm_headless_install(
               outsider,
               outsider_session,
               ctx.workspace.id,
               %{"request_id" => "denied"}
             )

    assert Repo.aggregate(Operation, :count) == 2
  end
end
