defmodule Comma.Repo.Migrations.AddConversationOperationOwners do
  use Ecto.Migration

  def change do
    create table(:comma_conversation_operation_owners, primary_key: false) do
      add(:owner_key, :string, primary_key: true)
      add(:operation_type, :string, null: false)
      add(:owner_type, :string, null: false)
      add(:owner_id, :string, null: false)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:desired_generation, :integer, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :comma_conversation_operation_owners,
        [:operation_type, :owner_type, :owner_id],
        name: :comma_conversation_operation_owner_identity_idx
      )
    )

    create(
      constraint(
        :comma_conversation_operation_owners,
        :comma_conversation_operation_owner_generation_check,
        check: "desired_generation >= 0"
      )
    )
  end
end
