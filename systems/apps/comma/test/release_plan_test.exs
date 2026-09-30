defmodule Comma.ReleasePlanTest do
  use ExUnit.Case, async: true

  defp facts(overrides \\ %{}) do
    steps = Comma.ReleaseManifestV2.manifest()["steps"]

    manifest =
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
        alert_router: ecto_facts.("alert_router"),
        comma: ecto_facts.("comma_core"),
        billing: ecto_facts.("billing_core"),
        bridge: ecto_facts.("bridge_for_teams"),
        salix: ecto_facts.("salix_store"),
        clickhouse: {:ok, %{manifest: manifest, pending: []}},
        catalog_digest: "catalog",
        catalog_current: true,
        require_provider: false
      },
      overrides
    )
  end

  test "plan is deterministic and current audited facts are online" do
    assert Comma.ReleasePlan.manifest_digest() == Comma.ReleasePlan.manifest_digest()

    assert {:ok, online} = Comma.ReleasePlan.plan(facts: fn -> facts() end)
    assert online.schemaVersion == 2
    assert online.requiredMode == "online"
    assert online.manifestDigest == Comma.ReleasePlan.manifest_digest()
    assert online.pendingIDs == []
    assert online.pendingSteps == []
    assert online.providerPendingIDs == []
  end

  test "unknown Ecto versions fail closed" do
    current = facts()

    assert {:error, {:unknown_ecto_versions, :billing, [20_991_231_000_001]}} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   billing: [{:up, 20_991_231_000_001, "unknown"} | current.billing]
                 })
               end
             )
  end

  test "model selection policy migration plans as an online expansion" do
    version = 20_260_924_000_000
    current = facts()

    comma =
      Enum.reject(current.comma, fn {_status, recorded_version, _name} ->
        recorded_version == version
      end)

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{comma: [{:down, version, "add_model_selection_policy"} | comma]})
               end
             )

    assert plan.requiredMode == "online"
    assert plan.pendingIDs == ["comma-20260924000000"]

    assert {:error, :automatic_down_forbidden} =
             Comma.ReleaseManifestV2.rollback_contract("comma-20260924000000")
  end

  test "SSH, Telegram, and iMessage identity migrations plan online and remain forward-only after application" do
    versions = [
      20_260_903_170_000,
      20_260_903_170_100,
      20_260_904_030_000,
      20_260_908_120_000,
      20_260_918_000_000
    ]

    ids = Enum.map(versions, &"comma-#{&1}")
    current = facts()

    other_comma =
      Enum.reject(current.comma, fn {_status, version, _name} -> version in versions end)

    pending = Enum.map(versions, &{:down, &1, "product-im-linking"})

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{comma: other_comma ++ pending}) end)

    assert plan.requiredMode == "online"
    assert plan.pendingIDs == ids

    for step <- plan.pendingSteps do
      assert step["phase"] == "expand"
      assert step["execution"]["transactional"]
      refute step["safety"]["destructive"]

      assert {:error, :automatic_down_forbidden} =
               Comma.ReleaseManifestV2.rollback_contract(step["id"])
    end

    applied = Enum.map(versions, &{:up, &1, "product-im-linking"})

    assert {:ok, complete} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{comma: other_comma ++ applied}) end)

    assert complete.requiredMode == "online"
    assert complete.pendingIDs == []
  end

  test "shared Postgres migration ledger accepts versions owned by every Ecto repo" do
    current = facts()

    shared_ledger =
      (current.comma ++ current.billing ++ current.bridge)
      |> Enum.uniq_by(fn {_status, version, _name} -> version end)

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   comma: shared_ledger,
                   billing: shared_ledger,
                   bridge: shared_ledger
                 })
               end
             )

    assert plan.requiredMode == "online"
    assert plan.pendingIDs == []
  end

  test "retired Loop grants plan online and their applied ledger is recognized" do
    version = 20_260_918_090_000
    id = "salix-#{version}"
    current = facts()
    other_salix = Enum.reject(current.salix, fn {_, v, _} -> v == version end)

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   salix: other_salix ++ [{:down, version, "drop_agent_loop_capabilities"}]
                 })
               end
             )

    assert plan.requiredMode == "online"
    assert plan.pendingIDs == [id]
    assert [step] = plan.pendingSteps
    refute step["compatibility"]["oldRuntimeRead"]
    refute step["compatibility"]["oldRuntimeWrite"]
    refute step["safety"]["backupRequired"]
    assert {:error, :automatic_down_forbidden} = Comma.ReleaseManifestV2.rollback_contract(id)

    assert {:ok, complete} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{salix: other_salix ++ [{:up, version, "drop_agent_loop_capabilities"}]})
               end
             )

    assert complete.requiredMode == "online"
    assert complete.pendingIDs == []
  end

  test "Admin Comma and Billing migrations keep distinct shared-ledger versions" do
    admin_steps =
      Comma.ReleaseManifestV2.manifest()["steps"]
      |> Enum.filter(fn step ->
        step["source"] in [
          "systems/apps/comma_core/priv/repo/migrations/20260725000002_add_comma_admin_control_plane.exs",
          "systems/apps/billing_core/priv/repo/migrations/20260725000001_add_admin_command_id_to_redeem_codes.exs"
        ]
      end)

    assert Enum.map(admin_steps, & &1["id"]) |> Enum.sort() == [
             "billing-20260725000001",
             "comma-20260725000002"
           ]

    assert admin_steps |> Enum.map(& &1["version"]) |> Enum.uniq() |> length() == 2
  end

  test "missing source-backed Ecto versions fail closed" do
    current = facts()
    [{_status, missing, _name} | remaining] = current.bridge

    assert {:error, {:missing_ecto_versions, :bridge, [^missing]}} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{bridge: remaining}) end)
  end

  test "the salix owner namespace is wired into the ledger validation" do
    # An empty salix ledger is missing the manifest's source-backed versions
    # and must fail closed like every other Postgres owner...
    assert {:error, {:missing_ecto_versions, :salix, missing}} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{salix: []}) end)

    assert 20_260_724_000_101 in missing

    # ...and versions unknown to the manifest fail closed too.
    current = facts()

    assert {:error, {:unknown_ecto_versions, :salix, [20_991_231_000_001]}} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{salix: [{:up, 20_991_231_000_001, "unknown"} | current.salix]})
               end
             )
  end

  test "the alert router owns an isolated migration ledger" do
    current = facts()

    expected_missing = Enum.map(current.alert_router, fn {:up, version, _} -> version end)

    assert {:error, {:missing_ecto_versions, :alert_router, ^expected_missing}} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{alert_router: []}) end)

    [{:up, foreign, _name} | _] = current.comma

    assert {:error, {:unknown_ecto_versions, :alert_router, [^foreign]}} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{alert_router: [{:up, foreign, "contaminated"} | current.alert_router]})
               end
             )
  end

  test "a release job that does not select alert router neither validates nor schedules it" do
    assert {:ok, plan} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{alert_router: :disabled}) end)

    assert plan.requiredMode == "online"
    refute Enum.any?(plan.pendingIDs, &String.starts_with?(&1, "alert-router-"))
  end

  test "a selected alert router schedules its down migration" do
    current = facts()

    [{:up, version, name} | applied] = Enum.reverse(current.alert_router)
    pending = [{:down, version, name} | applied]

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{alert_router: pending}) end)

    assert plan.requiredMode == "online"
    assert plan.pendingIDs == [name]
  end

  test "the isolated salix ledger rejects versions owned by the shared trio" do
    # Comma/Billing/BFT share one physical ledger, so those owners tolerate each
    # other's versions. Salix keeps an isolated `salix_schema_migrations`
    # ledger: a known *billing* version showing up in salix facts is
    # contamination and must fail closed rather than pass the shared union.
    current = facts()
    [{:up, foreign, _name} | _] = current.billing

    assert {:error, {:unknown_ecto_versions, :salix, [^foreign]}} =
             Comma.ReleasePlan.plan(
               facts: fn -> facts(%{salix: [{:up, foreign, "contaminated"}]}) end
             )

    # The shared trio still tolerates cross-owner sightings of that version.
    assert {:ok, _plan} =
             Comma.ReleasePlan.plan(
               facts: fn -> facts(%{comma: current.comma ++ [{:up, foreign, "shared"}]}) end
             )
  end

  test "the audited staging-only Billing tombstone is accepted but never pending" do
    current = facts()

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   billing: [
                     {:up, 20_260_714_000_002, "historical_orphan"} | current.billing
                   ]
                 })
               end
             )

    refute "billing-20260714000002" in plan.pendingIDs
  end

  test "the MeetingPlan purge tombstone accepts staging-applied and production-absent ledgers" do
    version = 20_260_818_000_101
    id = "salix-20260818000101"
    current = facts()

    salix_without_tombstone =
      Enum.reject(current.salix, fn {_status, actual, _name} -> actual == version end)

    assert {:ok, staging} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   salix: [
                     {:up, version, "historical_meeting_plan_purge"} | salix_without_tombstone
                   ]
                 })
               end
             )

    assert staging.requiredMode == "online"
    assert staging.pendingIDs == []
    refute id in staging.pendingIDs

    assert {:ok, production} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{salix: salix_without_tombstone}) end)

    assert production.requiredMode == "online"
    assert production.pendingIDs == []
    refute id in production.pendingIDs
  end

  test "local seed is pending only when the catalog projection differs" do
    assert {:ok, current} = Comma.ReleasePlan.plan(facts: fn -> facts() end)
    refute "comma-local-seed" in current.pendingIDs

    assert {:ok, stale} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{catalog_current: false}) end)

    assert stale.requiredMode == "online"
    assert stale.pendingIDs == ["comma-local-seed"]

    assert [
             %{
               "id" => "comma-local-seed",
               "phase" => "local_seed",
               "checksum" => "comma-local-seed-v1"
             }
           ] =
             stale.pendingSteps
  end

  test "ClickHouse checksum drift fails closed" do
    assert {:error, {:clickhouse_manifest_or_checksum_drift, %{1 => "bad"}}} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{clickhouse: {:ok, %{manifest: %{1 => "bad"}, pending: []}}})
               end
             )
  end

  test "unknown ClickHouse pending versions fail closed" do
    current = facts()

    assert {:error, {:unknown_clickhouse_pending_versions, [20_991_231_000_001]}} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   clickhouse:
                     {:ok,
                      %{
                        manifest: current.clickhouse |> elem(1) |> Map.fetch!(:manifest),
                        pending: [20_991_231_000_001]
                      }}
                 })
               end
             )
  end

  test "provider sync remains independent from release mode" do
    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{require_provider: true})
               end
             )

    assert plan.requiredMode == "online"
    assert plan.pendingIDs == []
    assert plan.pendingSteps == []
    assert plan.providerPendingIDs == ["billing-provider"]
  end

  test "contract steps are deferred outside ordinary release plans" do
    current = facts()

    assert {:ok, online} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   bridge: set_status(current.bridge, 20_260_827_000_002, :down),
                   salix: set_status(current.salix, 20_260_827_000_101, :down)
                 })
               end
             )

    assert online.requiredMode == "online"
    assert online.pendingIDs == []
    assert online.pendingSteps == []
  end

  test "required mode is derived from executable V2 phase, not legacy type" do
    current = facts()

    assert {:ok, exclusive} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   bridge: set_status(current.bridge, 20_260_711_000_001, :down)
                 })
               end
             )

    assert exclusive.requiredMode == "exclusive"
    assert exclusive.pendingIDs == ["bridge-20260711000001"]
    assert [%{"phase" => "exclusive"}] = exclusive.pendingSteps
  end

  test "strategy-v3 recertification remains pending after the legacy cutover is ledger-up" do
    current = facts()

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   salix: set_status(current.salix, 20_260_806_000_103, :down)
                 })
               end
             )

    assert plan.requiredMode == "exclusive"
    assert plan.pendingIDs == ["salix-20260806000103"]
    assert [%{"phase" => "exclusive"}] = plan.pendingSteps
  end

  test "external Session Activity revision cutover requires an exclusive release" do
    current = facts()

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 facts(%{
                   salix: set_status(current.salix, 20_260_807_000_101, :down)
                 })
               end
             )

    assert plan.requiredMode == "exclusive"
    assert plan.pendingIDs == ["salix-20260807000101"]
    assert [%{"phase" => "exclusive"}] = plan.pendingSteps
  end

  test "collision repair blocks dependent Comma steps on the first release" do
    current = facts()

    comma =
      current.comma
      |> set_status(20_260_723_000_007, :down)
      |> set_status(20_260_723_000_008, :down)
      |> set_status(20_260_723_000_009, :down)
      |> set_status(20_260_723_000_010, :down)
      |> set_status(20_260_723_000_014, :down)

    bridge =
      current.bridge
      |> set_status(20_260_723_000_012, :down)
      |> set_status(20_260_723_000_013, :down)

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(facts: fn -> facts(%{comma: comma, bridge: bridge}) end)

    assert plan.requiredMode == "online"

    assert plan.pendingIDs == [
             "bridge-20260723000012",
             "bridge-20260723000013",
             "comma-20260723000014",
             "comma-20260723000007",
             "comma-20260723000008",
             "comma-20260723000009",
             "comma-20260723000010"
           ]
  end

  test "a new release replans Comma 2 before repair and dependent steps" do
    current = facts()

    comma =
      current.comma
      |> set_status(20_260_723_000_002, :down)
      |> set_status(20_260_723_000_003, :down)
      |> set_status(20_260_723_000_007, :down)
      |> set_status(20_260_723_000_008, :down)
      |> set_status(20_260_723_000_009, :down)
      |> set_status(20_260_723_000_010, :down)
      |> set_status(20_260_723_000_014, :down)

    assert {:ok, plan} = Comma.ReleasePlan.plan(facts: fn -> facts(%{comma: comma}) end)
    assert plan.requiredMode == "exclusive"

    assert plan.pendingIDs == [
             "comma-20260723000002",
             "comma-20260723000014",
             "comma-20260723000003",
             "comma-20260723000007",
             "comma-20260723000008",
             "comma-20260723000009",
             "comma-20260723000010"
           ]
  end

  defp set_status(facts, version, status) do
    Enum.map(facts, fn
      {_old_status, ^version, name} -> {status, version, name}
      fact -> fact
    end)
  end
end
