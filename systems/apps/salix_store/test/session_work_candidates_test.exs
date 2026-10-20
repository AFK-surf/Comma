defmodule SalixStore.SessionWorkCandidatesTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

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

    parent = SystemsRuntime.Proc.self()

    writer =
      SystemsRuntime.Task.async(fn ->
        Repo.transaction(fn ->
          assert :ok =
                   SessionWorkCandidates.insert(
                     candidate("token-notify", %{
                       "agent_id" => "agent-notify",
                       "session_id" => "session-notify"
                     })
                   )

          SystemsRuntime.Proc.send(
            parent,
            {:candidate_inserted_inside_transaction, SystemsRuntime.Proc.self()}
          )

          SystemsRuntime.Proc.receive do
            :commit_candidate_transaction -> :ok
          end
        end)
      end)

    assert_receive {:candidate_inserted_inside_transaction, writer_pid}
    refute_receive {:notification, ^notifications, ^listen_ref, _channel, _payload}, 100

    SystemsRuntime.Proc.send(writer_pid, :commit_candidate_transaction)
    assert {:ok, :ok} = SystemsRuntime.Task.await(writer, :infinity)

    assert_receive {:notification, ^notifications, ^listen_ref, channel, payload}
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
end
