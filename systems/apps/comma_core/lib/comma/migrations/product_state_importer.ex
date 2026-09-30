defmodule Comma.Migrations.ProductStateImporter do
  @moduledoc """
  Audit-only compatibility name retained by the immutable cutover migration.

  The executable S3 importer was retired in Phase 7. This module has no import,
  source-read, or write API; it verifies only the final PostgreSQL ledger.
  """

  @identity "comma-product-state-final-import-v1"

  def audit(opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Comma.Repo)

    with @identity <- Keyword.get(opts, :expected_release_identity),
         expected_digest when is_binary(expected_digest) <-
           Keyword.get(opts, :expected_ledger_digest),
         {:ok, evidence} <-
           Comma.Migrations.ProductStateImportAudit.verify(repo, expected_digest) do
      {:ok,
       %{
         schema_version: 1,
         mode: :audit,
         status: :pass,
         release_identity: evidence.release_identity,
         ledger_digest: evidence.ledger_digest,
         verified_ledger_digest: expected_digest,
         verification_source: :postgres_import_ledger,
         completed_at: evidence.completed_at,
         secret_posture: :redacted
       }}
    else
      nil -> {:error, failure(:ledger_digest_required)}
      identity when is_binary(identity) -> {:error, failure(:release_identity_mismatch)}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  def audit_postcondition(%{
        schema_version: 1,
        mode: :audit,
        status: :pass,
        release_identity: @identity,
        ledger_digest: digest,
        verified_ledger_digest: digest,
        verification_source: :postgres_import_ledger,
        secret_posture: :redacted
      })
      when is_binary(digest),
      do: :ok

  def audit_postcondition(_evidence), do: {:error, :invalid_audit_evidence}

  defp failure(code), do: %{schema_version: 1, status: :fail, errors: [%{code: code}]}
end
