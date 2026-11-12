defmodule SalixStore.Repo.Migrations.CreateSalixTaskFiles do
  use Ecto.Migration

  # The Task file index (`SalixStore.TaskFiles`): one row per file or image an
  # Agent attached to a Task Message, written with the Message in its source
  # transaction. Expand-only: a new table, which old runtimes ignore. Rows for
  # Messages appended before this release come from the backfill the release
  # opens after the rollout (`SalixIM.TaskFiles.open_after_rollout/1`); readers
  # stay closed until it completes.
  def change do
    create table(:salix_task_files, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:conversation_id, :text, primary_key: true)
      add(:seq, :bigint, primary_key: true)
      add(:block_index, :integer, primary_key: true)
      add(:message_id, :text, null: false)
      add(:kind, :text, null: false)
      add(:file_name, :text, null: false)
      add(:folded_name, :text, null: false)
      add(:mime_type, :text)
      add(:size, :bigint, null: false)
      add(:agent_id, :text, null: false)
      add(:task_title, :text, null: false, default: "")
      add(:created_at, :bigint, null: false)
    end

    create(
      constraint(:salix_task_files, :salix_task_files_kind_valid,
        check: "kind in ('file', 'image')"
      )
    )

    # A Group's files, newest first, by keyset (the index read backward). A
    # file-name search walks it too, within its Group.
    create(
      index(:salix_task_files, [:group_id, :created_at, :conversation_id, :seq, :block_index],
        name: :salix_task_files_group_recent
      )
    )
  end
end
