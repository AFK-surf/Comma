defmodule SalixMeet.JoinRetryTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet"]
  alias SalixMeet.{JoinDispatch, Store}

  defmodule RetryDispatchPort do
    @behaviour SalixMeet.Ports.MeetingDispatch

    @impl true
    def join(_payload), do: {:error, :not_configured}

    @impl true
    def send_chat(_payload), do: {:error, :not_configured}

    @impl true
    def session_status(payload) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :join_retry_test_pid),
        {:probe, payload}
      )

      SystemsRuntime.get_env(:salix_meet, :join_retry_test_answer, {:ok, :unavailable})
    end
  end

  defmodule RecordingDriver do
    def join(doc) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :join_retry_test_pid),
        {:driver_join, doc["id"]}
      )

      SystemsRuntime.get_env(:salix_meet, :join_retry_test_driver_result, :ok)
    end
  end

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_dispatch = SystemsRuntime.get_env(:salix_meet, :meeting_dispatch_mod)
    previous_driver = SystemsRuntime.get_env(:salix_meet, :runtime_driver)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_meet, :meeting_dispatch_mod, RetryDispatchPort)
    SystemsRuntime.put_env(:salix_meet, :runtime_driver, RecordingDriver)
    SystemsRuntime.put_env(:salix_meet, :join_retry_test_pid, SystemsRuntime.Proc.self())

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      if is_nil(previous_backend),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)

      SystemsRuntime.put_env(:salix_meet, :meeting_dispatch_mod, previous_dispatch)
      SystemsRuntime.put_env(:salix_meet, :runtime_driver, previous_driver)
      SystemsRuntime.delete_env(:salix_meet, :join_retry_test_answer)
      SystemsRuntime.delete_env(:salix_meet, :join_retry_test_driver_result)
      SystemsRuntime.delete_env(:salix_meet, :join_retry_test_pid)
    end)

    :ok
  end

  defp seed_meeting(dispatch, extra_state \\ %{}) do
    meeting_id = "mtg-join-retry-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    state =
      %{
        "tenant_id" => "ten-join",
        "group_id" => "grp-join",
        "connect_id" => "conn-join",
        "runtime_source" => "connected_runtime",
        "status" => "joining",
        "join_requested_at" => 1_000
      }
      |> Map.merge(extra_state)
      |> then(fn state ->
        if dispatch == nil, do: state, else: Map.put(state, "join_dispatch", dispatch)
      end)

    {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)
    meeting_id
  end

  defp failed_dispatch(attempts) do
    %{
      "status" => "failed",
      "generation" => "g#{attempts}",
      "claimed_by" => "test",
      "claimed_at" => 1_000,
      "completed_at" => 1_100,
      "last_error" => ":no_meeting_runtime_available",
      "attempt_count" => attempts
    }
  end

  describe "claim gate" do
    test "a failed record re-claims only with a definitely-none answer" do
      meeting_id = seed_meeting(failed_dispatch(1))
      claim = %{"generation" => "g2", "claimed_by" => "test"}

      assert {:error, :join_liveness_required} =
               Store.claim_join_dispatch(meeting_id, claim, [])

      assert {:error, :join_liveness_required} =
               Store.claim_join_dispatch(meeting_id, claim, liveness: :unavailable)

      assert {:ok, :claimed, doc, _etag, claimed} =
               Store.claim_join_dispatch(meeting_id, claim, liveness: :none)

      assert claimed["attempt_count"] == 2
      assert claimed["previous_error"] == ":no_meeting_runtime_available"
      assert doc["state"]["join_dispatch"]["status"] == "dispatching"
    end

    test "a definitely-live answer converges the record without a claim to dispatch" do
      meeting_id = seed_meeting(failed_dispatch(1))
      claim = %{"generation" => "g2", "claimed_by" => "test"}

      assert {:ok, :dispatched, doc, _etag, converged} =
               Store.claim_join_dispatch(meeting_id, claim, liveness: :live)

      assert converged["recovered"] == "live_session"
      assert doc["state"]["join_dispatch"]["status"] == "dispatched"
    end

    test "a stale in-doubt dispatching claim is reclaimable; a fresh one is not" do
      stale = %{
        "status" => "dispatching",
        "generation" => "g1",
        "claimed_by" => "test",
        "claimed_at" => 1_000,
        "completed_at" => nil,
        "last_error" => nil,
        "attempt_count" => 1
      }

      meeting_id = seed_meeting(stale)
      claim = %{"generation" => "g2", "claimed_by" => "test"}
      fresh_now = 1_000 + Store.join_reclaim_after_ms() - 1
      stale_now = 1_000 + Store.join_reclaim_after_ms()

      assert {:error, :join_in_progress} =
               Store.claim_join_dispatch(meeting_id, claim, liveness: :none, now: fresh_now)

      assert {:ok, :claimed, _doc, _etag, claimed} =
               Store.claim_join_dispatch(meeting_id, claim, liveness: :none, now: stale_now)

      assert claimed["attempt_count"] == 2
    end

    test "an exhausted budget keeps the permanent failure" do
      meeting_id = seed_meeting(failed_dispatch(Store.join_max_attempts()))
      claim = %{"generation" => "gx", "claimed_by" => "test"}

      assert {:error, {:join_failed, _reason}} =
               Store.claim_join_dispatch(meeting_id, claim, liveness: :none)
    end
  end

  describe "stale dispatched (dispatch is not a join)" do
  end

  describe "JoinDispatch retry rounds" do

    test "a retry with a live session adopts it without a second join" do
      meeting_id = seed_meeting(failed_dispatch(1))
      SystemsRuntime.put_env(:salix_meet, :join_retry_test_answer, {:ok, :live})

      assert {:ok, _requested_at} = JoinDispatch.run(meeting_id, claimed_by: "test")
      settle_receive({:probe, %{"meeting_id" => ^meeting_id}})
      settle_refute_receive({:driver_join, _id}, 10)
      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["join_dispatch"]["status"] == "dispatched"
      assert doc["state"]["join_dispatch"]["recovered"] == "live_session"
    end
  end
end
