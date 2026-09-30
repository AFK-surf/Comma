defmodule SalixAgent.CompactionRecoveryPinTest do
  @moduledoc """
  The recovery producer's own regression.

  `auto_compaction_failure_events/6` writes a fixed recovery summary when
  summarization failed, and it is the likeliest of the three producers to
  commit long after the snapshot it describes. The archive suite covers the
  reducer and archive consequences, but it builds the compaction event by
  hand — so it cannot catch this producer omitting the pin, which is exactly
  what happened in the first cut. This drives the real producer.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{Compaction, InternalAgentRuntime, InternalSessionStore}

  @session "ses1_0000000000000000960"

  defmodule ControlTemplateResolver do
    def resolve(agent_id), do: SalixAgent.Templates.resolve_llm_for_agent(agent_id)
  end

  # Lands the second writer from INSIDE the model call — i.e. after the
  # snapshot compaction took, before it commits — then answers without the
  # `<compacted-context>` tags, which is a non-retryable failure and routes
  # into the recovery summary.
  defmodule LateWriterLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: complete(messages, tools, [])

    @impl true
    def complete(_messages, _tools, _opts) do
      {agent_id, session_id} = :persistent_term.get({__MODULE__, :target})

      {:ok, _} =
        SalixAgent.InternalSessionStore.prepare_commit(agent_id, session_id, [
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => "call-late",
            "status" => "running",
            "started_at" => 5_000
          },
          %{
            "type" => "async_tool_call_completed",
            "session_id" => session_id,
            "tool_call_id" => "call-late",
            "result" => %{"answer" => 42},
            "completed_at" => 5_001
          }
        ])

      # The assistant shape the summarizer expects, but with no
      # `<compacted-context>` tags — `missing_compaction_summary_tags`, which
      # is non-retryable and therefore routes into the recovery summary.
      {:assistant, "a summary with no tags at all", []}
    end
  end

  setup do
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_resolver = Application.get_env(:salix_agent, :llm_resolver)
    prev_summarizer = Application.get_env(:salix_agent, :summarizer)
    # `create_control_agent!/1` below installs a test GroupContext into the
    # GLOBAL app env. Capture it too, or this suite leaves it behind and
    # later synchronous tests behave differently depending on file order.
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    Application.put_env(:salix_agent, :llm, LateWriterLLM)
    Application.put_env(:salix_agent, :llm_resolver, ControlTemplateResolver)
    Application.delete_env(:salix_agent, :summarizer)

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      restore(:llm, prev_llm)
      restore(:llm_resolver, prev_resolver)
      restore(:summarizer, prev_summarizer)
      restore(:group_context_mod, prev_group_context)
      SalixAgent.TestSupport.stop_all_agents()
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, @session, [
        %{"type" => "session_created", "session_id" => @session, "name" => "Recovery pin"},
        # >= 2 messages including a user turn, or summarization skips as
        # "too small to compact meaningfully" before reaching the model.
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session,
          "message_id" => 1,
          "role" => "user",
          "content" => String.duplicate("q", 400),
          "source_message_id" => "src-1",
          "created_at" => 1_001
        },
        %{
          "type" => "assistant",
          "session_id" => @session,
          "message_id" => 2,
          "content" => String.duplicate("x", 400),
          "created_at" => 1_002
        },
        %{"type" => "ack", "session_id" => @session, "last_ack_message_id" => 2}
      ])

    # The session actor compacts, and the model call runs in its dependency
    # job, so the late writer finds its target here.
    :persistent_term.put({LateWriterLLM, :target}, {agent_id, @session})
    on_exit(fn -> :persistent_term.erase({LateWriterLLM, :target}) end)

    {:ok, agent_id: agent_id}
  end

  defp restore(key, value, app \\ :salix_agent)
  defp restore(key, nil, app), do: Application.delete_env(app, key)
  defp restore(key, value, app), do: Application.put_env(app, key, value)

  test "the recovery summary never covers a record that landed while it was failing", %{
    agent_id: agent_id
  } do
    {:ok, snapshot} = read_state(agent_id, @session)
    assert snapshot.last_seq == 2

    # `maybe_compact_session`, not `compact`: the recovery producer only runs
    # under `auto_compaction`, which is the automatic path. `threshold: 1`
    # forces it past the prefilter. Summarization then fails with
    # `missing_compaction_summary_tags` — non-retryable — so the recovery
    # summary is written, and the late result was committed from inside the
    # model call, above everything that summary could describe.
    assert {:ok, _context, %{"status" => status}} =
             Compaction.maybe_compact_session(
               %{agent_id: agent_id, session_id: @session},
               @session,
               threshold: 1
             )

    assert status in ["failed_soft", "failed_hard"]

    {:ok, session} = read_state(agent_id, @session)
    late = Enum.find(session.async_results, &(&1["tool_call_id"] == "call-late"))
    assert late["seq"] == 3, "the second writer must land above the snapshot"

    assert session.summary_sequence == snapshot.summary_sequence + 1,
           "the recovery summary must have been written by the real producer"

    # THE assertion. Without the pin the producer's event takes the reducer's
    # apply-time fallback, which — every message being covered — falls back
    # to last_seq and swallows the late result.
    assert session.compacted_seq == 2,
           "recovery summary covered seq #{session.compacted_seq}, but only saw up to 2"

    # And the consequence it protects: after archival the result is still
    # reachable rather than moved out of the window under a summary that
    # never described it.
    Application.put_env(:salix_store, :seal_line_bytes, 1)
    on_exit(fn -> Application.delete_env(:salix_store, :seal_line_bytes) end)
    # Archival writes as the session's owner: the actor that compacted it.
    [{owner, _}] =
      Registry.lookup(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(agent_id, @session)
      )

    test = self()

    :sys.replace_state(owner, fn state ->
      send(test, {:archived, InternalSessionStore.archive_compacted(agent_id, @session)})
      state
    end)

    assert_receive {:archived, {:ok, :archived}}

    assert {:ok, record} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-late")

    assert record["result"] == %{"answer" => 42}
  end

  # The store hands back an opaque handle; these fixtures assert over the
  # exported state and re-open it whenever a handle is required.
  defp read_state(agent_id, session_id) do
    with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, SalixAgent.InternalSession.export(session)}
    end
  end
end
