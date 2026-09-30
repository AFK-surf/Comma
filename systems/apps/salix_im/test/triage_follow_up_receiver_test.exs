defmodule SalixIM.Triage.FollowUpReceiverTest do
  use ExUnit.Case, async: false

  alias SalixCluster.Schedules
  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.Triage.FollowUpReceiver
  alias SalixStore.{Crypto, Ids, Repo, S3, TriageProductRuntime}

  defmodule ThreadReader do
    @behaviour SalixIM.Ports.TriageFollowUpThreadReader

    @impl true
    def read(_authority, _connect, _target) do
      {:ok, %{"messages" => Application.fetch_env!(:salix_im, :follow_up_receiver_messages)}}
    end
  end

  defmodule ResolvingThreadReader do
    @behaviour SalixIM.Ports.TriageFollowUpThreadReader

    @impl true
    def read(_authority, _connect, _target) do
      invocation = Application.fetch_env!(:salix_im, :follow_up_receiver_race_invocation)

      {:ok, :resolved} =
        SalixStore.TriageProductRuntime.settle_follow_up_wakeup(
          invocation.entry_id,
          invocation.authority_generation,
          invocation.schedule_id,
          invocation.scheduled_for_ms,
          :answered
        )

      {:ok, %{"messages" => Application.fetch_env!(:salix_im, :follow_up_receiver_messages)}}
    end
  end

  setup do
    previous_reader = Application.get_env(:salix_im, :triage_follow_up_thread_reader_mod)
    previous_messages = Application.get_env(:salix_im, :follow_up_receiver_messages)
    previous_race = Application.get_env(:salix_im, :follow_up_receiver_race_invocation)
    previous_backend = Application.get_env(:salix_store, :s3_backend)

    Application.put_env(:salix_im, :triage_follow_up_thread_reader_mod, ThreadReader)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    if Process.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    Repo.query!("TRUNCATE schedule_runs, schedules, triage_context_entries CASCADE")

    on_exit(fn ->
      restore_env(:salix_im, :triage_follow_up_thread_reader_mod, previous_reader)
      restore_env(:salix_im, :follow_up_receiver_messages, previous_messages)
      restore_env(:salix_im, :follow_up_receiver_race_invocation, previous_race)
      restore_env(:salix_store, :s3_backend, previous_backend)
    end)

    authority = SalixIM.TriageEngineFixtures.authority!()
    {:ok, authority: authority}
  end

  test "later human activity saying the issue remains open re-enters evaluation instead of resolving",
       %{
         authority: authority
       } do
    trigger_ts = "1788093000.000001"
    due_ms = 1_788_094_000_000

    %{entry_id: entry_id, schedule_id: schedule_id} =
      seed_follow_up!(authority, trigger_ts, due_ms)

    Application.put_env(:salix_im, :follow_up_receiver_messages, [
      trigger_message(trigger_ts),
      %{
        "ts" => "1788093001.000001",
        "actor_id" => "U_ANSWERING_HUMAN",
        "actor_kind" => "human",
        "text" => "我看看，公网探测仍然失败，还没修好。"
      }
    ])

    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due_ms)
    assert {:error, :not_found} = Schedules.get(schedule_id)

    assert {:ok, [%{entry_id: ^entry_id, state: :active, payload: payload}]} =
             TriageProductRuntime.list_context("project-follow-up")

    assert payload["last_wakeup_schedule_id"] == schedule_id
    assert payload["last_wakeup_scheduled_for_ms"] == due_ms
    refute Map.has_key?(payload, "resolved_reason")
    assert {:ok, _next} = Schedules.get(payload["schedule_id"])
    assert {:ok, page} = SalixIM.ProviderReceipts.list_slack_triage_page(:all, nil, 25)

    assert Enum.any?(page.receipts, fn receipt ->
             get_in(receipt, ["triage_event", "source_mode"]) == "scheduled_recheck" and
               receipt["event_id"] == payload["last_wakeup_event_id"] and
               get_in(receipt, ["triage_event", "message_ts"]) == trigger_ts
           end)
  end

  test "an unanswered occurrence re-enters the existing Runtime and arms one next Schedule", %{
    authority: authority
  } do
    trigger_ts = "1788093100.000001"
    due_ms = 1_788_095_000_000

    %{entry_id: entry_id, schedule_id: schedule_id} =
      seed_follow_up!(authority, trigger_ts, due_ms)

    Application.put_env(:salix_im, :follow_up_receiver_messages, [trigger_message(trigger_ts)])

    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due_ms)
    assert {:error, :not_found} = Schedules.get(schedule_id)

    assert {:ok, [%{entry_id: ^entry_id, state: :active, payload: payload} = follow_up]} =
             TriageProductRuntime.list_context("project-follow-up")

    next_schedule_id = payload["schedule_id"]
    refute next_schedule_id == schedule_id
    assert payload["last_wakeup_schedule_id"] == schedule_id
    assert payload["last_wakeup_scheduled_for_ms"] == due_ms

    assert {:ok, next_schedule} = Schedules.get(next_schedule_id)
    assert next_schedule["receiver"] == "triage_follow_up"

    assert Schedules.next_fire_ms(next_schedule) ==
             DateTime.to_unix(follow_up.next_check_at, :millisecond)

    assert {:ok, page} = SalixIM.ProviderReceipts.list_slack_triage_page(:all, nil, 25)

    assert Enum.any?(page.receipts, fn receipt ->
             get_in(receipt, ["triage_event", "source_mode"]) == "scheduled_recheck" and
               get_in(receipt, ["triage_event", "message_ts"]) == trigger_ts
           end)
  end

  test "an occurrence resolved after the thread read starts cannot re-enter Runtime", %{
    authority: authority
  } do
    trigger_ts = "1788093150.000001"
    due_ms = 1_788_095_500_000

    %{entry_id: entry_id, schedule_id: schedule_id} =
      seed_follow_up!(authority, trigger_ts, due_ms)

    Application.put_env(:salix_im, :triage_follow_up_thread_reader_mod, ResolvingThreadReader)
    Application.put_env(:salix_im, :follow_up_receiver_messages, [trigger_message(trigger_ts)])

    Application.put_env(:salix_im, :follow_up_receiver_race_invocation, %{
      entry_id: entry_id,
      authority_generation: authority["connect_generation"],
      schedule_id: schedule_id,
      scheduled_for_ms: due_ms
    })

    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due_ms)

    assert {:ok, [%{entry_id: ^entry_id, state: :resolved}]} =
             TriageProductRuntime.list_context("project-follow-up")

    assert {:ok, page} = SalixIM.ProviderReceipts.list_slack_triage_page(:all, nil, 25)

    refute Enum.any?(page.receipts, fn receipt ->
             get_in(receipt, ["triage_event", "source_mode"]) == "scheduled_recheck" and
               get_in(receipt, ["triage_event", "message_ts"]) == trigger_ts
           end)
  end

  test "a Task handover makes an already scheduled ambient follow-up inert", %{
    authority: authority
  } do
    trigger_ts = "1788093175.000001"
    due_ms = 1_788_095_750_000

    %{entry_id: entry_id, schedule_id: schedule_id} =
      seed_follow_up!(authority, trigger_ts, due_ms)

    Application.put_env(:salix_im, :follow_up_receiver_messages, [trigger_message(trigger_ts)])

    scope = route_scope(authority, trigger_ts)
    assert {:ok, task_identity} = ThreadRouteOwner.task_claim_identity(scope, "cnv_task_handover")
    assert {:ok, :task} = ThreadRouteOwner.claim_task(scope, task_identity)

    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due_ms)
    assert {:error, :not_found} = Schedules.get(schedule_id)

    assert {:ok, [%{entry_id: ^entry_id, state: :stopped, payload: payload}]} =
             TriageProductRuntime.list_context("project-follow-up")

    assert payload["resolved_reason"] == "source_authority_stale"

    assert {:ok, page} = SalixIM.ProviderReceipts.list_slack_triage_page(:all, nil, 25)

    refute Enum.any?(page.receipts, fn receipt ->
             get_in(receipt, ["triage_event", "source_mode"]) == "scheduled_recheck" and
               get_in(receipt, ["triage_event", "message_ts"]) == trigger_ts
           end)
  end

  test "a stale authority closes the context without inventing a superseding entry", %{
    authority: authority
  } do
    trigger_ts = "1788093200.000001"
    due_ms = 1_788_096_000_000

    %{entry_id: entry_id, schedule_id: schedule_id} =
      seed_follow_up!(authority, trigger_ts, due_ms, authority_generation: "stale-generation")

    Application.put_env(:salix_im, :follow_up_receiver_messages, [trigger_message(trigger_ts)])

    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due_ms)

    assert {:ok, [%{entry_id: ^entry_id, state: :stopped, payload: payload}]} =
             TriageProductRuntime.list_context("project-follow-up")

    assert payload["resolved_reason"] == "source_authority_stale"
    assert {:error, :not_found} = Schedules.get(schedule_id)
  end

  test "receiver rejects malformed shared-Schedule invocations" do
    assert FollowUpReceiver.receive(%{}, :claimed, []) ==
             {:error, :invalid_triage_follow_up_invocation}
  end

  defp seed_follow_up!(authority, trigger_ts, due_ms, opts \\ []) do
    entry_id = "triage-follow-up-#{System.unique_integer([:positive])}"
    schedule_id = Ids.new_schedule_id()

    authority_generation =
      Keyword.get(opts, :authority_generation, authority["connect_generation"])

    target = %{
      "connect_id" => authority["connect_id"],
      "connect_generation" => authority_generation,
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "thread_ts" => trigger_ts
    }

    payload = %{
      "schema" => "comma.triage-context-entry.v1",
      "entry_id" => entry_id,
      "kind" => "follow_up",
      "schedule_id" => schedule_id,
      "authority_generation" => authority_generation,
      "target" => target,
      "product_identity" => %{"project_salix_group_id" => authority["group_id"]},
      "trigger_message_ts" => trigger_ts,
      "recheck_after_hours" => 12
    }

    key = Crypto.hex(entry_id)

    Repo.query!(
      """
      INSERT INTO triage_context_entries
        (entry_id, project_id, agent_id, kind, subject_key, value_key, evidence_key,
         state, payload, next_check_at)
      VALUES ($1, 'project-follow-up', $2, 'follow_up', $3, $3, $3,
              'active', $4, to_timestamp($5::double precision / 1000.0))
      """,
      [entry_id, authority["inbound_agent_id"], key, payload, due_ms]
    )

    assert {:ok, _schedule} =
             Schedules.create(
               schedule_id,
               %{
                 receiver: "triage_follow_up",
                 payload: %{
                   entry_id: entry_id,
                   authority_generation: authority_generation
                 },
                 run_at: due_ms
               },
               now: due_ms - 1
             )

    if authority_generation == authority["connect_generation"] do
      assert {:ok, :triage} =
               ThreadRouteOwner.claim_triage(
                 route_scope(authority, trigger_ts),
                 Crypto.hex(["follow-up-test", trigger_ts])
               )
    end

    %{entry_id: entry_id, schedule_id: schedule_id}
  end

  defp route_scope(authority, thread_ts) do
    %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "connect_generation" => authority["connect_generation"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => thread_ts
    }
  end

  defp trigger_message(ts) do
    %{
      "ts" => ts,
      "actor_id" => "U_ORIGINAL_HUMAN",
      "actor_kind" => "human",
      "text" => "Deployment ownership remains unresolved."
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
