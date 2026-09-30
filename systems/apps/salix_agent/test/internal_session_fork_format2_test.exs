defmodule SalixAgent.InternalSessionForkFormat2Test do
  use ExUnit.Case, async: false

  alias SalixAgent.{
    AgentWorkspace,
    ImageRefs,
    InternalAgentRuntime,
    InternalSession,
    InternalSessionActor,
    InternalSessionStore
  }

  alias SalixAgent.InternalSession.State

  @source "ses1_0000000000000000860"

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    {:ok, agent_id: agent_id}
  end

  defp deliver(id) do
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

  defp stored_result(ref, call_id) do
    result_json = Jason.encode!(%{"call" => call_id, "payload" => String.duplicate("x", 1_000)})

    %{
      "type" => "tool_result_stored",
      "session_id" => @source,
      "result_ref" => ref,
      "tool_call_id" => call_id,
      "tool_name" => "composio.execute",
      "result_json" => result_json,
      "result_sha256" => :crypto.hash(:sha256, result_json) |> Base.encode16(case: :lower),
      "result_bytes" => byte_size(result_json),
      "result_chars" => String.length(result_json),
      "status" => "completed",
      "is_error" => false,
      "stored_at_ms" => 2_000
    }
  end

  defp result_capsule(message_id, ref, call_id) do
    %{
      "type" => "tool_result",
      "session_id" => @source,
      "message_id" => message_id,
      "tool_call_id" => call_id,
      "tool_name" => "composio.execute",
      "status" => "completed",
      "content" => Jason.encode!(%{"stored_result" => true, "result_ref" => ref}),
      "created_at" => 3_000 + message_id
    }
  end

  defp seed_source(agent_id, events, extra_events \\ []) do
    # Historical format-2 sources exercise read/fork compatibility. Business
    # writes use the current format; archived legacy data is prepared by a fixture.
    creation = %{"type" => "session_created", "session_id" => @source, "name" => "Source"}

    state =
      agent_id
      |> InternalSession.new(@source, %{})
      |> InternalSession.export()
      |> Map.put(:storage_format, 2)
      |> InternalSession.open()
      |> InternalSession.apply_events([creation | events])
      |> InternalSession.normalize()

    key = SalixStore.Keys.agent_internal_runtime_session(agent_id, @source)

    {:ok, _} =
      SalixStore.S3.put(
        key,
        SalixStore.Codec.encode_snapshot(InternalSession.export(state))
      )

    case extra_events do
      [] ->
        state

      extra ->
        {:ok, state} = InternalSessionStore.prepare_commit(agent_id, @source, extra)
        state
    end
  end

  test "the derived target address is a valid session id and a pure function of the identity" do
    a = InternalAgentRuntime.derive_fork_target_id(@source, "req-1")
    b = InternalAgentRuntime.derive_fork_target_id(@source, "req-1")
    c = InternalAgentRuntime.derive_fork_target_id(@source, "req-2")

    assert a == b
    refute a == c
    assert SalixStore.Ids.valid_session_id?(a)
  end

  test "a fork without identity is rejected", %{agent_id: agent_id} do
    seed_source(agent_id, [deliver(1)])

    assert {:error, :fork_identity_required} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{"name" => "F"})
  end

  test "retrying the same fork_request_id returns the existing target instead of a second fork",
       %{
         agent_id: agent_id
       } do
    seed_source(agent_id, [deliver(1), deliver(2)])

    attrs = %{"fork_request_id" => "req-idem", "name" => "F"}

    assert {:ok, first} = InternalAgentRuntime.fork_session_local(agent_id, @source, attrs)
    assert {:ok, second} = InternalAgentRuntime.fork_session_local(agent_id, @source, attrs)

    assert first["session_id"] == second["session_id"]

    assert {:ok, sessions} = InternalSessionStore.list(agent_id)

    fork_ids =
      sessions
      |> Enum.map(&SalixAgent.InternalSession.session_id/1)
      |> Enum.reject(&(&1 == @source))

    assert length(fork_ids) == 1
  end

  test "a different request colliding on the same explicit target is a genuine conflict", %{
    agent_id: agent_id
  } do
    seed_source(agent_id, [deliver(1)])
    target = "ses1_0000000000000000861"

    assert {:ok, _} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "target_session_id" => target,
               "fork_request_id" => "req-a"
             })

    assert {:error, :fork_target_conflict} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "target_session_id" => target,
               "fork_request_id" => "req-b"
             })
  end

  test "a cutoff below the compaction boundary is explicitly rejected", %{agent_id: agent_id} do
    seed_source(agent_id, Enum.map(1..20, &deliver/1), [
      %{
        "type" => "compaction",
        "session_id" => @source,
        "summary" => "s",
        "compacted_through" => 10,
        "summary_sequence" => 1
      }
    ])

    assert {:error, :fork_cutoff_below_compaction} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-cut",
               "message_id" => 5
             })

    assert {:ok, _} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-cut-ok",
               "message_id" => 15
             })
  end

  test "a cutoff fork does not fetch an archived tool result named only by a future capsule", %{
    agent_id: agent_id
  } do
    ref = "trf1_0000000000000000007"
    result_json = Jason.encode!(%{"answer" => "archive-only"})

    stored_event = %{
      "type" => "tool_result_stored",
      "session_id" => @source,
      "result_ref" => ref,
      "tool_call_id" => "call-future-capsule",
      "tool_name" => "composio.execute",
      "result_json" => result_json,
      "result_sha256" => :crypto.hash(:sha256, result_json) |> Base.encode16(case: :lower),
      "result_bytes" => byte_size(result_json),
      "result_chars" => String.length(result_json),
      "status" => "completed",
      "is_error" => false,
      "stored_at_ms" => 2_000
    }

    capsule = %{
      "type" => "tool_result",
      "session_id" => @source,
      "message_id" => 2,
      "tool_call_id" => "projection-future-capsule",
      "content" => Jason.encode!(%{"stored_result" => true, "result_ref" => ref}),
      "created_at" => 2_001
    }

    source =
      InternalSession.new(agent_id, @source, %{})
      |> InternalSession.apply_events([deliver(1), stored_event, capsule])
      |> InternalSession.apply_event(%{
        "type" => "compaction",
        "session_id" => @source,
        "summary" => "summary without the stored ref",
        "compacted_through" => 1,
        "summary_sequence" => 1
      })
      |> InternalSession.apply_event(%{
        "type" => "archive_advance",
        "session_id" => @source,
        "archived_through" => 2,
        "segments" => []
      })

    assert InternalSession.get(source, :async_results) == []
    assert InternalSession.get(source, :async_result_refs) == %{ref => 2}

    source_key = SalixStore.Keys.agent_internal_runtime_session(agent_id, @source)

    assert {:ok, _} =
             SalixStore.S3.put(
               source_key,
               SalixStore.Codec.encode_snapshot(InternalSession.export(source))
             )

    # Deliberately do not create the archive object. If the actor fetches the
    # source's full archived ref set before applying cutoff 1, this fork fails.
    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-no-future-archive-read",
               "message_id" => 1
             })

    assert {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])
    assert InternalSession.get(fork, :async_results) == []
    assert InternalSession.get(fork, :async_result_refs) == %{}
    assert InternalSession.lookup_async_call(fork, ref) == :not_found
  end

  test "a cutoff-visible capsule carries an archived tool result end to end", %{
    agent_id: agent_id
  } do
    ref = "trf1_0000000000000000008"
    result_json = Jason.encode!(%{"answer" => "archive-and-fork"})
    result_sha256 = :crypto.hash(:sha256, result_json) |> Base.encode16(case: :lower)

    stored_event = %{
      "type" => "tool_result_stored",
      "session_id" => @source,
      "result_ref" => ref,
      "tool_call_id" => "call-visible-archived-capsule",
      "tool_name" => "composio.execute",
      "result_json" => result_json,
      "result_sha256" => result_sha256,
      "result_bytes" => byte_size(result_json),
      "result_chars" => String.length(result_json),
      "status" => "completed",
      "is_error" => false,
      "stored_at_ms" => 2_000
    }

    capsule = %{
      "type" => "tool_result",
      "session_id" => @source,
      "message_id" => 2,
      "tool_call_id" => "projection-visible-archived-capsule",
      "content" => Jason.encode!(%{"stored_result" => true, "result_ref" => ref}),
      "created_at" => 2_001
    }

    seed_source(agent_id, [deliver(1), stored_event, capsule], [
      %{
        "type" => "compaction",
        "session_id" => @source,
        "summary" => "summary without the stored ref",
        "compacted_through" => 1,
        "summary_sequence" => 1
      }
    ])

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @source),
               nil
             )

    assert {:ok, :archived} = SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @source)
    assert {:ok, archived_source} = InternalSessionStore.read(agent_id, @source)
    assert InternalSession.get(archived_source, :async_results) == []
    assert InternalSession.get(archived_source, :async_result_refs) == %{ref => 2}

    assert {:ok, source_record} =
             InternalSessionStore.fetch_tool_result(agent_id, @source, ref)

    assert source_record["result_json"] == result_json
    assert source_record["result_sha256"] == result_sha256

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-visible-archived-result",
               "message_id" => 2
             })

    fork_id = forked["session_id"]
    assert {:ok, fork} = InternalSessionStore.read(agent_id, fork_id)
    assert {:ok, fork_record} = InternalSessionStore.fetch_tool_result(agent_id, fork_id, ref)
    assert InternalSession.get(fork, :async_result_refs) == %{ref => fork_record["seq"]}
    assert fork_record["result_json"] == result_json
    assert fork_record["result_sha256"] == result_sha256
  end

  test "a live runtime capsule carries its archived tool result into a fork", %{
    agent_id: agent_id
  } do
    ref = "trf1_0000000000000000010"
    call_id = "call-runtime-capsule"

    runtime_capsule = %{
      "type" => "runtime_message",
      "session_id" => @source,
      "from_queue" => true,
      "message_id" => 2,
      "runtime_message_id" => "tool-call-result:#{call_id}",
      "dedupe_key" => "tool-call-result:#{call_id}",
      "tool_call_id" => call_id,
      "content" => Jason.encode!(%{"stored_result" => true, "result_ref" => ref}),
      "created_at" => 3_000
    }

    seed_source(agent_id, [deliver(1), stored_result(ref, call_id), runtime_capsule], [
      %{
        "type" => "compaction",
        "session_id" => @source,
        "summary" => "one user message",
        "compacted_through" => 1,
        "summary_sequence" => 1
      }
    ])

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @source),
               nil
             )

    assert {:ok, :archived} = SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @source)
    assert {:ok, archived_source} = InternalSessionStore.read(agent_id, @source)
    assert InternalSession.get(archived_source, :async_results) == []
    assert InternalSession.get(archived_source, :async_result_refs) == %{ref => 2}

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-runtime-capsule-result"
             })

    assert {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])
    assert [%{role: "runtime", content: content}] = InternalSession.get(fork, :messages)
    assert %{"result_ref" => ^ref, "stored_result" => true} = Jason.decode!(content)

    assert {:ok, fork_record} =
             InternalSessionStore.fetch_tool_result(
               agent_id,
               InternalSession.session_id(fork),
               ref
             )

    assert fork_record["tool_call_id"] == call_id
    assert InternalSession.get(fork, :async_result_refs) == %{ref => fork_record["seq"]}
  end

  test "a live assistant result-ref argument carries its archived tool result into a fork", %{
    agent_id: agent_id
  } do
    ref = "trf1_0000000000000000011"
    source_call_id = "call-assistant-argument-source"

    assistant = %{
      "type" => "assistant",
      "session_id" => @source,
      "message_id" => 2,
      "content" => "",
      "tool_calls" => [
        %{
          "id" => "call-assistant-argument-reader",
          "name" => "tool_call.get_result",
          "args" => %{"result_ref" => ref, "offset" => 0}
        }
      ],
      "created_at" => 3_000
    }

    seed_source(agent_id, [deliver(1), stored_result(ref, source_call_id), assistant], [
      %{
        "type" => "compaction",
        "session_id" => @source,
        "summary" => "one user message",
        "compacted_through" => 1,
        "summary_sequence" => 1
      }
    ])

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @source),
               nil
             )

    assert {:ok, :archived} = SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @source)
    assert {:ok, archived_source} = InternalSessionStore.read(agent_id, @source)
    assert InternalSession.get(archived_source, :async_results) == []
    assert InternalSession.get(archived_source, :async_result_refs) == %{ref => 2}

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-assistant-argument-result"
             })

    assert {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])

    assert [%{role: "assistant", tool_calls: [tool_call]}] = InternalSession.get(fork, :messages)
    assert tool_call["args"]["result_ref"] == ref

    assert {:ok, fork_record} =
             InternalSessionStore.fetch_tool_result(
               agent_id,
               InternalSession.session_id(fork),
               ref
             )

    assert fork_record["tool_call_id"] == source_call_id
    assert InternalSession.get(fork, :async_result_refs) == %{ref => fork_record["seq"]}
  end

  test "opaque provider fork range reads are bounded by the live ref set", %{
    agent_id: agent_id
  } do
    refs = Enum.map(1..8, &"trf1_#{String.pad_leading(Integer.to_string(&1), 19, "0")}")

    events =
      refs
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {ref, message_id} ->
        call_id = "provider-result-#{message_id}"
        [stored_result(ref, call_id), result_capsule(message_id, ref, call_id)]
      end)

    seed_source(agent_id, events)

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @source),
               nil
             )

    assert {:ok, _compacted} =
             InternalSessionStore.commit(agent_id, @source, [
               %{
                 "type" => "provider_compaction",
                 "session_id" => @source,
                 "provider" => "openai",
                 "protocol" => "responses",
                 "strategy" => "openai_responses",
                 "items" => [%{"type" => "compaction", "encrypted_content" => "opaque"}],
                 "compacted_through" => 7,
                 "summary_sequence" => 1,
                 "created_at" => 4_000
               }
             ])

    assert {:ok, :archived} = SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @source)
    assert {:ok, archived} = InternalSessionStore.read(agent_id, @source)
    assert Map.keys(InternalSession.get(archived, :async_result_refs)) == [List.last(refs)]

    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-bounded-provider-result-refs"
             })

    archive_key = SalixStore.Keys.agent_internal_runtime_session_archive(agent_id, @source)

    assert Enum.count(SalixStore.S3.Fake.read_log(), &(&1 == {:get, archive_key})) == 1

    assert {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])

    assert Enum.map(InternalSession.get(fork, :async_results), & &1["result_ref"]) == [
             List.last(refs)
           ]

    assert map_size(InternalSession.get(fork, :async_result_refs)) == 1
  end

  test "the fork copies only the live window, renumbered, with the summary travelling", %{
    agent_id: agent_id
  } do
    source =
      seed_source(agent_id, Enum.map(1..20, &deliver/1), [
        %{
          "type" => "compaction",
          "session_id" => @source,
          "summary" => "the summary",
          "compacted_through" => 10,
          "summary_sequence" => 1
        }
      ])

    assert InternalSession.get(source, :compacted_seq) == 10

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-window"
             })

    {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])

    # Only the ten uncovered messages travel, densely renumbered from 1;
    # message ids keep their LLM semantics and the summary still covers them.
    assert Enum.map(InternalSession.get(fork, :messages), & &1[:id]) == Enum.to_list(11..20)
    assert Enum.map(InternalSession.get(fork, :messages), & &1[:seq]) == Enum.to_list(1..10)
    assert InternalSession.get(fork, :summary) == "the summary"
    assert InternalSession.compacted_through(fork) == 10

    assert {InternalSession.archived_through(fork), InternalSession.get(fork, :compacted_seq)} ==
             {0, 0}

    assert InternalSession.get(fork, :last_seq) == 10
    assert InternalSession.get(fork, :fork_request_id) == "req-window"
  end

  test "an ambiguous-but-landed addressed fork settles to the one committed target", %{
    agent_id: agent_id
  } do
    seed_source(agent_id, [deliver(1), deliver(2)])
    target = "ses1_0000000000000000862"
    target_key = SalixStore.Keys.agent_internal_runtime_session(agent_id, target)

    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, target_key})

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "target_session_id" => target,
               "fork_request_id" => "req-amb-after"
             })

    assert forked["session_id"] == target
    assert forked["fork_request_id"] == "req-amb-after"

    assert {:ok, sessions} = InternalSessionStore.list(agent_id)
    assert Enum.count(sessions, &(SalixAgent.InternalSession.session_id(&1) != @source)) == 1
  end

  test "an ambiguous-lost addressed fork retries the same address within the budget", %{
    agent_id: agent_id
  } do
    seed_source(agent_id, [deliver(1)])
    target = "ses1_0000000000000000863"
    target_key = SalixStore.Keys.agent_internal_runtime_session(agent_id, target)

    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_before, :put, target_key})

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "target_session_id" => target,
               "fork_request_id" => "req-amb-before"
             })

    assert forked["session_id"] == target
  end

  test "a different SOURCE with the same target and request key is a conflict, not adoption",
       %{agent_id: agent_id} do
    other_source = "ses1_0000000000000000864"
    seed_source(agent_id, [deliver(1)])

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, other_source, [
        %{"type" => "session_created", "session_id" => other_source, "name" => "Other"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 1,
          "role" => "user",
          "content" => "other input",
          "source_message_id" => "src-other-1",
          "created_at" => 1_001
        }
      ])

    target = "ses1_0000000000000000865"

    assert {:ok, _} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "target_session_id" => target,
               "fork_request_id" => "req-shared"
             })

    assert {:error, :fork_target_conflict} =
             InternalAgentRuntime.fork_session_local(agent_id, other_source, %{
               "target_session_id" => target,
               "fork_request_id" => "req-shared"
             })
  end

  test "the public contract requires a caller-stable key — no key is a fixable error, never a fork",
       %{agent_id: agent_id} do
    seed_source(agent_id, [deliver(1)])

    # Owner 2026-08-08: only the caller can hold a key across a lost
    # response, so a keyless invocation (with or without an explicit
    # target) is rejected before anything is created.
    assert {:error, :fork_identity_required} =
             InternalAgentRuntime.fork_session(agent_id, @source, %{"name" => "A"})

    assert {:error, :fork_identity_required} =
             InternalAgentRuntime.fork_session(agent_id, @source, %{
               "target_session_id" => "ses1_0000000000000000868"
             })

    assert {:ok, sessions} = InternalSessionStore.list(agent_id)
    assert Enum.count(sessions, &(InternalSession.session_id(&1) != @source)) == 0

    # The SAME body replayed with the caller's key converges on one child.
    attrs = %{"fork_request_id" => "req-replay", "name" => "A"}
    assert {:ok, first} = InternalAgentRuntime.fork_session(agent_id, @source, attrs)
    assert {:ok, second} = InternalAgentRuntime.fork_session(agent_id, @source, attrs)
    assert first["session_id"] == second["session_id"]
  end

  test "a fork cut exactly at the compaction boundary accepts fresh input", %{
    agent_id: agent_id
  } do
    seed_source(agent_id, Enum.map(1..10, &deliver/1), [
      %{
        "type" => "compaction",
        "session_id" => @source,
        "summary" => "all ten",
        "compacted_through" => 10,
        "summary_sequence" => 1
      }
    ])

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-boundary",
               "message_id" => 10
             })

    {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])

    # Empty copied window, summary watermark at 10: the id cursor must sit
    # above the watermark or fresh input would read as already summarized.
    assert InternalSession.get(fork, :messages) == []
    assert InternalSession.compacted_through(fork) == 10
    assert InternalSession.next_message_id(fork) >= 11

    appended =
      InternalSession.apply_events(fork, [deliver(InternalSession.next_message_id(fork))])

    assert [fresh] = InternalSession.get(appended, :messages)
    assert fresh[:id] >= 11
    assert InternalSession.next_message_id(appended) == fresh[:id] + 1
  end

  test "a cutoff at a tool-call message excludes the later completion everywhere", %{
    agent_id: agent_id
  } do
    events =
      Enum.map(1..11, &deliver/1) ++
        [
          %{
            "type" => "async_tool_call_started",
            "session_id" => @source,
            "tool_call_id" => "call-after-cut",
            "status" => "running",
            "started_at" => 5_000
          },
          deliver(12),
          %{
            "type" => "async_tool_call_completed",
            "session_id" => @source,
            "tool_call_id" => "call-after-cut",
            "result" => %{"answer" => "future"},
            "completed_at" => 5_001
          }
        ]

    seed_source(agent_id, events)

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-cut-tool",
               "message_id" => 11
             })

    {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])

    # One snapshot boundary for every record kind: message 12, the start
    # fact, the terminal result, and its pointer — all logged after message
    # 11 — must be absent, not just the later message.
    assert Enum.map(InternalSession.get(fork, :messages), & &1[:id]) == Enum.to_list(1..11)

    refute Enum.any?(
             InternalSession.get(fork, :events),
             &(&1["tool_call_id"] == "call-after-cut")
           )

    refute Enum.any?(
             InternalSession.get(fork, :async_results),
             &(&1["tool_call_id"] == "call-after-cut")
           )

    assert InternalSession.get(fork, :async_result_refs) == %{}

    assert {:error, :not_found} =
             InternalAgentRuntime.get_async_tool_call(
               agent_id,
               forked["session_id"],
               "call-after-cut"
             )
  end

  test "a boundary fork processes QUEUED input end to end", %{agent_id: agent_id} do
    seed_source(agent_id, Enum.map(1..10, &deliver/1), [
      %{
        "type" => "compaction",
        "session_id" => @source,
        "summary" => "ten",
        "compacted_through" => 10,
        "summary_sequence" => 1
      }
    ])

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-boundary-queue",
               "message_id" => 10
             })

    fork_id = forked["session_id"]

    # The production input path: queue_append then materialization — not a
    # hand-stamped delivery. The materialized message must clear every
    # carried watermark or the fork sits inert.
    assert {:ok, queued} =
             InternalSessionStore.prepare_commit(agent_id, fork_id, [
               %{
                 "type" => "queue_append",
                 "session_id" => fork_id,
                 "kind" => "user_message",
                 "dedupe_key" => "boundary-input-1",
                 "payload" => %{"content" => "fresh input", "role" => "user"},
                 "created_at" => 9_000
               }
             ])

    {events, _wake?, hwm} = InternalSession.materialize_pending_input_events(queued)
    assert events != []

    opts = if hwm > 0, do: [hwm: hwm], else: []

    assert {:ok, after_input} =
             InternalSessionStore.prepare_commit(agent_id, fork_id, events, opts)

    assert [fresh] = InternalSession.get(after_input, :messages)
    assert fresh[:id] >= 11
    assert InternalSession.last_ack_message_id(after_input) < fresh[:id]
  end

  test "a format-1 source fork retry settles on the persisted identity", %{agent_id: agent_id} do
    legacy_source = "ses1_0000000000000000866"

    state =
      agent_id
      |> InternalSession.new(legacy_source, %{})
      |> InternalSession.export()
      |> Map.put(:storage_format, 1)
      |> InternalSession.open()
      |> InternalSession.apply_events([
        %{"type" => "session_created", "session_id" => legacy_source, "name" => "Legacy"},
        deliver(1)
      ])

    state = %State{
      InternalSession.export(state)
      | messages: Enum.map(InternalSession.get(state, :messages), &Map.delete(&1, :seq)),
        last_seq: 0
    }

    key = SalixStore.Keys.agent_internal_runtime_session(agent_id, legacy_source)

    {:ok, _} =
      SalixStore.S3.put(
        key,
        SalixStore.Codec.encode_snapshot(state)
      )

    attrs = %{"fork_request_id" => "req-legacy-retry", "name" => "L"}

    assert {:ok, first} = InternalAgentRuntime.fork_session_local(agent_id, legacy_source, attrs)
    assert {:ok, second} = InternalAgentRuntime.fork_session_local(agent_id, legacy_source, attrs)

    assert first["session_id"] == second["session_id"]
    assert second["fork_request_id"] == "req-legacy-retry"
  end

  test "a cutoff fork carries no future control state: predicates clamp, dedupe shrinks", %{
    agent_id: agent_id
  } do
    seed_source(agent_id, Enum.map(1..100, &deliver/1), [
      %{
        "type" => "session_microcompact",
        "session_id" => @source,
        "tool_messages_through" => 100,
        "new_content" => "[microcompacted]"
      },
      %{
        "type" => "session_microcompact",
        "session_id" => @source,
        "non_model_messages_over_bytes_through" => 100,
        "non_model_message_max_bytes" => 1_000,
        "new_content" => "[emergency-compacted non-model message over 1000 bytes]"
      }
    ])

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-clamp",
               "message_id" => 50
             })

    {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])

    # Both predicates travelled clamped to the snapshot: fresh branch
    # non-model messages above the cutoff must not be born pre-masked.
    assert [
             %{"kind" => "tool_messages_through", "through_id" => 50},
             %{
               "kind" => "non_model_messages_over_bytes_through",
               "through_id" => 50,
               "max_bytes" => 1_000
             }
           ] = InternalSession.get(fork, :redactions)

    fresh_tool = %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => InternalSession.next_message_id(fork),
      "role" => "tool",
      "content" => "fresh branch tool output",
      "source_message_id" => "src-branch-tool",
      "created_at" => 9_000
    }

    {:ok, with_tool} =
      InternalSessionStore.prepare_commit(agent_id, forked["session_id"], [fresh_tool])

    fresh = Enum.find(InternalSession.masked_messages(with_tool), &(&1[:role] == "tool"))
    assert fresh[:content] == "fresh branch tool output"

    fresh_user = %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => InternalSession.next_message_id(with_tool),
      "role" => "user",
      "content" => String.duplicate("u", 1_001),
      "source_message_id" => "src-branch-large-user",
      "created_at" => 9_001
    }

    {:ok, with_large_user} =
      InternalSessionStore.prepare_commit(agent_id, forked["session_id"], [fresh_user])

    fresh =
      Enum.find(
        InternalSession.masked_messages(with_large_user),
        &(&1[:source_message_id] == "src-branch-large-user")
      )

    assert fresh[:content] == String.duplicate("u", 1_001)

    # A source dedupe key that belongs only to a post-cutoff input does not
    # suppress the branch delivery carrying the same key.
    post_cutoff_key = "src-60"

    refute Enum.any?(
             InternalSession.get(fork, :messages),
             &(&1[:source_message_id] == post_cutoff_key)
           )

    redelivery = %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => InternalSession.next_message_id(with_large_user),
      "role" => "user",
      "content" => "redelivered into the branch",
      "source_message_id" => post_cutoff_key,
      "created_at" => 9_002
    }

    {:ok, redelivered} =
      InternalSessionStore.prepare_commit(agent_id, forked["session_id"], [redelivery])

    assert Enum.any?(
             InternalSession.get(redelivered, :messages),
             &(&1[:content] == "redelivered into the branch")
           )
  end

  test "redaction overlays remap onto the fork's renumbered seqs", %{agent_id: agent_id} do
    seed_source(agent_id, Enum.map(1..20, &deliver/1), [
      %{
        "type" => "compaction",
        "session_id" => @source,
        "summary" => "s",
        "compacted_through" => 10,
        "summary_sequence" => 1
      },
      %{
        "type" => "session_microcompact",
        "session_id" => @source,
        "message_ids" => [15],
        "new_content" => "[gone]"
      }
    ])

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-redact"
             })

    {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])

    # Message id 15 sat at source seq 15 and lands at fork seq 5.
    assert [%{"seq" => 5, "message_id" => 15, "replacement" => "[gone]"}] =
             InternalSession.get(fork, :redactions)

    assert Enum.find(InternalSession.masked_messages(fork), &(&1[:id] == 15))[:content] ==
             "[gone]"
  end

  test "a fork remaps a runtime completion to its carried authoritative result", %{
    agent_id: agent_id
  } do
    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent_id, @source), nil)

    tool_call_id = "get-provider-before-fork"
    pdf = "%PDF-1.4\nforked async provider result\n%%EOF\n"

    {:ok, write_event} = AgentWorkspace.prepare_write(agent_id, "/forked-result.pdf", pdf)

    assert {:ok, _} =
             AgentWorkspace.seed_operation(agent_id, "forked-result-file", %{}, [write_event])

    provider_blocks = [
      %{
        "type" => "file",
        "path" => "/forked-result.pdf",
        "file_name" => "forked-result.pdf",
        "mime_type" => "application/pdf"
      }
    ]

    provider_record = %{
      "status" => "completed",
      "tool_call_id" => "provider-before-fork",
      "tool_name" => "im_api.feishu.fetch_message_resource",
      "error" => false,
      "result" => %{
        "id" => "provider-before-fork",
        "name" => "im_api.feishu.fetch_message_resource",
        "status" => "completed",
        "content" => Jason.encode!(provider_blocks),
        "error" => false
      }
    }

    seed_source(
      agent_id,
      Enum.map(1..10, &deliver/1) ++
        [
          %{
            "type" => "async_tool_call_started",
            "session_id" => @source,
            "tool_call_id" => tool_call_id,
            "tool_name" => "tool_call.get_result",
            "status" => "running",
            "started_at" => 5_000
          },
          %{
            "type" => "async_tool_call_completed",
            "session_id" => @source,
            "tool_call_id" => tool_call_id,
            "result" => %{
              "id" => tool_call_id,
              "name" => "tool_call.get_result",
              "status" => "completed",
              "content" => Jason.encode!(provider_record),
              "error" => false
            },
            "error" => false,
            "completed_at" => 5_001
          },
          %{
            "type" => "queue_append",
            "session_id" => @source,
            "kind" => "runtime_message",
            "dedupe_key" => "notify-get-provider-before-fork",
            "payload" => %{
              "runtime_message_id" => "notify-get-provider-before-fork",
              "type" => "tool_call_completed",
              "tool_call_id" => tool_call_id,
              "source_tool_call_id" => tool_call_id,
              "summary" => "provider result ready"
            }
          }
        ]
    )

    assert {:ok, compacted} =
             InternalSessionStore.prepare_commit(agent_id, @source, [
               %{
                 "type" => "compaction",
                 "session_id" => @source,
                 "summary" => "ten messages",
                 "compacted_through" => 10,
                 "summary_sequence" => 1
               }
             ])

    assert %{"get-provider-before-fork" => source_result_seq} =
             InternalSession.get(compacted, :async_result_refs)

    assert source_result_seq <= InternalSession.get(compacted, :compacted_seq)

    assert {:ok, :archived} = SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @source)
    assert {:ok, archived_source} = InternalSessionStore.read(agent_id, @source)
    assert InternalSession.archived_through(archived_source) >= source_result_seq
    assert InternalSession.get(archived_source, :async_results) == []

    {materialized, _wake?, hwm} =
      InternalSession.materialize_pending_input_events(archived_source)

    assert materialized != []
    opts = if hwm > 0, do: [hwm: hwm], else: []

    assert {:ok, _source} =
             InternalSessionStore.prepare_commit(agent_id, @source, materialized, opts)

    assert {:ok, forked} =
             InternalAgentRuntime.fork_session_local(agent_id, @source, %{
               "fork_request_id" => "req-result-pointer"
             })

    assert {:ok, fork} = InternalSessionStore.read(agent_id, forked["session_id"])

    runtime_message =
      Enum.find(
        InternalSession.get(fork, :messages),
        &(&1[:runtime_message_id] == "notify-get-provider-before-fork")
      )

    result =
      Enum.find(InternalSession.get(fork, :async_results), &(&1["tool_call_id"] == tool_call_id))

    assert runtime_message[:result_seq] == result["seq"]
    refute runtime_message[:result_seq] == source_result_seq

    assert [inlined] =
             ImageRefs.inline([runtime_message], %{
               agent_id: agent_id,
               protocol: "responses",
               async_result_resolver: fn seq ->
                 case Enum.find(InternalSession.get(fork, :async_results), &(&1["seq"] == seq)) do
                   nil -> {:error, :not_found}
                   record -> {:ok, record}
                 end
               end
             })

    assert inlined.native_content_trusted == true

    assert [%{"type" => "text", "text" => note}] = Jason.decode!(inlined.content)
    assert note =~ "forked-result.pdf"
    refute inlined.content =~ Base.encode64(pdf)
  end
end
