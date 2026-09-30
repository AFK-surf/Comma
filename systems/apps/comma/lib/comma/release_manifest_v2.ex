defmodule Comma.ReleaseManifestV2 do
  @moduledoc """
  Static compatibility and safety contract for every database/local-seed step.

  Revision 2 is the authoritative migration compatibility and safety contract.
  Source discovery is used solely to reject missing IDs and
  checksum/transactionality drift; execution phase and safety always come from
  this manifest.
  """

  @manifest_path Path.expand("../../priv/release/migration-manifest-v2.json", __DIR__)
  @external_resource @manifest_path
  @encoded_manifest @manifest_path |> File.read!() |> :json.decode()
  @step_defaults Map.fetch!(@encoded_manifest, "stepDefaults")
  @manifest @encoded_manifest
            |> Map.update!("steps", fn steps ->
              Enum.map(steps, fn step ->
                Map.merge(@step_defaults, step, fn
                  _key, default, override when is_map(default) and is_map(override) ->
                    Map.merge(default, override)

                  _key, _default, override ->
                    override
                end)
              end)
            end)
            |> Map.delete("stepDefaults")
  # Anchor discovery at the systems umbrella, whose location is stable both in
  # a repository checkout (`<repo>/systems`) and in the image builder (`/app`).
  # The repository root is not stable because Docker copies `systems/` to
  # `/app`; walking one directory higher there resolves to `/` and silently
  # produces an empty compile-time inventory.
  @systems_root Path.expand("../../../..", __DIR__)

  @source_specs [
    {"alert-router", "alert_router", "postgres", "apps/alert_router/priv/repo/migrations/*.exs"},
    {"comma", "comma_core", "postgres", "apps/comma_core/priv/repo/migrations/*.exs"},
    {"comma", "comma_core", "postgres", "apps/comma_core/priv/release_migrations/*.exs"},
    {"billing", "billing_core", "postgres", "apps/billing_core/priv/repo/migrations/*.exs"},
    {"bridge", "bridge_for_teams", "postgres",
     "apps/bridge_for_teams_core/priv/repo/migrations/*.exs"},
    {"bridge", "bridge_for_teams", "postgres",
     "apps/bridge_for_teams_core/priv/release_migrations/*.exs"},
    {"salix", "salix_store", "postgres", "apps/salix_store/priv/repo/migrations/*.exs"},
    {"salix", "salix_store", "postgres", "apps/salix_store/priv/release_migrations/*.exs"},
    {"analytics", "analytics", "clickhouse",
     "apps/salix_analytics/priv/clickhouse/migrations/*.sql"}
  ]

  @source_paths Enum.flat_map(@source_specs, fn {prefix, owner, store, pattern} ->
                  @systems_root
                  |> Path.join(pattern)
                  |> Path.wildcard()
                  |> Enum.sort()
                  |> Enum.map(&{&1, prefix, owner, store})
                end)

  @source_directories Enum.map(@source_specs, fn {_prefix, _owner, _store, pattern} ->
                        @systems_root |> Path.join(pattern) |> Path.dirname()
                      end)

  for path <- @source_directories do
    @external_resource path
  end

  for {path, _prefix, _owner, _store} <- @source_paths do
    @external_resource path
  end

  # The runtime image contains the compiled OTP release, not the source tree.
  # Embed the validated source facts in the BEAM. The source directories track
  # additions/removals and each file tracks content edits so incremental builds
  # cannot reuse stale inventory facts.
  @source_inventory Enum.map(@source_paths, fn {path, prefix, owner, store} ->
                      [version_text | _] =
                        path |> Path.basename() |> String.split("_", parts: 2)

                      source = File.read!(path)

                      transactional =
                        store == "postgres" and
                          not String.contains?(source, "@disable_ddl_transaction true") and
                          not String.contains?(source, "@disable_migration_lock true")

                      %{
                        "id" => "#{prefix}-#{version_text}",
                        "owner" => owner,
                        "store" => store,
                        "version" => String.to_integer(version_text),
                        "source" => "systems/" <> Path.relative_to(path, @systems_root),
                        "checksum" =>
                          "sha256:" <>
                            (:crypto.hash(:sha256, source) |> Base.encode16(case: :lower)),
                        "transactional" => transactional
                      }
                    end) ++
                      [
                        %{
                          "id" => "billing-20260714000002",
                          "owner" => "billing_core",
                          "store" => "postgres",
                          "version" => 20_260_714_000_002,
                          "source" => "historical-ledger-only",
                          "checksum" => "historical-staging-orphan-v1",
                          "transactional" => true
                        },
                        %{
                          "id" => "salix-20260818000101",
                          "owner" => "salix_store",
                          "store" => "postgres",
                          "version" => 20_260_818_000_101,
                          "source" => "historical-ledger-only",
                          "checksum" =>
                            "historical-staging-meeting-research-provider-participant-purge-v1",
                          "transactional" => true
                        },
                        %{
                          "id" => "salix-20260909000101",
                          "owner" => "salix_store",
                          "store" => "postgres",
                          "version" => 20_260_909_000_101,
                          "source" => "historical-ledger-only",
                          "checksum" =>
                            "historical-runtime-rollout-compatibility-cleanup-withdrawn-v1",
                          "transactional" => true
                        },
                        %{
                          "id" => "comma-local-seed",
                          "owner" => "comma_billing",
                          "store" => "postgres",
                          "version" => 1,
                          "source" => "Comma.Billing.PricingV1.catalog",
                          "checksum" => "comma-local-seed-v1",
                          "transactional" => true
                        }
                      ]

  @manifest_keys MapSet.new(["schemaVersion", "steps", "orderingConstraints"])
  @ordering_constraint_keys MapSet.new(["before", "after"])
  @step_keys MapSet.new([
               "id",
               "owner",
               "store",
               "version",
               "source",
               "checksum",
               "phase",
               "compatibility",
               "execution",
               "safety",
               "postconditions",
               "repair"
             ])
  @compatibility_keys MapSet.new([
                        "oldRuntimeRead",
                        "oldRuntimeWrite",
                        "newRuntimeRead",
                        "newRuntimeWrite"
                      ])
  @execution_keys MapSet.new([
                    "transactional",
                    "idempotent",
                    "timeoutSeconds",
                    "lockBudgetSeconds"
                  ])
  @safety_keys MapSet.new(["destructive", "backupRequired", "rollbackStrategy"])
  @phases MapSet.new(["expand", "contract", "exclusive", "legacy", "local_seed"])
  @legacy_step_ids MapSet.new([
                     "salix-20260728000103",
                     "salix-20260729000001",
                     "salix-20260729000002"
                   ])
  @rollback_strategies MapSet.new(["none", "compensating", "reversible_manual"])

  def manifest, do: @manifest

  def manifest_digest(manifest \\ @manifest) do
    body = manifest |> canonicalize() |> :json.encode() |> IO.iodata_to_binary()
    "sha256:" <> (:crypto.hash(:sha256, body) |> Base.encode16(case: :lower))
  end

  def validate(manifest \\ @manifest, inventory \\ source_inventory()) do
    with :ok <- exact_keys(manifest, @manifest_keys, :manifest),
         2 <- manifest["schemaVersion"] || {:error, :unsupported_schema_version},
         steps when is_list(steps) <- manifest["steps"] || {:error, :steps_must_be_a_list},
         constraints when is_list(constraints) <-
           manifest["orderingConstraints"] || {:error, :ordering_constraints_must_be_a_list},
         :ok <- validate_steps(steps),
         :ok <- validate_order(steps),
         :ok <- validate_ordering_constraints(steps, constraints),
         :ok <- validate_inventory(steps, inventory) do
      :ok
    else
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  def validate!(manifest \\ @manifest, inventory \\ source_inventory()) do
    case validate(manifest, inventory) do
      :ok -> :ok
      {:error, reason} -> raise "invalid migration manifest V2: #{inspect(reason)}"
    end
  end

  def diagnose(step_id, ledger_applied, postcondition_results, manifest \\ @manifest)
      when is_boolean(ledger_applied) and is_map(postcondition_results) do
    diagnose(step_id, ledger_applied, postcondition_results, manifest, source_inventory())
  end

  def diagnose(step_id, ledger_applied, postcondition_results, manifest, inventory)
      when is_boolean(ledger_applied) and is_map(postcondition_results) do
    with :ok <- validate(manifest, inventory),
         %{} = step <-
           Enum.find(manifest["steps"], &(&1["id"] == step_id)) || {:error, :unknown_step},
         true <-
           Map.keys(postcondition_results) |> Enum.sort() == Enum.sort(step["postconditions"]) ||
             {:error, :postcondition_set_drift} do
      values = Map.values(postcondition_results)

      cond do
        step["source"] == "historical-ledger-only" and Enum.all?(values) ->
          {:ok, :complete}

        step["source"] == "historical-ledger-only" ->
          {:error, :historical_ledger_postcondition_drift}

        ledger_applied and Enum.all?(values) ->
          {:ok, :complete}

        ledger_applied ->
          {:error, :ledger_postcondition_drift}

        Enum.any?(values) and not Enum.all?(values) ->
          {:ok, {:repair_partial_apply, step["repair"]}}

        true ->
          {:ok, {:retry_exact_version, step["repair"]}}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  def rollback_contract(step_id, manifest \\ @manifest) do
    case Enum.find(manifest["steps"], &(&1["id"] == step_id)) do
      nil -> {:error, :unknown_step}
      %{"safety" => %{"rollbackStrategy" => "none"}} -> {:error, :automatic_down_forbidden}
      step -> {:ok, step["safety"]["rollbackStrategy"]}
    end
  end

  def order_steps(steps, manifest \\ @manifest) when is_list(steps) do
    ids = MapSet.new(steps, & &1["id"])

    constraints =
      Enum.filter(
        manifest["orderingConstraints"],
        &(MapSet.member?(ids, &1["before"]) and MapSet.member?(ids, &1["after"]))
      )

    order_steps(steps, constraints, [])
  end

  def source_inventory, do: @source_inventory

  defp validate_steps(steps) do
    ids = Enum.map(steps, & &1["id"])

    cond do
      ids != Enum.uniq(ids) -> {:error, :duplicate_step_id}
      Enum.any?(steps, &(validate_step(&1) != :ok)) -> first_step_error(steps)
      true -> :ok
    end
  end

  defp first_step_error(steps) do
    Enum.find_value(steps, :ok, fn step ->
      case validate_step(step) do
        :ok -> nil
        {:error, reason} -> {:error, {step["id"], reason}}
      end
    end)
  end

  defp validate_step(step) when is_map(step) do
    compatibility = step["compatibility"]
    execution = step["execution"]
    safety = step["safety"]

    with :ok <- exact_keys(step, @step_keys, :step),
         true <- nonempty?(step["id"]) || {:error, :id_required},
         true <- nonempty?(step["owner"]) || {:error, :owner_required},
         true <- step["store"] in ["postgres", "clickhouse"] || {:error, :invalid_store},
         true <-
           (is_integer(step["version"]) and step["version"] > 0) || {:error, :invalid_version},
         true <- nonempty?(step["source"]) || {:error, :source_required},
         true <- nonempty?(step["checksum"]) || {:error, :checksum_required},
         true <- MapSet.member?(@phases, step["phase"]) || {:error, :invalid_phase},
         :ok <- exact_keys(compatibility, @compatibility_keys, :compatibility),
         true <-
           Enum.all?(@compatibility_keys, &is_boolean(compatibility[&1])) ||
             {:error, :invalid_compatibility},
         :ok <- exact_keys(execution, @execution_keys, :execution),
         true <- is_boolean(execution["transactional"]) || {:error, :transactional_required},
         true <- is_boolean(execution["idempotent"]) || {:error, :idempotent_required},
         true <- positive_integer?(execution["timeoutSeconds"]) || {:error, :invalid_timeout},
         true <-
           positive_integer?(execution["lockBudgetSeconds"]) || {:error, :invalid_lock_budget},
         :ok <- exact_keys(safety, @safety_keys, :safety),
         true <- is_boolean(safety["destructive"]) || {:error, :destructive_required},
         true <- is_boolean(safety["backupRequired"]) || {:error, :backup_required_flag_missing},
         true <-
           MapSet.member?(@rollback_strategies, safety["rollbackStrategy"]) ||
             {:error, :invalid_rollback_strategy},
         true <-
           (is_list(step["postconditions"]) and step["postconditions"] != [] and
              Enum.all?(step["postconditions"], &nonempty?/1)) ||
             {:error, :postcondition_required},
         true <- nonempty?(step["repair"]) || {:error, :repair_required},
         :ok <- validate_derived_safety(step) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_step(_step), do: {:error, :step_must_be_an_object}

  defp validate_derived_safety(step) do
    compatibility = step["compatibility"]
    execution = step["execution"]
    safety = step["safety"]

    cond do
      step["phase"] == "legacy" and not MapSet.member?(@legacy_step_ids, step["id"]) ->
        {:error, :legacy_phase_is_reserved_for_published_steps}

      step["phase"] == "legacy" and
          Enum.all?(@compatibility_keys, &compatibility[&1]) ->
        {:error, :legacy_phase_requires_an_incompatible_runtime_boundary}

      step["phase"] == "local_seed" and
          not (compatibility["oldRuntimeRead"] and compatibility["oldRuntimeWrite"] and
                 compatibility["newRuntimeRead"] and compatibility["newRuntimeWrite"]) ->
        {:error, :online_phase_is_not_bidirectionally_compatible}

      not execution["transactional"] and not execution["idempotent"] ->
        {:error, :nontransactional_step_must_be_idempotent}

      not execution["transactional"] and
          Enum.any?(step["postconditions"], fn postcondition ->
            not String.starts_with?(postcondition, ["postgres.", "clickhouse."])
          end) ->
        {:error, :nontransactional_step_requires_schema_postcondition}

      safety["destructive"] and not safety["backupRequired"] ->
        {:error, :destructive_step_requires_backup}

      safety["rollbackStrategy"] != "none" and step["phase"] == "expand" ->
        {:error, :break_glass_rollback_requires_non_expand_phase}

      true ->
        :ok
    end
  end

  defp validate_order(steps) do
    steps
    |> Enum.group_by(&{&1["owner"], &1["store"]})
    |> Enum.find_value(:ok, fn {owner_store, owner_steps} ->
      versions = Enum.map(owner_steps, & &1["version"])

      if versions == Enum.sort(versions),
        do: nil,
        else: {:error, {:non_monotonic_versions, owner_store}}
    end)
  end

  defp validate_ordering_constraints(steps, constraints) do
    with :ok <- validate_ordering_constraint_shapes(constraints) do
      ids = MapSet.new(steps, & &1["id"])
      pairs = Enum.map(constraints, &{&1["before"], &1["after"]})
      step_by_id = Map.new(steps, &{&1["id"], &1})

      cond do
        Enum.any?(pairs, fn {predecessor, successor} ->
          not MapSet.member?(ids, predecessor) or not MapSet.member?(ids, successor)
        end) ->
          {:error, :unknown_ordering_constraint_id}

        Enum.any?(pairs, fn {predecessor, successor} -> predecessor == successor end) ->
          {:error, :self_ordering_constraint}

        pairs != Enum.uniq(pairs) ->
          {:error, :duplicate_ordering_constraint}

        Enum.any?(pairs, fn {predecessor, successor} ->
          Map.fetch!(step_by_id, predecessor)["store"] !=
              Map.fetch!(step_by_id, successor)["store"]
        end) ->
          {:error, :cross_store_ordering_constraint}

        Enum.any?(pairs, fn {predecessor, successor} ->
          ordering_stage(Map.fetch!(step_by_id, predecessor)["phase"]) >
              ordering_stage(Map.fetch!(step_by_id, successor)["phase"])
        end) ->
          {:error, :infeasible_phase_ordering_constraint}

        length(order_steps(steps, constraints, [])) != length(steps) ->
          {:error, :cyclic_ordering_constraints}

        true ->
          :ok
      end
    end
  end

  defp validate_ordering_constraint_shapes(constraints) do
    Enum.find_value(constraints, :ok, fn constraint ->
      case exact_keys(constraint, @ordering_constraint_keys, :ordering_constraint) do
        :ok -> nil
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp ordering_stage(phase) when phase in ["expand", "local_seed"], do: 0
  defp ordering_stage(phase) when phase in ["exclusive", "legacy"], do: 1
  defp ordering_stage("contract"), do: 2

  defp order_steps([], _constraints, ordered), do: Enum.reverse(ordered)

  defp order_steps(remaining, constraints, ordered) do
    remaining_ids = MapSet.new(remaining, & &1["id"])

    ready =
      remaining
      |> Enum.reject(fn step ->
        Enum.any?(constraints, fn constraint ->
          constraint["after"] == step["id"] and
            MapSet.member?(remaining_ids, constraint["before"])
        end)
      end)
      |> Enum.min_by(& &1["id"], fn -> nil end)

    case ready do
      nil ->
        Enum.reverse(ordered)

      step ->
        order_steps(
          Enum.reject(remaining, &(&1["id"] == step["id"])),
          constraints,
          [step | ordered]
        )
    end
  end

  defp validate_inventory(steps, inventory) do
    declared = Map.new(steps, &{&1["id"], &1})

    duplicate_inventory_ids =
      inventory
      |> Enum.map(& &1["id"])
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    actual = Map.new(inventory, &{&1["id"], &1})

    cond do
      duplicate_inventory_ids != [] ->
        {:error, {:duplicate_inventory_ids, duplicate_inventory_ids}}

      Map.keys(declared) |> Enum.sort() != Map.keys(actual) |> Enum.sort() ->
        {:error,
         {:inventory_ids_differ,
          %{
            missing: Map.keys(actual) -- Map.keys(declared),
            stale: Map.keys(declared) -- Map.keys(actual)
          }}}

      true ->
        Enum.find_value(actual, :ok, fn {id, fact} ->
          step = Map.fetch!(declared, id)

          cond do
            step["checksum"] != fact["checksum"] ->
              {:error, {:checksum_drift, id}}

            step["source"] != fact["source"] ->
              {:error, {:source_drift, id}}

            step["owner"] != fact["owner"] or step["store"] != fact["store"] ->
              {:error, {:owner_store_drift, id}}

            step["version"] != fact["version"] ->
              {:error, {:version_drift, id}}

            step["execution"]["transactional"] != fact["transactional"] ->
              {:error, {:transactionality_drift, id}}

            true ->
              nil
          end
        end)
    end
  end

  defp exact_keys(value, expected, location) when is_map(value) do
    actual = value |> Map.keys() |> MapSet.new()

    if actual == expected,
      do: :ok,
      else:
        {:error,
         {:unexpected_keys, location, MapSet.difference(actual, expected) |> MapSet.to_list(),
          MapSet.difference(expected, actual) |> MapSet.to_list()}}
  end

  defp exact_keys(_value, _expected, location), do: {:error, {:object_required, location}}
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Map.new(fn {key, child} -> {key, canonicalize(child)} end)
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value
end
