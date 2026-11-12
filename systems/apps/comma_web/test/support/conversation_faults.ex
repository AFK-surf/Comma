defmodule CommaWeb.TestConversationFaults do
  @moduledoc false

  import ExUnit.Callbacks
  alias SalixStore.Repo

  def block_append!(group_id, conversation_id) do
    name = "comma_append_fault_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    group = String.replace(group_id, "'", "''")
    conversation = String.replace(conversation_id, "'", "''")

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.group_id = '#{group}' AND NEW.conversation_id = '#{conversation}'
         AND NEW.seq IS NOT NULL THEN
        RAISE EXCEPTION 'test Conversation append unavailable';
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER #{name} BEFORE INSERT OR UPDATE ON salix_conversation_messages " <>
        "FOR EACH ROW EXECUTE FUNCTION #{name}()"
    )

    unblock = fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON salix_conversation_messages")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
      :ok
    end

    on_exit(unblock)
    unblock
  end
end
