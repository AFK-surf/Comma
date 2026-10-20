defmodule SalixWeb.Dashboard.ComputeNodeLiveTest do
  use SystemsClock.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixStore.{AgentVMM, Compute, Repo}
  alias SalixWeb.AgentVMMAdminCursor

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    Repo.query!("""
    TRUNCATE agent_vmm_sessions, agent_vmm_audit_events, agent_vmm_install_operations,
      compute_commands, compute_runtime_instances, compute_workloads, compute_allocations,
      compute_provider_bindings, compute_environments, compute_pools,
      agent_vmm_registrations CASCADE
    """)

    registration = registration!("tenant-a", "registration-a", "node-a")
    %{registration: registration}
  end

  test "admin creates a Shell from the node workload tab and cannot target another environment",
       %{registration: registration} do
    previous = SystemsRuntime.get_env(:salix_store, :runtime_bundle_root)

    SystemsRuntime.put_env(
      :salix_store,
      :runtime_bundle_root,
      Path.expand("../../../salix_store/test/fixtures/runtime-bundle", __DIR__)
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :runtime_bundle_root, previous),
        else: SystemsRuntime.delete_env(:salix_store, :runtime_bundle_root)
    end)

    {:ok, pool} =
      Compute.create_pool(%{
        id: "shell-pool",
        tenant_id: "tenant-a",
        name: "shell",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "shell-environment",
        tenant_id: "tenant-a",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    Repo.insert!(%Compute.ProviderBinding{
      id: "shell-binding",
      pool_id: pool.id,
      environment_id: environment.id,
      provider: "agent_vmm",
      provider_ref: registration.id,
      status: "available",
      generation: 1,
      revision: 1,
      observation: %{},
      updated_at: SystemsClock.utc_now()
    })

    {:ok, view, _} =
      live(authed_conn("tenant-a"), "/dash/compute-nodes/#{registration.id}?tab=workloads")

    assert view |> element("button[phx-click=create_shell_workload]") |> render_click() =~
             "Shell workload accepted"

    assert Repo.aggregate(Compute.Workload, :count) == 1

    assert render_click(view, "create_shell_workload", %{"id" => "another-environment"}) =~
             "not_found"

    assert Repo.aggregate(Compute.Workload, :count) == 1
  end

  test "another tenant cannot open or list the node", %{registration: registration} do
    registration!("tenant-b", "registration-b", "node-b")

    {:ok, _index, html} = live(authed_conn("tenant-b"), "/dash/compute-nodes")
    assert html =~ "node-b"
    refute html =~ "node-a"

    assert {:error, {:live_redirect, %{to: "/dash/compute-nodes"}}} =
             live(authed_conn("tenant-b"), "/dash/compute-nodes/#{registration.id}")
  end

  test "fleet cursor is signed, tenant bound, and filter bound" do
    cursor = %{
      "rank" => 1,
      "updated_at" => SystemsClock.utc_now() |> DateTime.to_iso8601(),
      "id" => "registration-a"
    }

    assert {:ok, token} = AgentVMMAdminCursor.encode("tenant-a", cursor, %{"status" => "ready"})
    assert {:ok, ^cursor} = AgentVMMAdminCursor.decode(token, "tenant-a", %{"status" => "ready"})

    assert {:error, :invalid} =
             AgentVMMAdminCursor.decode(token, "tenant-b", %{"status" => "ready"})

    assert {:error, :invalid} = AgentVMMAdminCursor.decode(token, "tenant-a", %{})

    assert {:error, :invalid} =
             AgentVMMAdminCursor.decode(token <> "x", "tenant-a", %{"status" => "ready"})
  end

  test "requires the admin session" do
    conn = build_conn() |> Plug.Test.init_test_session(%{})
    assert {:error, {:redirect, %{to: "/dash/login"}}} = live(conn, "/dash/compute-nodes")
  end

  defp registration!(tenant_id, id, device_id) do
    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: id,
        tenant_id: tenant_id,
        group_id: "shared-group",
        device_id: device_id,
        enrollment_token: String.duplicate("s", 32)
      })

    {1, _} =
      Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^id),
        set: [status: "ready", desired_enabled: true, credential_hash: <<1, 2, 3>>]
      )

    %{registration | status: "ready", desired_enabled: true}
  end

  defp authed_conn(tenant_id) do
    build_conn()
    |> Plug.Test.init_test_session(%{
      "admin_authed" => true,
      "current_tenant" => tenant_id
    })
  end
end
