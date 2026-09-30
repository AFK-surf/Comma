defmodule Mix.Tasks.Salix.TenantConfigs.Audit do
  @shortdoc "Compare the legacy S3 tenant-config corpus with the Postgres rows"

  @moduledoc """
  Fail-closed comparison of the legacy S3 tenant-config objects
  (`ctl/tenant_configs/{tenant_id}/{name}.json`) with the Postgres
  `tenant_configs` table (docs/storage-search.md).

  Prints the cutover-marker status. Before the cutover (no marker) it reports the
  importable record count, failing closed only on a malformed or unreadable
  corpus (PG is legitimately empty pre-cutover, so it does not require equality).
  After the cutover (marker present) it reports the authoritative Postgres count
  only: PG-only deletes legitimately diverge PG from the still-present S3 objects
  until the cleanup PR removes them.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    if SalixStore.TenantConfigsCutover.marker_present?() do
      count = length(SalixStore.TenantConfigs.all_records())
      Mix.shell().info("cutover marker: present")
      Mix.shell().info("postgres authoritative: tenant_configs=#{count}")
    else
      Mix.shell().info("cutover marker: absent (pre-cutover preflight)")

      case SalixStore.TenantConfigsCutover.importable_count() do
        {:ok, %{"tenant_configs" => count}} ->
          Mix.shell().info("importable from S3: tenant_configs=#{count}")

        {:error, reason} ->
          Mix.raise("audit enumeration failed (fail-closed): #{inspect(reason)}")
      end
    end
  end
end
