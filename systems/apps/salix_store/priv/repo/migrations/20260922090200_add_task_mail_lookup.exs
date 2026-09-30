defmodule SalixStore.Repo.Migrations.AddTaskMailLookup do
  use Ecto.Migration

  def change do
    alter table(:conversation_search_states) do
      add(:mail_account_id, :text)
      add(:mail_thread_id, :text)
    end

    create(
      index(
        :conversation_search_states,
        [:writer_generation, :agent_group_id, :mail_account_id, :mail_thread_id],
        name: :conversation_search_mail_source,
        where: "mail_account_id IS NOT NULL AND mail_thread_id IS NOT NULL"
      )
    )
  end
end
