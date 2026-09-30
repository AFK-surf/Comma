defmodule SalixStore.ComputeMigration do
  @moduledoc """
  One-time Group CloudVM handoff after the old writer rollout has completed.

  The release runner owns writer quiescence. This module reads at most 20 source
  objects per page and commits their Compute facts and cursor in one transaction.
  Source objects, archives, bindings and credentials are retained. Serving paths
  remain closed until the last page commits; after admission, recovery is forward
  repair. No provider operation, shadow writer or source-read fallback runs here.
  """
  alias SalixStore.{Compute, Keys, Repo, S3}

  @marker "group_compute_authority_v1"
  @page_size 20
  @max_record_bytes 1_048_576

  def ensure_open do
    with {:ok, %{"phase" => "complete"}} <- state(),
         do: :ok,
         else: (_ -> {:error, :group_compute_handoff_pending})
  end

  def ensure_copying do
    with {:ok, %{"phase" => "copying"}} <- state(),
         do: :ok,
         else: (_ -> {:error, :group_compute_import_closed})
  end

  def state do
    case Repo.query("SELECT evidence FROM salix_cutover_markers WHERE name = $1", [@marker]) do
      {:ok, %{rows: [[evidence]]}} -> {:ok, evidence}
      {:ok, %{rows: []}} -> {:ok, %{"phase" => "blocked"}}
      _ -> {:error, :group_compute_state_unavailable}
    end
  rescue
    _ -> {:error, :group_compute_state_unavailable}
  catch
    :exit, _ -> {:error, :group_compute_state_unavailable}
  end

  @doc "Release-only entrypoint, called after all legacy writers have exited. Never deletes source data."
  def transfer_page(cursor \\ nil) when is_nil(cursor) or is_binary(cursor) do
    Repo.transaction(
      fn ->
        Repo.query!(
          "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, now(), $2) ON CONFLICT (name) DO NOTHING",
          [@marker, %{"phase" => "copying", "cursor" => nil, "processed" => 0}]
        )

        %{rows: [[evidence]]} =
          Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name = $1 FOR UPDATE", [
            @marker
          ])

        cond do
          evidence["phase"] == "complete" ->
            %{processed: 0, next_cursor: nil}

          evidence["phase"] != "copying" ->
            Repo.rollback(:invalid_group_compute_handoff)

          is_binary(cursor) and cursor != evidence["cursor"] and
              cursor == evidence["previous_cursor"] ->
            %{processed: 0, next_cursor: evidence["cursor"]}

          is_binary(cursor) and cursor != evidence["cursor"] ->
            Repo.rollback(:stale_group_compute_cursor)

          true ->
            copy_page(evidence)
        end
      end,
      timeout: 120_000
    )
  end

  @doc "Read-only source inventory with the same conversion checks as the writer."
  def inspect_page(cursor \\ nil) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_vms_prefix(), max_keys: @page_size, continuation_token: cursor) do
      results =
        Enum.map(objects, fn %{key: key} ->
          case source_record(key) do
            {:ok, facts} ->
              %{key: key, provider: facts["provider"], status: facts["status"], result: :ready}

            {:error, reason} ->
              %{key: key, result: :blocked, reason: reason}
          end
        end)

      {:ok, %{items: results, next_cursor: next}}
    end
  end

  defp copy_page(evidence) do
    case S3.list(Keys.ctl_vms_prefix(),
           max_keys: @page_size,
           continuation_token: evidence["cursor"]
         ) do
      {:ok, %{objects: objects, next: next}} ->
        Enum.each(objects, fn %{key: key} ->
          with {:ok, facts} <- source_record(key),
               {:ok, imported, _outcome} <- Compute.import_group_workload(facts),
               :ok <- verify_facts(facts, imported) do
            :ok
          else
            {:error, reason} -> Repo.rollback({:group_compute_import_failed, key, reason})
          end
        end)

        updated = %{
          "phase" => if(next, do: "copying", else: "complete"),
          "cursor" => next,
          "previous_cursor" => evidence["cursor"],
          "processed" => (evidence["processed"] || 0) + length(objects)
        }

        Repo.query!(
          "UPDATE salix_cutover_markers SET evidence = $2, completed_at = now() WHERE name = $1",
          [@marker, updated]
        )

        %{processed: length(objects), next_cursor: next}

      {:error, reason} ->
        Repo.rollback({:group_compute_source_unavailable, reason})
    end
  end

  defp source_record(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         true <- byte_size(body) <= @max_record_bytes || {:error, :source_record_too_large},
         {:ok, %{} = record} <- Jason.decode(body),
         true <- key == Keys.ctl_vm(record["group_id"]) || {:error, :source_scope_mismatch},
         {:ok, facts} <- normalize(record) do
      {:ok, facts}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_group_source}
    end
  end

  def normalize(record) when is_map(record) do
    with true <- record["schema_version"] in [nil, 1] || {:error, :unsupported_group_schema},
         true <-
           (is_nil(record["active_operation"]) and is_nil(record["requested_transition"])) ||
             {:error, :accepted_transition_requires_resolution},
         {:ok, facts} <- normalize_lifecycle(record),
         :ok <- Compute.validate_group_import(facts) do
      {:ok, facts}
    end
  end

  def normalize(_), do: {:error, :invalid_group_source}

  defp normalize_lifecycle(%{"coordinator_version" => 2, "lifecycle" => lifecycle} = record)
       when is_map(lifecycle) do
    allowed =
      ~w(availability residency generation provider provider_resource_id current_worker_version desired_worker_version workspace_dir updated_at)

    completed = record["last_completed_operation"]

    cond do
      Map.keys(lifecycle) -- allowed != [] ->
        {:error, :unmapped_lifecycle_fields}

      lifecycle["residency"] not in ~w(live absent archived) ->
        {:error, :unsupported_residency}

      lifecycle["availability"] not in ~w(ready unavailable) ->
        {:error, :unsupported_availability}

      not is_nil(completed) and completed["phase"] != "completed" ->
        {:error, :accepted_transition_requires_resolution}

      true ->
        fields = %{
          "provider" => lifecycle["provider"],
          "provider_resource_id" => lifecycle["provider_resource_id"],
          "current_worker_version_id" => lifecycle["current_worker_version"],
          "desired_worker_version_id" => lifecycle["desired_worker_version"],
          "workspace_dir" => lifecycle["workspace_dir"]
        }

        conflict =
          Enum.any?(fields, fn {key, value} ->
            not is_nil(value) and not is_nil(record[key]) and record[key] != value
          end)

        if conflict do
          {:error, :conflicting_lifecycle_facts}
        else
          facts =
            Map.drop(
              record,
              ~w(coordinator_version lifecycle revision active_operation requested_transition last_completed_operation)
            )

          fields = Map.reject(fields, fn {_key, value} -> is_nil(value) end)
          # Retired coordinator revisions are provenance only. Compute assigns
          # its own generation; no old command is replayed by this conversion.
          provenance = Map.take(lifecycle, ~w(generation availability residency updated_at))
          facts = Map.merge(facts, fields)
          spec = Map.put(facts["provider_spec"] || %{}, "migration_provenance", provenance)
          {:ok, Map.put(facts, "provider_spec", spec)}
        end
    end
  end

  defp normalize_lifecycle(record) do
    if record["coordinator_version"] in [nil, 1] do
      {:ok, Map.drop(record, ~w(coordinator_version active_operation requested_transition))}
    else
      {:error, :legacy_lifecycle_conversion_required}
    end
  end

  defp verify_facts(source, imported) do
    # schema_version describes the retired storage format; count is derived from
    # the retained active-operation map. Neither is a separate durable fact.
    facts = Map.drop(source, ~w(schema_version active_operation_count))
    if Map.take(imported, Map.keys(facts)) == facts, do: :ok, else: {:error, :group_fact_conflict}
  end
end
