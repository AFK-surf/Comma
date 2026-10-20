defmodule SalixMeet.JoinDispatchOutboxTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Regression coverage for the durable join-dispatch outbox.

  The meeting document, not the Meeting GenServer, owns the dispatch state.
  The process only gates a caller that claims the outbox and executes the
  external runtime in that same bounded caller.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet"]
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
      caller = SystemsRuntime.Proc.self()

      %{test_pid: test_pid, mode: mode} =
        Agent.get_and_update(__MODULE__, fn state ->
          call = %{caller: caller, doc: doc}
          {state, %{state | calls: [call | state.calls]}}
        end)

      SystemsRuntime.Proc.send(test_pid, {:runtime_join_started, caller, doc})

      case mode do
        {:return, result} ->
          result

        :block ->
          SystemsRuntime.Proc.receive do
            {:release_runtime_join, result} -> result
          end
      end
    end
  end

  setup do
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_driver = SystemsRuntime.get_env(:salix_meet, :runtime_driver)

    stop_all_meetings()
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_meet, :runtime_driver, RuntimeDriver)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(RuntimeDriver)
    SalixStore.S3.Fake.reset()
    RuntimeDriver.configure(SystemsRuntime.Proc.self(), {:return, :ok})

    on_exit(fn ->
      stop_all_meetings()
      restore_env(:salix_store, :s3_backend, previous_s3)
      restore_env(:salix_meet, :runtime_driver, previous_driver)
    end)

    {:ok, id: "join-outbox-#{SystemsRuntime.Proc.unique_integer([:positive])}"}
  end

  test "concurrent callers produce one claim and the loser sees join_in_progress", %{id: id} do
    meeting_pid = start_leader!(id)
    RuntimeDriver.configure(SystemsRuntime.Proc.self(), :block)

    winner = SystemsRuntime.Task.async(fn -> Meeting.join(id) end)

    settle_receive({:runtime_join_started, winner_pid, runtime_doc})
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
    settle_refute_receive({:runtime_join_started, _, _}, 50)
    assert [_single_claim] = RuntimeDriver.calls()

    SystemsRuntime.Proc.send(winner_pid, {:release_runtime_join, :ok})
    assert {:ok, requested_at} = settled_await(winner)

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
    RuntimeDriver.configure(SystemsRuntime.Proc.self(), {:return, {:ok, %{"accepted" => true}}})

    assert {:ok, requested_at} = Meeting.join(id)
    settle_receive({:runtime_join_started, caller, runtime_doc})
    assert caller == SystemsRuntime.Proc.self()
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
    RuntimeDriver.configure(SystemsRuntime.Proc.self(), {:return, {:error, :runtime_unavailable}})

    first_result = Meeting.join(id)
    assert {:error, _reason} = first_result
    settle_receive({:runtime_join_started, caller, _runtime_doc})
    assert caller == SystemsRuntime.Proc.self()

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
    settle_refute_receive({:runtime_join_started, _, _}, 50)
  end

  test "caller death leaves dispatching in doubt and a later caller does not redispatch", %{
    id: id
  } do
    meeting_pid = start_leader!(id)
    RuntimeDriver.configure(SystemsRuntime.Proc.self(), :block)

    caller = SystemsRuntime.Task.async(fn -> Meeting.join(id) end)
    settle_receive({:runtime_join_started, driver_pid, _runtime_doc})
    assert driver_pid == caller.pid
    assert driver_pid != meeting_pid

    caller_ref = SystemsRuntime.Proc.monitor(caller.pid)
    _ = SystemsRuntime.Task.shutdown(caller, :brutal_kill)
    settle_receive({:DOWN, ^caller_ref, :process, ^driver_pid, _reason})
    assert SystemsRuntime.Proc.alive?(meeting_pid)
    assert Meeting.leader?(id)
    assert {:ok, in_doubt, _etag} = Store.get(id)
    dispatch = dispatch!(in_doubt)
    assert dispatch["status"] == "dispatching"
    assert dispatch["completed_at"] == nil
    assert dispatch["last_error"] == nil

    assert {:error, :join_in_progress} = Meeting.join(id)
    assert [_single_dispatch] = RuntimeDriver.calls()
    settle_refute_receive({:runtime_join_started, _, _}, 50)
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
    settle_refute_receive({:runtime_join_started, _, _}, 50)
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

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp stop_all_meetings do
    if SystemsRuntime.Proc.whereis(SalixMeet.MeetingSup) do
      SalixMeet.MeetingSup
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(SalixMeet.MeetingSup, pid)
      end)
    end

    :ok
  end
end
