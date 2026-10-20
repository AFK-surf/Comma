defmodule Comma.Repo.Migrations.AddLinearAgentSessionTask do
  use Ecto.Migration

  # A Linear session now maps to a chat Conversation with the Router
  # (`conversation_id`); the Task the Router creates from it, if any, is
  # bound separately. Existing rows pointed straight at a Task.
  def up do
    alter table(:comma_linear_agent_sessions) do
      add(:task_conversation_id, :text)
    end

    execute("UPDATE comma_linear_agent_sessions SET task_conversation_id = conversation_id")
  end

  def down do
    alter table(:comma_linear_agent_sessions) do
      remove(:task_conversation_id)
    end
  end
end
