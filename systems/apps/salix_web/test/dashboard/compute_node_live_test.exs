defmodule SalixWeb.Dashboard.ComputeNodeLiveTest do
  use ExUnit.Case, async: false

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

  test "fleet and detail render tenant-scoped observations", %{
    registration: registration
  } do
    {:ok, _index, html} = live(authed_conn("tenant-a"), "/dash/compute-nodes")

    assert html =~ "Compute Nodes"
    assert html =~ "node-a"
    assert html =~ "not_reported"

    {:ok, _show, detail} =
      live(authed_conn("tenant-a"), "/dash/compute-nodes/#{registration.id}")

    assert detail =~ "Overview"
    assert detail =~ "Workloads"
    assert detail =~ "Operations"
    assert detail =~ "Activity"
    assert detail =~ "Not requested"
    refute detail =~ "Enable"
    refute detail =~ "Disable"
    refute detail =~ "Revoke"
  end

  test "admin creates a Shell from the node workload tab and cannot target another environment",
       %{registration: registration} do
    previous = Application.get_env(:salix_store, :runtime_bundle_root)

    Application.put_env(
      :salix_store,
      :runtime_bundle_root,
      Path.expand("../../../salix_store/test/fixtures/runtime-bundle", __DIR__)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :runtime_bundle_root, previous),
        else: Application.delete_env(:salix_store, :runtime_bundle_root)
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
      updated_at: DateTime.utc_now()
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

  test "detail overview mounts and the workloads tab renders reconcile error bytes", %{
    registration: registration
  } do
    now = DateTime.utc_now()
    millis = DateTime.to_unix(now, :millisecond)

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-a", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => [],
               "observation" => %{
                 "sequence" => "1",
                 "observedUnixMillis" => Integer.to_string(millis),
                 "protocolVersion" => "1",
                 "hostApiVersion" => "host.v1",
                 "connectorRelease" => "test",
                 "supportedFeatures" => ["connection-epoch-v1"],
                 "capacity" => %{
                   "perEnvironmentLimits" => %{},
                   "maxEgressMode" => "EGRESS_MODE_DENY_ALL"
                 },
                 "health" => %{"status" => "healthy", "components" => []},
                 "usage" => %{"stale" => false},
                 "inventoryWatermark" => "0",
                 "inventoryObservedUnixMillis" => Integer.to_string(millis)
               }
             })

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool-a",
        tenant_id: "tenant-a",
        name: "pool-a",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]}
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "environment-a",
        tenant_id: "tenant-a",
        owner_type: "project",
        owner_id: "project-a",
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding-a",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        generation: 1
      })

    Repo.update_all(
      from(b in Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [status: "available"]
    )

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation-a",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload-a",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "shell",
        template_key: "shell.default",
        generation: 1
      })

    Repo.insert!(%Compute.ReconcilerClaim{
      id: "agent_vmm:#{workload.id}:1",
      provider: "agent_vmm",
      workload_id: workload.id,
      generation: 1,
      claim_token: "ui-test",
      attempt_count: 1,
      last_error: %{
        "kind" => "provider_error",
        "code" => "resource_capacity_exhausted",
        "stage" => "import_admission",
        "resource" => "storage_headroom",
        "message" => "Guest storage headroom is unavailable.",
        "available_bytes" => 0,
        "required_bytes" => 2_147_483_648
      },
      created_at: now,
      updated_at: now
    })

    {:ok, _overview, _html} =
      live(authed_conn("tenant-a"), "/dash/compute-nodes/#{registration.id}")

    {:ok, _workloads, workloads} =
      live(authed_conn("tenant-a"), "/dash/compute-nodes/#{registration.id}?tab=workloads")

    assert workloads =~ "code=resource_capacity_exhausted"
    assert workloads =~ "available_bytes=0"
    assert workloads =~ "required_bytes=2147483648"
  end

  test "fleet cursor is signed, tenant bound, and filter bound" do
    cursor = %{
      "rank" => 1,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
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

  test "detail tabs expose signed pagination instead of truncating activity", %{
    registration: registration
  } do
    now = DateTime.utc_now()

    rows =
      for offset <- 1..51 do
        %{
          tenant_id: "tenant-a",
          subject_type: "registration",
          subject_id: registration.id,
          action: "connection_observed",
          outcome: "succeeded",
          metadata: %{"private" => "not projected"},
          created_at: DateTime.add(now, -offset, :second)
        }
      end

    {51, _} = Repo.insert_all(AgentVMM.AuditEvent, rows)

    {:ok, view, html} =
      live(
        authed_conn("tenant-a"),
        "/dash/compute-nodes/#{registration.id}?tab=activity"
      )

    assert html =~ "Next page"
    assert has_element?(view, "a", "Next page")
    refute html =~ "not projected"
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
