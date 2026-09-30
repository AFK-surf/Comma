defmodule Comma.ReleaseManifestV2Test do
  use ExUnit.Case, async: true

  alias Comma.ReleaseManifestV2, as: Manifest

  test "historical inventory is explicit, exact, and provider-free" do
    manifest = Manifest.manifest()
    assert :ok = Manifest.validate()
    assert manifest["schemaVersion"] == 2
    refute Enum.empty?(manifest["steps"])
    assert length(Enum.uniq_by(manifest["steps"], & &1["id"])) == length(manifest["steps"])
    refute Enum.any?(manifest["steps"], &String.contains?(&1["id"], "provider"))

    assert Enum.sort(Enum.map(manifest["steps"], & &1["id"])) ==
             Enum.sort(Enum.map(Manifest.source_inventory(), & &1["id"]))

    assert Manifest.manifest_digest() == Manifest.manifest_digest()
  end

  test "encoded manifest stores common policy once and expands it for consumers" do
    encoded =
      __DIR__
      |> Path.join("../priv/release/migration-manifest-v2.json")
      |> File.read!()
      |> :json.decode()

    defaults = encoded["stepDefaults"]
    first_encoded_step = hd(encoded["steps"])
    first_expanded_step = hd(Manifest.manifest()["steps"])

    assert defaults["phase"] == "expand"
    assert defaults["compatibility"]["oldRuntimeWrite"]
    refute Map.has_key?(first_encoded_step, "phase")
    refute Map.has_key?(first_encoded_step, "compatibility")
    assert first_expanded_step["phase"] == defaults["phase"]
    assert first_expanded_step["compatibility"] == defaults["compatibility"]
    assert first_expanded_step["execution"] == defaults["execution"]
    assert first_expanded_step["safety"] == defaults["safety"]
    assert first_expanded_step["repair"] == defaults["repair"]
  end

  test "Stripe billing lifecycle migration is registered as online and retry-safe" do
    step =
      Enum.find(
        Manifest.manifest()["steps"],
        &(&1["id"] == "billing-20260901000001")
      ) || flunk("billing-20260901000001 is missing from the release manifest")

    assert step["owner"] == "billing_core"
    assert step["store"] == "postgres"
    assert step["version"] == 20_260_901_000_001

    assert step["source"] ==
             "systems/apps/billing_core/priv/repo/migrations/20260901000001_complete_stripe_billing_lifecycle.exs"

    assert step["phase"] == "expand"

    assert step["compatibility"] == %{
             "oldRuntimeRead" => true,
             "oldRuntimeWrite" => true,
             "newRuntimeRead" => true,
             "newRuntimeWrite" => true
           }

    assert step["execution"] == %{
             "transactional" => false,
             "idempotent" => true,
             "timeoutSeconds" => 900,
             "lockBudgetSeconds" => 5
           }

    refute step["safety"]["destructive"]
    refute step["safety"]["backupRequired"]
    assert step["safety"]["rollbackStrategy"] == "none"
    assert step["postconditions"] != []
    assert step["repair"] == "preflight_then_concurrent_index_retry"
  end

  test "shared Postgres source versions add no collision beyond the audited legacy ledger" do
    duplicates =
      Manifest.source_inventory()
      |> Enum.filter(
        &(&1["store"] == "postgres" and String.starts_with?(&1["source"], "systems/"))
      )
      |> Enum.group_by(& &1["version"], & &1["id"])
      |> Enum.filter(fn {_version, ids} -> length(ids) > 1 end)
      |> Map.new(fn {version, ids} -> {version, Enum.sort(ids)} end)

    assert duplicates == %{
             20_260_617_000_001 => [
               "billing-20260617000001",
               "bridge-20260617000001"
             ],
             20_260_623_000_001 => [
               "billing-20260623000001",
               "bridge-20260623000001"
             ],
             20_260_710_000_001 => [
               "billing-20260710000001",
               "bridge-20260710000001"
             ]
           }
  end

  test "Comma-first convergence versions preserve strict cutover and Oban order" do
    steps =
      Manifest.manifest()["steps"]
      |> Enum.filter(&(&1["store"] == "postgres" and &1["version"] >= 20_260_723_000_001))

    assert Enum.find_index(steps, &(&1["id"] == "comma-20260723000003")) <
             Enum.find_index(steps, &(&1["id"] == "comma-20260723000004"))

    assert Enum.map(steps, & &1["version"]) ==
             Enum.uniq(Enum.map(steps, & &1["version"]))

    assert Enum.find(steps, &(&1["id"] == "comma-20260723000003"))["source"] ==
             "systems/apps/comma_core/priv/release_migrations/20260723000003_finalize_product_state_cutover.exs"

    assert Enum.find(steps, &(&1["id"] == "comma-20260723000004"))["source"] ==
             "systems/apps/comma_core/priv/repo/migrations/20260723000004_add_comma_durable_operations.exs"
  end

  test "recent product migrations are rolling-compatible expands" do
    steps =
      Manifest.manifest()["steps"]
      |> Map.new(&{&1["id"], &1})

    for id <- [
          "bridge-20260821000002",
          "salix-20260821000101",
          "salix-20260824000001",
          "salix-20260826000101",
          "salix-20260828000102",
          "salix-20260829000101",
          "salix-20260901000101",
          "salix-20260902000201",
          "salix-20260902009001",
          "salix-20260902009002",
          "salix-20260902009003",
          "salix-20260902009004",
          "salix-20260902009005",
          "salix-20260908000101",
          "salix-20260910000001",
          "salix-20260911000100",
          "bridge-20260826000001",
          "bridge-20260917000101"
        ] do
      step = Map.fetch!(steps, id)

      assert step["phase"] == "expand"

      assert step["compatibility"] == %{
               "oldRuntimeRead" => true,
               "oldRuntimeWrite" => true,
               "newRuntimeRead" => true,
               "newRuntimeWrite" => true
             }

      assert step["execution"]["transactional"]
      refute step["safety"]["destructive"]
    end

    assert "postgres.column/conversation_search_backfill_runs.retired_at=present-nullable" in steps[
             "salix-20260902000301"
           ]["postconditions"]

    for id <- [
          "salix-20260824000002",
          "salix-20260824000005",
          "salix-20260825000101",
          "salix-20260826000102",
          "salix-20260901000102",
          "salix-20260902000101",
          "bridge-20260902000001",
          "analytics-20260903000001",
          "analytics-20260905000001"
        ] do
      scoped_index = Map.fetch!(steps, id)

      assert scoped_index["phase"] == "expand"

      assert scoped_index["compatibility"] == %{
               "oldRuntimeRead" => true,
               "oldRuntimeWrite" => true,
               "newRuntimeRead" => true,
               "newRuntimeWrite" => true
             }

      refute scoped_index["execution"]["transactional"]
      assert scoped_index["execution"]["idempotent"]
      refute scoped_index["safety"]["destructive"]
    end

    legacy_index_contract = Map.fetch!(steps, "salix-20260824000003")

    # Release phase "contract" is reserved for explicit deferred execution.
    # This redundant-index removal is an online-compatible capability expand
    # after the compatible writer, scoped index, and closed gate are deployed.
    assert legacy_index_contract["phase"] == "expand"

    assert legacy_index_contract["compatibility"] == %{
             "oldRuntimeRead" => true,
             "oldRuntimeWrite" => true,
             "newRuntimeRead" => true,
             "newRuntimeWrite" => true
           }

    refute legacy_index_contract["execution"]["transactional"]
    assert legacy_index_contract["execution"]["idempotent"]
    refute legacy_index_contract["safety"]["destructive"]
  end

  test "Slack Router participation status migration has retryable schema postconditions" do
    step =
      Manifest.manifest()["steps"]
      |> Enum.find(&(&1["id"] == "salix-20260825000101"))

    assert step["execution"] == %{
             "transactional" => false,
             "idempotent" => true,
             "timeoutSeconds" => 300,
             "lockBudgetSeconds" => 5
           }

    assert step["postconditions"] == [
             "postgres.column/slack_router_thread_participations.participation_status=not-null-default-participating",
             "postgres.column/slack_router_thread_participations.status_expires_at=nullable-default-30-days",
             "postgres.constraint/slack_router_thread_participations_valid_status=present",
             "postgres.index/slack_router_thread_participations_status_expiry_idx=valid"
           ]

    assert step["repair"] == "drop_invalid_concurrent_index_then_retry_exact_version"
  end

  test "Triage record body-size migration is a bounded retryable expand" do
    step =
      Manifest.manifest()["steps"]
      |> Enum.find(&(&1["id"] == "salix-20260826000102"))

    assert step["execution"] == %{
             "transactional" => false,
             "idempotent" => true,
             "timeoutSeconds" => 900,
             "lockBudgetSeconds" => 5
           }

    assert step["compatibility"] == %{
             "oldRuntimeRead" => true,
             "oldRuntimeWrite" => true,
             "newRuntimeRead" => true,
             "newRuntimeWrite" => true
           }

    assert step["postconditions"] == [
             "postgres.table/triage_record_body_sizes=present-composite-key",
             "postgres.function/sync_triage_record_body_size=present",
             "postgres.triggers/triage-record-body-sizes=present-on-four-source-tables",
             "postgres.data/triage-record-body-sizes=complete-current-revision-and-bytes"
           ]

    assert step["repair"] == "retry_exact_version_idempotently_recompute_keyset_pages"
  end

  test "managed release catalog retirement is an explicit destructive contract" do
    step =
      Manifest.manifest()["steps"]
      |> Enum.find(&(&1["id"] == "salix-20260827000101"))

    assert step["phase"] == "contract"

    assert step["source"] ==
             "systems/apps/salix_store/priv/release_migrations/20260827000101_contract_managed_release_catalog.exs"

    assert step["compatibility"] == %{
             "oldRuntimeRead" => false,
             "oldRuntimeWrite" => false,
             "newRuntimeRead" => true,
             "newRuntimeWrite" => true
           }

    assert step["execution"] == %{
             "transactional" => true,
             "idempotent" => false,
             "timeoutSeconds" => 300,
             "lockBudgetSeconds" => 5
           }

    assert step["safety"] == %{
             "destructive" => true,
             "backupRequired" => true,
             "rollbackStrategy" => "none"
           }

    assert step["postconditions"] == [
             "postgres.column/agent_vmm_install_operations.host_component_release_id=absent",
             "postgres.column/agent_vmm_install_operations.platform=absent",
             "postgres.column/agent_vmm_install_operations.material_digest=absent",
             "postgres.table/active_release_catalogs=absent",
             "postgres.table/managed_release_catalog_components=absent",
             "postgres.table/managed_release_catalogs=absent",
             "postgres.table/managed_component_releases=absent"
           ]

    assert %{
             "before" => "salix-20260826000101",
             "after" => "salix-20260827000101"
           } in Manifest.manifest()["orderingConstraints"]
  end

  test "Bridge runner release refs retire as an explicit destructive contract" do
    step =
      Manifest.manifest()["steps"]
      |> Enum.find(&(&1["id"] == "bridge-20260827000002"))

    assert step["phase"] == "contract"

    assert step["source"] ==
             "systems/apps/bridge_for_teams_core/priv/release_migrations/20260827000002_contract_server_bound_release_refs.exs"

    assert step["compatibility"] == %{
             "oldRuntimeRead" => false,
             "oldRuntimeWrite" => false,
             "newRuntimeRead" => true,
             "newRuntimeWrite" => true
           }

    assert step["execution"] == %{
             "transactional" => true,
             "idempotent" => false,
             "timeoutSeconds" => 300,
             "lockBudgetSeconds" => 5
           }

    assert step["safety"] == %{
             "destructive" => true,
             "backupRequired" => true,
             "rollbackStrategy" => "none"
           }

    assert Enum.all?(step["postconditions"], &String.ends_with?(&1, "=absent"))
  end

  test "Slack Triage channel authority cutover is an idempotent rolling-compatible release step" do
    manifest = Manifest.manifest()
    step = Enum.find(manifest["steps"], &(&1["id"] == "salix-20260824000101"))

    assert step["source"] ==
             "systems/apps/salix_store/priv/release_migrations/20260824000101_slack_triage_channel_authority_cutover.exs"

    assert step["phase"] == "expand"

    assert step["compatibility"] == %{
             "oldRuntimeRead" => true,
             "oldRuntimeWrite" => true,
             "newRuntimeRead" => true,
             "newRuntimeWrite" => true
           }

    refute step["execution"]["transactional"]
    assert step["execution"]["idempotent"]
    refute step["safety"]["destructive"]

    assert Enum.all?(step["postconditions"], &String.starts_with?(&1, "postgres."))

    assert %{
             "before" => "salix-20260821000101",
             "after" => "salix-20260824000101"
           } in manifest["orderingConstraints"]
  end

  test "bounded Slack history and shared lifecycle migrations are rolling-compatible expands" do
    steps =
      Manifest.manifest()["steps"]
      |> Map.new(&{&1["id"], &1})

    for sequence <- 1..6 do
      id = "bridge-2026082500000#{sequence}"
      step = Map.fetch!(steps, id)

      assert step["phase"] == "expand"

      assert step["compatibility"] == %{
               "oldRuntimeRead" => true,
               "oldRuntimeWrite" => true,
               "newRuntimeRead" => true,
               "newRuntimeWrite" => true
             }

      assert step["execution"]["transactional"]
      refute step["safety"]["destructive"]
      assert step["safety"]["rollbackStrategy"] == "none"
    end
  end

  test "shared-ledger collision repair is an explicit dependency barrier" do
    manifest = Manifest.manifest()

    assert manifest["orderingConstraints"] == [
             %{
               "before" => "bridge-20260723000012",
               "after" => "comma-20260723000014"
             },
             %{
               "before" => "bridge-20260723000013",
               "after" => "comma-20260723000014"
             },
             %{"before" => "comma-20260723000002", "after" => "comma-20260723000014"},
             %{"before" => "comma-20260723000014", "after" => "comma-20260723000003"},
             %{"before" => "comma-20260723000014", "after" => "comma-20260723000007"},
             %{"before" => "comma-20260723000014", "after" => "comma-20260723000008"},
             %{"before" => "comma-20260723000014", "after" => "comma-20260723000009"},
             %{"before" => "comma-20260723000014", "after" => "comma-20260723000010"},
             %{"before" => "comma-20260723000009", "after" => "comma-20260723000015"},
             %{
               "before" => "bridge-20260724000018",
               "after" => "bridge-20260723000011"
             },
             %{"before" => "bridge-20260723000011", "after" => "comma-20260723000016"},
             %{"before" => "comma-20260723000014", "after" => "comma-20260723000016"},
             %{"before" => "comma-20260723000001", "after" => "comma-20260723000016"},
             %{"before" => "comma-20260723000016", "after" => "comma-20260724000017"},
             %{"before" => "comma-20260724000017", "after" => "comma-20260723000003"},
             %{"before" => "comma-20260723000015", "after" => "comma-20260724000001"},
             %{
               "before" => "salix-20260806000101",
               "after" => "salix-20260805000103"
             },
             %{
               "before" => "salix-20260806000102",
               "after" => "salix-20260805000103"
             },
             %{
               "before" => "salix-20260805000103",
               "after" => "salix-20260806000103"
             },
             %{
               "before" => "salix-20260821000101",
               "after" => "salix-20260824000101"
             },
             %{
               "before" => "salix-20260826000101",
               "after" => "salix-20260827000101"
             },
             %{
               "before" => "bridge-20260826000001",
               "after" => "bridge-20260827000002"
             }
           ]

    steps =
      manifest["steps"]
      |> Enum.filter(
        &(&1["id"] in [
            "comma-20260723000010",
            "comma-20260723000007",
            "comma-20260723000014",
            "bridge-20260723000013",
            "bridge-20260723000012"
          ])
      )
      |> Enum.reverse()

    assert Enum.map(Manifest.order_steps(steps), & &1["id"]) == [
             "bridge-20260723000012",
             "bridge-20260723000013",
             "comma-20260723000014",
             "comma-20260723000007",
             "comma-20260723000010"
           ]

    session_work_steps =
      Enum.filter(
        manifest["steps"],
        &(&1["id"] in [
            "salix-20260805000103",
            "salix-20260806000101",
            "salix-20260806000102",
            "salix-20260806000103"
          ])
      )

    assert Enum.map(Manifest.order_steps(session_work_steps), & &1["id"]) == [
             "salix-20260806000101",
             "salix-20260806000102",
             "salix-20260805000103",
             "salix-20260806000103"
           ]

    unknown =
      update_in(manifest["orderingConstraints"], fn constraints ->
        [%{"before" => "missing", "after" => "comma-20260723000014"} | constraints]
      end)

    assert {:error, :unknown_ordering_constraint_id} =
             Manifest.validate(unknown, Manifest.source_inventory())

    cyclic =
      update_in(manifest["orderingConstraints"], fn constraints ->
        [
          %{"before" => "comma-20260723000007", "after" => "comma-20260723000014"}
          | constraints
        ]
      end)

    assert {:error, :cyclic_ordering_constraints} =
             Manifest.validate(cyclic, Manifest.source_inventory())

    malformed = put_in(manifest, ["orderingConstraints", Access.at(0)], %{"before" => "x"})

    assert {:error, {:unexpected_keys, :ordering_constraint, [], ["after"]}} =
             Manifest.validate(malformed, Manifest.source_inventory())

    duplicate =
      update_in(manifest["orderingConstraints"], fn [first | _] = constraints ->
        [first | constraints]
      end)

    assert {:error, :duplicate_ordering_constraint} =
             Manifest.validate(duplicate, Manifest.source_inventory())

    self_edge =
      update_in(manifest["orderingConstraints"], fn constraints ->
        [
          %{"before" => "comma-20260723000014", "after" => "comma-20260723000014"}
          | constraints
        ]
      end)

    assert {:error, :self_ordering_constraint} =
             Manifest.validate(self_edge, Manifest.source_inventory())

    analytics_id =
      manifest["steps"]
      |> Enum.find(&(&1["store"] == "clickhouse"))
      |> Map.fetch!("id")

    cross_store =
      update_in(manifest["orderingConstraints"], fn constraints ->
        [
          %{
            "before" => analytics_id,
            "after" => "comma-20260723000014"
          }
          | constraints
        ]
      end)

    assert {:error, :cross_store_ordering_constraint} =
             Manifest.validate(cross_store, Manifest.source_inventory())

    impossible_phase =
      update_in(manifest["orderingConstraints"], fn constraints ->
        [
          %{"before" => "comma-20260723000003", "after" => "comma-20260723000007"}
          | constraints
        ]
      end)

    assert {:error, :infeasible_phase_ordering_constraint} =
             Manifest.validate(impossible_phase, Manifest.source_inventory())
  end

  test "unknown and missing declarations fail closed" do
    manifest = Manifest.manifest()
    unknown = put_in(manifest, ["steps", Access.at(0), "unexpected"], true)
    assert {:error, _} = Manifest.validate(unknown, Manifest.source_inventory())

    missing = update_in(manifest["steps"], &tl/1)

    assert {:error, {:inventory_ids_differ, %{missing: [_], stale: []}}} =
             Manifest.validate(missing, Manifest.source_inventory())
  end

  test "phase, compatibility, destructive, and rollback facts are strict" do
    manifest = Manifest.manifest()
    assert_invalid(manifest, ["steps", Access.at(0), "phase"], "online_schema")
    assert_invalid(manifest, ["steps", Access.at(0), "compatibility", "oldRuntimeWrite"], "no")

    assert {:error, {"comma-20260722000001", :legacy_phase_is_reserved_for_published_steps}} =
             manifest
             |> put_in(["steps", Access.at(0), "phase"], "legacy")
             |> Manifest.validate(Manifest.source_inventory())

    legacy_index =
      Enum.find_index(manifest["steps"], &(&1["id"] == "salix-20260728000103"))

    all_compatible_legacy =
      Enum.reduce(
        ~w(oldRuntimeRead oldRuntimeWrite newRuntimeRead newRuntimeWrite),
        manifest,
        &put_in(&2, ["steps", Access.at(legacy_index), "compatibility", &1], true)
      )

    assert {:error,
            {"salix-20260728000103", :legacy_phase_requires_an_incompatible_runtime_boundary}} =
             Manifest.validate(all_compatible_legacy, Manifest.source_inventory())

    destructive_index = Enum.find_index(manifest["steps"], & &1["safety"]["destructive"])

    assert_invalid(
      manifest,
      ["steps", Access.at(destructive_index), "safety", "backupRequired"],
      false
    )

    assert Enum.all?(manifest["steps"], &(&1["safety"]["rollbackStrategy"] == "none"))
  end

  test "runtime compatibility cleanup waits for a later mainline release" do
    step = Enum.find(Manifest.manifest()["steps"], &(&1["id"] == "salix-20260909000101"))

    assert step["source"] == "historical-ledger-only"
    assert step["checksum"] == "historical-runtime-rollout-compatibility-cleanup-withdrawn-v1"

    assert step["postconditions"] == [
             "salix_store.migration-ledger/20260909000101=historical-applied-or-absent"
           ]

    assert step["repair"] == "no_source_execution_accept_exact_historical_ledger_fact"
    refute step["safety"]["destructive"]
  end

  test "terminal product-state marker is release-only with exclusive ledger safety" do
    step = Enum.find(Manifest.manifest()["steps"], &(&1["id"] == "comma-20260723000003"))

    assert step["source"] ==
             "systems/apps/comma_core/priv/release_migrations/20260723000003_finalize_product_state_cutover.exs"

    refute String.contains?(step["source"], "/priv/repo/migrations/")
    assert step["phase"] == "exclusive"

    assert step["execution"] == %{
             "transactional" => false,
             "idempotent" => true,
             "timeoutSeconds" => 2100,
             "lockBudgetSeconds" => 5
           }

    assert step["safety"]["destructive"]
    assert step["safety"]["backupRequired"]
    assert Enum.all?(step["postconditions"], &String.starts_with?(&1, "postgres."))
  end

  test "published participant-state relocation is blocked from automatic release execution" do
    step = Enum.find(Manifest.manifest()["steps"], &(&1["id"] == "salix-20260728000103"))

    assert step["source"] ==
             "systems/apps/salix_store/priv/release_migrations/20260728000103_conversation_participant_states_flat.exs"

    assert step["phase"] == "legacy"
    refute step["compatibility"]["oldRuntimeRead"]
    refute step["compatibility"]["oldRuntimeWrite"]
    assert step["compatibility"]["newRuntimeRead"]
    assert step["compatibility"]["newRuntimeWrite"]
    assert step["execution"]["idempotent"]
    assert step["safety"]["destructive"]
    assert step["safety"]["backupRequired"]
  end

  test "published Task Conversation status projection is blocked from automatic release execution" do
    step = Enum.find(Manifest.manifest()["steps"], &(&1["id"] == "salix-20260729000001"))

    assert step["source"] ==
             "systems/apps/salix_store/priv/release_migrations/20260729000001_task_conversation_status.exs"

    assert step["phase"] == "legacy"
    assert step["compatibility"]["oldRuntimeRead"]
    refute step["compatibility"]["oldRuntimeWrite"]
    assert step["compatibility"]["newRuntimeRead"]
    assert step["compatibility"]["newRuntimeWrite"]
    assert step["execution"]["idempotent"]
    refute step["safety"]["destructive"]
    assert step["safety"]["backupRequired"]
  end

  test "external Session Activity revision certification is an exclusive forward-only cutover" do
    step = Enum.find(Manifest.manifest()["steps"], &(&1["id"] == "salix-20260807000101"))

    assert step["source"] ==
             "systems/apps/salix_store/priv/release_migrations/20260807000101_external_session_activity_revision_cutover.exs"

    assert step["phase"] == "exclusive"
    refute step["compatibility"]["oldRuntimeRead"]
    refute step["compatibility"]["oldRuntimeWrite"]
    assert step["compatibility"]["newRuntimeRead"]
    assert step["compatibility"]["newRuntimeWrite"]
    assert step["execution"]["transactional"]
    refute step["safety"]["destructive"]
    assert step["safety"]["rollbackStrategy"] == "none"

    schema_version = SalixAgent.ExternalSessionStatus.schema_version()

    assert "postgres.salix_store.cutover/external_session_activity_schema_v#{schema_version}=legacy-writers-drained-and-old-restore-forbidden" in step[
             "postconditions"
           ]
  end

  test "published participant notification-filter cutover is blocked from automatic release execution" do
    step = Enum.find(Manifest.manifest()["steps"], &(&1["id"] == "salix-20260729000002"))

    assert step["source"] ==
             "systems/apps/salix_store/priv/release_migrations/20260729000002_participant_notification_filter.exs"

    assert step["phase"] == "legacy"
    refute step["compatibility"]["oldRuntimeRead"]
    refute step["compatibility"]["oldRuntimeWrite"]
    assert step["compatibility"]["newRuntimeRead"]
    assert step["compatibility"]["newRuntimeWrite"]
    assert step["execution"]["idempotent"]
    assert step["safety"]["destructive"]
    assert step["safety"]["backupRequired"]
  end

  test "historical Workflow Router filters use rolling participant-owner convergence" do
    step = Enum.find(Manifest.manifest()["steps"], &(&1["id"] == "salix-20260810000101"))

    assert step["source"] ==
             "systems/apps/salix_store/priv/release_migrations/20260810000101_workflow_router_notification_filter.exs"

    assert step["phase"] == "expand"
    assert step["compatibility"]["oldRuntimeRead"]
    assert step["compatibility"]["oldRuntimeWrite"]
    assert step["compatibility"]["newRuntimeRead"]
    assert step["compatibility"]["newRuntimeWrite"]
    assert step["execution"]["transactional"]
    assert step["execution"]["idempotent"]
    refute step["safety"]["destructive"]
    refute step["safety"]["backupRequired"]
  end

  test "MeetingPlan provider purge is audited staging-only ledger evidence" do
    step = Enum.find(Manifest.manifest()["steps"], &(&1["id"] == "salix-20260818000101"))
    inventory = Enum.find(Manifest.source_inventory(), &(&1["id"] == step["id"]))

    assert step["source"] == "historical-ledger-only"
    assert String.starts_with?(step["checksum"], "historical-")

    assert inventory == %{
             "id" => step["id"],
             "owner" => step["owner"],
             "store" => step["store"],
             "version" => step["version"],
             "source" => step["source"],
             "checksum" => step["checksum"],
             "transactional" => step["execution"]["transactional"]
           }

    assert step["phase"] == "expand"
    assert step["compatibility"]["oldRuntimeRead"]
    assert step["compatibility"]["oldRuntimeWrite"]
    assert step["compatibility"]["newRuntimeRead"]
    assert step["compatibility"]["newRuntimeWrite"]
    assert step["execution"]["transactional"]
    assert step["execution"]["idempotent"]
    refute step["safety"]["destructive"]
    refute step["safety"]["backupRequired"]
    assert step["safety"]["rollbackStrategy"] == "none"
    assert :ok = Manifest.validate()
  end

  test "historical ledger-only steps diagnose applied and absent environments as complete" do
    for step_id <- [
          "billing-20260714000002",
          "salix-20260818000101",
          "salix-20260909000101"
        ] do
      step = Enum.find(Manifest.manifest()["steps"], &(&1["id"] == step_id))
      postcondition_results = Map.new(step["postconditions"], &{&1, true})

      assert {:ok, :complete} = Manifest.diagnose(step_id, true, postcondition_results)
      assert {:ok, :complete} = Manifest.diagnose(step_id, false, postcondition_results)

      for ledger_applied <- [true, false] do
        assert {:error, :historical_ledger_postcondition_drift} =
                 Manifest.diagnose(
                   step_id,
                   ledger_applied,
                   Map.new(step["postconditions"], &{&1, false})
                 )
      end
    end
  end

  test "non-transactional Ecto and ClickHouse steps require idempotent repair contracts" do
    manifest = Manifest.manifest()

    nontransactional =
      Enum.filter(manifest["steps"], &(not &1["execution"]["transactional"]))

    refute Enum.empty?(nontransactional)
    assert Enum.all?(nontransactional, & &1["execution"]["idempotent"])
    assert Enum.all?(nontransactional, &(&1["postconditions"] != [] and &1["repair"] != ""))

    index = Enum.find_index(manifest["steps"], &(not &1["execution"]["transactional"]))
    assert_invalid(manifest, ["steps", Access.at(index), "execution", "idempotent"], false)
    assert_invalid(manifest, ["steps", Access.at(index), "repair"], "")
  end

  test "source checksum and Ecto transaction flags cannot drift" do
    manifest = Manifest.manifest()
    inventory = Manifest.source_inventory()
    [first | rest] = inventory

    assert {:error, {:checksum_drift, id}} =
             Manifest.validate(manifest, [%{first | "checksum" => "sha256:bad"} | rest])

    assert id == first["id"]

    concurrent = Enum.find(inventory, &(&1["id"] == "bridge-20260624000001"))
    refute concurrent["transactional"]

    changed =
      update_in(manifest["steps"], fn steps ->
        Enum.map(steps, fn step ->
          if step["id"] == concurrent["id"],
            do: put_in(step, ["execution", "transactional"], true),
            else: step
        end)
      end)

    assert {:error, {:transactionality_drift, "bridge-20260624000001"}} =
             Manifest.validate(changed, inventory)
  end

  test "an executable source cannot shadow a historical ledger-only inventory tombstone" do
    for step_id <- ["billing-20260714000002", "salix-20260818000101"] do
      inventory = Manifest.source_inventory()
      historical = Enum.find(inventory, &(&1["id"] == step_id))

      restored_source = %{
        historical
        | "source" =>
            "systems/apps/restored/priv/release_migrations/#{historical["version"]}_restored.exs",
          "checksum" => "sha256:restored-source",
          "transactional" => false
      }

      assert {:error, {:duplicate_inventory_ids, [^step_id]}} =
               Manifest.validate(Manifest.manifest(), [restored_source | inventory])
    end
  end

  test "compiled inventory tracks every systems-umbrella source as an external resource" do
    repo_root = Path.expand("../../../..", __DIR__)
    systems_root = Path.join(repo_root, "systems")

    source_paths =
      Manifest.source_inventory()
      |> Enum.reject(
        &(&1["source"] in ["historical-ledger-only", "Comma.Billing.PricingV1.catalog"])
      )
      |> MapSet.new(&Path.join(repo_root, &1["source"]))

    external_resources =
      Manifest.module_info(:attributes)
      |> Keyword.get_values(:external_resource)
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.subset?(source_paths, external_resources)
    refute Enum.empty?(source_paths)
    assert Enum.all?(source_paths, &String.starts_with?(&1, systems_root <> "/"))

    source_directories = source_paths |> Enum.map(&Path.dirname/1) |> MapSet.new()
    assert MapSet.subset?(source_directories, external_resources)
    assert MapSet.size(source_directories) == 9
  end

  test "owner/store versions must remain strictly ordered" do
    manifest = Manifest.manifest()

    index =
      manifest["steps"]
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_index(fn [left, right] ->
        {left["owner"], left["store"]} == {right["owner"], right["store"]}
      end)

    reordered =
      update_in(manifest["steps"], fn steps ->
        {prefix, [first, second | suffix]} = Enum.split(steps, index)
        prefix ++ [second, first | suffix]
      end)

    assert {:error, {:non_monotonic_versions, _owner_store}} =
             Manifest.validate(reordered)
  end

  test "partial apply, repair, postcondition, and forward-fix decisions are deterministic" do
    step =
      Enum.find(
        Manifest.manifest()["steps"],
        &(&1["id"] == "analytics-20260623000003")
      )

    postcondition_results = Map.new(step["postconditions"], &{&1, true})

    assert {:ok, :complete} = Manifest.diagnose(step["id"], true, postcondition_results)

    assert {:error, :ledger_postcondition_drift} =
             Manifest.diagnose(
               step["id"],
               true,
               Map.new(step["postconditions"], &{&1, false})
             )

    [first | _] = step["postconditions"]
    partial = Map.new(step["postconditions"], &{&1, &1 == first})

    assert {:ok, {:repair_partial_apply, repair}} =
             Manifest.diagnose(step["id"], false, partial)

    assert repair == step["repair"]

    assert {:ok, {:retry_exact_version, ^repair}} =
             Manifest.diagnose(
               step["id"],
               false,
               Map.new(step["postconditions"], &{&1, false})
             )

    assert {:error, :automatic_down_forbidden} = Manifest.rollback_contract(step["id"])

    assert {:error, :postcondition_set_drift} =
             Manifest.diagnose(
               step["id"],
               false,
               Map.put(postcondition_results, "unknown", true)
             )
  end

  defp assert_invalid(manifest, path, value) do
    changed = put_in(manifest, path, value)
    assert {:error, _reason} = Manifest.validate(changed, Manifest.source_inventory())
  end
end
