defmodule Comma.Repo.Migrations.AddCommaDurableOperations do
  use Ecto.Migration

  def up do
    Oban.Migration.up()

    alter table(:comma_external_operations) do
      add(:finished_at, :utc_datetime_usec)
    end

    create(
      constraint(:comma_external_operations, :comma_external_operations_terminal_evidence_check,
        check: """
        (
          status IN ('succeeded', 'terminal_failed', 'superseded')
          AND finished_at IS NOT NULL
        ) OR (
          status IN ('pending', 'executing', 'retryable')
          AND finished_at IS NULL
        )
        """
      )
    )
  end

  def down do
    drop(constraint(:comma_external_operations, :comma_external_operations_terminal_evidence_check))

    alter table(:comma_external_operations) do
      remove(:finished_at)
    end

    Oban.Migration.down(version: 1)
  end
end
