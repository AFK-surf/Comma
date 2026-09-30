defmodule SalixAgent.InternalSessionFlushSettlementTest do
  use ExUnit.Case, async: false

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
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
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

  test "a matching flush marker cannot confirm different durable input facts" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    key = created_session(agent_id)
    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session)
    Application.put_env(:salix_store, :s3_backend, SameMarkerBackend)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, S3.Fake) end)
    SameMarkerBackend.arm(key)
    input = %{source_message_id: "unwritten-input", payload: %{content: "must be durable"}}

    assert {{:error, :precondition_failed}, _revision, nil} =
             SalixAgent.InternalSession.Command.run(
               agent_id,
               @session,
               base,
               :input,
               {input, false}
             )

    assert {:ok, %{body: body}} = S3.get(key)
    assert Codec.decode_snapshot(body).input_queue == []
  end

  test "source progress and input remain atomic across an uncommitted candidate and a lost CAS reply" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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
    agent_id = "agent-#{System.unique_integer([:positive])}"
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

  test "a scanned position and a previously admitted input advance without adding work" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    created_session(agent_id)
    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session)
    input = %{source_message_id: "existing", payload: %{content: "accepted work"}}

    assert {{:ok, :committed}, admitted, nil} =
             InternalSession.Command.run(agent_id, @session, base, :input, {input, false})

    source = %{
      "conversation_id" => "conversation",
      "participant_id" => "participant",
      "generation" => @session,
      "seq" => 1
    }

    entry = Map.put(input, :conversation_source, source)

    assert {{:ok, :committed}, advanced, nil} =
             InternalSession.Command.run(agent_id, @session, admitted, :input, {entry, false})

    scan = %{
      source_message_id: nil,
      payload: %{},
      conversation_source: Map.put(source, "seq", 2),
      conversation_scan_only: true
    }

    assert {{:ok, :committed}, _, nil} =
             InternalSession.Command.run(agent_id, @session, advanced, :input, {scan, false})

    assert {:ok, stored} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.conversation_sources(stored)["participant"]["seq"] == 2
    assert length(InternalSession.export(stored).input_queue) == 1
  end

  test "a duplicate of staged input must cross its durable fence before acknowledgment" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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

  test "a failed fence cannot acknowledge a duplicate found only in working state" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    key = created_session(agent_id)
    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session)
    input = %{source_message_id: "uncommitted-duplicate", payload: %{content: "not yet durable"}}

    assert {{:awaiting_fence, _}, staged, nil} =
             SalixAgent.InternalSession.Command.prepare(
               agent_id,
               @session,
               base,
               :input,
               {input, false}
             )

    Application.put_env(:salix_store, :s3_backend, SameMarkerBackend)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, S3.Fake) end)
    SameMarkerBackend.arm(key)

    assert {{:error, :precondition_failed}, restored, nil} =
             SalixAgent.InternalSession.Command.run(
               agent_id,
               @session,
               staged,
               :input,
               {input, false}
             )

    assert restored.etag == base.etag
    assert restored.pending == nil
    assert InternalSession.export(restored.state) === InternalSession.export(base.state)
    assert {:ok, %{body: body}} = S3.get(key)
    assert Codec.decode_snapshot(body).input_queue == []
  end

  test "ambiguous-but-landed CAS settles as committed without re-applying the batch" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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
    agent_id = "agent-#{System.unique_integer([:positive])}"
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
    agent_id = "agent-#{System.unique_integer([:positive])}"
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

  test "a landed write whose settlement budget exhausts is adopted, never re-applied" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    key = created_session(agent_id)

    # The PUT lands but the response is lost, and every settlement read-back
    # fails until the budget is gone. The commit's final byte-exact read-back
    # must adopt the landed state — retrying would double-apply the
    # dedupe-keyless assistant event. Faults are injected from the builder
    # so the commit's own base read stays clean.
    builder = fn _state ->
      :ok = S3.Fake.set_fault({:ambiguous_after, :put, key})
      for _ <- 1..4, do: :ok = S3.Fake.set_fault({:fail, 503, :get, key})
      {:ok, [assistant_event(1)], []}
    end

    assert {:ok, state, _meta} = InternalSessionStore.commit_dynamic(agent_id, @session, builder)

    assert {:ok, %{body: body}} = S3.get(key)
    stored = Codec.decode_snapshot(body)

    assert Enum.count(
             stored.messages,
             &(&1.role == "assistant")
           ) == 1

    assert stored.messages == SalixAgent.InternalSession.get(state, :messages)
  end

  test "an unchanged baseline after budget exhaustion does not reapply the batch" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    key = created_session(agent_id)

    # An unchanged baseline cannot distinguish a lost PUT from an in-flight PUT.
    # Exhaustion must not authorize another materialization.
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    builder = fn _state ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
        :ok = S3.Fake.set_fault({:ambiguous_before, :put, key})
        for _ <- 1..4, do: :ok = S3.Fake.set_fault({:fail, 503, :get, key})
      end

      {:ok, [assistant_event(1)], []}
    end

    assert {:error, :commit_indeterminate} =
             InternalSessionStore.commit_dynamic(agent_id, @session, builder)

    assert Agent.get(calls, & &1) == 1

    assert {:ok, %{body: body}} = S3.get(key)
    stored = Codec.decode_snapshot(body)

    assert Enum.count(
             stored.messages,
             &(&1.role == "assistant")
           ) == 0
  end

  test "an original CAS that lands during final read-back does not duplicate the batch" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    key = created_session(agent_id)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    builder = fn _state ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
        :ok = S3.Fake.set_fault({:apply_after_next_get, :put, key})
        for _ <- 1..4, do: :ok = S3.Fake.set_fault({:fail, 503, :get, key})
      end

      {:ok, [assistant_event(1)], []}
    end

    assert {:ok, state, _meta} = InternalSessionStore.commit_dynamic(agent_id, @session, builder)
    assert {:ok, %{body: body}} = S3.get(key)
    stored = Codec.decode_snapshot(body)
    assert Enum.count(stored.messages, &(&1.role == "assistant")) == 1
    assert stored.messages == InternalSession.get(state, :messages)
    assert Agent.get(calls, & &1) == 1
  end

  test "an original CAS that lands after the settlement read applies the batch once" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    key = created_session(agent_id)

    # The settlement read is not a fence: the ambiguous PUT is still in
    # flight, the read sees the unchanged base, the original then lands, and
    # the same-bytes retry takes a stale 412 for our own write. Treating that
    # 412 as a conflict would rebase and re-apply the dedupe-less assistant
    # record — the duplicate this asserts against.
    builder = fn _state ->
      :ok = S3.Fake.set_fault({:apply_after_next_get, :put, key})
      {:ok, [assistant_event(1)], []}
    end

    assert {:ok, state, _meta} = InternalSessionStore.commit_dynamic(agent_id, @session, builder)

    assert {:ok, %{body: body}} = S3.get(key)
    stored = Codec.decode_snapshot(body)

    assert Enum.count(
             stored.messages,
             &(&1.role == "assistant")
           ) == 1

    assert stored.messages == SalixAgent.InternalSession.get(state, :messages)
  end
end
