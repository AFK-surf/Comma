defmodule SalixIM.Triage.ClickHousePatrolTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SalixIM.{ProviderConnects, ProviderReceipts}
  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.Triage.{Bucketing, ClickHousePatrol, ClickHousePatrolWorker}

  alias SalixStore.{
    CasRecord,
    Ids,
    Keys,
    Repo,
    S3,
    SlackTriageChannels,
    TriagePatrolScanState,
    ULID
  }

  defmodule Reader do
    @moduledoc false

    def tail(scope) do
      row = row(scope)
      {:ok, Map.take(row, ~w(ingest_at message_ts_us version))}
    end

    def list_changes(scope, window, 25) do
      row = row(scope)

      {:ok,
       %{
         rows: [row],
         next_cursor: %{
           "ingest_at" => row["ingest_at"],
           "message_ts_us" => row["message_ts_us"],
           "version" => row["version"]
         },
         has_more?: false,
         input_window: window
       }}
    end

    def latest_states(scope, [message_ts_us]) do
      row = row(scope)
      ^message_ts_us = row["message_ts_us"]
      {:ok, %{message_ts_us => row}}
    end

    defp row(scope) do
      %{
        "tenant_id" => scope["tenant_id"],
        "workspace_id" => scope["workspace_id"],
        "channel_id" => scope["channel_id"],
        "message_ts_us" => 1_787_019_001_000_001,
        "message_ts" => "1787019001.000001",
        "thread_ts" => "",
        "version" => 3_574_038_002_000_002,
        "deleted" => false,
        "actor_kind" => "user",
        "actor_id" => "U_HUMAN",
        "subtype" => "",
        "text" => "please review this update",
        "ingest_at" => "2026-09-01T00:00:01.123Z"
      }
    end
  end

  defmodule WorkerProbe do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def put(state), do: Agent.update(__MODULE__, fn _ -> state end)
    def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
    def record(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
  end

  defmodule QuietReader do
    def tail(_scope),
      do:
        {:ok,
         %{
           "ingest_at" => "2026-09-01T00:00:00.000Z",
           "message_ts_us" => 1_787_019_000_000_000,
           "version" => 3_574_038_000_000_000
         }}

    def list_changes(_scope, _window, 25),
      do: {:ok, %{rows: [], next_cursor: nil, has_more?: false}}

    def latest_states(_scope, []), do: {:ok, %{}}
  end

  defmodule BackfillReader do
    def tail(scope), do: Reader.tail(scope)

    def list_changes(scope, window, 25) do
      {:ok, page} = Reader.list_changes(scope, window, 25)
      {:ok, %{page | rows: Enum.map(page.rows, &Map.put(&1, "ingest_source", "backfill"))}}
    end

    def latest_states(scope, keys) do
      {:ok, states} = Reader.latest_states(scope, keys)

      {:ok,
       Map.new(states, fn {key, row} -> {key, Map.put(row, "ingest_source", "backfill")} end)}
    end
  end

  defmodule AgentReader do
    def tail(scope), do: Reader.tail(scope)

    def list_changes(scope, window, 25) do
      {:ok, page} = Reader.list_changes(scope, window, 25)
      {:ok, %{page | rows: Enum.map(page.rows, &agent_row/1)}}
    end

    def latest_states(scope, keys) do
      {:ok, states} = Reader.latest_states(scope, keys)
      {:ok, Map.new(states, fn {key, row} -> {key, agent_row(row)} end)}
    end

    defp agent_row(row) do
      row
      |> Map.put("actor_kind", "bot")
      |> Map.put("actor_id", "B_PEER")
      |> Map.put("subtype", "bot_message")
      |> Map.put("text", "<@U_BFT> please take a look")
    end
  end

  defmodule PeerMentionReader do
    def tail(scope), do: Reader.tail(scope)

    def list_changes(scope, window, 25) do
      {:ok, page} = Reader.list_changes(scope, window, 25)
      {:ok, %{page | rows: Enum.map(page.rows, &peer_mention_row/1)}}
    end

    def latest_states(scope, keys) do
      {:ok, states} = Reader.latest_states(scope, keys)
      {:ok, Map.new(states, fn {key, row} -> {key, peer_mention_row(row)} end)}
    end

    defp peer_mention_row(row), do: Map.put(row, "text", "please ask <@UPEER123> to review")
  end

  defmodule AlertReader do
    def tail(scope), do: Reader.tail(scope)
    def list_changes(scope, window, limit), do: Reader.list_changes(scope, window, limit)

    def latest_states(scope, keys) do
      {:ok, states} = AgentReader.latest_states(scope, keys)

      {:ok,
       Map.new(states, fn {key, row} ->
         {key,
          Map.put(
            row,
            "text",
            "Deployment failed: service unavailable; investigate the linked run."
          )}
       end)}
    end
  end

  defmodule OwnAlertReader do
    def tail(scope), do: AlertReader.tail(scope)
    def list_changes(scope, window, limit), do: AlertReader.list_changes(scope, window, limit)

    def latest_states(scope, keys) do
      {:ok, states} = AlertReader.latest_states(scope, keys)
      {:ok, Map.new(states, fn {key, row} -> {key, Map.put(row, "actor_id", "B_BFT")} end)}
    end
  end

  defmodule AlertReplyReader do
    def tail(scope), do: AlertReader.tail(scope)
    def list_changes(scope, window, limit), do: AlertReader.list_changes(scope, window, limit)

    def latest_states(scope, keys) do
      {:ok, states} = AlertReader.latest_states(scope, keys)

      {:ok,
       Map.new(states, fn {key, row} -> {key, Map.put(row, "thread_ts", "1787019000.000001")} end)}
    end
  end

  defmodule TaskBindingPort do
    def get_thread_binding(_group_id, _connect_id, _channel_id, _thread_ts),
      do: {:ok, %{"version" => 3, "binding_type" => "task", "binding_status" => "active"}}

    def task_thread_binding_record?(binding),
      do: binding["version"] == 3 and binding["binding_type"] == "task"
  end

  defmodule WorkerReader do
    def tail(_scope), do: {:ok, WorkerProbe.get(:tail)}

    def list_changes(_scope, _cursor, _limit),
      do: {:ok, %{rows: [], next_cursor: %{}, has_more?: false}}

    def latest_states(_scope, _keys), do: {:ok, %{}}
  end

  defmodule WorkerChannelStore do
    def list_enabled_page(nil, 5) do
      {:ok,
       %{
         channels: [WorkerProbe.get(:channel)],
         scan_complete: true,
         next_cursor: nil
       }}
    end
  end

  defmodule WorkerCursorStore do
    def get(_tenant_id, _group_id, _connect_id, _channel_id), do: {:error, :not_found}

    def ensure(channel, authority, tail) do
      WorkerProbe.record(:ensure, {channel, authority, tail})
      {:ok, %{"scan_state" => tail}}
    end

    def claim_due("worker-test", limit: 1, lease_ms: 60_000),
      do: {:ok, [WorkerProbe.get(:claim)]}

    def settle(claim, result, opts) do
      WorkerProbe.record(:settle, {claim, result, opts})
      {:ok, %{status: :settled, revision: claim.revision + 1}}
    end

    def fail(claim, reason, backoff_ms) do
      WorkerProbe.record(:fail, {claim, reason, backoff_ms})
      {:ok, %{status: :failed, revision: claim.revision + 1}}
    end

    def deactivate(_claim), do: {:error, :unexpected_deactivate}
  end

  defmodule WorkerProviderConnects do
    def get_slack_triage_authority(_tenant_id, _group_id, _connect_id, _channel_id),
      do: {:ok, WorkerProbe.get(:authority)}

    def verify_slack_triage_authority(authority) do
      if authority == WorkerProbe.get(:authority), do: :ok, else: {:error, :stale}
    end
  end

  defmodule UnavailableWorkerProviderConnects do
    def get_slack_triage_authority(_tenant_id, _group_id, _connect_id, _channel_id),
      do: {:error, :slack_triage_authority_unavailable}

    def verify_slack_triage_authority(_authority),
      do: {:error, :slack_triage_authority_unavailable}
  end

  defmodule WorkerPatrol do
    def scan(authority, scan_state, opts) do
      :ok = opts[:authority_verifier].(authority)
      WorkerProbe.record(:scan, {authority, scan_state, opts})

      {:ok,
       %{
         created: 1,
         duplicate: 0,
         ineligible: 0,
         settled: 1,
         next_scan_state: WorkerProbe.get(:next_scan_state),
         has_more?: false
       }}
    end
  end

  defmodule TransitionReader do
    def tail(_scope), do: WorkerProbe.get(:tail_result)
    def list_changes(_scope, _cursor, _limit), do: {:error, :unexpected_read}
    def latest_states(_scope, _keys), do: {:error, :unexpected_read}
  end

  defmodule TransitionCursorStore do
    def get(_tenant_id, _group_id, _connect_id, _channel_id), do: {:error, :not_found}
    def ensure(_channel, _authority, _tail), do: {:ok, %{}}
    def claim_due(_holder, _opts), do: {:ok, []}
    def settle(_claim, _result, _opts), do: {:error, :unexpected_settle}
    def fail(_claim, _reason, _backoff_ms), do: {:error, :unexpected_fail}
    def deactivate(_claim), do: {:error, :unexpected_deactivate}
  end

  defmodule PagedTransitionChannelStore do
    def list_enabled_page(nil, 1) do
      {:ok,
       %{
         channels: [WorkerProbe.get(:first_channel)],
         scan_complete: false,
         next_cursor: "second-page"
       }}
    end

    def list_enabled_page("second-page", 1) do
      {:ok,
       %{
         channels: [WorkerProbe.get(:second_channel)],
         scan_complete: true,
         next_cursor: nil
       }}
    end
  end

  defmodule PagedTransitionReader do
    def tail(%{"channel_id" => channel_id}) do
      WorkerProbe.get(:tail_results) |> Map.fetch!(channel_id)
    end

    def list_changes(_scope, _cursor, _limit), do: {:error, :unexpected_read}
    def latest_states(_scope, _keys), do: {:error, :unexpected_read}
  end

  defmodule PagedTransitionProviderConnects do
    def get_slack_triage_authority(_tenant_id, _group_id, _connect_id, channel_id) do
      {:ok, Map.put(WorkerProbe.get(:authority), "approved_channel_id", channel_id)}
    end

    def verify_slack_triage_authority(_authority), do: :ok
  end

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_triage_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)

    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
    unless Process.whereis(Ids), do: start_supervised!(Ids)
    unless Process.whereis(WorkerProbe), do: start_supervised!(WorkerProbe)

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous_backend)
      restore_env(:salix_store, :triage_record_backend, previous_triage_backend)
    end)

    :ok
  end

  test "one scoped human CH row creates one durable v3 receipt and retries as a duplicate" do
    authority = authority()

    {:ok, scan_state} =
      TriagePatrolScanState.initial(%{
        "ingest_at" => "2026-09-01T00:00:00.000Z",
        "message_ts_us" => 1_787_019_000_000_000,
        "version" => 3_574_038_000_000_000
      })

    assert {:ok,
            %{
              created: 1,
              duplicate: 0,
              ineligible: 0,
              settled: 1,
              has_more?: false,
              next_scan_state: next_scan_state
            }} =
             scan(authority, scan_state,
               reader: Reader,
               cursor_revision: 7,
               limit: 25,
               authority_verifier: fn current -> if current == authority, do: :ok end
             )

    event_id = event_id(authority, 1_787_019_001_000_001)
    key = Keys.ctl_im_slack_event_receipt(authority["connect_id"], event_id)
    assert {:ok, receipt} = CasRecord.get(key)
    assert receipt["schema"] == "comma.slack-triage-event-receipt.v3"
    assert receipt["event_id"] == event_id
    assert receipt["triage_event"]["source_mode"] == "clickhouse_etl"
    assert ProviderReceipts.verify_slack_triage_receipt(authority, receipt) == :ok
    assert Bucketing.validate_receipt(receipt) == :ok

    assert receipt["triage_event"]["endpoint_provenance"] == %{
             "schema" => "comma.slack-clickhouse-etl-provenance.v1",
             "table" => "slack_messages",
             "message_ts_us" => 1_787_019_001_000_001,
             "observed_version" => 3_574_038_002_000_002,
             "ingest_at" => "2026-09-01T00:00:01.123Z",
             "cursor_revision" => 7
           }

    assert next_scan_state["committed"]["message_ts_us"] == 1_787_019_001_000_001
    assert next_scan_state["pass"] == nil

    assert {:ok, %{created: 0, duplicate: 1, settled: 1}} =
             scan(authority, scan_state,
               reader: Reader,
               cursor_revision: 7,
               limit: 25,
               authority_verifier: fn current -> if current == authority, do: :ok end
             )
  end

  test "new observations enter the real runtime without waiting for the historical receipt ring" do
    Application.delete_env(:salix_store, :triage_record_backend)
    authority = SalixIM.TriageEngineFixtures.authority!()
    namespace = "patrol-direct-#{System.unique_integer([:positive])}"

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime, name: nil, namespace: namespace, mode: :review},
        id: make_ref()
      )

    opts = [
      reader: Reader,
      cursor_revision: 7,
      limit: 25,
      admission: &SalixIM.Triage.accept_current(runtime, &1, &2)
    ]

    # No ReceiptRecovery process runs here. This is the production admission
    # transaction, with a fake provider store and a real PostgreSQL bucket.
    assert {:ok, %{created: 1}} = scan(authority, before_row_state(), opts)

    {:ok, receipt} =
      ProviderReceipts.fetch_slack(
        authority["connect_id"],
        event_id(authority, 1_787_019_001_000_001)
      )

    assert {:ok, bucket} = Bucketing.load(namespace, Bucketing.scope_key(receipt))
    assert bucket["open_receipts"] == [receipt]

    assert {:ok, %{duplicate: 1}} = scan(authority, before_row_state(), opts)
    assert {:ok, repeated} = Bucketing.load(namespace, Bucketing.scope_key(receipt))
    assert repeated["open_receipts"] == [receipt]
  end

  test "failed immediate admission keeps the durable receipt and retries the same scan" do
    authority = authority()
    opts = [reader: Reader, cursor_revision: 7, limit: 25, authority_verifier: fn _ -> :ok end]

    assert {:error, :triage_admission_unavailable} =
             scan(
               authority,
               before_row_state(),
               Keyword.put(opts, :admission, fn _, _ -> {:error, :unavailable} end)
             )

    assert {:ok, receipt} =
             ProviderReceipts.fetch_slack(
               authority["connect_id"],
               event_id(authority, 1_787_019_001_000_001)
             )

    test_pid = self()

    assert {:ok, %{duplicate: 1, settled: 1}} =
             scan(
               authority,
               before_row_state(),
               Keyword.put(opts, :admission, fn current, stored ->
                 send(test_pid, {:admitted, current, stored})
                 {:ok, :accepted}
               end)
             )

    assert_receive {:admitted, ^authority, ^receipt}
  end

  test "worker tail-initializes discovery and settles one exact fenced cursor claim" do
    authority = authority()

    channel = %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "channel_id" => authority["approved_channel_id"],
      "channel_name" => "atlas",
      "channel_generation" => ULID.generate()
    }

    tail = %{
      "ingest_at" => "2026-09-01T00:00:00.000Z",
      "message_ts_us" => 1_787_019_000_000_000,
      "version" => 3_574_038_000_000_000
    }

    {:ok, tail_state} = TriagePatrolScanState.initial(tail)

    {:ok, next_scan_state} =
      TriagePatrolScanState.initial(%{
        "ingest_at" => "2026-09-01T00:00:01.000Z",
        "message_ts_us" => 1_787_019_001_000_001,
        "version" => 3_574_038_002_000_002
      })

    claim = %{
      cursor_key: "cursor-atlas",
      tenant_id: authority["tenant_id"],
      group_id: authority["group_id"],
      connect_id: authority["connect_id"],
      channel_id: authority["approved_channel_id"],
      channel_name: "atlas",
      channel_generation: channel["channel_generation"],
      authority_generation: authority["connect_generation"],
      last_message_ts: "0.000000",
      scan_state: tail_state,
      revision: 3,
      claim_token: "claim-atlas",
      lease_until: DateTime.utc_now(),
      holder: "worker-test"
    }

    WorkerProbe.put(%{
      authority: authority,
      channel: channel,
      tail: tail,
      next_scan_state: next_scan_state,
      claim: claim
    })

    assert {:ok,
            %{
              discovered: 1,
              synced: 1,
              sync_errors: 0,
              claimed: 1,
              settled: 1,
              created: 1,
              discovery_complete?: true,
              discovery_cursor: nil
            }} =
             ClickHousePatrolWorker.process_once(
               reader: WorkerReader,
               channel_store: WorkerChannelStore,
               cursor_store: WorkerCursorStore,
               provider_connects: WorkerProviderConnects,
               patrol: WorkerPatrol,
               holder: "worker-test"
             )

    assert WorkerProbe.get(:ensure) == {channel, authority, tail_state}
    assert {^authority, ^tail_state, scan_opts} = WorkerProbe.get(:scan)
    assert scan_opts[:cursor_revision] == claim.revision

    assert {^claim, result, settle_opts} = WorkerProbe.get(:settle)
    assert result.scan_state == next_scan_state
    assert result.last_message_ts == "1787019001.000001"
    assert result.created == 1
    assert settle_opts[:interval_ms] == 2_000
  end

  test "stale installation leaves patrol until current member discovery reauthorizes it" do
    {original, _peer} = projected_peer_fixture!()

    %{
      "tenant_id" => tenant,
      "group_id" => group,
      "connect_id" => connect_id,
      "approved_channel_id" => channel_id
    } = original

    on_exit(fn ->
      Repo.query!("DELETE FROM triage_patrol_cursors WHERE group_id = $1", [group])
      Repo.query!("DELETE FROM slack_triage_channels WHERE group_id = $1", [group])
    end)

    {:ok, channel} = SlackTriageChannels.get(tenant, group, connect_id, channel_id)

    {:ok, authority} =
      ProviderConnects.get_slack_triage_authority(tenant, group, connect_id, channel_id)

    initial = before_row_state()
    {:ok, stored} = SalixStore.TriagePatrolCursors.ensure(channel, authority, initial)
    WorkerProbe.put(%{channel: channel})

    key = Keys.ctl_im_connect(group, connect_id)

    {:ok, reconnected} =
      CasRecord.update(key, &Map.put(&1, "connect_generation", ULID.generate()))

    opts = [
      reader: QuietReader,
      channel_store: WorkerChannelStore,
      page_limit: 25,
      holder: "stale-installation-test"
    ]

    assert {:ok, %{claimed: 1, inactive: 1, failed: 0, sync_errors: 0}} =
             ClickHousePatrolWorker.process_once(opts)

    assert {:ok, inactive} =
             SalixStore.TriagePatrolCursors.get(tenant, group, connect_id, channel_id)

    assert inactive["last_outcome"] == "inactive"
    assert inactive["scan_state"] == stored["scan_state"]
    assert {:ok, %{claimed: 0, sync_errors: 0}} = ClickHousePatrolWorker.process_once(opts)
    assert {:ok, ^channel} = SlackTriageChannels.get(tenant, group, connect_id, channel_id)

    assert :ok =
             ProviderConnects.observe_slack_member_channels(reconnected, [
               %{
                 "id" => channel_id,
                 "name" => "atlas",
                 "is_private" => false,
                 "is_archived" => false,
                 "is_shared" => false
               }
             ])

    {:ok, current} = SlackTriageChannels.get(tenant, group, connect_id, channel_id)
    WorkerProbe.put(%{channel: current})

    assert {:ok, %{claimed: 1, settled: 1, failed: 0, sync_errors: 0}} =
             ClickHousePatrolWorker.process_once(opts)
  end

  test "an unavailable authority remains retryable instead of suspending patrol" do
    {original, _peer} = projected_peer_fixture!()
    tenant = original["tenant_id"]
    group = original["group_id"]
    connect = original["connect_id"]
    channel_id = original["approved_channel_id"]

    on_exit(fn ->
      Repo.query!("DELETE FROM triage_patrol_cursors WHERE group_id = $1", [group])
      Repo.query!("DELETE FROM slack_triage_channels WHERE group_id = $1", [group])
    end)

    {:ok, channel} = SlackTriageChannels.get(tenant, group, connect, channel_id)

    {:ok, authority} =
      ProviderConnects.get_slack_triage_authority(tenant, group, connect, channel_id)

    {:ok, stored} = SalixStore.TriagePatrolCursors.ensure(channel, authority, before_row_state())
    WorkerProbe.put(%{channel: channel})

    opts = [
      reader: QuietReader,
      channel_store: WorkerChannelStore,
      provider_connects: UnavailableWorkerProviderConnects
    ]

    assert {:ok, %{claimed: 1, failed: 1, sync_errors: 1}} =
             ClickHousePatrolWorker.process_once(opts)

    {:ok, current} = SalixStore.TriagePatrolCursors.get(tenant, group, connect, channel_id)
    assert current["last_outcome"] == "failed"
    assert current["scan_state"] == stored["scan_state"]

    Repo.query!(
      "UPDATE triage_patrol_cursors SET next_due_at = statement_timestamp() WHERE cursor_key = $1",
      [stored["cursor_key"]]
    )

    assert {:ok, %{claimed: 1, failed: 1, sync_errors: 1}} =
             ClickHousePatrolWorker.process_once(opts)
  end

  test "worker reports channel sync degradation once and recovery once without stopping patrol" do
    authority = authority()

    tail = %{
      "ingest_at" => "2026-09-01T00:00:00.000Z",
      "message_ts_us" => 1_787_019_000_000_000,
      "version" => 3_574_038_000_000_000
    }

    channel = %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "channel_id" => authority["approved_channel_id"],
      "channel_generation" => ULID.generate()
    }

    WorkerProbe.put(%{
      authority: authority,
      channel: channel,
      tail: tail,
      tail_result: {:error, :reader_unavailable}
    })

    opts = [
      reader: TransitionReader,
      channel_store: WorkerChannelStore,
      cursor_store: TransitionCursorStore,
      provider_connects: WorkerProviderConnects,
      patrol: WorkerPatrol,
      holder: "worker-test",
      interval_ms: 100,
      initial_delay_ms: 0
    ]

    assert {:ok, initial} = ClickHousePatrolWorker.init(opts)

    degraded_log =
      capture_log(fn ->
        assert {:noreply, degraded} = ClickHousePatrolWorker.handle_info(:tick, initial)
        assert degraded.sync_errors == 1
        send(self(), {:degraded, degraded})
      end)

    assert degraded_log =~ "channel sync degraded errors=1"
    assert_receive {:degraded, degraded}

    unchanged_log =
      capture_log(fn ->
        assert {:noreply, unchanged} = ClickHousePatrolWorker.handle_info(:tick, degraded)
        assert unchanged.sync_errors == 1
      end)

    refute unchanged_log =~ "channel sync degraded"

    WorkerProbe.record(:tail_result, {:ok, tail})

    recovered_log =
      capture_log(fn ->
        assert {:noreply, recovered} = ClickHousePatrolWorker.handle_info(:tick, degraded)
        assert recovered.sync_errors == 0
      end)

    assert recovered_log =~ "channel sync recovered"
  end

  test "worker clears channel sync degradation only after a complete clean discovery pass" do
    authority = authority()

    tail = %{
      "ingest_at" => "2026-09-01T00:00:00.000Z",
      "message_ts_us" => 1_787_019_000_000_000,
      "version" => 3_574_038_000_000_000
    }

    first_channel = %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "channel_id" => "C_FAILING",
      "channel_generation" => ULID.generate()
    }

    second_channel = %{first_channel | "channel_id" => "C_HEALTHY"}

    WorkerProbe.put(%{
      authority: authority,
      first_channel: first_channel,
      second_channel: second_channel,
      tail_results: %{
        "C_FAILING" => {:error, :reader_unavailable},
        "C_HEALTHY" => {:ok, tail}
      }
    })

    opts = [
      reader: PagedTransitionReader,
      channel_store: PagedTransitionChannelStore,
      cursor_store: TransitionCursorStore,
      provider_connects: PagedTransitionProviderConnects,
      patrol: WorkerPatrol,
      holder: "worker-test",
      interval_ms: 100,
      initial_delay_ms: 0,
      discovery_limit: 1
    ]

    assert {:ok, initial} = ClickHousePatrolWorker.init(opts)

    first_page_log =
      capture_log(fn ->
        assert {:noreply, first_page} = ClickHousePatrolWorker.handle_info(:tick, initial)
        assert first_page.sync_errors == 1
        assert first_page.discovery_cursor == "second-page"
        send(self(), {:first_page, first_page})
      end)

    assert first_page_log =~ "channel sync degraded errors=1"
    assert_receive {:first_page, first_page}

    second_page_log =
      capture_log(fn ->
        assert {:noreply, second_page} = ClickHousePatrolWorker.handle_info(:tick, first_page)
        assert second_page.sync_errors == 1
        assert second_page.discovery_cursor == nil
        send(self(), {:second_page, second_page})
      end)

    refute second_page_log =~ "channel sync recovered"
    assert_receive {:second_page, degraded}

    WorkerProbe.record(:tail_results, %{
      "C_FAILING" => {:ok, tail},
      "C_HEALTHY" => {:ok, tail}
    })

    clean_first_page_log =
      capture_log(fn ->
        assert {:noreply, clean_first_page} =
                 ClickHousePatrolWorker.handle_info(:tick, degraded)

        assert clean_first_page.sync_errors == 1
        send(self(), {:clean_first_page, clean_first_page})
      end)

    refute clean_first_page_log =~ "channel sync recovered"
    assert_receive {:clean_first_page, clean_first_page}

    clean_second_page_log =
      capture_log(fn ->
        assert {:noreply, recovered} =
                 ClickHousePatrolWorker.handle_info(:tick, clean_first_page)

        assert recovered.sync_errors == 0
      end)

    assert clean_second_page_log =~ "channel sync recovered"
  end

  test "an empty bounded pass commits its captured tail without inventing a message" do
    authority = authority()
    {:ok, scan_state} = TriagePatrolScanState.initial(elem(QuietReader.tail(%{}), 1))

    assert {:ok,
            %{
              created: 0,
              duplicate: 0,
              ineligible: 0,
              settled: 0,
              has_more?: false,
              next_scan_state: completed
            }} =
             scan(authority, scan_state,
               reader: QuietReader,
               cursor_revision: 7,
               limit: 25,
               authority_verifier: fn _current -> flunk("no row may request authority") end
             )

    assert completed == scan_state
  end

  test "a backfilled history row is not an ambient Triage subject" do
    authority = authority()
    scan_state = before_row_state()

    assert {:ok, %{created: 0, duplicate: 0, ineligible: 1, settled: 1}} =
             scan(authority, scan_state,
               reader: BackfillReader,
               cursor_revision: 7,
               limit: 25,
               authority_verifier: fn _current -> flunk("backfill must not write a receipt") end
             )

    refute match?(
             {:ok, _receipt},
             CasRecord.get(
               Keys.ctl_im_slack_event_receipt(
                 authority["connect_id"],
                 event_id(authority, 1_787_019_001_000_001)
               )
             )
           )
  end

  test "a Task-bound physical thread is inert even when its CH root is otherwise ambient" do
    authority = authority()
    scan_state = before_row_state()

    assert {:ok, %{created: 0, duplicate: 0, ineligible: 1, settled: 1}} =
             scan(authority, scan_state,
               reader: Reader,
               thread_binding_port: TaskBindingPort,
               cursor_revision: 7,
               limit: 25,
               authority_verifier: fn _current -> flunk("Task-owned row must not write") end
             )

    refute match?(
             {:ok, _receipt},
             CasRecord.get(
               Keys.ctl_im_slack_event_receipt(
                 authority["connect_id"],
                 event_id(authority, 1_787_019_001_000_001)
               )
             )
           )
  end

  test "a Task handover after the binding read wins before the CH receipt write" do
    authority = authority()
    scan_state = before_row_state()
    scope = route_scope(authority, "1787019001.000001")

    assert {:ok, %{created: 0, duplicate: 0, ineligible: 1, settled: 1}} =
             scan(authority, scan_state,
               reader: Reader,
               cursor_revision: 7,
               limit: 25,
               authority_verifier: fn _current ->
                 assert {:ok, task_identity} =
                          ThreadRouteOwner.task_claim_identity(scope, "cnv_racing_task")

                 assert {:ok, :task} = ThreadRouteOwner.claim_task(scope, task_identity)
                 :ok
               end
             )

    refute match?(
             {:ok, _receipt},
             CasRecord.get(
               Keys.ctl_im_slack_event_receipt(
                 authority["connect_id"],
                 event_id(authority, 1_787_019_001_000_001)
               )
             )
           )
  end

  test "ordinary bot_message replies explicitly addressing this bot remain eligible" do
    authority = authority()
    scan_state = before_row_state()

    assert {:ok, %{created: 1, ineligible: 0, settled: 1}} =
             scan(authority, scan_state,
               reader: AgentReader,
               cursor_revision: 7,
               limit: 25,
               authority_verifier: fn _current -> :ok end
             )

    event_id = event_id(authority, 1_787_019_001_000_001)

    assert {:ok, receipt} =
             CasRecord.get(Keys.ctl_im_slack_event_receipt(authority["connect_id"], event_id))

    assert receipt["triage_event"]["actor_kind"] == "agent"
    assert receipt["triage_event"]["addressing_kind"] == "directed"
  end

  test "an undirected bot alert root reaches triage once without manufacturing a reply" do
    authority = authority()
    scan_state = before_row_state()

    opts = [
      reader: AlertReader,
      cursor_revision: 7,
      limit: 25,
      authority_verifier: fn _ -> :ok end
    ]

    assert {:ok, %{created: 1}} = scan(authority, scan_state, opts)
    assert {:ok, %{created: 0, duplicate: 1}} = scan(authority, scan_state, opts)

    key =
      Keys.ctl_im_slack_event_receipt(
        authority["connect_id"],
        event_id(authority, 1_787_019_001_000_001)
      )

    assert {:ok, receipt} = CasRecord.get(key)
    assert receipt["triage_event"]["actor_kind"] == "agent"
    assert receipt["triage_event"]["addressing_kind"] == "ambient"
    assert ProviderReceipts.verify_slack_triage_receipt(authority, receipt) == :ok
    assert Bucketing.validate_receipt(receipt) == :ok

    forged =
      update_in(
        receipt,
        ["triage_event"],
        &Map.merge(&1, %{
          "addressing_kind" => "directed",
          "trigger_kind" => "mention",
          "fast_path" => true,
          "addressed_connect" => authority["connect_id"]
        })
      )

    assert {:error, _reason} = ProviderReceipts.verify_slack_triage_receipt(authority, forged)
  end

  test "own bot alerts and undirected bot replies do not start an ambient loop" do
    for reader <- [OwnAlertReader, AlertReplyReader] do
      assert {:ok, %{created: 0, ineligible: 1}} =
               scan(authority(), before_row_state(),
                 reader: reader,
                 cursor_revision: 7,
                 limit: 25,
                 authority_verifier: fn _ -> :ok end
               )
    end
  end

  test "a projected sibling bot mention settles as ineligible without claiming the root" do
    {authority, peer} = projected_peer_fixture!()

    on_exit(fn ->
      Repo.query!("DELETE FROM slack_triage_channels WHERE group_id = $1", [authority["group_id"]])
    end)

    assert {:ok, true} =
             ProviderConnects.slack_triage_peer_mentioned?(authority, [peer["bot_user_id"]])

    assert ThreadRouteOwner.lookup(route_scope(authority, "1787019001.000001")) == :unbound

    assert {:ok, %{created: 0, ineligible: 1, settled: 1}} =
             scan(authority, before_row_state(),
               reader: PeerMentionReader,
               cursor_revision: 7,
               limit: 25,
               authority_verifier: fn _current -> :ok end
             )

    assert ThreadRouteOwner.lookup(route_scope(authority, "1787019001.000001")) == :unbound
  end

  test "member discovery defaults channels on and preserves explicit exclusions" do
    {authority, _peer} = projected_peer_fixture!()

    on_exit(fn ->
      Repo.query!("DELETE FROM slack_triage_channels WHERE group_id = $1", [authority["group_id"]])
    end)

    key = Keys.ctl_im_connect(authority["group_id"], authority["connect_id"])
    {:ok, connect} = CasRecord.get(key)

    channels = [
      %{
        "id" => "C_ALERTS",
        "name" => "comma-app-alerts",
        "is_private" => false,
        "is_archived" => false,
        "is_shared" => false
      }
    ]

    assert :ok = ProviderConnects.observe_slack_member_channels(connect, channels)

    assert {:ok, current} =
             ProviderConnects.get_slack_triage_authority(
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               "C_ALERTS"
             )

    assert current["approved_channel_id"] == "C_ALERTS"

    for {field, value} <- [
          {"is_member", false},
          {"is_private", true},
          {"is_archived", true},
          {"is_shared", true},
          {"is_im", true},
          {"is_mpim", true}
        ] do
      channel = channels |> hd() |> Map.put("id", "C_EXCLUDED_" <> field) |> Map.put(field, value)
      assert :ok = ProviderConnects.observe_slack_member_channels(connect, [channel])

      assert {:error, :not_found} =
               SlackTriageChannels.get(
                 connect["tenant_id"],
                 connect["group_id"],
                 connect["connect_id"],
                 channel["id"]
               )
    end

    stale = Map.put(connect, "connect_generation", ULID.generate())

    assert :ok =
             ProviderConnects.observe_slack_member_channels(stale, [
               Map.put(hd(channels), "id", "C_STALE")
             ])

    assert {:error, :not_found} =
             SlackTriageChannels.get(
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               "C_STALE"
             )

    assert :ok =
             ProviderConnects.set_slack_triage_channel_enabled(
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               "C_ALERTS",
               false
             )

    assert :ok = ProviderConnects.observe_slack_member_channels(connect, channels)

    assert {:error, :slack_triage_authority_ineligible} =
             ProviderConnects.get_slack_triage_authority(
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               "C_ALERTS"
             )

    assert {:ok, reconnected} =
             CasRecord.update(key, &Map.put(&1, "connect_generation", ULID.generate()))

    assert :ok = ProviderConnects.observe_slack_member_channels(reconnected, channels)

    assert {:ok, excluded} =
             SlackTriageChannels.get(
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               "C_ALERTS"
             )

    assert excluded["installation_generation"] == reconnected["connect_generation"]
    assert excluded["enabled"] == false
  end

  test "authority rotation treats the same physical CH source as a duplicate instead of blocking" do
    first = authority()
    second = Map.put(first, "connect_generation", ULID.generate())
    scan_state = before_row_state()

    assert {:ok, %{created: 1}} =
             scan(first, scan_state,
               reader: Reader,
               cursor_revision: 7,
               limit: 25,
               authority_verifier: fn _current -> :ok end
             )

    assert {:ok, %{created: 0, duplicate: 1, settled: 1}} =
             scan(second, scan_state,
               reader: Reader,
               cursor_revision: 8,
               limit: 25,
               authority_verifier: fn _current -> :ok end
             )
  end

  # Existing provider/route cases isolate admission. The direct-admission
  # regression above overrides this callback with the real Runtime and DB.
  defp scan(authority, state, opts) do
    opts = Keyword.put_new(opts, :admission, fn _, _ -> {:ok, :accepted} end)
    ClickHousePatrol.scan(authority, state, opts)
  end

  defp authority do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    agent = Ids.new_agent_id(group)

    %{
      "provider" => "slack",
      "tenant_id" => tenant,
      "group_id" => group,
      "connect_id" => "connect-atlas",
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_ATLAS",
      "approved_channel_id" => "C_ATLAS",
      "inbound_agent_id" => agent,
      "app_id" => "A_BFT",
      "bot_user_id" => "U_BFT",
      "bot_id" => "B_BFT",
      "oauth_completed_at" => 1,
      "triage_enabled" => true
    }
  end

  defp projected_peer_fixture! do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)

    authority =
      authority()
      |> Map.put("tenant_id", tenant_id)
      |> Map.put("group_id", group_id)
      |> Map.put("inbound_agent_id", agent_id)
      |> Map.put("connect_id", Ids.new_connect_id())

    connect =
      authority
      |> Map.put("bot_token", "xoxb-primary-test-token")
      |> Map.put("triage_provisioned_at", 1)
      |> Map.put("disabled_at", nil)
      |> Map.put("deleted_at", nil)

    peer =
      connect
      |> Map.put("connect_id", Ids.new_connect_id())
      |> Map.put("connect_generation", ULID.generate())
      |> Map.put("app_id", "A_PEER")
      |> Map.put("bot_user_id", "UPEER123")
      |> Map.put("bot_id", "B_PEER")

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "router_agent_id" => agent_id,
      "router_conversation_id" => Ids.new_conversation_id()
    }

    assert {:ok, _} = CasRecord.create(Keys.ctl_group(group_id), group)

    for current <- [connect, peer] do
      assert {:ok, _} =
               CasRecord.create(Keys.ctl_im_connect(group_id, current["connect_id"]), current)

      assert {:ok, _} =
               SlackTriageChannels.provision(%{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "connect_id" => current["connect_id"],
                 "channel_id" => current["approved_channel_id"],
                 "installation_generation" => current["connect_generation"],
                 "workspace_id" => current["workspace_id"],
                 "channel_name" => "atlas"
               })
    end

    {authority, peer}
  end

  defp event_id(authority, message_ts_us) do
    [
      "slack-clickhouse-etl-v1",
      authority["connect_id"],
      authority["approved_channel_id"],
      Integer.to_string(message_ts_us)
    ]
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp route_scope(authority, root_thread_ts) do
    %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "connect_generation" => authority["connect_generation"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => root_thread_ts
    }
  end

  defp before_row_state do
    {:ok, state} =
      TriagePatrolScanState.initial(%{
        "ingest_at" => "2026-09-01T00:00:00.000Z",
        "message_ts_us" => 1_787_019_000_000_000,
        "version" => 3_574_038_000_000_000
      })

    state
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
