defmodule SalixAgent.InternalAgentRuntimeStatusTest do
  @moduledoc """
  `session_status/2` reports the model an internal session runs on and how much
  of that model's context window its live context occupies — measured against
  the SAME window and estimate the auto-compaction trigger uses.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{Compaction, InternalAgentRuntime, InternalSessionStore}

  defmodule ControlTemplateResolver do
    @moduledoc false
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.Templates.resolve_llm_for_agent(agent_id)
  end

  defmodule FailingResolver do
    @moduledoc false
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(_agent_id), do: {:error, :template_unreadable}
  end

  # An agent with no template-backed config: no control record, or a blank
  # `template_id`.
  defmodule EmptyResolver do
    @moduledoc false
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(_agent_id), do: {:ok, nil}
  end

  @session_id "ses1_0000000000000009001"

  setup do
    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      llm_resolver: Application.get_env(:salix_agent, :llm_resolver)
    }

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm_resolver, ControlTemplateResolver)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_agent, :llm_resolver, previous.llm_resolver)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()

    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      "model" => "claude-opus-5",
      "provider" => "anthropic",
      "context_tokens" => 200_000
    })

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

  @tag resident_activity: true
  test "resident activity uses committed state without rereading the Session", %{
    agent_id: agent_id
  } do
    alias SalixAgent.InternalSessionActor
    alias SalixStore.{Keys, S3}

    assert {:ok, initial} = InternalAgentRuntime.get_session_activity(agent_id, @session_id)
    refute InternalSessionActor.running?(agent_id, @session_id)
    {:ok, revision} = InternalSessionStore.read_revision(agent_id, @session_id)

    owner =
      start_supervised!(
        {InternalSessionActor,
         agent_id: agent_id, session_id: @session_id, process_on_init: false}
      )

    :sys.replace_state(owner, &%{&1 | revision: revision})
    key = Keys.agent_internal_runtime_session(agent_id, @session_id)

    assert :ok = S3.Fake.set_fault({:fail, 503, :get, key})
    assert {:ok, ^initial} = InternalAgentRuntime.get_session_activity(agent_id, @session_id)
    assert {:error, _} = S3.get(key)

    {:ok, pending} =
      InternalSessionStore.write_revision(revision, [
        %{"type" => "status", "status" => "active"},
        %{"type" => "activity_status", "activity_status" => "thinking"}
      ])

    :sys.replace_state(owner, &%{&1 | revision: pending})
    assert :ok = S3.Fake.set_fault({:fail, 503, :get, key})
    assert {:ok, ^initial} = InternalAgentRuntime.get_session_activity(agent_id, @session_id)
    assert {:error, _} = S3.get(key)

    :sys.replace_state(owner, fn state ->
      {:ok, committed} = InternalSessionStore.durable_fence(agent_id, @session_id, state.revision)
      %{state | revision: committed}
    end)

    assert :ok = S3.Fake.set_fault({:fail, 503, :get, key})

    assert {:ok, %{"state" => "active", "status" => "is thinking..."}} =
             InternalAgentRuntime.get_session_activity(agent_id, @session_id)

    assert {:error, _} = S3.get(key)

    stop_supervised!({InternalSessionActor, agent_id, @session_id})

    assert {:ok, %{"state" => "active", "status" => "is thinking..."}} =
             InternalAgentRuntime.get_session_activity(agent_id, @session_id)

    refute InternalSessionActor.running?(agent_id, @session_id)
  end

  test "reports the live template model and context usage", %{agent_id: agent_id} do
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

  # A template edit applies on the next read (willow's activation-time resolve),
  # so the status surface must never report a snapshot.
  test "picks up a template model change without restarting anything", %{agent_id: agent_id} do
    {:ok, agent} = SalixAgent.Control.get(agent_id)

    {:ok, _tmpl} =
      SalixAgent.Templates.update(agent["template_id"], %{"model" => "claude-fable-5"})

    assert {:ok, %{"model" => "claude-fable-5"}} =
             InternalAgentRuntime.session_status(agent_id, @session_id)
  end

  # Diagnostics degrade rather than fail: the session's own context facts are
  # still true, and reporting the 128000 default as this agent's window would
  # misstate the denominator.
  test "omits model and window when the template cannot be resolved", %{agent_id: agent_id} do
    Application.put_env(:salix_agent, :llm_resolver, FailingResolver)

    assert {:ok, status} = InternalAgentRuntime.session_status(agent_id, @session_id)

    refute Map.has_key?(status, "model")
    refute Map.has_key?(status, "context_tokens")
    assert status["estimated_context_tokens"] > 0
  end

  # The reachable degradation shape: `resolve_runtime/1` maps `{:ok, nil}` to
  # `{:ok, []}`, and `context_window([])` answers the 128000 default. That is a
  # real number but not a statement about THIS agent, so it must not appear as
  # a denominator under a usage figure nothing sized.
  test "omits the window when the resolver returns no config at all", %{agent_id: agent_id} do
    Application.put_env(:salix_agent, :llm_resolver, EmptyResolver)

    assert {:ok, []} = SalixAgent.LlmResolver.resolve_runtime(agent_id)
    assert Compaction.context_window([]) == 128_000

    assert {:ok, status} = InternalAgentRuntime.session_status(agent_id, @session_id)

    refute Map.has_key?(status, "model")
    refute Map.has_key?(status, "context_tokens")
    assert status["estimated_context_tokens"] > 0
  end

  test "an unknown session is an error, not an empty status", %{agent_id: agent_id} do
    assert {:error, _reason} =
             InternalAgentRuntime.session_status(agent_id, "ses1_0000000000000009999")
  end

  defp read_session!(agent_id, session_id) do
    {:ok, session} = InternalSessionStore.read(agent_id, session_id)
    session
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
