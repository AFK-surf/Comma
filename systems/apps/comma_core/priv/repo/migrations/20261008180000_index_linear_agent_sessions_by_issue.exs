defmodule Comma.Repo.Migrations.IndexLinearAgentSessionsByIssue do
  use Ecto.Migration

  # An Issue webhook finds the sessions of that issue inside its installation.
  def change do
    create(index(:comma_linear_agent_sessions, [:installation_id, :issue_id]))
  end
end
