defmodule SalixAgent.InternalSessionFlushSettlementTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{InternalSession, InternalSessionActor, InternalSessionStore}
  alias SalixStore.{Codec, Keys, S3}

  @session "ses1_0000000000000000700"

  defmodule SameMarkerBackend do
    def arm(key), do: Process.put({__MODULE__, :target}, key)

    def put(key, body, opts) do
      if Process.get({__MODULE__, :target}) == key do
        Process.delete({__MODULE__, :target})
        candidate = Codec.decode_snapshot(body)
        {:ok, %{body: original}} = S3.Fake.get(key, [])
        base = Codec.decode_snapshot(original)
        # A foreign CAS retains the base facts but shares this attempt's marker.
        # The caller's candidate does not land; its transport result is lost.
        foreign = %{base | flush_id: candidate.flush_id}
        {:ok, _} = S3.Fake.put(key, Codec.encode_snapshot(foreign), opts)
        for _ <- 1..4, do: S3.Fake.set_fault({:fail, 503, :get, key})
        {:error, {:ambiguous, :injected}}
      else
        S3.Fake.put(key, body, opts)
      end
    end

    defdelegate get(key, opts), to: S3.Fake
    defdelegate head(key), to: S3.Fake
    defdelegate list(prefix, opts), to: S3.Fake
    defdelegate delete(key, opts), to: S3.Fake
  end

  setup do
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    :ok
  end

  defp become_owner(agent_id, session_id) do
    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id), nil)

    :ok
  end

  defp created_session(agent_id) do
    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session, %{})
    become_owner(agent_id, @session)
    Keys.agent_internal_runtime_session(agent_id, @session)
  end

  defp deliver_event(id) do
    %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => id,
      "role" => "user",
      "content" => "input #{id}",
      "source_message_id" => "src-#{id}",
      "created_at" => 1_000 + id
    }
  end

  defp assistant_event(id) do
    %{"type" => "assistant", "message_id" => id, "content" => "reply", "created_at" => 2_000}
  end

  test "source progress and input remain atomic across an uncommitted candidate and a lost CAS reply" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    key = created_session(agent_id)
    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session)

    entry = %{
      source_message_id: "conversation-input",
      payload: %{content: "accepted work"},
      conversation_source: %{
        "conversation_id" => "conversation",
        "participant_id" => "participant",
        "generation" => @session,
        "seq" => 1
      }
    }

    assert {{:awaiting_fence, _}, _uncommitted, nil} =
             InternalSession.Command.prepare(agent_id, @session, base, :input, {entry, false})

    assert {:ok, before} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.conversation_sources(before) == %{}
    assert InternalSession.export(before).input_queue == []

    S3.Fake.set_fault({:ambiguous_after, :put, key})

    assert {{:ok, :committed}, committed, nil} =
             InternalSession.Command.run(agent_id, @session, base, :input, {entry, false})

    assert {:ok, after_crash} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.conversation_sources(after_crash)["participant"]["seq"] == 1
    assert length(InternalSession.export(after_crash).input_queue) == 1

    assert {{:ok, :duplicate}, _, nil} =
             InternalSession.Command.run(agent_id, @session, committed, :input, {entry, false})

    assert {:ok, after_retry} = InternalSessionStore.read(agent_id, @session)
    assert length(InternalSession.export(after_retry).input_queue) == 1

    other = %{
      entry
      | source_message_id: "another-conversation-input",
        conversation_source: %{
          entry.conversation_source
          | "participant_id" => "other-participant",
            "conversation_id" => "other-conversation"
        }
    }

    assert {{:ok, :committed}, _, nil} =
             InternalSession.Command.run(agent_id, @session, committed, :input, {other, false})

    assert {:ok, fan_in} = InternalSessionStore.read(agent_id, @session)
    assert map_size(InternalSession.conversation_sources(fan_in)) == 2
    assert length(InternalSession.export(fan_in).input_queue) == 2
  end

  test "source gaps and retired binding generations cannot admit inputs" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    created_session(agent_id)
    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session)

    for {seq, generation} <- [{2, @session}, {1, "retired-session"}] do
      entry = %{
        source_message_id: "rejected-source",
        payload: %{content: "must not enter"},
        conversation_source: %{
          "conversation_id" => "conversation",
          "participant_id" => "participant",
          "generation" => generation,
          "seq" => seq
        }
      }

      assert {{:error, :conversation_source_gap}, _, nil} =
               InternalSession.Command.run(agent_id, @session, base, :input, {entry, false})
    end

    assert {:ok, stored} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.conversation_sources(stored) == %{}
    assert InternalSession.export(stored).input_queue == []
  end

  test "a duplicate of staged input must cross its durable fence before acknowledgment" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    key = created_session(agent_id)
    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session)
    input = %{source_message_id: "staged-duplicate", payload: %{content: "retain this input"}}

    assert {{:awaiting_fence, _}, staged, nil} =
             SalixAgent.InternalSession.Command.prepare(
               agent_id,
               @session,
               base,
               :input,
               {input, false}
             )

    assert {:ok, %{body: before}} = S3.get(key)
    assert Codec.decode_snapshot(before).input_queue == []

    assert {{:ok, :duplicate}, committed, nil} =
             SalixAgent.InternalSession.Command.run(
               agent_id,
               @session,
               staged,
               :input,
               {input, false}
             )

    assert {:ok, %{body: after_write}} = S3.get(key)

    assert [%{"dedupe_key" => "staged-duplicate"}] =
             Codec.decode_snapshot(after_write).input_queue

    assert committed.pending == nil
  end

  test "ambiguous-but-landed CAS settles as committed without re-applying the batch" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    key = created_session(agent_id)

    :ok = S3.Fake.set_fault({:ambiguous_after, :put, key})

    assert {:ok, state} =
             InternalSessionStore.commit(agent_id, @session, [assistant_event(1)])

    assert Enum.count(SalixAgent.InternalSession.get(state, :messages)) == 1

    # The durable object holds the batch exactly once.
    assert {:ok, %{body: body}} = S3.get(key)
    stored = Codec.decode_snapshot(body)

    assert Enum.count(
             stored.messages,
             &(&1.role == "assistant")
           ) == 1

    assert stored.messages == SalixAgent.InternalSession.get(state, :messages)
  end

  test "ambiguous-not-landed CAS retries the same materialization" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    key = created_session(agent_id)

    :ok = S3.Fake.set_fault({:ambiguous_before, :put, key})

    assert {:ok, state} =
             InternalSessionStore.commit(agent_id, @session, [deliver_event(1)])

    assert {:ok, %{body: body}} = S3.get(key)
    stored = Codec.decode_snapshot(body)

    # Retries retain the same materialization.
    assert Enum.count(stored.messages) == 1

    assert stored.messages == SalixAgent.InternalSession.get(state, :messages)
  end

  test "a takeover between ambiguity and settlement rebases instead of double-writing" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    key = created_session(agent_id)

    # First commit lands one message so the takeover has a base to move.
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [deliver_event(1)])

    # The builder runs after the commit captured its base: a foreign writer
    # moves the object, then the owner's own put is swallowed without
    # applying. Settlement reads back a foreign object at a foreign ETag —
    # neither our bytes nor our base — and must rebase, not blind-retry.
    injected = {__MODULE__, :takeover_injected}
    Process.delete(injected)

    builder = fn _state ->
      unless Process.get(injected, false) do
        Process.put(injected, true)

        {:ok, %{body: body, etag: etag}} = S3.get(key)
        foreign = Codec.decode_snapshot(body)
        foreign = %{foreign | storage_revision: "foreign-revision", flush_id: "foreign-flush"}
        {:ok, _} = S3.put(key, Codec.encode_snapshot(foreign), if_match: etag)

        :ok = S3.Fake.set_fault({:ambiguous_before, :put, key})
      end

      {:ok, [assistant_event(2)]}
    end

    assert {:ok, state, _meta} = InternalSessionStore.commit_dynamic(agent_id, @session, builder)

    # The rebase re-read the foreign object and applied the batch exactly
    # once on top of it.
    assert {:ok, %{body: body}} = S3.get(key)
    stored = Codec.decode_snapshot(body)

    assert Enum.count(
             stored.messages,
             &(&1.role == "assistant")
           ) == 1

    assert stored.messages == SalixAgent.InternalSession.get(state, :messages)
  end
end
