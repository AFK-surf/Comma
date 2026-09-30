defmodule SalixAgent.ContextFreshnessFixture do
  @moduledoc false

  def seed_old_prompt!(agent_id, session_id, prompt, stale_date) do
    prompt = prompt <> "\n<agent-config>\ncurrent_date: " <> stale_date <> "\n</agent-config>"

    {:ok, _} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id},
        %{
          "type" => "session_system_prompt",
          "session_id" => session_id,
          "system_prompt" => prompt
        },
        %{
          "type" => "assistant",
          "session_id" => session_id,
          "message_id" => 1,
          "content" => "Previous task completed.",
          "do_not_send_to_llm" => %{
            "context_provider_states" => %{
              "migration_notice" => %{"version" => SalixAgent.MigrationNotice.version()}
            }
          }
        },
        %{"type" => "ack", "session_id" => session_id, "last_ack_message_id" => 1}
      ])

    :ok
  end
end
