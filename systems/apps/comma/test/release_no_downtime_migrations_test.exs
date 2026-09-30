defmodule Comma.ReleaseNoDowntimeMigrationsTest do
  use ExUnit.Case, async: true

  @legacy_salix_versions [
    20_260_728_000_103,
    20_260_729_000_001,
    20_260_729_000_002
  ]
  @workflow_router_version 20_260_810_000_101
  @ordinary_online_cutoff 20_260_818_000_102
  @approved_incompatible_steps MapSet.new([
                                 "salix-20260827000101",
                                 "bridge-20260827000002",
                                 "salix-20260910140000",
                                 "salix-20260910140001",
                                 "comma-20260912000001",
                                 "salix-20260915183001",
                                 "salix-20260916000100",
                                 "salix-20260918090000",
                                 "salix-20260921090000",
                                 "salix-20260924000101",
                                 "comma-20260918000000"
                               ])
  @recertification_versions [20_260_910_140_001, 20_260_915_183_001]

  test "new ordinary release migrations remain rolling-compatible" do
    violating_steps =
      Comma.ReleaseManifestV2.manifest()["steps"]
      |> Enum.filter(fn step ->
        step["version"] >= @ordinary_online_cutoff and
          not MapSet.member?(@approved_incompatible_steps, step["id"]) and
          step["source"] != "historical-ledger-only" and
          (step["phase"] not in ["expand", "local_seed"] or
             Enum.any?(step["compatibility"], fn {_fact, compatible?} -> not compatible? end))
      end)
      |> Enum.map(& &1["id"])

    assert violating_steps == []
  end

  # {name, owner, version, expected release mode, step checks}. A `true` check
  # must be truthy, `false` falsy, and any other value equal.
  @incompatible_step_cases [
    {"Task graph retirement requires exclusive cutover and retained-data backup", :salix,
     20_260_924_000_101, "exclusive",
     [
       {["phase"], "exclusive"},
       {["safety", "backupRequired"], true},
       {["compatibility", "oldRuntimeRead"], false},
       {["compatibility", "oldRuntimeWrite"], false}
     ]},
    {"on-demand workload storage cutover requires the exclusive release path", :salix,
     20_260_910_140_000, "exclusive",
     [
       {["phase"], "exclusive"},
       {["safety", "destructive"], true},
       {["safety", "backupRequired"], true}
     ]},
    {"run capacity queue removal uses rolling release with command backup evidence", :salix,
     20_260_916_000_100, "online",
     [
       {["safety", "backupRequired"], true},
       {["compatibility", "oldRuntimeRead"], false},
       {["compatibility", "oldRuntimeWrite"], false}
     ]},
    {"disposable Loop grants are removed online without classifying retained Loop rows as destructive",
     :salix, 20_260_918_090_000, "online",
     [
       {["compatibility", "oldRuntimeRead"], false},
       {["compatibility", "oldRuntimeWrite"], false},
       {["safety", "destructive"], false},
       {["safety", "backupRequired"], false},
       {["execution", "transactional"], true}
     ]},
    {"allocation authority replaces disposable lease projections online", :salix,
     20_260_921_090_000, "online",
     [
       {["compatibility", "oldRuntimeRead"], false},
       {["compatibility", "oldRuntimeWrite"], false},
       {["safety", "destructive"], false},
       {["safety", "backupRequired"], false},
       {["execution", "transactional"], true}
     ]},
    {"Routine generation cutover requires writer fencing and backup evidence", :comma,
     20_260_912_000_001, "exclusive",
     [
       {["phase"], "exclusive"},
       {["execution", "transactional"], true},
       {["compatibility", "oldRuntimeWrite"], false},
       {["safety", "destructive"], false},
       {["safety", "backupRequired"], true},
       {["safety", "rollbackStrategy"], "none"}
     ]}
  ]

  for {name, owner, version, mode, checks} <- @incompatible_step_cases do
    test name do
      owner = unquote(owner)
      version = unquote(version)
      current = facts()

      assert {:ok, plan} =
               Comma.ReleasePlan.plan(
                 facts: fn ->
                   facts(%{owner => set_status(Map.fetch!(current, owner), version, :down)})
                 end
               )

      assert plan.requiredMode == unquote(mode)
      assert [step] = plan.pendingSteps
      assert step["id"] == "#{owner}-#{version}"

      for {path, expected} <- unquote(Macro.escape(checks)) do
        actual = get_in(step, path)

        case expected do
          true -> assert actual, "expected #{inspect(path)} to be truthy"
          false -> refute actual, "expected #{inspect(path)} to be falsy"
          value -> assert actual == value
        end
      end
    end
  end

  test "recovery projection recertification requires an exclusive, non-destructive release" do
    current = facts()

    for version <- @recertification_versions do
      assert {:ok, plan} =
               Comma.ReleasePlan.plan(
                 facts: fn -> facts(%{salix: set_status(current.salix, version, :down)}) end
               )

      assert plan.requiredMode == "exclusive"
      assert [step] = plan.pendingSteps
      assert step["version"] == version
      assert step["phase"] == "exclusive"
      refute step["execution"]["transactional"]
      assert step["execution"]["idempotent"]
      refute step["safety"]["destructive"]
      refute step["safety"]["backupRequired"]
    end
  end

  test "meeting projection sealing is a later rolling-compatible release" do
    refute Enum.any?(
             Comma.ReleaseManifestV2.manifest()["steps"],
             &(&1["id"] == "salix-20260820000102")
           )

    step =
      Enum.find(
        Comma.ReleaseManifestV2.manifest()["steps"],
        &(&1["id"] == "salix-20260831000101")
      )

    assert step["phase"] == "expand"
    assert Enum.all?(step["compatibility"], fn {_fact, compatible?} -> compatible? end)
    assert step["execution"]["idempotent"]
    refute step["execution"]["transactional"]
    refute step["safety"]["destructive"]
    refute step["safety"]["backupRequired"]

    assert step["source"] ==
             "systems/apps/salix_store/priv/repo/migrations/20260831000101_backfill_meeting_group_projection.exs"
  end

  test "direct Slack Triage provenance expands the subscription schema online" do
    step =
      Enum.find(
        Comma.ReleaseManifestV2.manifest()["steps"],
        &(&1["id"] == "salix-20260901000101")
      )

    assert step["phase"] == "expand"
    assert Enum.all?(step["compatibility"], fn {_fact, compatible?} -> compatible? end)
    assert step["execution"]["transactional"]
    refute step["safety"]["destructive"]
    refute step["safety"]["backupRequired"]

    assert step["source"] ==
             "systems/apps/salix_store/priv/repo/migrations/20260901000101_add_slack_triage_provider_message_ref.exs"
  end

  test "published Salix compatibility migrations never select the zero-replica release path" do
    current = facts()

    for version <- @legacy_salix_versions do
      assert {:ok, plan} =
               Comma.ReleasePlan.plan(
                 facts: fn ->
                   facts(%{salix: set_status(current.salix, version, :down)})
                 end
               )

      assert plan.requiredMode == "blocked_legacy"
      assert [%{"phase" => "legacy"}] = plan.pendingSteps
    end

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   salix: set_status(current.salix, @workflow_router_version, :down)
                 })
               end
             )

    assert plan.requiredMode == "online"
    assert [%{"phase" => "expand"}] = plan.pendingSteps
  end

  test "a stale cutover invocation cannot execute a pending legacy step" do
    current = facts()
    [version | _] = @legacy_salix_versions

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{salix: set_status(current.salix, version, :down)})
               end
             )

    parent = self()

    assert_raise RuntimeError, fn ->
      Comma.Release.execute_plan_stage(
        "cutover",
        plan.manifestDigest,
        plan.pendingIDs,
        plan: fn -> plan end,
        cutover_executor: fn ids ->
          send(parent, {:cutover_executed, ids})
          :ok
        end
      )
    end

    refute_received {:cutover_executed, _ids}
  end

  test "a stale cutover invocation cannot rerun an already-applied legacy step" do
    assert {:ok, plan} = Comma.ReleasePlan.plan(facts: fn -> facts() end)
    parent = self()

    assert_raise RuntimeError, fn ->
      Comma.Release.execute_plan_stage(
        "cutover",
        plan.manifestDigest,
        ["salix-20260728000103"],
        plan: fn -> plan end,
        cutover_executor: fn ids ->
          send(parent, {:stale_cutover_executed, ids})
          :ok
        end
      )
    end

    refute_received {:stale_cutover_executed, _ids}
  end

  test "a pending legacy step blocks every stage executor" do
    [legacy_version | _] = @legacy_salix_versions

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 current = facts()

                 facts(%{
                   salix:
                     current.salix
                     |> set_status(legacy_version, :down)
                     |> set_status(@workflow_router_version, :down)
                 })
               end
             )

    assert plan.requiredMode == "blocked_legacy"
    parent = self()

    assert_raise RuntimeError, fn ->
      Comma.Release.execute_plan_stage(
        "online",
        plan.manifestDigest,
        ["salix-20260810000101"],
        plan: fn -> plan end,
        online_executor: fn ids ->
          send(parent, {:online_executed_while_legacy_pending, ids})
          :ok
        end
      )
    end

    refute_received {:online_executed_while_legacy_pending, _ids}
  end

  test "a pending legacy step also blocks the provider stage executor" do
    [legacy_version | _] = @legacy_salix_versions

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 current = facts()

                 facts(%{
                   salix: set_status(current.salix, legacy_version, :down),
                   require_provider: true
                 })
               end
             )

    assert plan.requiredMode == "blocked_legacy"
    assert plan.providerPendingIDs == ["billing-provider", "comma-signup-credits"]
    parent = self()

    assert_raise RuntimeError, fn ->
      Comma.Release.execute_plan_stage(
        "provider",
        plan.manifestDigest,
        plan.providerPendingIDs,
        plan: fn -> plan end,
        provider_executor: fn ->
          send(parent, :provider_executed_while_legacy_pending)
          :ok
        end
      )
    end

    refute_received :provider_executed_while_legacy_pending
  end

  test "the audited legacy-upgrade executor requires its dedicated carrier" do
    plan = legacy_upgrade_plan()
    parent = self()

    assert_raise RuntimeError,
                 "legacy upgrade execution requires the audited upgrade carrier",
                 fn ->
                   Comma.Release.execute_legacy_upgrade_stage(
                     "cutover",
                     plan.manifestDigest,
                     plan.pendingIDs,
                     plan: fn -> plan end,
                     legacy_upgrade_authorized: false,
                     cutover_executor: fn ids ->
                       send(parent, {:unauthorized_legacy_upgrade_executed, ids})
                       :ok
                     end
                   )
                 end

    refute_received {:unauthorized_legacy_upgrade_executed, _ids}
  end

  test "the audited legacy-upgrade executor runs only the three reserved migrations" do
    plan = legacy_upgrade_plan()
    parent = self()
    {:ok, converged?} = Agent.start_link(fn -> false end)

    plan_fun = fn ->
      if Agent.get(converged?, & &1), do: %{plan | pendingSteps: []}, else: plan
    end

    assert :ok =
             Comma.Release.execute_legacy_upgrade_stage(
               "cutover",
               plan.manifestDigest,
               plan.pendingIDs,
               plan: plan_fun,
               legacy_upgrade_authorized: true,
               cutover_executor: fn ids ->
                 Agent.update(converged?, fn _ -> true end)
                 send(parent, {:legacy_upgrade_executed, ids})
                 :ok
               end
             )

    assert_received {:legacy_upgrade_executed,
                     [
                       "salix-20260728000103",
                       "salix-20260729000001",
                       "salix-20260729000002"
                     ]}
  end

  test "the audited legacy-upgrade executor rejects an unreserved legacy migration" do
    plan = legacy_upgrade_plan()

    unsafe_plan =
      Map.update!(plan, :pendingSteps, fn steps ->
        steps ++ [%{"id" => "salix-unaudited", "phase" => "legacy"}]
      end)

    assert_raise RuntimeError, "legacy upgrade plan contains an unaudited legacy step", fn ->
      Comma.Release.execute_legacy_upgrade_stage(
        "cutover",
        unsafe_plan.manifestDigest,
        unsafe_plan.pendingIDs,
        plan: fn -> unsafe_plan end,
        legacy_upgrade_authorized: true
      )
    end
  end

  defp facts(overrides \\ %{}) do
    steps = Comma.ReleaseManifestV2.manifest()["steps"]

    clickhouse_manifest =
      SalixAnalytics.Migrations.migrations()
      |> Map.new(&{&1.version, &1.checksum})

    ecto_facts = fn owner ->
      steps
      |> Enum.filter(
        &(&1["owner"] == owner and &1["store"] == "postgres" and
            &1["source"] != "historical-ledger-only")
      )
      |> Enum.map(&{:up, &1["version"], &1["id"]})
    end

    Map.merge(
      %{
        comma: ecto_facts.("comma_core"),
        billing: ecto_facts.("billing_core"),
        bridge: ecto_facts.("bridge_for_teams"),
        salix: ecto_facts.("salix_store"),
        alert_router: ecto_facts.("alert_router"),
        clickhouse: {:ok, %{manifest: clickhouse_manifest, pending: []}},
        catalog_digest: "catalog",
        catalog_current: true,
        require_provider: false
      },
      overrides
    )
  end

  defp set_status(facts, version, status) do
    Enum.map(facts, fn
      {_old_status, ^version, name} -> {status, version, name}
      fact -> fact
    end)
  end

  defp legacy_upgrade_plan do
    current = facts()

    salix =
      Enum.reduce(@legacy_salix_versions, current.salix, fn version, migration_facts ->
        set_status(migration_facts, version, :down)
      end)

    assert {:ok, plan} = Comma.ReleasePlan.plan(facts: fn -> facts(%{salix: salix}) end)
    assert plan.requiredMode == "blocked_legacy"
    plan
  end
end
