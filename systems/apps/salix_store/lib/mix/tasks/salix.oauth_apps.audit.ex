defmodule Mix.Tasks.Salix.OauthApps.Audit do
  @shortdoc "Compare the legacy S3 OAuth-apps corpus with the Postgres rows"

  @moduledoc """
  Fail-closed comparison of the legacy S3 OAuth static-client-credential objects
  (provider apps + deployment defaults) with their `oauth_provider_apps` Postgres
  table (docs/storage-search.md, PR-1). Remote-MCP provider apps
  stay in S3 and migrate in a later PR.

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

    # Three-state: an unreadable marker table must fail non-zero, not fold into
    # "absent" and silently report a preflight against an unreachable database.
    case SalixStore.OAuthAppsCutover.marker_status() do
      :present ->
        provider = length(SalixStore.OAuthProviderApps.all_scoped_records())
        Mix.shell().info("cutover marker: present")
        Mix.shell().info("postgres authoritative: provider_apps=#{provider}")

      :absent ->
        Mix.shell().info("cutover marker: absent (pre-cutover preflight)")

        bound = Application.get_env(:salix_store, :oauth_apps_cutover_max_objects, 500)

        case SalixStore.OAuthAppsCutover.importable_count() do
          {:ok, %{"provider_apps" => provider}} when provider > bound ->
            Mix.raise(
              "importable count #{provider} exceeds the recorded preflight bound #{bound} — " <>
                "the maintenance-cutover approval lapses; re-rehearse at the new scale " <>
                "(run/0 enforces the same bound and would abort)"
            )

          {:ok, %{"provider_apps" => provider}} ->
            Mix.shell().info("importable from S3: provider_apps=#{provider} (bound #{bound})")

          {:error, reason} ->
            Mix.raise("audit enumeration failed (fail-closed): #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("cutover marker table unreadable (fail-closed): #{inspect(reason)}")
    end
  end
end
