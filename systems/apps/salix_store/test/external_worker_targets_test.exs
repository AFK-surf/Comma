defmodule SalixStore.ExternalWorkerTargetsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SalixStore.{Compute, ExternalWorkerTargets, Repo}

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_sessions, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    :ok
  end

  test "page and exact validation cannot cross project or registration group" do
    project_a = fixture("a", "project-a", "group-a", "codex")
    project_b = fixture("b", "project-b", "group-a", "codex")
    wrong_group = fixture("c", "project-c", "group-b", "codex")

    assert {:ok, %{items: [item], next_cursor: nil}} =
             ExternalWorkerTargets.page(scope("project-a", "group-a", "codex"))

    assert item.workload_id == project_a.workload.id
    assert item.selectable
    assert item.reason == nil
    assert item.provider == "codex"

    assert Map.keys(item.selection_fence) |> Enum.sort() ==
             ~w(allocation_generation allocation_id environment_generation workload_generation)a

    assert {:ok, ^item} =
             ExternalWorkerTargets.validate(
               scope("project-a", "group-a", "codex"),
               project_a.workload.id,
               item.selection_fence
             )

    browser_fence = item.selection_fence |> Jason.encode!() |> Jason.decode!()

    assert {:ok, ^item} =
             ExternalWorkerTargets.validate(
               scope("project-a", "group-a", "codex"),
               project_a.workload.id,
               browser_fence
             )

    assert {:error, :scope_mismatch} =
             ExternalWorkerTargets.validate(
               scope("project-a", "group-a", "codex"),
               project_b.workload.id,
               item.selection_fence
             )

    assert {:error, :scope_mismatch} =
             ExternalWorkerTargets.validate_binding(
               scope("project-c", "group-a", "codex"),
               wrong_group.workload.id
             )

    assert {:ok, %{items: []}} =
             ExternalWorkerTargets.page(scope("project-c", "group-a", "codex"))
  end

  test "selection fence and finite readiness reason fail closed" do
    fixture = fixture("pi", "project", "group", "pi")

    assert {:ok, %{items: [ready]}} =
             ExternalWorkerTargets.page(scope("project", "group", "pi"))

    assert {:error, :selection_changed} =
             ExternalWorkerTargets.validate(
               scope("project", "group", "pi"),
               fixture.workload.id,
               %{
                 ready.selection_fence
                 | workload_generation: ready.selection_fence.workload_generation + 1
               }
             )

    Repo.update_all(Compute.RuntimeInstance, set: [readiness: "pending"])

    now = DateTime.utc_now()

    Repo.insert!(%Compute.ReconcilerClaim{
      id: "agent_vmm:#{fixture.workload.id}:#{fixture.workload.generation}",
      provider: "agent_vmm",
      workload_id: fixture.workload.id,
      generation: fixture.workload.generation,
      claim_token: "target-projection-test",
      attempt_count: 1,
      last_error: %{
        "kind" => "provider_error",
        "code" => "resource_capacity_exhausted",
        "stage" => "import_admission",
        "resource" => "storage_headroom",
        "message" => "Guest storage headroom is unavailable.",
        "available_bytes" => 1_073_741_824,
        "required_bytes" => 2_147_483_648,
        "private" => "projection-secret"
      },
      created_at: now,
      updated_at: now
    })

    assert {:ok,
            %{
              items: [
                %{
                  selectable: true,
                  reason: nil,
                  availability: "starting",
                  availability_issue: "runtime_not_ready",
                  reconcile_error: %{
                    "code" => "resource_capacity_exhausted",
                    "stage" => "import_admission",
                    "resource" => "storage_headroom",
                    "message" => "Guest storage headroom is unavailable.",
                    "available_bytes" => 1_073_741_824,
                    "required_bytes" => 2_147_483_648
                  }
                }
              ]
            }} =
             ExternalWorkerTargets.page(scope("project", "group", "pi"))

    assert {:error, :invalid_query} =
             ExternalWorkerTargets.page(scope("project", "group", "pi"),
               include_unavailable: "true"
             )
  end

  test "expired recovery remains automatically recoverable without hiding revoked access" do
    fixture = fixture("recovery", "project", "group", "codex")
    Repo.update_all(Compute.RuntimeInstance, set: [status: "disconnected", readiness: "pending"])
    now = DateTime.utc_now()

    Repo.insert!(%Compute.ReconcilerClaim{
      id: "agent_vmm:#{fixture.workload.id}:1",
      provider: "agent_vmm",
      workload_id: fixture.workload.id,
      generation: 1,
      claim_token: "legacy-expired",
      attempt_count: 2,
      created_at: now,
      updated_at: now,
      last_error: %{"kind" => "action_required", "code" => "runtime_recovery_expired"}
    })

    assert {:ok, %{items: [item]}} =
             ExternalWorkerTargets.page(scope("project", "group", "codex"))

    assert item.selectable
    assert item.availability == "starting"
    assert item.availability_issue == "runtime_recovery_expired"

    Repo.update_all(SalixStore.AgentVMM.Registration,
      set: [status: "revoked", desired_enabled: false]
    )

    assert {:ok, %{items: [revoked]}} =
             ExternalWorkerTargets.page(scope("project", "group", "codex"),
               include_unavailable: true
             )

    refute revoked.selectable
    refute revoked.availability == "starting"
  end

  test "a sleeping workload stays selectable and transient runtime changes keep its fence stable" do
    fixture = fixture("sleep", "project", "group", "codex")
    allocation = Repo.get!(Compute.Allocation, fixture.workload.allocation_id)

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation: %{
          "current_container" => %{
            "id" => "sleep-container",
            "instance_id" => "sleep-instance"
          },
          "container_status" => "stopped"
        },
        revision: allocation.revision + 1
      ]
    )

    assert {:ok, %{items: [sleeping]}} =
             ExternalWorkerTargets.page(scope("project", "group", "codex"))

    assert sleeping.selectable
    assert sleeping.reason == nil
    assert sleeping.availability == "sleeping"
    fence = sleeping.selection_fence

    Repo.update_all(Compute.RuntimeInstance,
      set: [status: "disconnected", readiness: "pending", connection_epoch: "2", revision: 9]
    )

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation: %{
          "current_container" => %{},
          "container_status" => "absent"
        },
        revision: allocation.revision + 2
      ]
    )

    assert {:ok, %{items: [changed]}} =
             ExternalWorkerTargets.page(scope("project", "group", "codex"))

    assert changed.selection_fence == fence
    assert changed.availability == "sleeping"

    assert {:ok, _} =
             ExternalWorkerTargets.validate(
               scope("project", "group", "codex"),
               fixture.workload.id,
               fence
             )
  end

  test "an empty unconfirmed container observation is not reported as sleeping" do
    fixture = fixture("unknown-container", "project", "group", "codex")
    allocation = Repo.get!(Compute.Allocation, fixture.workload.allocation_id)

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation: %{"current_container" => %{}},
        revision: allocation.revision + 1
      ]
    )

    assert {:ok, %{items: [target]}} =
             ExternalWorkerTargets.page(scope("project", "group", "codex"))

    assert target.selectable
    assert target.availability == "starting"
    assert target.availability_issue == nil
  end

  test "terminal workloads stay out of target discovery while active unavailable targets remain visible" do
    terminal = fixture("terminal", "project", "group", "codex")

    unavailable =
      SalixStore.TestSupport.ExternalWorkerTargetFixture.add_workload(
        terminal,
        "unavailable",
        "codex"
      )

    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^terminal.workload.id),
      set: [desired_state: "stopped"]
    )

    Repo.update_all(
      from(r in SalixStore.AgentVMM.Registration,
        where: r.id == ^terminal.registration.id
      ),
      set: [status: "revoked", desired_enabled: false]
    )

    assert {:ok,
            %{
              items: [
                %{
                  workload_id: unavailable_id,
                  selectable: false,
                  reason: "registration_unavailable"
                }
              ]
            }} =
             ExternalWorkerTargets.page(scope("project", "group", "codex"),
               include_unavailable: true
             )

    assert unavailable_id == unavailable.workload.id
  end

  test "provider and search are project-local, Claude is supported, and Kimi is not a Compute provider" do
    fixture("codex", "project", "group", "codex")
    fixture("pi", "pi-project", "group", "pi")
    fixture("claude", "claude-project", "group", "claude")

    assert {:ok, %{items: [%{provider: "codex"}]}} =
             ExternalWorkerTargets.page(scope("project", "group", "codex"),
               query: "codex-work"
             )

    assert {:ok, %{items: []}} =
             ExternalWorkerTargets.page(scope("project", "group", "codex"), query: "pi-work")

    assert {:ok, %{items: [%{provider: "claude", workload_id: "claude-workload"}]}} =
             ExternalWorkerTargets.page(scope("claude-project", "group", "claude"))

    assert {:error, :invalid_query} =
             ExternalWorkerTargets.page(scope("project", "group", "kimi"))
  end

  test "environment owner and workload keyset indexes support bounded page order" do
    target = fixture("plan", "project", "group", "codex")

    Repo.query!(
      """
      INSERT INTO compute_workloads
        (id, environment_id, allocation_id, kind, spec, template_key, runtime_revision,
         capability_requirements, desired_state, observed_state, generation, revision,
         created_at, updated_at)
      SELECT 'history-workload-' || n, $1, $2, 'external_worker', '{}'::jsonb,
             'external.codex', 'runtime-1', ARRAY[]::text[], 'ready', 'ready', 1, 1,
             now() - (n || ' seconds')::interval, now() - (n || ' seconds')::interval
      FROM generate_series(1, 5000) AS n
      """,
      [target.environment.id, target.workload.allocation_id]
    )

    Repo.query!("ANALYZE compute_workloads")

    # Pin the planner setting and its queries to one pooled connection. The
    # transaction also restores the setting before the connection is reused.
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL enable_seqscan = off")

      owner_plan =
        Repo.query!("""
        EXPLAIN (COSTS OFF)
        SELECT id FROM compute_environments
        WHERE tenant_id = 'tenant' AND owner_type = 'project' AND owner_id = 'project'
        """).rows
        |> List.flatten()
        |> Enum.join("\n")

      page_plan =
        Repo.query!(
          """
          EXPLAIN (COSTS OFF)
          SELECT id FROM compute_workloads
          WHERE environment_id = $1 AND desired_state = 'ready'
          ORDER BY updated_at DESC, id DESC
          LIMIT 51
          """,
          [target.environment.id]
        ).rows
        |> List.flatten()
        |> Enum.join("\n")

      assert owner_plan =~ "Index Scan"
      assert owner_plan =~ "tenant_id = 'tenant'"
      refute owner_plan =~ "Seq Scan"
      assert page_plan =~ "compute_workloads_environment_page_idx"

      analyzed =
        Repo.query!("""
        EXPLAIN (ANALYZE, COSTS OFF, FORMAT JSON)
        SELECT page.id
        FROM compute_environments e
        JOIN LATERAL (
          SELECT candidate.id, candidate.updated_at
          FROM compute_workloads candidate
          WHERE candidate.environment_id = e.id AND candidate.kind = 'external_worker'
            AND candidate.template_key = 'external.codex'
            AND candidate.desired_state = 'ready'
            AND EXISTS (
              SELECT 1
              FROM compute_allocations ca
              JOIN compute_provider_bindings cb
                ON cb.id = ca.provider_binding_id AND cb.environment_id = ca.environment_id
               AND cb.provider = 'agent_vmm'
              JOIN agent_vmm_registrations cr
                ON cr.id = cb.provider_ref AND cr.tenant_id = 'tenant' AND cr.group_id = 'group'
              WHERE ca.id = candidate.allocation_id
                AND ca.environment_id = candidate.environment_id
              LIMIT 1 OFFSET 0
            )
          ORDER BY candidate.updated_at DESC, candidate.id DESC
          LIMIT 51
        ) page ON true
        WHERE e.tenant_id = 'tenant' AND e.owner_type = 'project' AND e.owner_id = 'project'
        ORDER BY page.updated_at DESC, page.id DESC
        """).rows
        |> hd()
        |> hd()
        |> hd()
        |> Map.fetch!("Plan")
        |> flatten_plan()

      workload_scan =
        Enum.find(analyzed, fn node ->
          node["Index Name"] == "compute_workloads_environment_page_idx"
        end)

      assert workload_scan, inspect(analyzed, pretty: true)
      assert workload_scan["Actual Rows"] <= 51
      assert (workload_scan["Actual Rows Removed by Filter"] || 0) <= 51

      refute Enum.any?(
               analyzed,
               &(&1["Relation Name"] == "compute_workloads" and &1["Node Type"] == "Seq Scan")
             )
    end)
  end

  defp scope(project_id, group_id, provider) do
    %{
      tenant_id: "tenant",
      owner_type: "project",
      owner_id: project_id,
      group_id: group_id,
      provider: provider
    }
  end

  defp fixture(prefix, project_id, group_id, provider),
    do:
      SalixStore.TestSupport.ExternalWorkerTargetFixture.create(
        prefix,
        project_id,
        group_id,
        provider
      )

  defp flatten_plan(plan) do
    [plan | Enum.flat_map(plan["Plans"] || [], &flatten_plan/1)]
  end
end
