defmodule SalixStore.Repo.Migrations.CreateSlackSemanticJobs do
  use Ecto.Migration

  # New optional queue schema only. Canonical message tables and the webhook
  # outbox are untouched; neither migration nor readiness calls the GPU.
  def up do
    Oban.Migration.up(prefix: "slack_semantic", version: 14)

    create(
      index(:oban_jobs, [:priority, :inserted_at],
        prefix: "slack_semantic",
        name: :semantic_pending,
        where: "state IN ('available', 'scheduled', 'retryable', 'executing')"
      )
    )

    create(
      index(:oban_jobs, [:inserted_at, :id],
        prefix: "slack_semantic",
        name: :semantic_terminal_cleanup,
        where: "state IN ('completed', 'cancelled')"
      )
    )
  end

  def down, do: Oban.Migration.down(prefix: "slack_semantic", version: 1)
end
