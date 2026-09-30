defmodule BridgeForTeams.Repo.Migrations.AddReplacementStateToUserAssistantChats do
  use Ecto.Migration

  def change do
    alter table(:user_assistant_chats) do
      add :disposition, :string
      add :replacement_seed_conversation_id, :string
    end
  end
end
