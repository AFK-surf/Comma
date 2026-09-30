defmodule SalixVerifiedKernel.SnapshotRecoveryTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  test "storage commits use the persistable candidate and fail closed on unresolved writes" do
    handle = Session.new("agent", "session")
    bytes = Session.persist(handle)
    key = hot_key()

    for outcome <- [:written, :ambiguous_settled] do
      {cursor, {:cas, ^key, ^bytes, "base-etag"}} =
        Session.start_storage_commit(handle, key, "base-etag")

      assert {:ok, "committed-etag"} =
               Session.resume_storage_commit(cursor, {:ok, "committed-etag", outcome})
    end

    {cursor, {:cas, ^key, ^bytes, "base-etag"}} =
      Session.start_storage_commit(handle, key, "base-etag")

    assert {:error, :commit_indeterminate} =
             Session.resume_storage_commit(cursor, {:error, :settlement_indeterminate})

    assert {:error, :precondition_failed} =
             Session.resume_storage_commit(cursor, {:error, :precondition_failed})

    assert Session.persist(handle) == bytes
  end

  test "a storage continuation returns its captured facts, not a later Session value" do
    handle = Session.new("agent", "session", %{name: "captured"})
    key = hot_key()

    {cursor, {:cas, ^key, bytes, "base-etag"}} =
      Session.start_storage_commit(handle, key, "base-etag")

    later = Session.new("agent", "session", %{name: "later"})
    assert Session.persist(later) != bytes

    {:verified_kernel, 1, :storage_commit, resident} = cursor

    assert {:ok, committed, {:ok, "committed-etag"}} =
             SalixVerifiedKernel.invoke_session_commit(
               resident,
               :resume,
               {:ok, "committed-etag", :written}
             )

    restored = {:verified_kernel, 1, :session_state, committed}
    assert Session.persist(restored) == bytes
    assert Session.get(restored, :name) == "captured"

    {:verified_kernel, 1, :session_state, unprepared} = later

    assert {:ok, nil, {:error, :invalid_term}} =
             SalixVerifiedKernel.invoke_session_commit(
               unprepared,
               :resume,
               {:ok, "unissued-etag", :written}
             )
  end

  defp hot_key do
    digest = :crypto.hash(:sha256, "session") |> Base.encode16(case: :lower)
    "agents/agent/internal_runtime/sessions/#{digest}/state.etf.zst"
  end

  test "large stored transcripts normalize without exhausting the native scheduler stack" do
    messages = Enum.map(1..20_000, &%{id: &1, seq: &1, role: "user"})

    state = %{
      __struct__: SalixAgent.InternalSession.State,
      status: :active,
      activity_status: :thinking,
      messages: messages,
      events: [],
      last_seq: 0
    }

    # Snapshot recovery sorts the transcript to recover provider boundaries.
    # The old recursive merge crashes the whole VM at this realistic size.
    for transcript <- [messages, Enum.reverse(messages)] do
      bytes =
        :erlang.term_to_binary({:comma_internal_session, 3, %{state | messages: transcript}})

      assert {:ok, handle} = Session.load(bytes)
      restored = Session.export(handle)
      assert restored.messages == transcript
      assert restored.last_seq == 20_000
    end
  end

  test "provider boundary sorting keeps the first equal-key entry" do
    boundary = fn id, version ->
      %{
        id: id,
        role: "assistant",
        do_not_send_to_llm: %{
          "context_provider_states" => %{"example" => %{"version" => version}}
        }
      }
    end

    state = %{
      __struct__: SalixAgent.InternalSession.State,
      status: :active,
      messages: [boundary.(2, 20), boundary.(1, 10), boundary.(2, 21)]
    }

    assert {:ok, handle} =
             Session.load(:erlang.term_to_binary({:comma_internal_session, 3, state}))

    assert Session.export(handle).context_provider_states == %{"example" => %{"version" => 20}}
  end
end
