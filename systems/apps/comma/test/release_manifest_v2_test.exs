defmodule Comma.ReleaseManifestV2Test do
  use SystemsClock.Case, async: true

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

  test "shared-ledger collision repair is an explicit dependency barrier" do
    manifest = Manifest.manifest()

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

    registration_steps =
      Enum.filter(
        manifest["steps"],
        &(&1["id"] in ["salix-20261001000200", "salix-20260824000005"])
      )

    assert Enum.map(Manifest.order_steps(registration_steps), & &1["id"]) == [
             "salix-20260824000005",
             "salix-20261001000200"
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
