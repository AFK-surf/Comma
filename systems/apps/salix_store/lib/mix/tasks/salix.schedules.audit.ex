defmodule Mix.Tasks.Salix.Schedules.Audit do
  @shortdoc "Compare the legacy S3 schedule corpus with the Postgres rows"

  @moduledoc """
  Fail-closed comparison of the legacy S3 schedule definitions
  (`ctl/schedules/{id}.json`) with the Postgres `schedules` table
  (docs/storage-search.md).

  Prints the cutover-marker status. Before the cutover (no marker) it reports
  the importable record count, failing closed only on a malformed or unreadable
  corpus (PG is legitimately empty pre-cutover, so it does not require
  equality). After the cutover (marker present) it reports the authoritative
  Postgres count only: PG-only writes legitimately diverge PG from the
  still-present S3 objects until the cleanup PR removes them. Run claims are
  deliberately not compared — they are not imported (see
  `SalixStore.SchedulesCutover`).
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    if SalixStore.SchedulesCutover.marker_present?() do
      count = length(SalixStore.Schedules.all_records())
      Mix.shell().info("cutover marker: present")
      Mix.shell().info("postgres authoritative: schedules=#{count}")
    else
      Mix.shell().info("cutover marker: absent (pre-cutover preflight)")

      case SalixStore.SchedulesCutover.importable_count() do
        {:ok, %{"schedules" => count}} ->
          Mix.shell().info("importable from S3: schedules=#{count}")

        {:error, reason} ->
          Mix.raise("audit enumeration failed (fail-closed): #{inspect(reason)}")
      end
    end
  end
end
