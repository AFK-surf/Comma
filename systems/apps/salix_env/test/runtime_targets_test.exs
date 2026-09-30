defmodule SalixEnv.RuntimeTargetsTest do
  use ExUnit.Case, async: false

  alias SalixEnv.RuntimeTargets
  alias SalixStore.{Ids, Repo, SessionWorkCandidates, SessionWorkNotifications}

  setup do
    Repo.query!("TRUNCATE session_work_candidates")
    group_id = Ids.new_group_id(Ids.new_tenant_id())
    now = System.system_time(:second)

    device = %{
      "tenant_id" => Ids.tenant_id_from_group!(group_id),
      "group_id" => group_id,
      "device_id" => "notification-device",
      "status" => "connected",
      "meta" => %{
        "agent_runtimes" => [
          %{
            "provider" => "codex",
            "device_runtime_id" => "runtime-notification-target",
            "ready" => true,
            "auth_ready" => true,
            "native_server_startable" => true,
            "version_detected" => true,
            "readiness_checked_at" => now,
            "readiness_valid_until" => now + 300
          }
        ]
      }
    }

    %{device: device, group_id: group_id}
  end

  test "wait registration after READY uses durable scoped eligibility and preserves tool deadlines",
       %{device: device, group_id: group_id} do
    # No listener consumes this event. Registering later still finds readiness.
    assert :ok = RuntimeTargets.observe(device)
    future = System.system_time(:millisecond) + 60_000

    candidate =
      candidate(group_id, "original", %{
        "reasons" => ["runtime_wait", "wait_deadline"],
        "recover_after_ms" => future
      })

    assert :ok = SessionWorkCandidates.insert(candidate)
    other_group = Ids.new_group_id(Ids.new_tenant_id())
    assert :ok = SessionWorkCandidates.insert(candidate(other_group, "other-group"))

    assert :ok =
             SessionWorkCandidates.insert(
               candidate(group_id, "other-runtime", %{
                 "device_runtime_id" => "another-runtime"
               })
             )

    assert {:ok, %{records: [ready]}} = SessionWorkCandidates.list_eager()
    assert ready["token"] == "original"
    assert ready["recover_after_ms"] == future

    assert :ok = RuntimeTargets.observe(%{device | "status" => "disconnected"})
    assert {:ok, %{records: []}} = SessionWorkCandidates.list_eager()
    assert {:ok, %{records: [due]}} = SessionWorkCandidates.list_due(future)
    assert due["token"] == "original"

    # Offline cleanup does not remove accepted work or its timer.
    assert {:ok, records} = SessionWorkCandidates.list_all()
    assert length(records) == 3
    assert :ok = RuntimeTargets.observe(device)
    assert {:ok, %{records: [ready]}} = SessionWorkCandidates.list_eager()
    assert ready["token"] == "original"

    # Heartbeat publication cannot refresh expired probe evidence.
    expired =
      put_in(device, ["meta", "agent_runtimes"], [
        %{hd(device["meta"]["agent_runtimes"]) | "readiness_valid_until" => 1}
      ])

    assert :ok = RuntimeTargets.observe(expired)
    assert {:ok, %{records: []}} = SessionWorkCandidates.list_eager()
  end

  test "merged recovery pages keep order and do not repeat work eligible in both lanes", %{
    device: device,
    group_id: group_id
  } do
    assert :ok = RuntimeTargets.observe(device)

    for {token, reasons} <- [
          {"a-ready", ["runtime_wait"]},
          {"b-both", ["runtime_wait", "process_local_background_tool_run"]},
          {"c-ordinary", ["unacked_queue_item"]}
        ] do
      assert :ok =
               SessionWorkCandidates.insert(candidate(group_id, token, %{"reasons" => reasons}))
    end

    {tokens, _cursor} =
      Enum.map_reduce(1..3, nil, fn page, cursor ->
        assert {:ok, %{records: [record], eof: eof}} =
                 SessionWorkCandidates.list_eager(limit: 1, after: cursor)

        assert eof == (page == 3)

        next = %{
          agent_id: record["agent_id"],
          runtime_kind: record["runtime_kind"],
          session_id: record["session_id"],
          candidate_token: record["token"]
        }

        {record["token"], next}
      end)

    assert tokens == ["a-ready", "b-both", "c-ordinary"]
  end

  test "publication commits readiness and notification together", %{device: device} do
    notifications =
      start_supervised!({Postgrex.Notifications, Repo.config() |> Keyword.delete(:name)})

    channel = SessionWorkNotifications.channel()
    assert {:ok, ref} = Postgrex.Notifications.listen(notifications, channel)
    payload = SessionWorkNotifications.runtime_ready_payload()

    assert {:error, :injected_failure} =
             Repo.transaction(fn ->
               assert :ok = RuntimeTargets.observe(device)
               Repo.rollback(:injected_failure)
             end)

    refute_receive {:notification, ^notifications, ^ref, ^channel, ^payload}, 50
    assert is_nil(Repo.get_by(RuntimeTargets.Locator, group_id: device["group_id"]))

    assert :ok = RuntimeTargets.observe(device)
    assert_receive {:notification, ^notifications, ^ref, ^channel, ^payload}, 1_000

    assert %RuntimeTargets.Locator{ready_until_ms: expiry} =
             Repo.get_by(RuntimeTargets.Locator, group_id: device["group_id"])

    assert expiry > System.system_time(:millisecond)

    assert :ok = RuntimeTargets.observe(device)
    refute_receive {:notification, ^notifications, ^ref, ^channel, ^payload}, 50
  end

  defp candidate(group_id, token, extra \\ %{}) do
    Map.merge(
      %{
        "token" => token,
        "agent_id" => Ids.agent_id_prefix_for_group!(group_id) <> "0000000000000000001",
        "runtime_kind" => "external",
        "session_id" => "session-" <> token,
        "base_revision" => "base-" <> token,
        "updated_at" => 1,
        "reasons" => ["runtime_wait"],
        "device_runtime_id" => "runtime-notification-target"
      },
      extra
    )
  end
end
