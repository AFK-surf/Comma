defmodule SalixMeetNativeTest do
  use ExUnit.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixMeetNative"]

  alias SalixMeetNative.FakeSession

  test "a meeting is joined once cluster-wide, can be left from its id and reports the outcome" do
    test = self()
    meeting_id = "lifecycle-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    request = %{"meeting_id" => meeting_id, "meet_url" => "https://meet.google.com/abc-defg-hij"}

    opts = [
      deliver: fn event -> send(test, {:delivered, event}) && :ok end,
      session_module: FakeSession,
      session: [test_pid: test]
    ]

    assert {:ok, pid, :started} = SalixMeetNative.join(request, opts)
    settle_receive({:fake_session, _session, _})
    assert {:ok, ^pid, :reused} = SalixMeetNative.join(request, opts)
    settle_refute_receive({:fake_session, _, _})

    assert SalixMeetNative.session_status(meeting_id) == {:ok, :live}
    assert meeting_id in SalixMeetNative.list()

    assert :ok = SalixMeetNative.leave(meeting_id)
    settle_receive({:delivered, %{"event_id" => event_id, "status" => "cancelled"}})
    assert event_id == meeting_id <> ":runtime:cancelled"

    ref = Process.monitor(pid)
    settle_receive({:DOWN, ^ref, :process, ^pid, _})
    assert SalixMeetNative.session_status(meeting_id) == {:ok, :none}
    assert SalixMeetNative.leave(meeting_id) == {:error, :not_found}
    assert SalixMeetNative.send_chat(meeting_id, "hi") == {:error, :not_found}
  end

  test "a second meeting id for the same Meet link is refused while the bot runs" do
    test = self()
    url = "https://meet.google.com/xyz-abcd-efg"

    opts = [
      deliver: fn event -> send(test, {:delivered, event}) && :ok end,
      session_module: FakeSession,
      session: [test_pid: test]
    ]

    first = "code-a-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    second = "code-b-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    assert {:ok, pid, :started} =
             SalixMeetNative.join(%{"meeting_id" => first, "meet_url" => url}, opts)

    assert {:error, :meet_in_use} =
             SalixMeetNative.join(%{"meeting_id" => second, "meet_url" => url}, opts)

    settle_receive({:fake_session, _session, _})
    settle_refute_receive({:fake_session, _, _})
    assert SalixMeetNative.session_status(second) == {:ok, :none}
    assert :ok = SalixMeetNative.leave(first)
    ref = Process.monitor(pid)
    settle_receive({:DOWN, ^ref, :process, ^pid, _})

    assert {:ok, _pid, :started} =
             SalixMeetNative.join(%{"meeting_id" => second, "meet_url" => url}, opts)

    assert :ok = SalixMeetNative.leave(second)
  end

  test "draining the node makes every local bot leave and deliver before it stops" do
    test = self()
    admitted = "drain-in-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    waiting = "drain-wait-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    opts = [
      deliver: fn event -> send(test, {:delivered, event}) && :ok end,
      session_module: FakeSession,
      session: [test_pid: test]
    ]

    assert {:ok, in_pid, :started} = SalixMeetNative.join(%{"meeting_id" => admitted}, opts)
    settle_receive({:fake_session, session, _})
    FakeSession.emit(session, {:status, %{self: "joined"}})
    settle_receive({:delivered, %{"joiner_event" => %{"status" => "in_meeting"}}})

    assert {:ok, wait_pid, :started} = SalixMeetNative.join(%{"meeting_id" => waiting}, opts)
    settle_receive({:fake_session, _session, _})

    assert :ok = SalixMeetNative.Drain.drain(timeout_ms: 5_000)

    assert_received {:delivered, %{"event_id" => done_id, "status" => "done"}}
    assert done_id == admitted <> ":runtime:done"

    # A bot drained before admission fails the join attempt so the Meeting can
    # be retried elsewhere.
    assert_received {:delivered, %{"event_id" => failed_id, "status" => "failed"} = failed}
    assert failed_id == waiting <> ":runtime:failed"
    assert failed["error"] == "The meeting assistant restarted before it was admitted"

    refute Process.alive?(in_pid)
    refute Process.alive?(wait_pid)
  end

  test "a join without a meeting id is rejected" do
    assert SalixMeetNative.join(%{"meet_url" => "x"}, []) == {:error, :missing_meeting_id}
  end
end
