defmodule SalixMeet.JoinDispatchOutboxTest do
  @moduledoc """
  Regression coverage for the durable join-dispatch outbox.

  The meeting document, not the Meeting GenServer, owns the dispatch state.
  The process only gates a caller that claims the outbox and executes the
  external runtime in that same bounded caller.
  """
  use ExUnit.Case, async: false

  alias SalixMeet.{Meeting, Store}

  defmodule RuntimeDriver do
    @behaviour SalixMeet.RuntimeDriver

    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn -> %{test_pid: nil, mode: {:return, :ok}, calls: []} end,
        name: __MODULE__
      )
    end

    def configure(test_pid, mode) do
      Agent.update(__MODULE__, fn state ->
        %{state | test_pid: test_pid, mode: mode, calls: []}
      end)
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    @impl true
    def join(doc) do
      caller = self()

      %{test_pid: test_pid, mode: mode} =
        Agent.get_and_update(__MODULE__, fn state ->
          call = %{caller: caller, doc: doc}
          {state, %{state | calls: [call | state.calls]}}
        end)

      send(test_pid, {:runtime_join_started, caller, doc})

      case mode do
        {:return, result} ->
          result

        :block ->
          receive do
            {:release_runtime_join, result} -> result
          end
      end
    end
  end

  setup do
    previous_s3 = Application.get_env(:salix_store, :s3_backend)
    previous_driver = Application.get_env(:salix_meet, :runtime_driver)

    stop_all_meetings()
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_meet, :runtime_driver, RuntimeDriver)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(RuntimeDriver)
    SalixStore.S3.Fake.reset()
    RuntimeDriver.configure(self(), {:return, :ok})

    on_exit(fn ->
      stop_all_meetings()
      restore_env(:salix_store, :s3_backend, previous_s3)
      restore_env(:salix_meet, :runtime_driver, previous_driver)
    end)

    {:ok, id: "join-outbox-#{System.unique_integer([:positive])}"}
  end

  test "concurrent callers produce one claim and the loser sees join_in_progress", %{id: id} do
    meeting_pid = start_leader!(id)
    RuntimeDriver.configure(self(), :block)

    winner = Task.async(fn -> Meeting.join(id) end)

    assert_receive {:runtime_join_started, winner_pid, runtime_doc}, 1_000
    assert winner_pid == winner.pid
    assert winner_pid != meeting_pid

    dispatch = dispatch!(runtime_doc)
    assert dispatch["status"] == "dispatching"
    assert is_binary(dispatch["generation"])
    assert dispatch["generation"] != ""
    assert is_binary(dispatch["claimed_by"])
    assert dispatch["claimed_by"] != ""
    assert is_integer(dispatch["claimed_at"])

    assert {:error, :join_in_progress} = Meeting.join(id)
    refute_receive {:runtime_join_started, _, _}, 50
    assert [_single_claim] = RuntimeDriver.calls()

    send(winner_pid, {:release_runtime_join, :ok})
    assert {:ok, requested_at} = Task.await(winner, 1_000)

    assert eventually(fn ->
             case Store.get(id) do
               {:ok, doc, _etag} ->
                 join_dispatch_status(doc) == "dispatched" and
                   doc["join_requested_at"] == requested_at

               _ ->
                 false
             end
           end)
  end

  test "a successful runtime call checkpoints the winning generation as dispatched", %{id: id} do
    start_leader!(id)
    RuntimeDriver.configure(self(), {:return, {:ok, %{"accepted" => true}}})

    assert {:ok, requested_at} = Meeting.join(id)
    assert_receive {:runtime_join_started, caller, runtime_doc}, 1_000
    assert caller == self()
    assert runtime_doc["join_requested_at"] == requested_at

    assert {:ok, persisted, _etag} = Store.get(id)
    dispatch = dispatch!(persisted)
    runtime_dispatch = dispatch!(runtime_doc)

    assert dispatch["status"] == "dispatched"
    assert dispatch["generation"] == runtime_dispatch["generation"]
    assert is_integer(dispatch["completed_at"])
    assert dispatch["last_error"] == nil

    assert {:ok, ^requested_at} = Meeting.join(id)
    assert [_single_dispatch] = RuntimeDriver.calls()
  end

  test "a runtime failure stays reclaimable, but a retry without a definite liveness answer fails closed",
       %{id: id} do
    start_leader!(id)
    RuntimeDriver.configure(self(), {:return, {:error, :runtime_unavailable}})

    first_result = Meeting.join(id)
    assert {:error, _reason} = first_result
    assert_receive {:runtime_join_started, caller, _runtime_doc}, 1_000
    assert caller == self()

    assert {:ok, failed, _etag} = Store.get(id)
    dispatch = dispatch!(failed)
    assert dispatch["status"] == "failed"
    assert is_integer(dispatch["completed_at"])
    assert dispatch["last_error"] not in [nil, ""]
    # In-budget failure no longer converges the meeting terminally: the
    # record is reclaimable under RFC contract one.
    assert failed["state"]["status"] == "joining"

    # No live-session authority is configured here, so the probe answer is
    # unavailable and the retry round fails closed — no budget consumed, no
    # second driver call.
    assert {:error, :join_liveness_unavailable} = Meeting.join(id)
    assert [_single_dispatch] = RuntimeDriver.calls()
    refute_receive {:runtime_join_started, _, _}, 50
  end

  test "caller death leaves dispatching in doubt and a later caller does not redispatch", %{
    id: id
  } do
    meeting_pid = start_leader!(id)
    RuntimeDriver.configure(self(), :block)

    caller = Task.async(fn -> Meeting.join(id) end)
    assert_receive {:runtime_join_started, driver_pid, _runtime_doc}, 1_000
    assert driver_pid == caller.pid
    assert driver_pid != meeting_pid

    caller_ref = Process.monitor(caller.pid)
    _ = Task.shutdown(caller, :brutal_kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^driver_pid, _reason}, 1_000

    assert Process.alive?(meeting_pid)
    assert Meeting.leader?(id)
    assert {:ok, in_doubt, _etag} = Store.get(id)
    dispatch = dispatch!(in_doubt)
    assert dispatch["status"] == "dispatching"
    assert dispatch["completed_at"] == nil
    assert dispatch["last_error"] == nil

    assert {:error, :join_in_progress} = Meeting.join(id)
    assert [_single_dispatch] = RuntimeDriver.calls()
    refute_receive {:runtime_join_started, _, _}, 50
  end

  test "a durable abandonment racing the claim is rejected atomically", %{id: id} do
    start_leader!(id)
    RuntimeDriver.configure(self(), {:return, :ok})

    assert {:ok, _doc, etag} = Store.get(id)

    assert {:ok, abandoned, _etag} =
             Store.update_state(id, etag, fn state ->
               Map.put(state, "join_dispatch", %{
                 "status" => "abandoned",
                 "generation" => "cancelled-before-claim",
                 "claimed_by" => nil,
                 "claimed_at" => nil,
                 "completed_at" => 7_000,
                 "last_error" => "calendar event cancelled"
               })
             end)

    assert abandoned["join_requested_at"] == nil
    assert {:error, :abandoned} = Meeting.join(id)
    assert RuntimeDriver.calls() == []
    refute_receive {:runtime_join_started, _, _}, 50

    assert {:ok, unchanged, _etag} = Store.get(id)
    assert unchanged["join_requested_at"] == nil
    assert dispatch!(unchanged) == dispatch!(abandoned)
  end

  test "terminal meetings reject join claims before mutating the outbox", %{id: id} do
    Enum.each(~w(done failed cancelled), fn status ->
      terminal_id = "#{id}-#{status}"
      start_leader!(terminal_id)

      assert {:ok, _doc, etag} = Store.get(terminal_id)

      assert {:ok, terminal, _etag} =
               Store.update_state(terminal_id, etag, &Map.put(&1, "status", status))

      assert terminal["join_requested_at"] == nil
      refute get_in(terminal, ["state", "join_dispatch"])
      assert {:error, :terminal_meeting} = Meeting.join(terminal_id)

      assert {:ok, unchanged, _etag} = Store.get(terminal_id)
      assert unchanged["join_requested_at"] == nil
      refute get_in(unchanged, ["state", "join_dispatch"])
    end)

    assert RuntimeDriver.calls() == []
    refute_receive {:runtime_join_started, _, _}, 50
  end

  test "a dispatched meeting rejects a later join after becoming terminal", %{id: id} do
    start_leader!(id)

    assert {:ok, requested_at} = Meeting.join(id)
    assert_receive {:runtime_join_started, _caller, _runtime_doc}, 1_000
    assert [_single_dispatch] = RuntimeDriver.calls()

    assert {:ok, dispatched, etag} = Store.get(id)
    assert join_dispatch_status(dispatched) == "dispatched"
    assert dispatched["join_requested_at"] == requested_at

    assert {:ok, terminal, _etag} =
             Store.update_state(id, etag, &Map.put(&1, "status", "done"))

    assert {:error, :terminal_meeting} = Meeting.join(id)
    assert [_single_dispatch] = RuntimeDriver.calls()
    refute_receive {:runtime_join_started, _, _}, 50

    assert {:ok, unchanged, _etag} = Store.get(id)
    assert unchanged["join_requested_at"] == requested_at
    assert dispatch!(unchanged) == dispatch!(terminal)
  end

  test "a slow driver runs in the bounded caller and never blocks the Meeting GenServer", %{
    id: id
  } do
    meeting_pid = start_leader!(id)
    RuntimeDriver.configure(self(), :block)

    bounded_caller = Task.async(fn -> Meeting.join(id) end)
    assert_receive {:runtime_join_started, driver_pid, _runtime_doc}, 1_000

    assert driver_pid == bounded_caller.pid
    assert driver_pid != meeting_pid

    readiness_check = Task.async(fn -> Meeting.leader?(id) end)
    assert Task.await(readiness_check, 250)

    send(driver_pid, {:release_runtime_join, :ok})
    assert {:ok, _requested_at} = Task.await(bounded_caller, 1_000)
    assert Process.alive?(meeting_pid)
  end

  defp start_leader!(id) do
    assert {:ok, pid} =
             SalixMeet.Application.start_meeting(id,
               node: "join-outbox-test-node",
               interval_ms: 60_000
             )

    assert eventually(fn -> Meeting.leader?(id) end)
    pid
  end

  defp dispatch!(doc) do
    dispatch = get_in(doc, ["state", "join_dispatch"])
    assert is_map(dispatch)
    dispatch
  end

  defp join_dispatch_status(doc), do: get_in(doc, ["state", "join_dispatch", "status"])

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp stop_all_meetings do
    if Process.whereis(SalixMeet.MeetingSup) do
      SalixMeet.MeetingSup
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(SalixMeet.MeetingSup, pid)
      end)
    end

    :ok
  end
end
