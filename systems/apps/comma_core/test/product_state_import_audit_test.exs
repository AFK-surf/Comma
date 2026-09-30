defmodule Comma.ProductStateImportAuditTest do
  use ExUnit.Case, async: true

  alias Comma.Data.ImportRun
  alias Comma.Migrations.{ProductStateImportAudit, ProductStateImporter}

  defmodule RepoStub do
    def get(ImportRun, "comma-product-state-final-import-v1"),
      do: Process.get({__MODULE__, :run})
  end

  test "accepts the immutable complete ledger without reading S3" do
    run = valid_run()
    Process.put({RepoStub, :run}, run)

    assert {:ok, evidence} = ProductStateImportAudit.verify(RepoStub, run.evidence_digest)
    assert evidence.release_identity == run.release_identity
    assert evidence.ledger_digest == run.evidence_digest

    assert {:ok, audit} =
             ProductStateImporter.audit(
               repo: RepoStub,
               expected_ledger_digest: run.evidence_digest,
               expected_release_identity: run.release_identity
             )

    assert :ok = ProductStateImporter.audit_postcondition(audit)
  end

  test "rejects malformed ledger payload and an expected digest mismatch" do
    run = valid_run()
    Process.put({RepoStub, :run}, %{run | evidence: Map.delete(run.evidence, "secret_posture")})

    assert {:error, :import_ledger_drift} =
             ProductStateImportAudit.verify(RepoStub, run.evidence_digest)

    Process.put({RepoStub, :run}, run)

    assert {:error, :ledger_digest_mismatch} =
             ProductStateImportAudit.verify(RepoStub, String.duplicate("f", 64))
  end

  test "audit-only compatibility surface rejects missing or wrong identity" do
    run = valid_run()
    Process.put({RepoStub, :run}, run)

    assert {:error, %{errors: [%{code: :release_identity_mismatch}]}} =
             ProductStateImporter.audit(
               repo: RepoStub,
               expected_ledger_digest: run.evidence_digest,
               expected_release_identity: "obsolete-import"
             )

    assert {:error, %{errors: [%{code: :ledger_digest_required}]}} =
             ProductStateImporter.audit(
               repo: RepoStub,
               expected_release_identity: run.release_identity
             )
  end

  defp valid_run do
    identity = "comma-product-state-final-import-v1"
    digest = String.duplicate("0", 64)
    completed_at = ~U[2026-07-23 00:00:00.000000Z]

    evidence = %{
      "schema_version" => 1,
      "release_identity" => identity,
      "mode" => "import",
      "status" => "pass",
      "source_count" => 0,
      "source_object_count" => 0,
      "target_count" => 0,
      "checkpoint_count" => 0,
      "membership_index_count" => 0,
      "excluded_counts" => %{},
      "relation_counts" => %{},
      "source_digest" => digest,
      "target_digest" => digest,
      "checkpoint_digest" => digest,
      "checkpoint_target_digest" => digest,
      "secret_posture" => "redacted"
    }

    envelope = %{
      "release_identity" => identity,
      "status" => "complete",
      "evidence" => evidence,
      "completed_at" => DateTime.to_iso8601(completed_at)
    }

    %ImportRun{
      release_identity: identity,
      status: "complete",
      evidence: evidence,
      evidence_digest: digest(envelope),
      completed_at: completed_at
    }
  end

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
