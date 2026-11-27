defmodule Comma.Repo.Migrations.CreateDocumentShares do
  use Ecto.Migration

  def change do
    create table(:comma_document_shares, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:token, :text, null: false)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:group_id, :text, null: false)
      add(:conversation_id, :text, null: false)

      add(:created_by, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:file_name, :text, null: false)
      add(:message_id, :text, null: false)
      add(:block_index, :integer, null: false)
      add(:revoked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_document_shares, [:token]))

    create(
      unique_index(:comma_document_shares, [:conversation_id, :file_name],
        where: "revoked_at IS NULL",
        name: :comma_document_shares_active_document_index
      )
    )

    create(index(:comma_document_shares, [:workspace_id]))

    create(
      constraint(:comma_document_shares, :comma_document_shares_block_index_check,
        check: "block_index >= 0"
      )
    )
  end
end
