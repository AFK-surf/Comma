defmodule Salix.Bindings.TriageReceiptConsumerTest do
  use ExUnit.Case, async: false

  defmodule RecordingAgentDelivery do
    @behaviour SalixIM.Ports.AgentDelivery

    @impl true
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts) do
      if pid = Application.get_env(:salix_web, :triage_receipt_consumer_test_pid) do
        send(pid, {:agent_delivery, agent_id, payload, opts})
      end

      Application.get_env(
        :salix_web,
        :triage_receipt_consumer_delivery_result,
        {:ok, :created}
      )
    end

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_found}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_found}
  end

  alias SalixIM.Triage.Bucketing
  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.ProviderConnects
  alias SalixIM.TestSupport.HistoricalProviderReceipts, as: ProviderReceipts
  alias SalixStore.{CasRecord, Crypto, Ids, Keys, Repo, S3, ULID}

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_agent_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    previous_test_pid = Application.get_env(:salix_web, :triage_receipt_consumer_test_pid)

    previous_delivery_result =
      Application.get_env(:salix_web, :triage_receipt_consumer_delivery_result)

    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)
    connect_id = Ids.new_connect_id()

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "router_agent_id" => agent_id,
      "router_conversation_id" => Ids.new_conversation_id()
    }

    router_agent = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "agent_id" => agent_id,
      "role" => "router",
      "router_session_id" => Ids.new_session_id(),
      "heartbeat_schedule_id" => "schedule-triage-admission-test"
    }

    connect = %{
      "provider" => "slack",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_TRIAGE_ADMISSION",
      "approved_channel_id" => "C_TRIAGE_ADMISSION",
      "inbound_agent_id" => agent_id,
      "app_id" => "A_TRIAGE_ADMISSION",
      "bot_user_id" => "U_TRIAGE_ADMISSION_BOT",
      "bot_id" => "B_TRIAGE_ADMISSION_BOT",
      "bot_token" => "xoxb-private-admission-token",
      "signing_secret" => "triage-admission-signing-secret",
      "oauth_completed_at" => 1,
      "triage_enabled" => true,
      "disabled_at" => nil,
      "deleted_at" => nil
    }

    assert {:ok, _group} = CasRecord.create(Keys.ctl_group(group_id), group)
    assert {:ok, _agent} = CasRecord.create(Keys.ctl_agent(agent_id), router_agent)
    assert {:ok, _connect} = CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), connect)
    provision_channel!(connect)

    assert {:ok, authority} =
             ProviderConnects.get_slack_triage_authority(tenant_id, group_id, connect_id)

    assert {:ok, :created, receipt} =
             ProviderReceipts.record_slack_triage_clickhouse(
               authority,
               verified_clickhouse(authority),
               7
             )

    namespace = "triage-admission-#{System.unique_integer([:positive])}"

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: namespace},
        id: make_ref()
      )

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous_backend)
      restore_env(:salix_im, :agent_delivery_mod, previous_agent_delivery)
      restore_env(:salix_web, :triage_receipt_consumer_test_pid, previous_test_pid)

      restore_env(
        :salix_web,
        :triage_receipt_consumer_delivery_result,
        previous_delivery_result
      )

      S3.Fake.clear_blackhole()
    end)

    {:ok,
     authority: authority,
     connect: connect,
     namespace: namespace,
     receipt: receipt,
     runtime: runtime}
  end

  test "production consumer admits one CH receipt and restart replay is byte-idempotent",
       %{
         authority: authority,
         connect: connect,
         namespace: namespace,
         receipt: receipt,
         runtime: runtime
       } do
    opts = [delivery_mode: :review, runtime: runtime]

    assert :ok =
             Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(authority, receipt, opts)

    scope = Bucketing.scope_key(receipt)

    marker_key =
      SalixStore.TriageKeys.ctl_im_triage_projection_marker(namespace, receipt["receipt_ref"])

    alias_key =
      SalixStore.TriageKeys.ctl_im_triage_source_alias(namespace, Bucketing.source_key(receipt))

    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    assert {:ok, marker} = CasRecord.get(marker_key)
    assert {:ok, source_alias} = CasRecord.get(alias_key)
    assert {:ok, bucket} = CasRecord.get(bucket_key)

    assert marker == %{
             "schema" => "comma.triage-receipt-projection.v1",
             "receipt_ref" => receipt["receipt_ref"],
             "event_id" => receipt["event_id"]
           }

    assert source_alias == %{
             "schema" => "comma.triage-source-alias.v1",
             "source_message_ref" => receipt["source_message_ref"],
             "canonical_receipt_ref" => receipt["receipt_ref"],
             "recipient_key" => Crypto.hex(connect["connect_id"])
           }

    assert bucket["schema"] == "comma.triage-durable-bucket.v1"
    assert bucket["bucket_scope"] == scope
    assert bucket["open_receipts"] == [receipt]
    assert bucket["sealed_generations"] == []

    :ok = GenServer.stop(runtime)

    restarted =
      start_supervised!(
        {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: namespace},
        id: make_ref()
      )

    assert :ok =
             Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
               authority,
               receipt,
               delivery_mode: :review,
               runtime: restarted
             )

    assert CasRecord.get(marker_key) == {:ok, marker}
    assert CasRecord.get(alias_key) == {:ok, source_alias}
    assert CasRecord.get(bucket_key) == {:ok, bucket}
  end

  test "supervised recovery admits a durable CH receipt without another callback",
       %{authority: authority, namespace: namespace, receipt: receipt, runtime: runtime} do
    bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(receipt))

    assert CasRecord.get(bucket_key) == {:error, :not_found}

    recovery_name =
      {:global, {:triage_receipt_recovery_test, System.unique_integer([:positive])}}

    recovery =
      start_supervised!(
        {SalixIM.Triage.ReceiptRecovery,
         name: recovery_name,
         runtime: runtime,
         interval_ms: 5,
         full_ring_idle_ms: 5,
         held_poll_ms: 5,
         lease_key: "ctl/test/triage-receipt-recovery/#{System.unique_integer([:positive])}",
         lease_ttl_ms: 50},
        id: make_ref()
      )

    assert Process.alive?(recovery)

    assert eventually(fn ->
             CasRecord.get(bucket_key) ==
               {:ok,
                %{
                  "schema" => "comma.triage-durable-bucket.v1",
                  "bucket_scope" => Bucketing.scope_key(receipt),
                  "open_generation" => bucket_generation(CasRecord.get(bucket_key)),
                  "open_first_at" => receipt["created_at"],
                  "open_last_at" => receipt["created_at"],
                  "open_fast_path" => receipt["triage_event"]["fast_path"],
                  "open_receipts" => [receipt],
                  "sealed_generations" => []
                }}
           end)

    assert CasRecord.get(receipt_storage_key(receipt)) == {:ok, receipt}

    assert {:ok, bucket_before_restart} = CasRecord.get(bucket_key)
    Process.exit(recovery, :kill)

    assert eventually(fn ->
             case GenServer.whereis(recovery_name) do
               pid when is_pid(pid) -> pid != recovery and Process.alive?(pid)
               _missing -> false
             end
           end)

    assert {:ok, :created, after_restart_receipt} =
             ProviderReceipts.record_slack_triage_clickhouse(
               authority,
               verified_clickhouse(authority, "1787020000.000099"),
               8
             )

    after_restart_bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(
        namespace,
        Bucketing.scope_key(after_restart_receipt)
      )

    assert eventually(fn ->
             with {:ok, bucket} <- CasRecord.get(after_restart_bucket_key) do
               after_restart_bucket_key == bucket_key and
                 bucket["open_generation"] == bucket_before_restart["open_generation"] and
                 bucket["open_receipts"] == [receipt, after_restart_receipt]
             else
               _missing -> false
             end
           end)
  end

  test "recovery resolves an authority beyond the first thousand connect records",
       %{namespace: namespace, receipt: receipt, runtime: runtime} do
    Enum.each(1..1_000, fn index ->
      dummy_connect_id = "dummy-connect-#{String.pad_leading(Integer.to_string(index), 4, "0")}"
      dummy_group_id = "0000-dummy-group-#{String.pad_leading(Integer.to_string(index), 4, "0")}"

      assert {:ok, _record} =
               CasRecord.create(
                 Keys.ctl_im_connect(dummy_group_id, dummy_connect_id),
                 %{
                   "provider" => "slack",
                   "group_id" => dummy_group_id,
                   "connect_id" => dummy_connect_id
                 }
               )
    end)

    bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(receipt))

    assert CasRecord.get(bucket_key) == {:error, :not_found}

    recovery =
      start_supervised!(
        {SalixIM.Triage.ReceiptRecovery,
         name: nil,
         runtime: runtime,
         interval_ms: 1,
         lease_key: "ctl/test/triage-receipt-recovery/#{System.unique_integer([:positive])}",
         lease_ttl_ms: 5_000},
        id: make_ref()
      )

    assert Process.alive?(recovery)

    assert eventually(fn ->
             match?({:ok, %{"open_receipts" => [^receipt]}}, CasRecord.get(bucket_key))
           end)
  end

  test "authority rotation while the PostgreSQL bucket transaction is stalled leaves only an inert old-generation projection",
       %{
         authority: authority,
         connect: connect,
         namespace: namespace,
         receipt: receipt,
         runtime: runtime
       } do
    bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(receipt))

    seed_empty_bucket!(bucket_key, Bucketing.scope_key(receipt))
    {locker, locker_backend_pid} = hold_bucket_lock!(bucket_key)

    admission =
      Task.async(fn ->
        Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
          authority,
          receipt,
          delivery_mode: :review,
          runtime: runtime
        )
      end)

    assert eventually(fn -> blocked_by?(locker_backend_pid) end)

    connect_key = Keys.ctl_im_connect(connect["group_id"], connect["connect_id"])

    assert {:ok, rotated} =
             CasRecord.update(connect_key, fn current ->
               current
               |> Map.put("connect_generation", ULID.generate())
               |> Map.put("triage_enabled", false)
             end)

    refute rotated["connect_generation"] == authority["connect_generation"]
    release_bucket_lock!(locker, bucket_key)
    assert Task.await(admission) == {:error, :slack_triage_authority_stale}

    assert {:ok, bucket} = CasRecord.get(bucket_key)
    assert bucket["open_receipts"] == [receipt]

    assert bucket["open_receipts"] |> hd() |> Map.fetch!("connect_generation") ==
             authority["connect_generation"]

    # The engine Runtime always carries an `active` map, a local bucket view,
    # and flush schedules — asserting those KEYS are absent was a leftover from
    # the pre-engine state shape and passed for the wrong reason on both sides.
    # What a rotated generation must leave behind is no ARMED work of any kind
    # for its scope.
    state = :sys.get_state(runtime)
    scope_key = Bucketing.scope_key(receipt)

    refute Map.has_key?(state.active, scope_key)
    refute Map.has_key?(state.buckets, scope_key)
    refute Map.has_key?(state.flush_schedules, scope_key)

    assert Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
             authority,
             receipt,
             delivery_mode: :review,
             runtime: runtime
           ) == {:error, :slack_triage_authority_stale}

    assert CasRecord.get(bucket_key) == {:ok, bucket}
  end

  test "a stalled channel admission does not block a healthy channel",
       %{
         authority: authority,
         namespace: namespace,
         receipt: stalled_receipt,
         runtime: runtime
       } do
    healthy_channel = "C_TRIAGE_HEALTHY"
    provision_channel!(Map.put(authority, "approved_channel_id", healthy_channel))

    assert {:ok, healthy_authority} =
             ProviderConnects.get_slack_triage_authority(
               authority["tenant_id"],
               authority["group_id"],
               authority["connect_id"],
               healthy_channel
             )

    assert {:ok, :created, healthy_receipt} =
             ProviderReceipts.record_slack_triage_clickhouse(
               healthy_authority,
               verified_clickhouse(healthy_authority, "1787020000.000003"),
               8
             )

    stalled_bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(stalled_receipt))

    healthy_bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(healthy_receipt))

    seed_empty_bucket!(stalled_bucket_key, Bucketing.scope_key(stalled_receipt))
    {locker, locker_backend_pid} = hold_bucket_lock!(stalled_bucket_key)

    stalled =
      Task.async(fn ->
        Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
          authority,
          stalled_receipt,
          delivery_mode: :review,
          runtime: runtime
        )
      end)

    assert eventually(fn -> blocked_by?(locker_backend_pid) end)

    healthy =
      Task.async(fn ->
        Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
          healthy_authority,
          healthy_receipt,
          delivery_mode: :review,
          runtime: runtime
        )
      end)

    assert {:ok, :ok} = Task.yield(healthy, 500)
    assert {:ok, %{"open_receipts" => [^healthy_receipt]}} = CasRecord.get(healthy_bucket_key)
    assert Task.yield(stalled, 0) == nil

    release_bucket_lock!(locker, stalled_bucket_key)
    assert Task.await(stalled) == :ok
    assert {:ok, %{"open_receipts" => [^stalled_receipt]}} = CasRecord.get(stalled_bucket_key)
  end

  test "a rotated directed copy stays evidence-only even under a new legacy route owner",
       %{
         authority: authority,
         connect: connect,
         namespace: namespace,
         runtime: runtime
       } do
    first_verified =
      authority
      |> verified_root("Ev-triage-agent-before-rotation", "1787020000.000003")
      |> Map.merge(%{
        "event_type" => "app_mention",
        "actor_id" => "U_TRIAGE_ADMISSION_PEER_AGENT",
        "actor_kind" => "agent",
        "text" => "<@#{authority["bot_user_id"]}> first peer context"
      })

    assert {:ok, :created, first_receipt} =
             ProviderReceipts.record_slack_triage_root(authority, first_verified)

    assert Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
             authority,
             first_receipt,
             delivery_mode: :review,
             runtime: runtime
           ) == :ok

    connect_key = Keys.ctl_im_connect(connect["group_id"], connect["connect_id"])

    assert {:ok, rotated_connect} =
             CasRecord.update(connect_key, fn current ->
               Map.put(current, "connect_generation", ULID.generate())
             end)

    provision_channel!(rotated_connect)

    assert {:ok, rotated_authority} =
             ProviderConnects.get_slack_triage_authority(
               rotated_connect["tenant_id"],
               rotated_connect["group_id"],
               rotated_connect["connect_id"]
             )

    rotated_verified =
      rotated_authority
      |> verified_root("Ev-triage-agent-after-rotation", first_verified["message_ts"])
      |> Map.merge(%{
        "event_type" => "app_mention",
        "actor_id" => "U_TRIAGE_ADMISSION_PEER_AGENT",
        "actor_kind" => "agent",
        "text" => "<@#{rotated_authority["bot_user_id"]}> delayed rotated copy"
      })

    assert {:ok, :created, rotated_receipt} =
             ProviderReceipts.record_slack_triage_root(rotated_authority, rotated_verified)

    assert ThreadRouteOwner.claim_legacy(
             legacy_scope(rotated_authority, rotated_connect, rotated_verified),
             String.duplicate("f", 64)
           ) ==
             {:ok, :legacy}

    Application.put_env(:salix_im, :agent_delivery_mod, RecordingAgentDelivery)
    Application.put_env(:salix_web, :triage_receipt_consumer_test_pid, self())

    assert Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
             rotated_authority,
             rotated_receipt,
             delivery_mode: :review,
             runtime: runtime
           ) == :ok

    refute_receive {:agent_delivery, _, _, _}

    first_bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(
        namespace,
        Bucketing.scope_key(first_receipt)
      )

    rotated_bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(
        namespace,
        Bucketing.scope_key(rotated_receipt)
      )

    assert {:ok, first_bucket} = CasRecord.get(first_bucket_key)
    assert Bucketing.member?(first_bucket, first_receipt["receipt_ref"])
    refute Bucketing.member?(first_bucket, rotated_receipt["receipt_ref"])
    assert CasRecord.get(rotated_bucket_key) == {:error, :not_found}
  end

  test "a sealed canonical directed-agent duplicate retries the stable Router projection",
       %{
         authority: authority,
         connect: connect,
         namespace: namespace,
         runtime: runtime
       } do
    verified =
      authority
      |> verified_root("Ev-triage-agent-evidence-only", "1787020000.000004")
      |> Map.merge(%{
        "event_type" => "app_mention",
        "actor_id" => "U_TRIAGE_ADMISSION_PEER_AGENT",
        "actor_kind" => "agent",
        "text" => "<@#{authority["bot_user_id"]}> peer context"
      })

    assert {:ok, :created, receipt} =
             ProviderReceipts.record_slack_triage_root(authority, verified)

    scope = legacy_scope(authority, connect, verified)

    assert ThreadRouteOwner.claim_legacy(scope, String.duplicate("a", 64)) == {:ok, :legacy}

    Application.put_env(:salix_im, :agent_delivery_mod, RecordingAgentDelivery)
    Application.put_env(:salix_web, :triage_receipt_consumer_test_pid, self())

    assert Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
             authority,
             receipt,
             delivery_mode: :review,
             runtime: runtime
           ) == :ok

    assert_receive {:agent_delivery, _, _, first_opts}
    assert first_opts[:no_wake] == true

    bucket_scope = Bucketing.scope_key(receipt)
    assert {:ok, bucket} = Bucketing.load(namespace, bucket_scope)
    assert Bucketing.open_member?(bucket, receipt["receipt_ref"])

    generation = bucket["open_generation"]

    assert {:ok, %{"generation" => ^generation}} =
             Bucketing.seal(
               namespace,
               bucket_scope,
               generation,
               %{debounce_ms: 0, max_wait_ms: 1},
               receipt["created_at"] + 1
             )

    assert Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
             authority,
             receipt,
             delivery_mode: :review,
             runtime: runtime
           ) == :ok

    refute_receive {:agent_delivery, _, _, _}, 100

    bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, bucket_scope)

    assert {:ok, sealed_bucket} = CasRecord.get(bucket_key)
    refute Bucketing.open_member?(sealed_bucket, receipt["receipt_ref"])
    assert Bucketing.member?(sealed_bucket, receipt["receipt_ref"])
  end

  test "a failed Router projection remains retryable after its Triage generation seals",
       %{
         authority: authority,
         connect: connect,
         namespace: namespace,
         runtime: runtime
       } do
    verified =
      authority
      |> verified_root("Ev-triage-agent-failure-seal", "1787020000.000005")
      |> Map.merge(%{
        "event_type" => "app_mention",
        "actor_id" => "U_TRIAGE_ADMISSION_PEER_AGENT",
        "actor_kind" => "agent",
        "text" => "<@#{authority["bot_user_id"]}> retry this peer context"
      })

    assert {:ok, :created, receipt} =
             ProviderReceipts.record_slack_triage_root(authority, verified)

    assert ThreadRouteOwner.claim_legacy(
             legacy_scope(authority, connect, verified),
             String.duplicate("e", 64)
           ) ==
             {:ok, :legacy}

    Application.put_env(:salix_im, :agent_delivery_mod, RecordingAgentDelivery)
    Application.put_env(:salix_web, :triage_receipt_consumer_test_pid, self())

    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(authority["group_id"])
    key = Keys.ctl_group_conversation(authority["group_id"], conversation["conversation_id"])
    :ok = S3.Fake.blackhole({:fail, 503, :put, key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
             authority,
             receipt,
             delivery_mode: :review,
             runtime: runtime
           ) == {:error, :triage_router_context_unavailable}

    refute_receive {:agent_delivery, _, _, _}, 100
    S3.Fake.clear_blackhole()

    bucket_scope = Bucketing.scope_key(receipt)
    assert {:ok, bucket} = Bucketing.load(namespace, bucket_scope)
    generation = bucket["open_generation"]

    assert {:ok, %{"generation" => ^generation}} =
             Bucketing.seal(
               namespace,
               bucket_scope,
               generation,
               %{debounce_ms: 0, max_wait_ms: 1},
               receipt["created_at"] + 1
             )

    Application.put_env(
      :salix_web,
      :triage_receipt_consumer_delivery_result,
      {:ok, :created}
    )

    assert Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
             authority,
             receipt,
             delivery_mode: :review,
             runtime: runtime
           ) == :ok

    assert_receive {:agent_delivery, _, _, retry_opts}
    assert retry_opts[:no_wake] == true
  end

  test "malformed derived records and receipt drift fail closed without deleting the inbox truth",
       %{authority: authority, namespace: namespace, receipt: receipt, runtime: runtime} do
    Enum.each([:marker, :alias, :bucket], fn kind ->
      S3.Fake.reset()
      seed_authority_records(authority)
      assert {:ok, _receipt} = CasRecord.create(receipt_storage_key(receipt), receipt)

      case_namespace = "#{namespace}-#{kind}"
      key = derived_record_key(kind, case_namespace, receipt)
      malformed = malformed_derived_record(kind, receipt)
      seed_malformed_derived_record!(kind, key, case_namespace, receipt, malformed)

      case_runtime =
        start_supervised!(
          {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: case_namespace},
          id: make_ref()
        )

      assert {:error, :conflict} =
               Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
                 authority,
                 receipt,
                 delivery_mode: :review,
                 runtime: case_runtime
               )

      assert CasRecord.get(receipt_storage_key(receipt)) == {:ok, receipt}
      assert CasRecord.get(key) == {:ok, malformed}
    end)

    S3.Fake.reset()
    seed_authority_records(authority)
    assert {:ok, _receipt} = CasRecord.create(receipt_storage_key(receipt), receipt)
    drifted = put_in(receipt, ["triage_event", "bucket", "channel_id"], "C_FOREIGN")
    puts_before_drift = S3.Fake.put_log()

    assert Salix.Bindings.TriageReceiptConsumer.handle_typed_receipt(
             authority,
             drifted,
             delivery_mode: :review,
             runtime: runtime
           ) == {:error, :invalid_slack_triage_receipt}

    assert CasRecord.get(receipt_storage_key(receipt)) == {:ok, receipt}
    assert S3.Fake.put_log() == puts_before_drift
  end

  defp verified_clickhouse(authority, message_ts \\ "1787020000.000001") do
    [seconds, micros] = String.split(message_ts, ".", parts: 2)
    message_ts_us = String.to_integer(seconds) * 1_000_000 + String.to_integer(micros)

    %{
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => message_ts,
      "message_ts" => message_ts,
      "message_ts_us" => message_ts_us,
      "observed_version" => message_ts_us * 2,
      "ingest_at" => "2026-09-01T00:00:01.000Z",
      "actor_id" => "U_TRIAGE_ADMISSION_HUMAN",
      "actor_kind" => "human",
      "text" => "please review this update"
    }
  end

  defp verified_root(
         authority,
         event_id \\ "Ev-triage-admission",
         message_ts \\ "1787020000.000001"
       ) do
    %{
      "provider_event_id" => event_id,
      "callback_app_id" => authority["app_id"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => message_ts,
      "message_ts" => message_ts,
      "event_type" => "message",
      "actor_id" => "U_TRIAGE_ADMISSION_HUMAN",
      "actor_kind" => "human",
      "text" => "please review this update"
    }
  end

  defp legacy_scope(authority, connect, verified) do
    %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "connect_generation" => connect["connect_generation"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => verified["root_thread_ts"]
    }
  end

  defp receipt_storage_key(receipt),
    do: Keys.ctl_im_slack_event_receipt(receipt["connect_id"], receipt["event_id"])

  defp seed_empty_bucket!(bucket_key, scope) do
    bucket = %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope,
      "open_generation" => ULID.generate(),
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => []
    }

    assert {:ok, ^bucket} = CasRecord.create(bucket_key, bucket)
  end

  defp hold_bucket_lock!(bucket_key) do
    test = self()

    locker =
      Task.async(fn ->
        Repo.transaction(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")

          Repo.query!("SELECT 1 FROM triage_buckets WHERE record_key = $1 FOR UPDATE", [
            bucket_key
          ])

          send(test, {:bucket_lock_acquired, self(), backend_pid, bucket_key})

          receive do
            {:release_bucket_lock, ^bucket_key} -> :released
          after
            5_000 -> Repo.rollback(:bucket_lock_timeout)
          end
        end)
      end)

    locker_pid = locker.pid
    assert_receive {:bucket_lock_acquired, ^locker_pid, backend_pid, ^bucket_key}, 2_000
    {locker, backend_pid}
  end

  defp release_bucket_lock!(locker, bucket_key) do
    send(locker.pid, {:release_bucket_lock, bucket_key})
    assert Task.await(locker) == {:ok, :released}
  end

  defp blocked_by?(backend_pid) do
    case Repo.query(
           "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)))",
           [backend_pid]
         ) do
      {:ok, %{rows: [[blocked?]]}} -> blocked?
      _unavailable -> false
    end
  end

  defp derived_record_key(:marker, namespace, receipt),
    do:
      SalixStore.TriageKeys.ctl_im_triage_projection_marker(
        namespace,
        receipt["receipt_ref"]
      )

  defp derived_record_key(:alias, namespace, receipt),
    do: SalixStore.TriageKeys.ctl_im_triage_source_alias(namespace, Bucketing.source_key(receipt))

  defp derived_record_key(:bucket, namespace, receipt),
    do: SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(receipt))

  defp malformed_derived_record(:marker, receipt) do
    %{
      "schema" => "comma.triage-receipt-projection.v1",
      "receipt_ref" => receipt["receipt_ref"],
      "event_id" => receipt["event_id"],
      "raw" => "U_PRIVATE"
    }
  end

  defp malformed_derived_record(:alias, receipt) do
    %{
      "schema" => "comma.triage-source-alias.v1",
      "source_message_ref" => receipt["source_message_ref"],
      "canonical_receipt_ref" => receipt["receipt_ref"],
      "raw" => "U_PRIVATE"
    }
  end

  defp malformed_derived_record(:bucket, receipt) do
    %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => Bucketing.scope_key(receipt),
      "open_generation" => ULID.generate(),
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => [],
      "raw" => "U_PRIVATE"
    }
  end

  defp seed_malformed_derived_record!(:marker, key, namespace, receipt, malformed) do
    Repo.query!(
      "INSERT INTO triage_receipt_projections (record_key, namespace_key, receipt_key, receipt_ref, body) VALUES ($1, $2, $3, $4, $5)",
      [
        key,
        SalixStore.TriageKeys.namespace_key(namespace),
        Crypto.hex(receipt["receipt_ref"]),
        receipt["receipt_ref"],
        malformed
      ]
    )
  end

  defp seed_malformed_derived_record!(:alias, key, namespace, receipt, malformed) do
    Repo.query!(
      "INSERT INTO triage_ambient_aliases (record_key, namespace_key, physical_source_key, body) VALUES ($1, $2, $3, $4)",
      [
        key,
        SalixStore.TriageKeys.namespace_key(namespace),
        Crypto.hex(Bucketing.source_key(receipt)),
        malformed
      ]
    )
  end

  defp seed_malformed_derived_record!(:bucket, key, namespace, receipt, malformed) do
    Repo.query!(
      "INSERT INTO triage_buckets (record_key, namespace_key, bucket_key, body) VALUES ($1, $2, $3, $4)",
      [
        key,
        SalixStore.TriageKeys.namespace_key(namespace),
        Crypto.hex(Bucketing.scope_key(receipt)),
        malformed
      ]
    )
  end

  defp bucket_generation({:ok, %{"open_generation" => generation}}), do: generation
  defp bucket_generation(_missing), do: nil

  defp seed_authority_records(authority) do
    group = %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "router_agent_id" => authority["inbound_agent_id"],
      "router_conversation_id" => Ids.new_conversation_id()
    }

    connect =
      authority
      |> Map.put("bot_token", "xoxb-private-admission-token")
      |> Map.put("disabled_at", nil)
      |> Map.put("deleted_at", nil)

    assert {:ok, _group} = CasRecord.create(Keys.ctl_group(authority["group_id"]), group)

    assert {:ok, _connect} =
             CasRecord.create(
               Keys.ctl_im_connect(authority["group_id"], authority["connect_id"]),
               connect
             )

    provision_channel!(authority)
  end

  defp provision_channel!(authority) do
    assert {:ok, _channel} =
             SalixStore.SlackTriageChannels.provision(%{
               "tenant_id" => authority["tenant_id"],
               "group_id" => authority["group_id"],
               "connect_id" => authority["connect_id"],
               "channel_id" => authority["approved_channel_id"],
               "installation_generation" => authority["connect_generation"],
               "workspace_id" => authority["workspace_id"],
               "channel_name" => "triage",
               "channel_generation" => authority["connect_generation"]
             })

    :ok
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
