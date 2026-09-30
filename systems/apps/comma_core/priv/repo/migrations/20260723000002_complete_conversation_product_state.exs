defmodule Comma.Repo.Migrations.CompleteConversationProductState do
  use Ecto.Migration

  def up do
    alter table(:comma_import_checkpoints) do
      add(:release_identity, :string)
    end

    execute("""
    UPDATE comma_import_checkpoints
    SET release_identity = 'comma-product-state-import-v1'
    WHERE release_identity IS NULL
    """)

    drop(index(:comma_import_checkpoints, [], name: :comma_import_checkpoint_target_idx))
    execute("ALTER TABLE comma_import_checkpoints DROP CONSTRAINT comma_import_checkpoints_pkey")

    alter table(:comma_import_checkpoints) do
      modify(:release_identity, :string, null: false)
    end

    execute("""
    ALTER TABLE comma_import_checkpoints
    ADD CONSTRAINT comma_import_checkpoints_pkey PRIMARY KEY (release_identity, source_key)
    """)

    create(
      unique_index(
        :comma_import_checkpoints,
        [:release_identity, :target_relation, :target_identity],
        name: :comma_import_checkpoint_target_idx
      )
    )

    alter table(:comma_conversation_bindings) do
      add(:salix_group_id, :string)
      add(:group_generation, :string)
    end

    execute("""
    UPDATE comma_conversation_bindings AS binding
    SET salix_group_id = workspace.salix_group_id,
        group_generation = workspace.group_generation
    FROM comma_workspaces AS workspace
    WHERE workspace.id = binding.workspace_id
      AND (binding.salix_group_id IS NULL OR binding.group_generation IS NULL)
    """)

    alter table(:comma_conversation_bindings) do
      modify(:salix_group_id, :string, null: false)
      modify(:group_generation, :string, null: false)
    end

    create(
      index(
        :comma_conversation_bindings,
        [:workspace_id, :salix_group_id, :group_generation, :kind, :state, :id],
        name: :comma_conversation_bindings_authorization_page_idx
      )
    )

    alter table(:comma_assistant_chat_bindings) do
      modify(:conversation_id, :string, null: true)
      add(:status, :string, null: false, default: "active")
      add(:disposition, :string)
      add(:replacement_seed_salix_conversation_id, :string)
    end

    create(
      constraint(:comma_assistant_chat_bindings, :comma_assistant_chat_bindings_state_check,
        check: """
        (status = 'active'
          AND conversation_id IS NOT NULL
          AND disposition IS NULL
          AND replacement_seed_salix_conversation_id IS NULL)
        OR
        (status = 'invalid_candidate'
          AND conversation_id IS NULL
          AND disposition = 'replace_invalid_router_participant'
          AND replacement_seed_salix_conversation_id IS NOT NULL)
        """
      )
    )

    alter table(:comma_conversation_adoption_attempts) do
      add(:metadata, :map, null: false, default: %{})
    end

    alter table(:comma_conversation_adoption_suppressions) do
      modify(:expires_at, :utc_datetime_usec, null: true)
    end
  end

  def down do
    execute(
      "DELETE FROM comma_import_checkpoints WHERE release_identity = 'comma-product-state-final-import-v1'"
    )

    drop(index(:comma_import_checkpoints, [], name: :comma_import_checkpoint_target_idx))
    execute("ALTER TABLE comma_import_checkpoints DROP CONSTRAINT comma_import_checkpoints_pkey")

    alter table(:comma_import_checkpoints) do
      remove(:release_identity)
    end

    execute("""
    ALTER TABLE comma_import_checkpoints
    ADD CONSTRAINT comma_import_checkpoints_pkey PRIMARY KEY (source_key)
    """)

    create(
      unique_index(:comma_import_checkpoints, [:target_relation, :target_identity],
        name: :comma_import_checkpoint_target_idx
      )
    )

    execute("DELETE FROM comma_conversation_adoption_suppressions WHERE expires_at IS NULL")

    alter table(:comma_conversation_adoption_suppressions) do
      modify(:expires_at, :utc_datetime_usec, null: false)
    end

    alter table(:comma_conversation_adoption_attempts) do
      remove(:metadata)
    end

    drop(constraint(:comma_assistant_chat_bindings, :comma_assistant_chat_bindings_state_check))

    alter table(:comma_assistant_chat_bindings) do
      remove(:replacement_seed_salix_conversation_id)
      remove(:disposition)
      remove(:status)
      modify(:conversation_id, :string, null: false)
    end

    drop(
      index(:comma_conversation_bindings, [],
        name: :comma_conversation_bindings_authorization_page_idx
      )
    )

    alter table(:comma_conversation_bindings) do
      remove(:group_generation)
      remove(:salix_group_id)
    end
  end
end
