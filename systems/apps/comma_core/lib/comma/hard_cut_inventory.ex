defmodule Comma.HardCutInventory do
  @moduledoc """
  Read-only inventory for retired Comma-local Conversation data.

  Comma Workspaces and memberships remain product-owned data. Task, Chat,
  Conversation binding, adoption, reconciliation, and Inbox projection rows are
  physical leftovers only: production does not read, write, validate, or
  migrate them. Their physical purge remains a separately approved ops action.

  The bounded users/sessions/grants inventory is retained for the independent
  Session lifecycle hard-cut release fence.
  """

  alias Comma.Migrations.LegacyS3Inventory

  @inventory_reader ["Comma.HardCutInventory (read-only inventory)"]

  @active_buckets [
    {:workspaces, "Comma.Workspaces", "comma_workspaces", "private_identity", "import",
     ["Comma.Workspaces"], ["Comma.Workspaces"]},
    {:user_workspaces, "Comma.Workspaces membership index", "comma_workspace_memberships",
     "private_identity", "normalize", ["Comma.Workspaces"], ["Comma.Workspaces"]}
  ]

  @retired_conversation_buckets [
    {:conversations, "private_identity"},
    {:salix_conversation_projections, "private_identity"},
    {:assistant_chat_bindings, "private_identity"},
    {:conversation_adoption_negatives, "private_operational"},
    {:conversation_adoption_retries, "private_operational"},
    {:conversation_adoption_attempts, "private_operational"},
    {:conversation_reconciliation_cursors, "private_operational"}
  ]

  @auth_cutover_stop_buckets [
    {:users, "private_profile", @inventory_reader},
    {:sessions, "bearer_secret", @inventory_reader},
    {:grants, "restricted_session_material", @inventory_reader}
  ]

  @legacy_buckets [
    :assistant_bindings,
    :conversation_create_requests,
    :conversation_aggregates,
    :conversation_aggregate_segments,
    :workspace_conversations,
    :conversation_aggregate_projection_repairs,
    :conversation_aggregate_projection_progress,
    :conversation_aggregate_projection_cursors,
    :conversation_aggregate_migration_retries,
    :conversation_aggregate_migration_quarantine,
    :conversation_message_events,
    :conversation_message_event_claims,
    :conversation_message_event_claim_cursors,
    :conversation_message_event_migration_retries,
    :conversation_message_event_migration_quarantine,
    :conversation_message_commit_claims,
    :conversation_message_commit_claim_cursors
  ]

  @history_buckets [
    :conversation_aggregate_migration_reports,
    :conversation_aggregate_migration_renumber_wal
  ]

  @manual_gates [
    "real_user_data_disposition_confirmed",
    "published_client_compatibility_confirmed",
    "oauth_connector_runtime_references_confirmed",
    "billing_and_stripe_ownership_confirmed",
    "external_automation_references_confirmed",
    "backup_and_restore_evidence_recorded",
    "product_and_ops_physical_purge_approved"
  ]

  @doc """
  Run only the accepted, bounded S3 auth-prefix stop inventory.

  The lifecycle writer-epoch release guard calls this function while its
  PostgreSQL fence is held. Keeping the implementation here prevents release
  orchestration from creating a second users/sessions/grants inventory path.
  """
  def auth_cutover_stop_inventory do
    with {:ok, assets} <- auth_cutover_stop_assets() do
      {:ok,
       %{
         "schema_version" => 1,
         "mode" => "read_only",
         "empty" => Enum.all?(assets, &(&1["record_count"] == 0)),
         "artifacts" => assets,
         "destructive_actions" => []
       }}
    end
  end

  def generate do
    with {:ok, active_assets} <- active_assets(),
         {:ok, retired_conversation_assets} <- retired_conversation_assets(),
         {:ok, auth_cutover_stop_assets} <- auth_cutover_stop_assets(),
         {:ok, legacy_assets} <- legacy_assets(),
         {:ok, history_assets} <- history_assets(),
         {:ok, workspaces} <- LegacyS3Inventory.all(:workspaces),
         {:ok, workspace_items} <- workspace_item_asset(workspaces),
         {:ok, legacy_event_streams} <- legacy_event_stream_asset(),
         {:ok, identity_history} <- identity_history_asset() do
      checks = [
        check(
          "legacy_auth_prefixes_empty",
          Enum.sum(Enum.map(auth_cutover_stop_assets, & &1["record_count"])),
          "legacy S3 users/sessions/grants are empty; any rows stop cutover and require a separately owned migration design"
        )
      ]

      {:ok,
       %{
         "schema_version" => 3,
         "generated_at" =>
           DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
         "mode" => "read_only",
         "machine_ready" => Enum.all?(checks, &(&1["status"] == "pass")),
         "machine_checks" => checks,
         "manual_gates" => Enum.map(@manual_gates, &%{"id" => &1, "status" => "unconfirmed"}),
         "artifacts" =>
           active_assets ++
             retired_conversation_assets ++
             auth_cutover_stop_assets ++
             [workspace_items] ++
             legacy_assets ++
             [legacy_event_streams] ++
             history_assets ++
             [identity_history],
         "destructive_actions" => []
       }}
    end
  end

  defp active_assets do
    materialize_buckets(@active_buckets, fn
      {bucket, owner, target, secret_posture, mapping, writers, readers},
      values,
      last_written_at ->
        asset(
          bucket,
          "active_serving",
          owner,
          writers,
          readers,
          values,
          last_written_at,
          "migrate",
          target,
          secret_posture,
          mapping
        )
    end)
  end

  defp retired_conversation_assets do
    materialize_buckets(@retired_conversation_buckets, fn
      {bucket, secret_posture}, values, last_written_at ->
        retired_conversation_asset(bucket, values, last_written_at, secret_posture)
    end)
  end

  defp auth_cutover_stop_assets do
    Enum.reduce_while(@auth_cutover_stop_buckets, {:ok, []}, fn
      {bucket, secret_posture, readers}, {:ok, acc} ->
        prefix = "comma/#{bucket}/"

        case SalixStore.S3.list(prefix, max_keys: 1) do
          {:ok, %{objects: objects, next: next}} ->
            case latest_last_modified(objects) do
              {:ok, last_written_at} ->
                artifact =
                  asset(
                    bucket,
                    "non_serving_cutover_stop",
                    "retired Comma S3 auth implementation",
                    "none",
                    readers,
                    objects,
                    last_written_at,
                    "migration_decision_required",
                    "undecided",
                    secret_posture,
                    "requires_explicit_migration_design"
                  )
                  |> Map.merge(%{
                    "record_count_semantics" => "bounded_existence_lower_bound",
                    "record_count_limit" => 1,
                    "has_more" => not is_nil(next)
                  })

                {:cont, {:ok, [artifact | acc]}}

              {:error, reason} ->
                {:halt, {:error, {:inventory_unavailable, bucket, reason}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:inventory_unavailable, bucket, {:unavailable, reason}}}}
        end
    end)
    |> case do
      {:ok, assets} -> {:ok, Enum.reverse(assets)}
      {:error, _} = error -> error
    end
  end

  defp legacy_assets do
    materialize_buckets(@legacy_buckets, fn bucket, values, last_written_at ->
      asset(
        bucket,
        "legacy_data",
        "retired Comma-local Conversation implementation",
        "none",
        @inventory_reader,
        values,
        last_written_at,
        "inventory_then_purge",
        "none",
        "historical_private_data",
        "exclude_legacy"
      )
    end)
  end

  defp history_assets do
    materialize_buckets(@history_buckets, fn bucket, values, last_written_at ->
      asset(
        bucket,
        "append_only_history",
        "historical Comma migration audit",
        "none",
        ["ops/audit tooling only"],
        values,
        last_written_at,
        "retain",
        "none",
        "historical_audit",
        "exclude_history"
      )
    end)
  end

  defp materialize_buckets(definitions, materializer) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, acc} ->
      bucket = if is_tuple(definition), do: elem(definition, 0), else: definition

      case LegacyS3Inventory.all_with_metadata(bucket) do
        {:ok, rows} ->
          case latest_last_modified(rows) do
            {:ok, last_written_at} ->
              values = Enum.map(rows, & &1.value)
              {:cont, {:ok, [materializer.(definition, values, last_written_at) | acc]}}

            {:error, reason} ->
              {:halt, {:error, {:inventory_unavailable, bucket, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:inventory_unavailable, bucket, reason}}}
      end
    end)
    |> case do
      {:ok, assets} -> {:ok, Enum.reverse(assets)}
      {:error, _} = error -> error
    end
  end

  defp workspace_item_asset(workspaces) do
    Enum.reduce_while(workspaces, {:ok, []}, fn workspace, {:ok, acc} ->
      bucket = "workspace_conversation_items/#{workspace["id"]}"

      case LegacyS3Inventory.all_with_metadata(bucket) do
        {:ok, rows} -> {:cont, {:ok, rows ++ acc}}
        {:error, reason} -> {:halt, {:error, {:inventory_unavailable, bucket, reason}}}
      end
    end)
    |> case do
      {:ok, rows} ->
        with {:ok, last_written_at} <- latest_last_modified(rows) do
          {:ok,
           %{
             "id" => "workspace_conversation_items",
             "bucket" => "workspace_conversation_items/<workspace_id>",
             "key_prefix" => "comma/workspace_conversation_items/<workspace_id>/",
             "category" => "legacy_data",
             "canonical_owner" => "retired Comma-local Conversation implementation",
             "current_writer" => "none",
             "current_writers" => [],
             "current_readers" => @inventory_reader,
             "record_count" => length(rows),
             "last_written_at" => last_written_at,
             "external_references" => [],
             "target_relation" => "none",
             "secret_posture" => "private_projection",
             "migration_mapping" => "exclude_legacy",
             "disposition" => "inventory_then_purge",
             "disposition_owner" => "Comma ops",
             "verification_command" => verification_command()
           }}
        end

      {:error, _} = error ->
        error
    end
  end

  defp legacy_event_stream_asset do
    prefix = "comma/conversation_events/"

    case SalixStore.S3.list_all(prefix) do
      {:ok, objects} ->
        with {:ok, last_written_at} <- latest_last_modified(objects) do
          {:ok,
           %{
             "id" => "conversation_event_streams",
             "key_prefix" => prefix,
             "category" => "legacy_data",
             "canonical_owner" => "retired Comma-local Conversation implementation",
             "current_writer" => "none",
             "current_writers" => [],
             "current_readers" => @inventory_reader,
             "record_count" => length(objects),
             "last_written_at" => last_written_at,
             "external_references" => [],
             "target_relation" => "none",
             "secret_posture" => "historical_private_data",
             "migration_mapping" => "exclude_legacy",
             "disposition" => "inventory_then_purge",
             "disposition_owner" => "Comma ops",
             "verification_command" => verification_command()
           }}
        end

      {:error, reason} ->
        {:error, {:inventory_unavailable, prefix, reason}}
    end
  end

  defp identity_history_asset do
    prefix = "ctl/migrations/conversation_identity_v1/"

    case SalixStore.S3.list_all(prefix) do
      {:ok, objects} ->
        with {:ok, last_written_at} <- latest_last_modified(objects) do
          {:ok,
           %{
             "id" => "conversation_identity_history",
             "key_prefix" => prefix,
             "category" => "append_only_history",
             "canonical_owner" => "Salix conversation identity migration",
             "current_writer" => "migration ledger only",
             "current_writers" => ["migration ledger only"],
             "current_readers" => ["migration retry/audit tooling"],
             "record_count" => length(objects),
             "last_written_at" => last_written_at,
             "external_references" => ["migration completion and identity maps"],
             "target_relation" => "none",
             "secret_posture" => "historical_audit",
             "migration_mapping" => "exclude_history",
             "disposition" => "retain",
             "disposition_owner" => "Salix ops",
             "verification_command" =>
               "prove serving runtime has zero reads before retention change"
           }}
        end

      {:error, reason} ->
        {:error, {:inventory_unavailable, prefix, reason}}
    end
  end

  defp retired_conversation_asset(bucket, values, last_written_at, secret_posture) do
    asset(
      bucket,
      "legacy_data",
      "retired Comma-local Conversation implementation",
      "none",
      @inventory_reader,
      values,
      last_written_at,
      "inventory_then_purge",
      "none",
      secret_posture,
      "exclude_legacy"
    )
  end

  defp asset(
         bucket,
         category,
         owner,
         writer,
         readers,
         values,
         last_written_at,
         disposition,
         target_relation,
         secret_posture,
         migration_mapping
       ) do
    writers = if is_list(writer), do: writer, else: if(writer == "none", do: [], else: [writer])

    %{
      "id" => to_string(bucket),
      "bucket" => to_string(bucket),
      "key_prefix" => "comma/#{bucket}/",
      "category" => category,
      "canonical_owner" => owner,
      "current_writer" => List.first(writers) || "none",
      "current_writers" => writers,
      "current_readers" => readers,
      "record_count" => length(values),
      "last_written_at" => last_written_at,
      "external_references" => [],
      "target_relation" => target_relation,
      "secret_posture" => secret_posture,
      "migration_mapping" => migration_mapping,
      "disposition" => disposition,
      "disposition_owner" => "Comma",
      "verification_command" => verification_command()
    }
  end

  defp check(id, count, expectation) do
    %{
      "id" => id,
      "status" => if(count == 0, do: "pass", else: "block"),
      "blocking_count" => count,
      "expectation" => expectation
    }
  end

  defp latest_last_modified([]), do: {:ok, nil}

  defp latest_last_modified(objects) do
    values = Enum.map(objects, &Map.get(&1, :last_modified))

    if Enum.all?(values, &is_binary/1),
      do: {:ok, Enum.max(values)},
      else: {:error, {:unavailable, :last_modified}}
  end

  defp verification_command, do: "mix comma.hard_cut.inventory --require-machine-ready"
end
