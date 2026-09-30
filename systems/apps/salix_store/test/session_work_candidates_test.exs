defmodule SalixStore.SessionWorkCandidatesTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Repo, SessionWorkCandidates, SessionWorkNotifications}

  setup do
    Repo.query!("TRUNCATE session_work_candidates")
    :ok
  end

  test "candidate tokens are immutable and exact deletion cannot remove a sibling" do
    assert :ok = SessionWorkCandidates.insert(candidate("token-a"))

    assert :ok =
             SessionWorkCandidates.insert(
               candidate("token-a", %{"agent_id" => "overwritten", "reasons" => ["other"]})
             )

    assert :ok = SessionWorkCandidates.insert(candidate("token-b"))

    assert {:ok, [first, second]} = SessionWorkCandidates.list_all()
    assert first["token"] == "token-a"
    assert first["agent_id"] == "agent-a"
    assert first["reasons"] == ["queued_input"]
    assert second["token"] == "token-b"

    assert :ok = SessionWorkCandidates.delete_exact("token-a")
    assert {:ok, [%{"token" => "token-b"}]} = SessionWorkCandidates.list_all()
  end

  test "candidate insertion publishes its exact address only when the transaction commits" do
    notifications =
      start_supervised!(
        {Postgrex.Notifications,
         Repo.config()
         |> Keyword.delete(:name)
         |> Keyword.put(:auto_reconnect, false)}
      )

    assert {:ok, listen_ref} =
             Postgrex.Notifications.listen(notifications, SessionWorkNotifications.channel())

    parent = self()

    writer =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert :ok =
                   SessionWorkCandidates.insert(
                     candidate("token-notify", %{
                       "agent_id" => "agent-notify",
                       "session_id" => "session-notify"
                     })
                   )

          send(parent, {:candidate_inserted_inside_transaction, self()})

          receive do
            :commit_candidate_transaction -> :ok
          end
        end)
      end)

    assert_receive {:candidate_inserted_inside_transaction, writer_pid}
    refute_receive {:notification, ^notifications, ^listen_ref, _channel, _payload}, 100

    send(writer_pid, :commit_candidate_transaction)
    assert {:ok, :ok} = Task.await(writer)

    assert_receive {:notification, ^notifications, ^listen_ref, channel, payload}, 1_000
    assert channel == SessionWorkNotifications.channel()

    assert {:ok,
            %{
              version: 1,
              candidate_token: "token-notify",
              agent_id: "agent-notify",
              runtime: :internal,
              session_id: "session-notify"
            }} = SessionWorkNotifications.decode(payload)
  end

  test "workload discovery retains the original candidate location and excludes other targets" do
    original = %{"runtime_kind" => "external", "workload_id" => "workload-original"}
    assert :ok = SessionWorkCandidates.insert(candidate("token-a", original))

    assert :ok =
             SessionWorkCandidates.insert(
               candidate("token-a", %{original | "workload_id" => "workload-rebound"})
             )

    assert :ok = SessionWorkCandidates.insert(candidate("token-internal"))

    assert :ok =
             SessionWorkCandidates.insert(
               candidate("token-other", %{original | "workload_id" => "workload-other"})
             )

    assert {:ok,
            %{records: [%{"token" => "token-a", "workload_id" => "workload-original"}], eof: true}} =
             SessionWorkCandidates.list_eager(workload_id: "workload-original")

    assert {:ok, %{records: [], eof: true}} =
             SessionWorkCandidates.list_eager(workload_id: "workload-rebound")
  end

  test "scoped deletion cannot remove the same token at another Session address" do
    assert :ok = SessionWorkCandidates.insert(candidate("token-a"))

    assert :ok =
             SessionWorkCandidates.delete_scoped("token-a", %{
               agent_id: "agent-other",
               runtime_kind: "internal",
               session_id: "session-other"
             })

    assert {:ok, %{"agent_id" => "agent-a", "session_id" => "session-a"}} =
             SessionWorkCandidates.fetch_exact("token-a")
  end

  test "oversized discovery requests stop at 128 candidates and retain continuation" do
    rows =
      for number <- 1..129 do
        %{
          candidate_token: "bounded-" <> String.pad_leading(to_string(number), 3, "0"),
          agent_id: "bounded-agent",
          runtime_kind: "external",
          session_id: "bounded-session",
          workload_id: "bounded-workload",
          reasons: ["unacked_queue_item"],
          updated_at_seconds: 1_000
        }
      end

    Repo.insert_all(SessionWorkCandidates.Row, rows)

    assert {:ok, %{records: records, eof: false}} =
             SessionWorkCandidates.list_eager(workload_id: "bounded-workload", limit: 10_000)

    assert length(records) == 128

    assert {:ok, %{records: [%{"token" => "bounded-129"}], eof: true}} =
             SessionWorkCandidates.list_eager(
               workload_id: "bounded-workload",
               limit: 10_000,
               after: cursor(List.last(records))
             )
  end

  test "eager keyset pages use the immutable bytewise identity order" do
    assert :ok =
             SessionWorkCandidates.insert(candidate("token-a", %{"agent_id" => "agent_A"}))

    assert :ok =
             SessionWorkCandidates.insert(candidate("token-b", %{"agent_id" => "agent_a"}))

    assert {:ok, %{records: [first], eof: false}} =
             SessionWorkCandidates.list_eager(limit: 1)

    assert first["agent_id"] == "agent_A"

    assert {:ok, %{records: [second], eof: true}} =
             SessionWorkCandidates.list_eager(limit: 1, after: cursor(first))

    assert second["agent_id"] == "agent_a"
  end

  test "distinct address keyset pages bound duplicate-token crash residue" do
    assert :ok = SessionWorkCandidates.insert(candidate("token-a"))
    assert :ok = SessionWorkCandidates.insert(candidate("token-b"))

    assert :ok =
             SessionWorkCandidates.insert(
               candidate("token-c", %{
                 "agent_id" => "agent-b",
                 "session_id" => "session-b"
               })
             )

    assert {:ok, %{addresses: [first], eof: false}} =
             SessionWorkCandidates.list_addresses(limit: 1)

    assert first == %{agent_id: "agent-a", runtime_kind: "internal", session_id: "session-a"}

    assert {:ok, %{addresses: [second], eof: true}} =
             SessionWorkCandidates.list_addresses(limit: 1, after: first)

    assert second == %{agent_id: "agent-b", runtime_kind: "internal", session_id: "session-b"}
  end

  test "deferred pages exclude future candidates and order due identities exactly" do
    now = 10_000

    assert :ok =
             SessionWorkCandidates.insert(
               candidate("token-later", %{"recover_after_ms" => now + 1})
             )

    assert :ok =
             SessionWorkCandidates.insert(
               candidate("token-b", %{"agent_id" => "agent-b", "recover_after_ms" => now})
             )

    assert :ok =
             SessionWorkCandidates.insert(
               candidate("token-a", %{"agent_id" => "agent-a", "recover_after_ms" => now})
             )

    assert {:ok, %{records: [first], eof: false}} =
             SessionWorkCandidates.list_due(now, limit: 1)

    assert first["token"] == "token-a"

    assert {:ok, %{records: [second], eof: true}} =
             SessionWorkCandidates.list_due(now, limit: 1, after: cursor(first))

    assert second["token"] == "token-b"
  end

  test "invalid revision or reasons fail closed without creating a candidate" do
    assert {:error, :invalid} =
             SessionWorkCandidates.insert(candidate("bad-revision", %{"base_revision" => 1}))

    assert {:error, :invalid} =
             SessionWorkCandidates.insert(candidate("bad-reasons", %{"reasons" => [:queued]}))

    assert {:ok, []} = SessionWorkCandidates.list_all()
  end

  test "count reports the physical rollout projection size" do
    assert {:ok, 0} = SessionWorkCandidates.count()
    assert :ok = SessionWorkCandidates.insert(candidate("token-a"))
    assert :ok = SessionWorkCandidates.insert(candidate("token-b"))
    assert {:ok, 2} = SessionWorkCandidates.count()
  end

  test "the seconds-named field still maps to the legacy inserted_at_ms column" do
    # `updated_at` is the marker's own timestamp in SECONDS
    # (`SalixAgent.SessionWorkIndex.mark/5` mints it with
    # `System.system_time(:second)`), and the physical column is still named
    # `inserted_at_ms`. Pin both halves: the value round-trips unscaled, and the
    # schema keeps writing the legacy column, so dropping the `source:` mapping
    # or renaming the column in Postgres fails here instead of silently
    # writing NULL.
    seconds = 1_787_056_555

    assert :ok =
             SessionWorkCandidates.insert(candidate("token-seconds", %{"updated_at" => seconds}))

    assert {:ok, %{"updated_at" => ^seconds}} = SessionWorkCandidates.fetch_exact("token-seconds")

    assert %{rows: [[^seconds]]} =
             Repo.query!(
               "SELECT inserted_at_ms FROM session_work_candidates WHERE candidate_token = $1",
               ["token-seconds"]
             )
  end

  test "cloud VM demand includes runnable work but excludes human waits and other Groups" do
    group = SalixStore.Ids.new_group_id(SalixStore.Ids.new_tenant_id())
    agent = SalixStore.Ids.agent_id_prefix_for_group!(group) <> "0000000000000000001"
    scope = %{"agent_id" => agent, "runtime_kind" => "external"}
    assert {:ok, false} = SessionWorkCandidates.ready_for_external_group?(group)

    assert :ok =
             SessionWorkCandidates.insert(
               candidate(
                 "human-wait",
                 Map.merge(scope, %{"reasons" => ["external_callback_tool_call"]})
               )
             )

    assert {:ok, false} = SessionWorkCandidates.ready_for_external_group?(group)

    assert :ok =
             SessionWorkCandidates.insert(
               candidate("queued", Map.merge(scope, %{"reasons" => ["unacked_queue_item"]}))
             )

    assert {:ok, true} = SessionWorkCandidates.ready_for_external_group?(group)
    assert :ok = SessionWorkCandidates.delete_exact("queued")
    assert {:ok, false} = SessionWorkCandidates.ready_for_external_group?(group)

    assert :ok =
             SessionWorkCandidates.insert(candidate("other", %{"reasons" => ["active_round"]}))

    assert {:ok, false} = SessionWorkCandidates.ready_for_external_group?(group)
  end

  defp candidate(token, overrides \\ %{}) do
    Map.merge(
      %{
        "token" => token,
        "agent_id" => "agent-a",
        "runtime_kind" => "internal",
        "session_id" => "session-a",
        "base_revision" => "revision-a",
        "reasons" => ["queued_input"],
        "updated_at" => 1_000
      },
      overrides
    )
  end

  defp cursor(record) do
    %{
      agent_id: record["agent_id"],
      runtime_kind: record["runtime_kind"],
      session_id: record["session_id"],
      candidate_token: record["token"]
    }
    |> then(fn cursor ->
      case record["recover_after_ms"] do
        due when is_integer(due) -> Map.put(cursor, :due_at_ms, due)
        _ -> cursor
      end
    end)
  end
end
