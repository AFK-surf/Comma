defmodule Comma.Repo.Migrations.IndexCompletedObanJobsForPruner do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Oban's Pruner selects `state = 'completed' AND scheduled_at < cutoff`
  # beside the cancelled and discarded branches that Oban migration 13
  # indexes. Without this index each pass reads the whole table, which holds a
  # full day of finished jobs.
  def change do
    create_if_not_exists(
      index(:oban_jobs, [:state, :scheduled_at],
        name: :oban_jobs_state_scheduled_at_index,
        concurrently: true
      )
    )
  end
end
