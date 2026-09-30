defmodule BridgeForTeams.Repo.Migrations.AddContextTrackingToUserAssistantChats do
  use Ecto.Migration

  def change do
    alter table(:user_assistant_chats) do
      # Which revision of the dashboard-context instructions this conversation
      # last received (sha256 of the stable instruction block), and the chat
      # session's compaction sequence at that send. A NULL digest (every
      # pre-existing row) or a drifted value triggers one context refresh on
      # the next dashboard visit — see AssistantChats.ensure_chat/4.
      add :context_digest, :string
      add :context_summary_seq, :integer
    end
  end
end
