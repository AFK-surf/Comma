defmodule SalixMeet.JoinRetryTest do
  use ExUnit.Case, async: false

  alias SalixMeet.{JoinDispatch, Store}

  defmodule RetryDispatchPort do
    @behaviour SalixMeet.Ports.MeetingDispatch

    @impl true
    def join(_payload), do: {:error, :not_configured}

    @impl true
    def send_chat(_payload), do: {:error, :not_configured}

    @impl true
    def session_status(payload) do
      send(Application.fetch_env!(:salix_meet, :join_retry_test_pid), {:probe, payload})
      Application.get_env(:salix_meet, :join_retry_test_answer, {:ok, :unavailable})
    end
  end

  defmodule RecordingDriver do
    def join(doc) do
      send(Application.fetch_env!(:salix_meet, :join_retry_test_pid), {:driver_join, doc["id"]})
      Application.get_env(:salix_meet, :join_retry_test_driver_result, :ok)
    end
  end

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_dispatch = Application.get_env(:salix_meet, :meeting_dispatch_mod)
    previous_driver = Application.get_env(:salix_meet, :runtime_driver)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_meet, :meeting_dispatch_mod, RetryDispatchPort)
    Application.put_env(:salix_meet, :runtime_driver, RecordingDriver)
    Application.put_env(:salix_meet, :join_retry_test_pid, self())

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      if is_nil(previous_backend),
        do: Application.delete_env(:salix_store, :s3_backend),
        else: Application.put_env(:salix_store, :s3_backend, previous_backend)

      Application.put_env(:salix_meet, :meeting_dispatch_mod, previous_dispatch)
      Application.put_env(:salix_meet, :runtime_driver, previous_driver)
      Application.delete_env(:salix_meet, :join_retry_test_answer)
      Application.delete_env(:salix_meet, :join_retry_test_driver_result)
      Application.delete_env(:salix_meet, :join_retry_test_pid)
    end)

    :ok
  end

  defp seed_meeting(dispatch, extra_state \\ %{}) do
    meeting_id = "mtg-join-retry-#{System.unique_integer([:positive])}"

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

    test "checkpoint failure marks the meeting terminal only when the budget is exhausted" do
      meeting_id = seed_meeting(failed_dispatch(1))
      claim = %{"generation" => "g2", "claimed_by" => "test"}

      assert {:ok, :claimed, _doc, _etag, _claimed} =
               Store.claim_join_dispatch(meeting_id, claim, liveness: :none)

      assert {:ok, doc, _etag} =
               Store.checkpoint_join_dispatch(meeting_id, "g2", {:failed, :boom})

      assert doc["state"]["join_dispatch"]["status"] == "failed"
      assert doc["state"]["status"] == "joining"

      # Walk the remaining budget: each round re-claims with :none and fails.
      final =
        Enum.reduce(3..Store.join_max_attempts(), nil, fn attempt, _acc ->
          generation = "g#{attempt}"

          assert {:ok, :claimed, _d, _e, %{"attempt_count" => ^attempt}} =
                   Store.claim_join_dispatch(
                     meeting_id,
                     %{"generation" => generation, "claimed_by" => "test"},
                     liveness: :none
                   )

          assert {:ok, doc, _e} =
                   Store.checkpoint_join_dispatch(meeting_id, generation, {:failed, :boom})

          doc
        end)

      assert final["state"]["status"] == "failed"
      assert final["state"]["join_dispatch"]["attempt_count"] == Store.join_max_attempts()

      # The exhausted-budget convergence already made the meeting terminal, so
      # the claim is refused at the terminal check.
      assert {:error, :terminal_meeting} =
               Store.claim_join_dispatch(
                 meeting_id,
                 %{"generation" => "gz", "claimed_by" => "test"},
                 liveness: :none
               )
    end
  end

  describe "stale dispatched (dispatch is not a join)" do
    defp dispatched_state(now, extra) do
      Map.merge(
        %{
          "status" => "joining",
          "join_requested_at" => now - 200_000,
          "join_dispatch" => %{
            "status" => "dispatched",
            "generation" => "g-stale",
            "claimed_by" => "node-a",
            "claimed_at" => now - 200_000,
            "completed_at" => now - 200_000,
            "attempt_count" => 1
          }
        },
        extra
      )
    end

    test "a dispatched record with no join past the reclaim age is a retry candidate" do
      now = 1_700_000_000_000
      id = "stale-dispatched-#{System.unique_integer([:positive])}"
      assert {:ok, doc, _} = Store.create_once(id, state: dispatched_state(now, %{}))
      assert Store.join_retry_candidate?(doc, now)
    end

    test "a joined meeting or a fresh dispatch is not" do
      now = 1_700_000_000_000
      joined = "stale-joined-#{System.unique_integer([:positive])}"
      fresh = "fresh-dispatched-#{System.unique_integer([:positive])}"

      assert {:ok, joined_doc, _} =
               Store.create_once(joined,
                 state: dispatched_state(now, %{"joined_at" => now - 100})
               )

      refute Store.join_retry_candidate?(joined_doc, now)

      assert {:ok, fresh_doc, _} = Store.create_once(fresh, state: dispatched_state(now, %{}))
      refute Store.join_retry_candidate?(fresh_doc, now - 190_000)
    end

    test "a live answer converges the stale record without a dispatch and without spending budget" do
      now = 1_700_000_000_000
      id = "stale-live-#{System.unique_integer([:positive])}"
      assert {:ok, _doc, _} = Store.create_once(id, state: dispatched_state(now, %{}))
      Application.put_env(:salix_meet, :join_retry_test_answer, {:ok, :live})

      assert {:ok, _requested_at} = JoinDispatch.run(id, now: now, claimed_by: "node-b")
      assert_received {:probe, %{"meeting_id" => ^id}}
      refute_received {:driver_join, _}

      assert {:ok, doc, _} = Store.get(id)
      dispatch = doc["state"]["join_dispatch"]
      assert dispatch["status"] == "dispatched"
      assert dispatch["recovered"] == "live_session"
      assert dispatch["attempt_count"] == 1
      assert dispatch["completed_at"] == now
    end

    test "a definitely-none answer re-dispatches the stale record as a new attempt" do
      now = 1_700_000_000_000
      id = "stale-none-#{System.unique_integer([:positive])}"
      assert {:ok, _doc, _} = Store.create_once(id, state: dispatched_state(now, %{}))
      Application.put_env(:salix_meet, :join_retry_test_answer, {:ok, :none})

      assert {:ok, _requested_at} = JoinDispatch.run(id, now: now, claimed_by: "node-b")
      assert_received {:driver_join, ^id}

      assert {:ok, doc, _} = Store.get(id)
      assert doc["state"]["join_dispatch"]["status"] == "dispatched"
      assert doc["state"]["join_dispatch"]["attempt_count"] == 2
      assert doc["state"]["status"] == "joining"
    end
  end

  describe "JoinDispatch retry rounds" do
    test "a fresh first dispatch asks the runtime nothing" do
      meeting_id = seed_meeting(nil, %{"join_requested_at" => nil})

      # Precondition: never dispatched at the top level either.
      assert {:ok, doc, _etag} = Store.get(meeting_id)
      refute is_integer(doc["join_requested_at"])

      assert {:ok, _requested_at} = JoinDispatch.run(meeting_id, claimed_by: "test")
      assert_receive {:driver_join, ^meeting_id}
      refute_receive {:probe, _payload}, 100
    end

    test "a retry probes first and dispatches on definitely-none" do
      meeting_id = seed_meeting(failed_dispatch(1))
      Application.put_env(:salix_meet, :join_retry_test_answer, {:ok, :none})

      assert {:ok, _requested_at} = JoinDispatch.run(meeting_id, claimed_by: "test")
      assert_receive {:probe, %{"meeting_id" => ^meeting_id, "group_id" => "grp-join"}}
      assert_receive {:driver_join, ^meeting_id}

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["join_dispatch"]["status"] == "dispatched"
      assert doc["state"]["join_dispatch"]["attempt_count"] == 2
    end

    test "an attested idempotent runtime permits the retry without a definite answer" do
      meeting_id = seed_meeting(failed_dispatch(1))
      Application.put_env(:salix_meet, :join_retry_test_answer, {:ok, :unavailable_idempotent})

      assert {:ok, _requested_at} = JoinDispatch.run(meeting_id, claimed_by: "test")
      assert_receive {:probe, %{"meeting_id" => ^meeting_id}}
      assert_receive {:driver_join, ^meeting_id}

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["join_dispatch"]["status"] == "dispatched"
      assert doc["state"]["join_dispatch"]["attempt_count"] == 2
    end

    test "a retry with a live session adopts it without a second join" do
      meeting_id = seed_meeting(failed_dispatch(1))
      Application.put_env(:salix_meet, :join_retry_test_answer, {:ok, :live})

      assert {:ok, _requested_at} = JoinDispatch.run(meeting_id, claimed_by: "test")
      assert_receive {:probe, %{"meeting_id" => ^meeting_id}}
      refute_receive {:driver_join, _id}, 100

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["join_dispatch"]["status"] == "dispatched"
      assert doc["state"]["join_dispatch"]["recovered"] == "live_session"
    end

    test "an unavailable answer fails the round closed without consuming budget" do
      meeting_id = seed_meeting(failed_dispatch(1))
      Application.put_env(:salix_meet, :join_retry_test_answer, {:ok, :unavailable})

      assert {:error, :join_liveness_unavailable} =
               JoinDispatch.run(meeting_id, claimed_by: "test")

      refute_receive {:driver_join, _id}, 100

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["join_dispatch"]["status"] == "failed"
      assert doc["state"]["join_dispatch"]["attempt_count"] == 1
    end

    test "a failed driver retry keeps the meeting retryable inside the budget" do
      meeting_id = seed_meeting(failed_dispatch(1))
      Application.put_env(:salix_meet, :join_retry_test_answer, {:ok, :none})
      Application.put_env(:salix_meet, :join_retry_test_driver_result, {:error, :boom})

      assert {:error, {:join_failed, _reason}} = JoinDispatch.run(meeting_id, claimed_by: "test")

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["join_dispatch"]["status"] == "failed"
      assert doc["state"]["join_dispatch"]["attempt_count"] == 2
      assert doc["state"]["status"] == "joining"
    end
  end
end
