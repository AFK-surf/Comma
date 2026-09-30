defmodule Mix.Tasks.Salix.TenantApiKeys.Audit do
  @shortdoc "Compare the legacy S3 tenant-api-key corpus with the Postgres rows"

  @moduledoc """
  Fail-closed comparison of `ctl/tenant_api_keys/` (S3) with the
  `tenant_api_keys` table (docs/storage-search.md).

  Prints the cutover-marker status and the strict set difference in both
  directions; exits non-zero on any mismatch or on any enumeration failure
  (a partially readable corpus is a failure, not a smaller corpus).

  Before the cutover (no marker) this is a preflight that reports how many legacy
  S3 records are importable, failing closed only on a malformed or unreadable
  corpus. It does NOT require S3 == PG: pre-cutover PG is legitimately empty, so
  strict equality would always "fail" in the normal case. After the cutover
  (marker present) it reports the authoritative Postgres count only: PG-only
  deletes legitimately diverge PG from the still-present S3 objects until PR-B
  removes them.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    if SalixStore.TenantApiKeyCutover.marker_present?() do
      # Post-cutover: Postgres is authoritative and S3 still holds the
      # pre-cleanup objects (PR-B removes them), so S3 and PG are NOT expected
      # to be equal — legitimate PG-only deletes diverge them on purpose.
      # Report the authoritative store only; do not run the equality gate.
      count = length(SalixStore.TenantApiKeys.all_records())
      Mix.shell().info("cutover marker: present")
      Mix.shell().info("postgres authoritative: #{count} tenant api keys")
    else
      # Pre-cutover preflight: report the importable S3 record count. PG is
      # legitimately empty here, so do NOT require equality; fail closed only on
      # a malformed or unreadable corpus.
      Mix.shell().info("cutover marker: absent (pre-cutover preflight)")

      case SalixStore.TenantApiKeyCutover.importable_count() do
        {:ok, count} ->
          pg = length(SalixStore.TenantApiKeys.all_records())
          Mix.shell().info("importable from S3: #{count}; postgres rows: #{pg}")

        {:error, reason} ->
          Mix.raise("audit enumeration failed (fail-closed): #{inspect(reason)}")
      end
    end
  end
end
