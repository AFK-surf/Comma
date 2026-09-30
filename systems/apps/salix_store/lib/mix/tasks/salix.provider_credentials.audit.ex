defmodule Mix.Tasks.Salix.ProviderCredentials.Audit do
  @shortdoc "Compare the legacy S3 provider-credential corpus with the Postgres rows"

  @moduledoc """
  Fail-closed comparison of the legacy S3 provider-credential objects (Composio
  settings + Feishu bot apps) with their Postgres tables
  (docs/storage-search.md).

  Prints the cutover-marker status. Before the cutover (no marker) it reports the
  importable record count per class, failing closed only on a malformed or
  unreadable corpus (PG is legitimately empty pre-cutover, so it does not require
  equality). After the cutover (marker present) it reports the authoritative
  Postgres counts only: PG-only deletes legitimately diverge PG from the
  still-present S3 objects until the cleanup PR removes them.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    if SalixStore.ProviderCredentialsCutover.marker_present?() do
      composio = length(SalixStore.ComposioSettings.all_scoped_records())
      feishu = length(SalixStore.FeishuTenantApps.all_records())
      Mix.shell().info("cutover marker: present")
      Mix.shell().info("postgres authoritative: composio=#{composio} feishu=#{feishu}")
    else
      Mix.shell().info("cutover marker: absent (pre-cutover preflight)")

      case SalixStore.ProviderCredentialsCutover.importable_count() do
        {:ok, %{"composio" => composio, "feishu" => feishu}} ->
          Mix.shell().info("importable from S3: composio=#{composio} feishu=#{feishu}")

        {:error, reason} ->
          Mix.raise("audit enumeration failed (fail-closed): #{inspect(reason)}")
      end
    end
  end
end
