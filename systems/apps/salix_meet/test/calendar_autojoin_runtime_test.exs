defmodule SalixMeet.CalendarAutojoinRuntimeTest do
  use ExUnit.Case, async: false

  alias SalixMeet.{
    CalendarAutojoin,
    CalendarProjection,
    Runtime,
    RuntimeEvents,
    SlackThreadIndex,
    Store
  }

  alias SalixStore.{Ids, Keys, S3}

  defmodule TestCalendar do
    @behaviour SalixMeet.Ports.CalendarOccurrences

    @impl true
    def list(_group, _t0_ms, _t1_ms),
      do: {:ok, Application.get_env(:salix_meet, :calendar_autojoin_runtime_test_events, [])}

    @impl true
    def revalidate(_group, event) do
      case Application.get_env(
             :salix_meet,
             :calendar_autojoin_runtime_test_revalidation,
             :ok
           ) do
        revalidate when is_function(revalidate, 1) -> revalidate.(event)
        result -> result
      end
    end
  end

  defmodule TestChannel do
    @behaviour SalixMeet.Ports.MeetingChannel

    @impl true
    def resolve(_group) do
      {:ok,
       %{
         "connect_id" => "slack-runtime-test",
         "workspace_id" => "T-runtime-test",
         "channel_id" => "C-runtime-test",
         "thread_ts" => "111.222"
       }}
    end
  end

  defmodule RuntimeDriver do
    @behaviour SalixMeet.RuntimeDriver

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{calls: [], results: []} end, name: __MODULE__)
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{calls: [], results: []} end)

    def return(results) when is_list(results) do
      Agent.update(__MODULE__, &%{&1 | results: results})
    end

    @impl true
    def join(doc) do
      Agent.get_and_update(__MODULE__, fn state ->
        {result, remaining} = pop_result(state.results)
        {result, %{state | calls: state.calls ++ [doc], results: remaining}}
      end)
    end

    def calls, do: Agent.get(__MODULE__, & &1.calls)

    defp pop_result([result | rest]), do: {result, rest}
    defp pop_result([]), do: {:ok, []}
  end

  @now 10_000_000

  setup do
    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      llm: Application.get_env(:salix_agent, :llm),
      calendar: Application.get_env(:salix_meet, :calendar_occurrences_mod),
      channel: Application.get_env(:salix_meet, :meeting_channel_mod),
      join_fun: Application.get_env(:salix_meet, :calendar_join_fun),
      runtime_driver: Application.get_env(:salix_meet, :runtime_driver),
      agent_runtime: Application.get_env(:salix_meet, :agent_runtime_mod),
      copilot_enabled: Application.get_env(:salix_meet, :copilot_enabled),
      default_bot_name: Application.get_env(:salix_meet, :default_bot_name),
      default_caption_language: Application.get_env(:salix_meet, :default_caption_language),
      calendar_revalidation:
        Application.get_env(:salix_meet, :calendar_autojoin_runtime_test_revalidation),
      calendar_events: Application.get_env(:salix_meet, :calendar_autojoin_runtime_test_events)
    }

    stop_all_meetings()
    stop_all_agents()

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    Application.put_env(:salix_meet, :calendar_occurrences_mod, TestCalendar)
    Application.put_env(:salix_meet, :meeting_channel_mod, TestChannel)
    Application.delete_env(:salix_meet, :calendar_join_fun)
    Application.put_env(:salix_meet, :runtime_driver, RuntimeDriver)
    Application.put_env(:salix_meet, :agent_runtime_mod, SalixMeet.TestAgentRuntime)
    Application.put_env(:salix_meet, :copilot_enabled, false)
    Application.put_env(:salix_meet, :calendar_autojoin_runtime_test_events, [])
    Application.put_env(:salix_meet, :calendar_autojoin_runtime_test_revalidation, :ok)

    ensure_started!(SalixStore.S3.Fake)
    ensure_started!(SalixAgent.LLM.Mock)
    ensure_started!(RuntimeDriver)
    SalixStore.S3.Fake.reset()
    RuntimeDriver.reset()

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    put_group!(tenant_id, group_id)

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "calendar_id" => "calendar-primary@example.com",
      "calendar_connected_account_id" => "ca-primary"
    }

    on_exit(fn ->
      stop_all_meetings()
      stop_all_agents()
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_agent, :llm, previous.llm)
      restore_env(:salix_meet, :calendar_occurrences_mod, previous.calendar)
      restore_env(:salix_meet, :meeting_channel_mod, previous.channel)
      restore_env(:salix_meet, :calendar_join_fun, previous.join_fun)
      restore_env(:salix_meet, :runtime_driver, previous.runtime_driver)
      restore_env(:salix_meet, :agent_runtime_mod, previous.agent_runtime)
      restore_env(:salix_meet, :copilot_enabled, previous.copilot_enabled)
      restore_env(:salix_meet, :default_bot_name, previous.default_bot_name)

      restore_env(
        :salix_meet,
        :default_caption_language,
        previous.default_caption_language
      )

      restore_env(
        :salix_meet,
        :calendar_autojoin_runtime_test_revalidation,
        previous.calendar_revalidation
      )

      restore_env(
        :salix_meet,
        :calendar_autojoin_runtime_test_events,
        previous.calendar_events
      )
    end)

    {:ok, tenant_id: tenant_id, group_id: group_id, group: group}
  end

  test "a calendar sweep uses Meeting.join and dispatches a complete durable runtime identity", %{
    group: group,
    group_id: group_id
  } do
    Application.put_env(:salix_meet, :default_bot_name, "Configured Calendar Bot")
    Application.put_env(:salix_meet, :default_caption_language, "Japanese")

    event = event("runtime-contract", @now + 30_000)
    set_events([event])

    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)
    assert [%{action: :joined, mid: meeting_id}] = CalendarAutojoin.join_sweep([group], now: @now)

    assert [runtime_doc] = RuntimeDriver.calls()
    assert runtime_doc["id"] == meeting_id

    state = runtime_doc["state"]
    agent_id = state["meeting_agent_id"]
    session_id = state["meeting_session_id"]

    assert Ids.valid_agent_id_for_group?(agent_id, group_id)
    assert Ids.valid_session_id?(session_id)
    refute agent_id == session_id
    assert state["runtime_ref"] == session_id

    token = state["runtime_token"]
    assert is_binary(token)
    assert {:ok, token_bytes} = Base.url_decode64(token, padding: false)
    assert byte_size(token_bytes) == 32
    assert state["artifact_root"] == RuntimeEvents.artifact_root(meeting_id)
    assert state["bot_name"] == "Configured Calendar Bot"
    assert state["caption_language"] == "Japanese"

    assert {:ok, persisted, _etag} = Store.get(meeting_id)
    assert persisted["state"]["meeting_agent_id"] == agent_id
    assert persisted["state"]["meeting_session_id"] == session_id
    assert persisted["state"]["runtime_token"] == token
    assert persisted["state"]["artifact_root"] == RuntimeEvents.artifact_root(meeting_id)

    assert {:ok, durable_agent} = read_json(Keys.meet_agent(group_id))
    assert durable_agent["meeting_agent_id"] == agent_id
    assert durable_agent["meeting_session_id"] == session_id

    assert {:ok, %{"meeting_id" => ^meeting_id}} =
             SlackThreadIndex.fetch(
               persisted["state"],
               "C-runtime-test",
               "111.222"
             )
  end

  test "a CalendarAutojoin-owned Slack thread blocks a parallel manual meeting",
       %{group: group, tenant_id: tenant_id, group_id: group_id} do
    event = event("cross-path-thread-owner", @now + 30_000)
    set_events([event])

    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    assert [%{action: :joined, mid: calendar_meeting_id}] =
             CalendarAutojoin.join_sweep([group], now: @now)

    connect = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => "slack-runtime-test",
      "workspace_id" => "T-runtime-test",
      "bot_token" => ""
    }

    envelope = %{
      "event_id" => "Ev-cross-path-manual",
      "event" => %{
        "type" => "message",
        "user" => "U1",
        "text" => "please join https://meet.google.com/mno-pqrs-tuv",
        "channel" => "C-runtime-test",
        "thread_ts" => "111.222",
        "ts" => "700.000",
        "event_ts" => "700.000"
      }
    }

    assert {:ok, :handled} = SalixMeet.SlackProvider.handle_event(connect, envelope)
    assert {:ok, [^calendar_meeting_id]} = Store.list()
    assert Enum.map(RuntimeDriver.calls(), & &1["id"]) == [calendar_meeting_id]
  end

  test "an existing meeting created before dispatch is resumed while its join CAS is absent", %{
    group: group,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    event = event("resume-before-dispatch", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    assert [%{mid: meeting_id}] = CalendarAutojoin.join_sweep([group], now: @now, dry_run: true)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)

    state = durable_calendar_state(group, meeting_agent, event, meeting_id)
    assert {:ok, created, _etag} = Store.create_once(meeting_id, state: state, now: @now)
    assert created["join_requested_at"] == nil

    assert [%{action: :joined, mid: ^meeting_id}] =
             CalendarAutojoin.join_sweep([group], now: @now)

    assert [%{"id" => ^meeting_id}] = RuntimeDriver.calls()
    assert {:ok, joined, _etag} = Store.get(meeting_id)
    assert is_integer(joined["join_requested_at"])
  end

  test "an already-dispatched calendar meeting backfills Slack thread ownership without redispatch",
       %{group: group, tenant_id: tenant_id, group_id: group_id} do
    event = event("backfill-thread-owner", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(group, event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)

    state =
      group
      |> durable_calendar_state(meeting_agent, event, meeting_id)
      |> Map.put("join_dispatch", %{
        "status" => "dispatched",
        "generation" => "legacy-generation",
        "claimed_by" => "legacy-node",
        "claimed_at" => @now,
        "completed_at" => @now,
        "last_error" => nil
      })

    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    assert [] = CalendarAutojoin.join_sweep([group], now: @now, group_bounded: true)
    assert RuntimeDriver.calls() == []

    assert {:ok, %{"meeting_id" => ^meeting_id}} =
             SlackThreadIndex.fetch(state, "C-runtime-test", "111.222")
  end

  defmodule StaleDispatchPort do
    @behaviour SalixMeet.Ports.MeetingDispatch

    @impl true
    def join(_payload), do: {:error, :not_configured}

    @impl true
    def send_chat(_payload), do: {:error, :not_configured}

    @impl true
    def session_status(_payload),
      do: Application.get_env(:salix_meet, :stale_dispatch_test_answer, {:ok, :unavailable})
  end

  # "Dispatched" is not "joined". A record that was dispatched, never reported
  # a join, and is older than the reclaim age is not reported as `already`
  # any more: it is re-evaluated through the runtime liveness gate. The
  # runtime's answer — not this end — decides whether that means a second
  # dispatch (definitely none) or just refreshed timestamps (live).
  describe "stale dispatched records re-enter the liveness-gated join" do
    setup do
      previous = Application.get_env(:salix_meet, :meeting_dispatch_mod)
      Application.put_env(:salix_meet, :meeting_dispatch_mod, StaleDispatchPort)

      on_exit(fn ->
        Application.delete_env(:salix_meet, :stale_dispatch_test_answer)
        restore_env(:salix_meet, :meeting_dispatch_mod, previous)
      end)

      :ok
    end

    defp seed_stale_dispatched(group, tenant_id, group_id, label) do
      event = event(label, @now + 30_000)
      set_events([event])
      assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)
      meeting_id = CalendarAutojoin.meeting_id(group, event)
      assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)

      state =
        group
        |> durable_calendar_state(meeting_agent, event, meeting_id)
        |> Map.put("join_dispatch", %{
          "status" => "dispatched",
          "generation" => "stale-generation",
          "claimed_by" => "old-node",
          "claimed_at" => @now - 200_000,
          "completed_at" => @now - 200_000,
          "attempt_count" => 1,
          "last_error" => nil
        })

      assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)
      meeting_id
    end

    test "a definitely-none answer re-dispatches it as a second attempt",
         %{group: group, tenant_id: tenant_id, group_id: group_id} do
      meeting_id = seed_stale_dispatched(group, tenant_id, group_id, "stale-none")
      Application.put_env(:salix_meet, :stale_dispatch_test_answer, {:ok, :none})

      assert [%{action: :joined, mid: ^meeting_id}] =
               CalendarAutojoin.join_sweep([group], now: @now)

      assert [_one_call] = RuntimeDriver.calls()
      assert {:ok, persisted, _etag} = Store.get(meeting_id)
      assert get_in(persisted, ["state", "join_dispatch", "attempt_count"]) == 2
      # The second attempt is a normal dispatch; the meeting must not have been
      # terminalized on the way (this fixture's driver reports "provisioning").
      refute get_in(persisted, ["state", "status"]) in ~w(done failed cancelled)
    end

    test "a live answer converges it without a dispatch and without spending budget",
         %{group: group, tenant_id: tenant_id, group_id: group_id} do
      meeting_id = seed_stale_dispatched(group, tenant_id, group_id, "stale-live")
      Application.put_env(:salix_meet, :stale_dispatch_test_answer, {:ok, :live})

      assert [%{mid: ^meeting_id} = result] = CalendarAutojoin.join_sweep([group], now: @now)
      refute result.action == :error

      assert RuntimeDriver.calls() == []
      assert {:ok, persisted, _etag} = Store.get(meeting_id)
      dispatch = get_in(persisted, ["state", "join_dispatch"])
      assert dispatch["status"] == "dispatched"
      assert dispatch["recovered"] == "live_session"
      assert dispatch["attempt_count"] == 1
    end

    test "an unavailable answer fails the round closed and reports it, not `already`",
         %{group: group, tenant_id: tenant_id, group_id: group_id} do
      meeting_id = seed_stale_dispatched(group, tenant_id, group_id, "stale-unavailable")

      assert [%{action: :skipped, reason: :join_liveness_unavailable, mid: ^meeting_id}] =
               CalendarAutojoin.join_sweep([group], now: @now)

      assert RuntimeDriver.calls() == []
    end
  end

  test "an already-dispatched pre-root meeting does not create a Slack root during recovery",
       %{group: group, tenant_id: tenant_id, group_id: group_id} do
    event = event("dispatched-before-root", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(group, event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)

    state =
      group
      |> durable_calendar_state(meeting_agent, event, meeting_id)
      |> put_in(["slack_ref", "thread_ts"], "")
      |> Map.put("join_dispatch", %{
        "status" => "dispatched",
        "generation" => "legacy-generation",
        "claimed_by" => "legacy-node",
        "claimed_at" => @now,
        "completed_at" => @now,
        "last_error" => nil
      })

    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    assert [%{action: :already, mid: ^meeting_id}] =
             CalendarAutojoin.join_sweep([group], now: @now)

    assert RuntimeDriver.calls() == []
    assert {:ok, persisted, _etag} = Store.get(meeting_id)
    assert get_in(persisted, ["state", "slack_ref", "thread_ts"]) == ""
  end

  test "group-bounded backfill advances past a pre-patch thread-owner conflict",
       %{group: group, tenant_id: tenant_id, group_id: group_id} do
    event = event("backfill-thread-owner-conflict", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(group, event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)

    state =
      group
      |> durable_calendar_state(meeting_agent, event, meeting_id)
      |> Map.put("join_dispatch", %{
        "status" => "dispatched",
        "generation" => "legacy-generation",
        "claimed_by" => "legacy-node",
        "claimed_at" => @now,
        "completed_at" => @now,
        "last_error" => nil
      })

    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    assert {:ok, _owner} =
             SlackThreadIndex.claim(
               state,
               "C-runtime-test",
               "111.222",
               "mtg-pre-patch-owner"
             )

    assert [] = CalendarAutojoin.join_sweep([group], now: @now, group_bounded: true)

    assert %{"fresh" => [], "recovery" => []} = persisted_projection(group_id)
    assert [] = CalendarAutojoin.join_sweep([group], now: @now, group_bounded: true)
    assert RuntimeDriver.calls() == []
  end

  test "an incomplete meeting remains indexed and resumes after the normal join window", %{
    group: group,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    event = event("resume-after-window", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    assert [%{mid: meeting_id}] = CalendarAutojoin.join_sweep([group], now: @now, dry_run: true)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)

    state = durable_calendar_state(group, meeting_agent, event, meeting_id)
    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    recovery_now = event["start_ms"] + 300_001
    set_events([])

    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: recovery_now)

    assert %{
             "fresh" => [],
             "recovery" => [
               %{"event" => %{"event_id" => "resume-after-window"}}
             ]
           } = persisted_projection(group_id)

    assert [%{action: :joined, mid: ^meeting_id}] =
             CalendarAutojoin.join_sweep([group], now: recovery_now)

    assert [%{"id" => ^meeting_id}] = RuntimeDriver.calls()
  end

  test "an incomplete meeting is explicitly abandoned after the recovery deadline", %{
    group: group,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    event = event("recovery-deadline", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(group, event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)
    state = durable_calendar_state(group, meeting_agent, event, meeting_id)
    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    set_events([])
    expired_now = @now + 15 * 60 * 1_000 + 1
    assert [{^group_id, 0}] = CalendarAutojoin.scan_once([group], now: expired_now)

    assert %{"fresh" => [], "recovery" => []} = persisted_projection(group_id)
    assert {:ok, abandoned, _etag} = Store.get(meeting_id)
    assert abandoned["state"]["calendar_root"]["status"] == "abandoned"
    assert abandoned["state"]["calendar_autojoin_abandoned_at"] == expired_now
    assert RuntimeDriver.calls() == []
  end

  test "a transient recovery revalidation failure preserves recovery and dispatches fresh work",
       %{
         group: group,
         tenant_id: tenant_id,
         group_id: group_id
       } do
    event = event("transient-revalidation", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(group, event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)
    state = durable_calendar_state(group, meeting_agent, event, meeting_id)
    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    fresh_event = event("fresh-during-revalidation-timeout", @now + 60_000)
    fresh_mid = CalendarAutojoin.meeting_id(group, fresh_event)
    set_events([fresh_event])

    Application.put_env(
      :salix_meet,
      :calendar_autojoin_runtime_test_revalidation,
      fn revalidated_event ->
        if revalidated_event["event_id"] == event["event_id"],
          do: {:error, :timeout},
          else: :ok
      end
    )

    assert [{^group_id, {:partial, 2, partial_errors}}] =
             CalendarAutojoin.scan_once([group], now: @now + 60_000)

    assert [%{meeting_id: ^meeting_id, reason: partial_reason}] = partial_errors
    assert partial_reason == {:calendar_revalidation, meeting_id, :timeout}

    assert %{
             "fresh" => [
               %{"meeting_id" => ^fresh_mid, "event" => %{"event_id" => fresh_event_id}}
             ],
             "recovery" => [
               %{
                 "meeting_id" => ^meeting_id,
                 "event" => %{"event_id" => recovery_event_id},
                 "last_error" => last_error
               }
             ]
           } = persisted_projection(group_id)

    assert fresh_event_id == fresh_event["event_id"]
    assert recovery_event_id == event["event_id"]
    assert last_error

    assert {:ok, persisted, _etag} = Store.get(meeting_id)
    refute persisted["state"]["calendar_autojoin_abandoned_at"]

    assert [%{action: :joined, mid: ^fresh_mid}] =
             CalendarAutojoin.join_sweep([group], now: @now + 60_000)

    assert [%{"id" => ^fresh_mid}] = RuntimeDriver.calls()

    assert [
             %{
               action: :error,
               mid: ^meeting_id,
               reason: {:calendar_revalidation, :timeout}
             }
           ] =
             CalendarAutojoin.join_sweep([group],
               now: @now + 60_000,
               group_bounded: true
             )

    assert %{"recovery" => [%{"meeting_id" => ^meeting_id}]} = persisted_projection(group_id)
    assert [%{"id" => ^fresh_mid}] = RuntimeDriver.calls()
  end

  test "a changed event remains recoverable without dispatch until the deadline", %{
    group: group,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    event = event("changed-recovery", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(group, event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)
    state = durable_calendar_state(group, meeting_agent, event, meeting_id)
    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    set_events([])

    Application.put_env(
      :salix_meet,
      :calendar_autojoin_runtime_test_revalidation,
      {:error, :calendar_event_changed}
    )

    recovery_now = event["start_ms"] + 300_001

    assert [{^group_id, {:partial, 1, [partial_error]}}] =
             CalendarAutojoin.scan_once([group], now: recovery_now)

    assert partial_error == %{
             meeting_id: meeting_id,
             reason: {:calendar_revalidation, meeting_id, :calendar_event_changed}
           }

    assert %{
             "fresh" => [],
             "recovery" => [
               %{
                 "meeting_id" => ^meeting_id,
                 "event" => %{"event_id" => "changed-recovery"},
                 "last_error" => last_error
               }
             ]
           } = persisted_projection(group_id)

    assert last_error =~ "calendar_event_changed"
    assert {:ok, retained, _etag} = Store.get(meeting_id)
    refute retained["state"]["calendar_autojoin_abandoned_at"]

    assert [%{action: :skipped, mid: ^meeting_id, reason: :calendar_event_changed}] =
             CalendarAutojoin.join_sweep([group], now: recovery_now)

    assert %{"recovery" => [%{"meeting_id" => ^meeting_id}]} = persisted_projection(group_id)
    assert RuntimeDriver.calls() == []

    expired_now = @now + 15 * 60 * 1_000 + 1
    assert [{^group_id, 0}] = CalendarAutojoin.scan_once([group], now: expired_now)
    assert %{"fresh" => [], "recovery" => []} = persisted_projection(group_id)

    assert {:ok, abandoned, _etag} = Store.get(meeting_id)
    assert abandoned["state"]["calendar_autojoin_abandoned_at"] == expired_now
  end

  test "a cancelled exact event is terminally abandoned and removed from recovery", %{
    group: group,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    event = event("cancelled-revalidation", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(group, event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)
    state = durable_calendar_state(group, meeting_agent, event, meeting_id)
    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    set_events([])

    Application.put_env(
      :salix_meet,
      :calendar_autojoin_runtime_test_revalidation,
      {:error, :calendar_event_cancelled}
    )

    scan_now = @now + 60_000
    assert [{^group_id, 0}] = CalendarAutojoin.scan_once([group], now: scan_now)
    assert %{"fresh" => [], "recovery" => []} = persisted_projection(group_id)

    assert {:ok, persisted, _etag} = Store.get(meeting_id)
    assert persisted["state"]["calendar_autojoin_abandoned_at"] == scan_now
    assert persisted["state"]["calendar_root"]["status"] == "abandoned"
    assert persisted["state"]["calendar_root"]["last_error"] =~ "calendar_event_cancelled"

    Application.put_env(:salix_meet, :calendar_autojoin_runtime_test_revalidation, :ok)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: scan_now + 1)

    assert [%{action: :skipped, mid: ^meeting_id, reason: :calendar_autojoin_abandoned}] =
             CalendarAutojoin.join_sweep([group], now: scan_now + 1)

    assert RuntimeDriver.calls() == []
  end

  test "an existing document with a different OccurrenceRef is never dispatched", %{
    group: group,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    event = event("durable-event-mismatch", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(group, event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)

    state =
      group
      |> durable_calendar_state(meeting_agent, event, meeting_id)
      |> put_in(["source", "occurrence_ref", "recurrence_key", "value"], "other-slot")

    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    assert [%{action: :error, mid: ^meeting_id, reason: :meeting_event_scope_mismatch}] =
             CalendarAutojoin.join_sweep([group], now: @now)

    assert RuntimeDriver.calls() == []
  end

  test "a reschedule retains occurrence identity and refreshes mutable runtime state", %{
    group: group,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    old_event = event("start-change", @now + 30_000)
    set_events([old_event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    old_mid = CalendarAutojoin.meeting_id(group, old_event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)
    old_state = durable_calendar_state(group, meeting_agent, old_event, old_mid)
    assert {:ok, _created, _etag} = Store.create_once(old_mid, state: old_state, now: @now)

    new_event = Map.update!(old_event, "start_ms", &(&1 + 1_000))
    new_mid = CalendarAutojoin.meeting_id(group, new_event)
    assert new_mid == old_mid
    set_events([new_event])

    Application.put_env(
      :salix_meet,
      :calendar_autojoin_runtime_test_revalidation,
      fn candidate ->
        if candidate["start_ms"] == new_event["start_ms"],
          do: :ok,
          else: {:error, :calendar_event_changed}
      end
    )

    scan_now = @now + 1

    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: scan_now)

    assert %{
             "fresh" => [%{"event" => %{"start_ms" => new_start}}],
             "recovery" => []
           } = persisted_projection(group_id)

    assert new_start == new_event["start_ms"]
    assert {:ok, retained, _etag} = Store.get(old_mid)
    refute retained["state"]["calendar_autojoin_abandoned_at"]

    assert [%{action: :joined, mid: ^old_mid}] =
             CalendarAutojoin.join_sweep([group], now: scan_now)

    assert [%{"id" => ^old_mid, "state" => runtime_state}] = RuntimeDriver.calls()
    assert runtime_state["start_at"] == div(new_event["start_ms"], 1_000)
    assert %{"recovery" => []} = persisted_projection(group_id)
  end

  test "a duration change after scan defers the stale candidate and refreshes the same identity",
       %{
         group: group,
         tenant_id: tenant_id,
         group_id: group_id
       } do
    indexed_event = event("duration-change", @now + 30_000)
    set_events([indexed_event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(group, indexed_event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)
    state = durable_calendar_state(group, meeting_agent, indexed_event, meeting_id)
    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    changed_event = Map.update!(indexed_event, "end_ms", &(&1 + 900_000))
    assert CalendarAutojoin.meeting_id(group, changed_event) == meeting_id

    Application.put_env(
      :salix_meet,
      :calendar_autojoin_runtime_test_revalidation,
      fn candidate ->
        if candidate["end_ms"] == changed_event["end_ms"],
          do: :ok,
          else: {:error, :calendar_event_changed}
      end
    )

    assert [%{action: :skipped, mid: ^meeting_id, reason: :calendar_event_changed}] =
             CalendarAutojoin.join_sweep([group], now: @now)

    assert {:ok, deferred, _etag} = Store.get(meeting_id)
    refute deferred["state"]["calendar_autojoin_abandoned_at"]
    refute get_in(deferred, ["state", "calendar_root", "status"]) == "abandoned"
    assert RuntimeDriver.calls() == []

    set_events([changed_event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now + 1)

    assert [%{action: :joined, mid: ^meeting_id}] =
             CalendarAutojoin.join_sweep([group], now: @now + 1)

    assert [%{"state" => runtime_state}] = RuntimeDriver.calls()
    assert runtime_state["end_at"] == div(changed_event["end_ms"], 1_000)
    assert runtime_state["source"]["event_id"] == changed_event["event_id"]
  end

  test "a provider locator move stays behind the local occurrence identity", %{
    group: group,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    source_group =
      Map.put(group, "calendars", [
        %{"account_id" => "ca-source-a", "calendar_id" => "source-a@example.com"},
        %{"account_id" => "ca-source-b", "calendar_id" => "source-b@example.com"}
      ])

    indexed_event = event("source-a-event", @now + 30_000)

    set_events([indexed_event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([source_group], now: @now)

    meeting_id = CalendarAutojoin.meeting_id(source_group, indexed_event)
    assert {:ok, meeting_agent} = Runtime.start_for_group(tenant_id, group_id, now: @now)

    state = durable_calendar_state(source_group, meeting_agent, indexed_event, meeting_id)

    assert {:ok, _created, _etag} = Store.create_once(meeting_id, state: state, now: @now)

    moved_event =
      indexed_event
      |> Map.put("event_id", "source-b-event")

    assert CalendarAutojoin.meeting_id(source_group, moved_event) == meeting_id

    Application.put_env(
      :salix_meet,
      :calendar_autojoin_runtime_test_revalidation,
      fn candidate ->
        if candidate["event_id"] == moved_event["event_id"],
          do: :ok,
          else: {:error, :calendar_event_not_found}
      end
    )

    assert [%{action: :skipped, mid: ^meeting_id, reason: :calendar_event_not_found}] =
             CalendarAutojoin.join_sweep([source_group], now: @now)

    assert {:ok, deferred, _etag} = Store.get(meeting_id)
    refute deferred["state"]["calendar_autojoin_abandoned_at"]
    refute get_in(deferred, ["state", "calendar_root", "status"]) == "abandoned"
    assert RuntimeDriver.calls() == []

    set_events([moved_event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([source_group], now: @now + 1)

    assert [%{action: :joined, mid: ^meeting_id}] =
             CalendarAutojoin.join_sweep([source_group], now: @now + 1)

    assert [%{"state" => runtime_state}] = RuntimeDriver.calls()
    assert runtime_state["source"]["event_id"] == moved_event["event_id"]
    assert runtime_state["source"]["calendar_id"] == moved_event["calendar_id"]
    refute Map.has_key?(runtime_state["source"], "calendar_connected_account_id")
  end

  test "a deferred queue-head candidate is rotated past and the next pass dispatches",
       %{group: group, group_id: group_id} do
    blocked = event("deferred-head", @now + 30_000)
    healthy = event("healthy-second", @now + 60_000)
    set_events([blocked, healthy])
    assert [{^group_id, 2}] = CalendarAutojoin.scan_once([group], now: @now)

    Application.put_env(
      :salix_meet,
      :calendar_autojoin_runtime_test_revalidation,
      fn revalidated ->
        if revalidated["event_id"] == "deferred-head",
          do: {:error, :timeout},
          else: :ok
      end
    )

    # One real candidate step per pass: the stuck head is recorded and
    # rotated, and the pass ends with its cursor checkpointed.
    first = CalendarAutojoin.join_sweep([group], now: @now, group_bounded: true)
    assert Enum.any?(first, &match?(%{reason: {:calendar_revalidation, :timeout}}, &1))
    refute Enum.any?(first, &match?(%{action: :joined}, &1))
    assert [] = RuntimeDriver.calls()

    # The next pass starts at the rotated head with a full budget and
    # dispatches the healthy meeting instead of starving behind the stuck
    # one.
    second = CalendarAutojoin.join_sweep([group], now: @now, group_bounded: true)
    assert Enum.any?(second, &match?(%{action: :joined}, &1))
    assert [joined_doc] = RuntimeDriver.calls()
    assert joined_doc["state"]["title"] == "Calendar healthy-second"
  end

  test "a slow deferred head under a small task budget cannot kill the pass",
       %{group: group, group_id: group_id} do
    blocked = event("slow-head", @now + 30_000)
    healthy = event("healthy-after-slow", @now + 60_000)
    set_events([blocked, healthy])
    assert [{^group_id, 2}] = CalendarAutojoin.scan_once([group], now: @now)

    # The review repro: with a shared-deadline reserve the pass still tried
    # revalidation + join for the next candidate and overran a small budget.
    # With one real step per pass, the pass's time envelope IS the single
    # step: the slow head alone, well inside the budget — no task_exit, no
    # discarded checkpoint, no stranded in-doubt join.
    Application.put_env(
      :salix_meet,
      :calendar_autojoin_runtime_test_revalidation,
      fn revalidated ->
        if revalidated["event_id"] == "slow-head" do
          Process.sleep(300)
          {:error, :timeout}
        else
          :ok
        end
      end
    )

    results =
      CalendarAutojoin.join_sweep([group],
        now: @now,
        task_timeout_ms: 1_000,
        group_bounded: true
      )

    refute Enum.any?(results, &match?(%{action: :error, reason: {:task_exit, _}}, &1))
    assert Enum.any?(results, &match?(%{reason: {:calendar_revalidation, :timeout}}, &1))
    refute Enum.any?(results, &match?(%{action: :joined}, &1))
    assert [] = RuntimeDriver.calls()

    assert {:ok, persisted} = read_json(SalixStore.Keys.ctl_meet_calendar_projection(group_id))
    assert is_binary(persisted["cursor"]) and persisted["cursor"] != ""

    next =
      CalendarAutojoin.join_sweep([group],
        now: @now,
        task_timeout_ms: 1_000,
        group_bounded: true
      )

    assert Enum.any?(next, &match?(%{action: :joined}, &1))
    assert [joined_doc] = RuntimeDriver.calls()
    assert joined_doc["state"]["title"] == "Calendar healthy-after-slow"
  end

  test "an all-deferred pass still checkpoints the rotated cursor",
       %{group: group, group_id: group_id} do
    first = event("deferred-a", @now + 30_000)
    second = event("deferred-b", @now + 60_000)
    set_events([first, second])
    assert [{^group_id, 2}] = CalendarAutojoin.scan_once([group], now: @now)

    parent = self()

    Application.put_env(
      :salix_meet,
      :calendar_autojoin_runtime_test_revalidation,
      fn revalidated ->
        send(parent, {:revalidated, revalidated["event_id"]})
        {:error, :timeout}
      end
    )

    assert [] = RuntimeDriver.calls()
    _ = CalendarAutojoin.join_sweep([group], now: @now, group_bounded: true)
    first_pass = collect_revalidations([])

    _ = CalendarAutojoin.join_sweep([group], now: @now, group_bounded: true)
    second_pass = collect_revalidations([])

    # One real step per pass, and the durable cursor rotation is directly
    # observable: the second pass examines the OTHER candidate (the pre-fix
    # pass discarded its projection intent here, freezing the cursor
    # forever).
    assert [first_examined] = first_pass
    assert [second_examined] = second_pass
    assert first_examined != second_examined
    assert Enum.sort([first_examined, second_examined]) == ["deferred-a", "deferred-b"]
    assert [] = RuntimeDriver.calls()

    assert {:ok, persisted} = read_json(SalixStore.Keys.ctl_meet_calendar_projection(group_id))
    assert is_binary(persisted["cursor"]) and persisted["cursor"] != ""
  end

  defp collect_revalidations(acc) do
    receive do
      {:revalidated, id} -> collect_revalidations(acc ++ [id])
    after
      100 -> acc
    end
  end

  test "a runtime error stays reclaimable; the retry fails closed without a liveness authority",
       %{
         group: group,
         group_id: group_id
       } do
    event = event("driver-failure", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)
    RuntimeDriver.return([{:error, :dispatch_failed}])

    assert [%{action: :error, reason: {:join_failed, ":dispatch_failed"}, mid: meeting_id}] =
             CalendarAutojoin.join_sweep([group], now: @now)

    assert [%{"id" => ^meeting_id}] = RuntimeDriver.calls()
    assert {:ok, failed, _etag} = Store.get(meeting_id)
    assert is_integer(failed["join_requested_at"])
    # In-budget failure no longer converges the meeting terminally.
    assert failed["state"]["status"] == "joining"

    # The retry round needs a definite live-session answer; without one the
    # round fails closed, consumes no budget, and makes no second driver call.
    assert [%{action: :skipped, reason: :join_liveness_unavailable, mid: ^meeting_id}] =
             CalendarAutojoin.join_sweep([group], now: @now)

    assert [_single_dispatch] = RuntimeDriver.calls()
    assert {:ok, still_failed, _etag} = Store.get(meeting_id)
    assert still_failed["state"]["join_dispatch"]["attempt_count"] == 1
  end

  test "the bounded join pass logs and meters an in-window meeting stuck on a failed dispatch",
       %{group: group, group_id: group_id} do
    event = event("driver-failure-observed", @now + 30_000)
    set_events([event])
    assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: @now)
    RuntimeDriver.return([{:error, :dispatch_failed}])

    assert [%{action: :error, reason: {:join_failed, ":dispatch_failed"}, mid: meeting_id}] =
             CalendarAutojoin.join_sweep([group], now: @now)

    # Exhaust the retry budget: with no attempts left the record is a
    # permanent, surfaced loss again (this is the state the skip metric
    # watches now that in-budget failures retry).
    {:ok, _doc, _etag} =
      Store.update_state_retrying(meeting_id, fn state ->
        Map.update!(state, "join_dispatch", fn dispatch ->
          Map.put(dispatch, "attempt_count", SalixMeet.Store.join_max_attempts())
        end)
      end)

    handler_id = "join-skip-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :operation, :stop],
        fn _event, _measurements, metadata, _config -> send(parent, {:operation, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [] = CalendarAutojoin.join_sweep([group], now: @now, group_bounded: true)
      end)

    assert log =~ "join budget exhausted"

    assert_receive {:operation,
                    %{
                      component: "salix_meet",
                      operation: "calendar_join_dispatch_skip",
                      outcome: "failed"
                    }}

    assert [_single_dispatch] = RuntimeDriver.calls()
  end

  test "meeting ids are SHA-256 digests over tenant, group and OccurrenceRef",
       %{group: group, tenant_id: tenant_id} do
    event = event("shared-event", @now + 30_000)
    set_events([event])

    second_group = Map.put(group, "group_id", Ids.new_group_id(tenant_id))
    other_tenant = Ids.new_tenant_id()

    third_group =
      group
      |> Map.put("tenant_id", other_tenant)
      |> Map.put("group_id", Ids.new_group_id(other_tenant))

    assert [_first, _second, _third] =
             CalendarAutojoin.scan_once([group, second_group, third_group])

    distinct = [dry_run_mid(group), dry_run_mid(second_group), dry_run_mid(third_group)]
    assert Enum.all?(distinct, &Regex.match?(~r/^mtg-cal-[0-9a-f]{64}$/, &1))
    assert length(Enum.uniq(distinct)) == 3

    other_calendar =
      group
      |> Map.put("calendar_id", "calendar-secondary@example.com")
      |> Map.put("calendar_connected_account_id", "ca-secondary")

    assert CalendarAutojoin.meeting_id(other_calendar, event) == dry_run_mid(group)

    later_start = Map.update!(event, "start_ms", &(&1 + 1_000))
    assert CalendarAutojoin.meeting_id(group, later_start) == dry_run_mid(group)
  end

  test "known phash2-colliding event instances receive distinct meeting ids", %{group: group} do
    first = event("event-8458", 10_008_458)
    second = event("event-12226", 10_012_226)

    assert :erlang.phash2({first["event_id"], first["start_ms"]}) == 129_325_228
    assert :erlang.phash2({second["event_id"], second["start_ms"]}) == 129_325_228

    set_events([first, second])
    assert [_] = CalendarAutojoin.scan_once([group], now: @now)

    mids =
      CalendarAutojoin.join_sweep([group], now: @now, dry_run: true)
      |> Enum.map(& &1.mid)

    assert length(mids) == 2
    assert length(Enum.uniq(mids)) == 2
    assert Enum.all?(mids, &Regex.match?(~r/^mtg-cal-[0-9a-f]{64}$/, &1))
  end

  defp dry_run_mid(group) do
    assert [%{mid: meeting_id}] = CalendarAutojoin.join_sweep([group], now: @now, dry_run: true)
    meeting_id
  end

  defp event(id, start_ms) do
    %{
      "event_id" => id,
      "calendar_id" => "cal-runtime-test",
      "calendar_item_id" => "item-#{id}",
      "occurrence_ref" => occurrence_ref(id, start_ms),
      "meeting_plan_id" => "plan-#{id}",
      "start_ms" => start_ms,
      "end_ms" => start_ms + 1_800_000,
      "meet_url" => "https://meet.google.com/abc-defg-hij",
      "title" => "Calendar #{id}"
    }
  end

  defp occurrence_ref(id, start_ms) do
    %{
      "calendar_id" => "cal-runtime-test",
      "scheduling_link_id" => "link-#{id}",
      "recurrence_key" => %{"kind" => "recurring", "value" => "slot-#{start_ms}"}
    }
  end

  defp durable_calendar_state(group, meeting_agent, event, meeting_id) do
    %{
      "tenant_id" => group["tenant_id"],
      "group_id" => group["group_id"],
      "meeting_id" => meeting_id,
      "meeting_agent_id" => meeting_agent["meeting_agent_id"],
      "meeting_session_id" => meeting_agent["meeting_session_id"],
      "provider" => "slack",
      "connect_id" => "slack-runtime-test",
      "slack_ref" => %{"channel_id" => "C-runtime-test", "thread_ts" => "111.222"},
      "meet_url" => event["meet_url"],
      "title" => event["title"],
      "bot_name" => "Cirno",
      "caption_language" => "English",
      "status" => "provisioning",
      "runtime_token" => 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
      "runtime_ref" => meeting_agent["meeting_session_id"],
      "artifact_root" => RuntimeEvents.artifact_root(meeting_id),
      "source" => %{
        "kind" => "calendar",
        "calendar_id" => event["calendar_id"],
        "calendar_item_id" => event["calendar_item_id"],
        "occurrence_ref" => event["occurrence_ref"],
        "meeting_plan_id" => event["meeting_plan_id"],
        "event_id" => event["event_id"]
      },
      "start_at" => div(event["start_ms"], 1_000),
      "end_at" => div(event["end_ms"], 1_000),
      "captions" => [],
      "chats" => [],
      "artifacts" => %{},
      "delivery" => %{}
    }
  end

  defp set_events(events),
    do: Application.put_env(:salix_meet, :calendar_autojoin_runtime_test_events, events)

  defp put_group!(tenant_id, group_id) do
    now = System.system_time(:second)

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "name" => "Calendar Runtime Test",
      "router_conversation_id" => Ids.new_conversation_id(),
      "billing_owner" => %{
        "billing_account_id" => "ba-calendar-runtime",
        "surface" => "bridge",
        "product_owner_type" => "organization",
        "product_owner_id" => "org-calendar-runtime",
        "salix_tenant_id" => tenant_id,
        "salix_group_id" => group_id
      },
      "created_at" => now,
      "updated_at" => now
    }

    assert {:ok, _} = S3.put(Keys.ctl_group(group_id), Jason.encode!(group), if_none_match: "*")
  end

  defp persisted_projection(group_id) do
    assert {:ok, projection} = read_json(CalendarProjection.key(group_id))
    projection
  end

  defp read_json(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      other -> other
    end
  end

  defp ensure_started!(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

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

  defp stop_all_agents do
    if Process.whereis(SalixAgent.Registry) do
      SalixAgent.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
      |> Enum.uniq()
      |> Enum.each(&SalixAgent.Fleet.stop/1)
    end

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
