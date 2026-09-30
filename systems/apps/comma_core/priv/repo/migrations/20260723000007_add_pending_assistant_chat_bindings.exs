defmodule Comma.Repo.Migrations.AddPendingAssistantChatBindings do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE comma_assistant_chat_bindings
    DROP CONSTRAINT IF EXISTS comma_assistant_chat_bindings_state_check
    """)

    create(
      constraint(:comma_assistant_chat_bindings, :comma_assistant_chat_bindings_state_check,
        check: """
        (status = 'active'
          AND conversation_id IS NOT NULL
          AND disposition IS NULL
          AND replacement_seed_salix_conversation_id IS NULL)
        OR
        (status = 'pending'
          AND conversation_id IS NULL
          AND disposition IS NULL)
        OR
        (status = 'invalid_candidate'
          AND conversation_id IS NULL
          AND disposition = 'replace_invalid_router_participant'
          AND replacement_seed_salix_conversation_id IS NOT NULL)
        """
      )
    )
  end

  def down do
    execute("DELETE FROM comma_assistant_chat_bindings WHERE status = 'pending'")

    execute("""
    ALTER TABLE comma_assistant_chat_bindings
    DROP CONSTRAINT IF EXISTS comma_assistant_chat_bindings_state_check
    """)

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
  end
end
