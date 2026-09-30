defmodule Comma.Migrations.ProductStateImportAudit do
  @moduledoc """
  PostgreSQL-only verification of the immutable final product-state import ledger.

  The S3 importer was retired after cutover. This audit can only verify the
  already-persisted ledger and its content digest.
  """

  alias Comma.Data.ImportRun

  @identity "comma-product-state-final-import-v1"
  @ledger_relations MapSet.new([
                      "comma_users",
                      "comma_workspaces",
                      "comma_workspace_memberships",
                      "comma_conversation_bindings",
                      "comma_salix_conversation_projections",
                      "comma_assistant_chat_bindings",
                      "comma_conversation_adoption_suppressions",
                      "comma_external_operations",
                      "comma_conversation_adoption_attempts",
                      "comma_reconciliation_cursors",
                      "comma_sessions",
                      "comma_session_budget_consumptions",
                      "comma_workspace_conversation_items"
                    ])
  @ledger_exclusions MapSet.new([
                       "conversation_aggregate_legacy",
                       "conversation_aggregate_projection_legacy",
                       "grants_no_serving_reader"
                     ])

  @spec verify(module(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(repo \\ Comma.Repo, expected_digest)

  def verify(repo, expected_digest) when is_binary(expected_digest) do
    with true <- valid_digest?(expected_digest) || {:error, :invalid_release_evidence},
         %ImportRun{} = run <- repo.get(ImportRun, @identity) || {:error, :import_ledger_missing},
         true <- valid_import_run?(run) || {:error, :import_ledger_drift},
         true <- run.evidence_digest == expected_digest || {:error, :ledger_digest_mismatch} do
      {:ok,
       %{
         release_identity: @identity,
         ledger_digest: run.evidence_digest,
         completed_at: run.completed_at
       }}
    else
      {:error, _} = error -> error
      _invalid -> {:error, :import_ledger_drift}
    end
  end

  def verify(_repo, _expected_digest), do: {:error, :invalid_release_evidence}

  defp valid_import_run?(%ImportRun{} = run) do
    expected =
      digest(%{
        "release_identity" => run.release_identity,
        "status" => run.status,
        "evidence" => run.evidence,
        "completed_at" => DateTime.to_iso8601(run.completed_at)
      })

    run.release_identity == @identity and run.status == "complete" and
      valid_ledger_payload?(run.evidence) and run.evidence_digest == expected
  end

  defp valid_ledger_payload?(%{
         "schema_version" => 1,
         "release_identity" => @identity,
         "mode" => "import",
         "status" => "pass",
         "source_count" => source_count,
         "source_object_count" => source_object_count,
         "target_count" => target_count,
         "checkpoint_count" => checkpoint_count,
         "membership_index_count" => membership_index_count,
         "excluded_counts" => excluded_counts,
         "relation_counts" => relation_counts,
         "source_digest" => source_digest,
         "target_digest" => target_digest,
         "checkpoint_digest" => checkpoint_digest,
         "checkpoint_target_digest" => checkpoint_target_digest,
         "secret_posture" => "redacted"
       }) do
    non_negative_integer?(source_count) and
      non_negative_integer?(source_object_count) and
      non_negative_integer?(target_count) and
      non_negative_integer?(checkpoint_count) and
      non_negative_integer?(membership_index_count) and
      target_count == source_count and checkpoint_count == source_count and
      valid_count_map?(relation_counts, @ledger_relations, target_count) and
      valid_count_map?(excluded_counts, @ledger_exclusions) and
      valid_digest?(source_digest) and valid_digest?(target_digest) and
      valid_digest?(checkpoint_digest) and checkpoint_target_digest == target_digest
  end

  defp valid_ledger_payload?(_payload), do: false

  defp valid_count_map?(value, allowed, expected_total \\ nil)

  defp valid_count_map?(value, allowed, expected_total) when is_map(value) do
    valid? =
      Enum.all?(value, fn {key, count} ->
        is_binary(key) and MapSet.member?(allowed, key) and is_integer(count) and count > 0
      end)

    valid? and (is_nil(expected_total) or Enum.sum(Map.values(value)) == expected_total)
  end

  defp valid_count_map?(_value, _allowed, _expected_total), do: false
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)

  defp digest(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(%DateTime{} = value),
    do: {:utc_microsecond, DateTime.to_unix(value, :microsecond)}

  defp canonical(value) when is_map(value) do
    value |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end) |> Enum.sort()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
