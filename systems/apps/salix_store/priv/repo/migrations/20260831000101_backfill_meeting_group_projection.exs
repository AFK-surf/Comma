defmodule SalixStore.Repo.Migrations.BackfillMeetingGroupProjection do
  @moduledoc """
  Online, idempotent completion of the meeting group projection rollout.

  The projection-first writer shipped before this migration. While normal
  meeting writes continue, this pass fills every legacy row, verifies exact
  S3-to-PostgreSQL identity and row-count equality, and only then persists the
  `meeting_group_projection_v1` readiness marker. A partial attempt leaves the
  source unsealed and retries through this exact migration version.
  """

  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # TLA: tla/salix/MeetingGroupIndex.tla::SealReady.
    # The online migrator starts the repo, but the authoritative meeting scan
    # also needs salix_store's S3 client and storage configuration.
    started_apps =
      case Application.ensure_all_started(:salix_store) do
        {:ok, started} ->
          started

        {:error, reason} ->
          raise "failed to start salix_store for meeting projection: #{inspect(reason)}"
      end

    try do
      case SalixMeet.Release.run_online_group_projection_backfill() do
        :ok ->
          :ok

        {:error, reason} ->
          raise "meeting group projection online backfill failed: #{inspect(reason)}"
      end
    after
      # In the cold `Comma.Release.migrate/0` carrier, with_repo owns the Repo
      # that was already alive when SalixStore.Application started. The app
      # therefore does not supervise that Repo, and with_repo stops it after
      # this migration. Restore the pre-migration application state so the
      # following dev/compose cutovers can start salix_store again with a
      # supervised Repo instead of observing a started app with no Repo.
      if :salix_store in started_apps do
        :ok = Application.stop(:salix_store)
      end
    end
  end
end
