defmodule SalixAgent.InternalAgentRuntimeStatusTest do
  @moduledoc """
  `session_status/2` reports the model an internal session runs on and how much
  of that model's context window its live context occupies — measured against
  the SAME window and estimate the auto-compaction trigger uses.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{Compaction, InternalAgentRuntime, InternalSessionStore}

  defmodule AgentModelResolver do
    @moduledoc false
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.AgentModel.resolve_llm_for_agent(agent_id)
  end

  defmodule FailingResolver do
    @moduledoc false
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(_agent_id), do: {:error, :model_unreadable}
  end

  # An agent with no resolvable config: no control record.
  defmodule EmptyResolver do
    @moduledoc false
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(_agent_id), do: {:ok, nil}
  end

  @session_id "ses1_0000000000000009001"

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      llm_resolver: SystemsRuntime.get_env(:salix_agent, :llm_resolver)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, AgentModelResolver)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_agent, :llm_resolver, previous.llm_resolver)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()

    SalixAgent.TestSupport.create_control_agent!(agent_id)
    configure_worker_model!("claude-opus-5")

    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 1,
          "content" => String.duplicate("a", 4_000)
        },
        %{
          "type" => "assistant",
          "session_id" => @session_id,
          "message_id" => 2,
          "content" => "done"
        },
        %{"type" => "ack", "session_id" => @session_id, "last_ack_message_id" => 2}
      ])

    %{agent_id: agent_id}
  end

  test "reports the live model and context usage", %{agent_id: agent_id} do
    assert {:ok, status} = InternalAgentRuntime.session_status(agent_id, @session_id)

    assert status["agent_id"] == agent_id
    assert status["session_id"] == @session_id
    assert status["runtime_kind"] == "internal"
    assert status["model"] == "claude-opus-5"
    assert status["provider"] == "anthropic"
    assert status["context_tokens"] == 200_000
    assert status["message_count"] == 2
    assert status["compacted_through"] == 0
    session = read_session!(agent_id, @session_id)

    # The chat surface renders these as the session's state annotation, so a
    # dropped key silently removes "(failed)" from every status reply.
    assert status["status"] == to_string(SalixAgent.InternalSession.status(session))

    assert status["activity_status"] ==
             to_string(SalixAgent.InternalSession.activity_status(session))

    assert status["context_bytes"] == SalixAgent.InternalSession.context_byte_size(session)

    # The reported usage IS the trigger's own estimate, not a second one.
    assert status["estimated_context_tokens"] == Compaction.context_tokens_used(session)
    assert status["estimated_context_tokens"] > 0
    assert status["estimated_context_tokens"] < status["context_tokens"]
  end

  defp read_session!(agent_id, session_id) do
    {:ok, session} = InternalSessionStore.read(agent_id, session_id)
    session
  end

  # The Agent follows the platform Worker model.
  defp configure_worker_model!(model) do
    SalixAgent.TestSupport.configure_platform_tier!(
      "worker",
      "https://api.anthropic.example.test/v1",
      model,
      %{"context_tokens" => 200_000}
    )
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
