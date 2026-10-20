defmodule SalixIM.SlackTriageReceiptTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.Provider.Slack.EndpointRevision
  alias SalixIM.ProviderConnects
  alias SalixIM.TestSupport.HistoricalProviderReceipts, as: ProviderReceipts
  alias SalixIM.Triage.{AddressingEvidence, Bucketing, CanonicalJSON}
  alias SalixStore.{CasRecord, Ids, Keys, Repo, S3, SlackTriageChannelCutover, ULID}

  defmodule ReceiptReadProbe do
    @moduledoc false
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{active: 0, max_active: 0} end, name: __MODULE__)

    def reset, do: Agent.update(__MODULE__, fn _ -> %{active: 0, max_active: 0} end)

    def begin_get do
      Agent.update(__MODULE__, fn state ->
        active = state.active + 1
        %{state | active: active, max_active: max(state.max_active, active)}
      end)
    end

    def end_get, do: Agent.update(__MODULE__, &%{&1 | active: &1.active - 1})
    def snapshot, do: Agent.get(__MODULE__, & &1)
  end

  defmodule InstrumentedReceiptS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    # Only receipt reads count: background owners (lease renewal, recovery)
    # read the same store. Each receipt read holds until eight are in flight,
    # so the page reads concurrently or never finishes, whatever the timing.
    @impl true
    def get(key, opts) do
      if String.starts_with?(key, Keys.ctl_im_slack_event_receipts_prefix()) do
        ReceiptReadProbe.begin_get()

        try do
          await_in_flight(8)
          SalixStore.S3.Fake.get(key, opts)
        after
          ReceiptReadProbe.end_get()
        end
      else
        SalixStore.S3.Fake.get(key, opts)
      end
    end

    defp await_in_flight(count) do
      unless ReceiptReadProbe.snapshot().max_active >= count do
        SystemsClock.sleep(1)
        await_in_flight(count)
      end
    end

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_triage_backend = SystemsRuntime.get_env(:salix_store, :triage_record_backend)
    previous_channel_mode = SlackTriageChannelCutover.mode()
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    use_legacy_channel_authority!()

    if SystemsRuntime.Proc.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    unless SystemsRuntime.Proc.whereis(Ids), do: start_supervised!(Ids)

    on_exit(fn ->
      if previous_channel_mode == :projected do
        enable_projected_channel_authority!()
      end

      if is_nil(previous_backend) do
        SystemsRuntime.delete_env(:salix_store, :s3_backend)
      else
        SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
      end

      if is_nil(previous_triage_backend) do
        SystemsRuntime.delete_env(:salix_store, :triage_record_backend)
      else
        SystemsRuntime.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      end
    end)

    :ok
  end

  defp use_legacy_channel_authority! do
    Repo.query!("""
    DELETE FROM salix_cutover_markers
    WHERE name IN ('slack_triage_channels_v1', 'slack_triage_channels_v1_preparing')
    """)
  end

  defp enable_projected_channel_authority! do
    Repo.query!("""
    INSERT INTO salix_cutover_markers (name, completed_at, evidence)
    VALUES ('slack_triage_channels_v1', now(), '{"mode":"receipt-test-restore"}'::jsonb)
    ON CONFLICT (name) DO NOTHING
    """)
  end

  test "typed root receipt is durable, exact-duplicate idempotent, and payload drift conflicts" do
    authority = authority()
    verified_root = verified_root(authority)

    assert {:ok, :created, receipt} =
             ProviderReceipts.record_slack_triage_root(authority, verified_root)

    assert Map.keys(receipt) |> Enum.sort() ==
             ~w(connect_generation connect_id created_at event_id receipt_ref schema source_message_ref triage_event)

    assert receipt["schema"] == "comma.slack-triage-event-receipt.v2"
    assert receipt["connect_id"] == authority["connect_id"]
    assert receipt["event_id"] == verified_root["provider_event_id"]
    assert receipt["connect_generation"] == authority["connect_generation"]

    assert receipt["triage_event"] == %{
             "event_id" => verified_root["provider_event_id"],
             "connect_generation" => authority["connect_generation"],
             "message_ts" => verified_root["message_ts"],
             "actor_id" => verified_root["actor_id"],
             "actor_kind" => "human",
             "text" => verified_root["text"],
             "event_type" => "message",
             "addressing_kind" => "ambient",
             "trigger_kind" => "none",
             "fast_path" => false,
             "bucket" => %{
               "workspace_id" => authority["workspace_id"],
               "channel_id" => authority["approved_channel_id"],
               "thread_ts" => verified_root["root_thread_ts"]
             },
             "endpoint_provenance" => %{
               "schema" => "comma.slack-endpoint-provenance.v1",
               "captured_at_ms" => receipt["created_at"],
               "callback_api_app_id" => authority["app_id"],
               "fast_path_bot_user_id" => authority["bot_user_id"],
               "endpoint_revision_sha256" => endpoint_revision!(authority)
             },
             "source_mode" => "callback"
           }

    assert {:ok, :duplicate, duplicate} =
             ProviderReceipts.record_slack_triage_root(authority, verified_root)

    assert duplicate == receipt

    assert ProviderReceipts.record_slack_triage_root(
             authority,
             Map.put(verified_root, "text", "different callback payload")
           ) == {:error, :triage_duplicate_payload_drift}

    key =
      Keys.ctl_im_slack_event_receipt(authority["connect_id"], verified_root["provider_event_id"])

    assert CasRecord.get(key) == {:ok, receipt}
  end

  test "Triage receipts withhold Bearer spans before admission and sealing" do
    authority = authority()
    text = "接入要求 Bearer QUJDREVGRw，且仅公开只读工具"
    withheld = "接入要求 [Bearer-credential withheld]"

    assert {:ok, :created, etl} =
             SalixIM.ProviderReceipts.record_slack_triage_clickhouse(
               authority,
               %{
                 "workspace_id" => authority["workspace_id"],
                 "channel_id" => authority["approved_channel_id"],
                 "root_thread_ts" => "1787019000.000003",
                 "message_ts" => "1787019000.000003",
                 "message_ts_us" => 1_787_019_000_000_003,
                 "observed_version" => 1,
                 "ingest_at" => "2026-09-01T00:00:01.000Z",
                 "actor_id" => "U_HUMAN",
                 "actor_kind" => "human",
                 "text" => text
               },
               7
             )

    assert etl["triage_event"]["text"] == withheld
    assert SalixIM.ProviderReceipts.verify_slack_triage_receipt(authority, etl) == :ok

    assert {:ok, :created, recheck} =
             SalixIM.ProviderReceipts.record_slack_triage_recheck(
               authority,
               Map.put(verified_recheck_message(authority), "text", text),
               %{
                 "entry_id" => "triage-context-entry-bearer",
                 "schedule_id" => Ids.new_schedule_id(),
                 "scheduled_for_ms" => 1_787_019_600_000
               }
             )

    assert recheck["triage_event"]["text"] == withheld

    key_text = "Bearer -----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg\n-----END PRIVATE KEY-----"

    assert {:ok, :created, raw} =
             SalixIM.ProviderReceipts.record_slack_triage_recheck(
               authority,
               Map.put(verified_recheck_message(authority), "text", key_text),
               %{
                 "entry_id" => "triage-context-entry-private-key",
                 "schedule_id" => Ids.new_schedule_id(),
                 "scheduled_for_ms" => 1_787_019_600_000
               }
             )

    assert raw["triage_event"]["text"] == key_text
  end

  test "scheduled rechecks preserve the physical source while deduplicating each logical occurrence" do
    authority = authority()
    message = verified_recheck_message(authority)

    first_occurrence = %{
      "entry_id" => "triage-context-entry-1",
      "schedule_id" => Ids.new_schedule_id(),
      "scheduled_for_ms" => 1_787_019_600_000
    }

    second_occurrence = %{
      first_occurrence
      | "schedule_id" => Ids.new_schedule_id(),
        "scheduled_for_ms" => first_occurrence["scheduled_for_ms"] + :timer.hours(1)
    }

    assert {:ok, :created, first} =
             ProviderReceipts.record_slack_triage_recheck(
               authority,
               message,
               first_occurrence
             )

    assert {:ok, :duplicate, ^first} =
             ProviderReceipts.record_slack_triage_recheck(
               authority,
               message,
               first_occurrence
             )

    assert {:ok, :created, second} =
             ProviderReceipts.record_slack_triage_recheck(
               authority,
               message,
               second_occurrence
             )

    assert first["triage_event"]["source_mode"] == "scheduled_recheck"

    assert first["triage_event"]["recheck_context_ref"] ==
             "triage-context://#{first_occurrence["entry_id"]}"

    assert first["source_message_ref"] == second["source_message_ref"]
    assert first["event_id"] =~ ~r/^recheck:[0-9a-f]{64}$/
    refute first["event_id"] == second["event_id"]
    refute Bucketing.source_key(first) == Bucketing.source_key(second)
    assert ProviderReceipts.verify_slack_triage_receipt(authority, first) == :ok
    assert ProviderReceipts.verify_slack_triage_receipt(authority, second) == :ok

    namespace = "triage-scheduled-recheck-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    for receipt <- [first, second] do
      assert Bucketing.claim_receipt(namespace, receipt) == {:ok, :accepted, :canonical}
      assert Bucketing.append(namespace, receipt) == {:ok, :appended}
    end

    assert {:ok, bucket} = Bucketing.load(namespace, Bucketing.scope_key(first))

    assert bucket["open_receipts"]
           |> Enum.map(& &1["receipt_ref"])
           |> MapSet.new() == MapSet.new([first["receipt_ref"], second["receipt_ref"]])

    assert {:error, :invalid_addressing_evidence} =
             first["triage_event"]
             |> Map.put("source_mode", "callback")
             |> AddressingEvidence.validate_shape_only()

    historical = update_in(first, ["triage_event"], &Map.delete(&1, "recheck_context_ref"))
    key = Keys.ctl_im_slack_event_receipt(authority["connect_id"], first["event_id"])
    assert {:ok, ^historical} = CasRecord.update(key, fn _ -> historical end)

    assert {:ok, :duplicate, ^historical} =
             ProviderReceipts.record_slack_triage_recheck(authority, message, first_occurrence)
  end

  test "a reply receipt joins the exact bucket of its root and keeps its own source alias" do
    authority = authority()

    assert {:ok, :created, root} =
             ProviderReceipts.record_slack_triage_root(authority, verified_root(authority))

    assert {:ok, :created, reply} =
             ProviderReceipts.record_slack_triage_reply(authority, verified_reply(authority))

    assert Bucketing.scope_key(reply) == Bucketing.scope_key(root)
    refute Bucketing.source_key(reply) == Bucketing.source_key(root)
    refute reply["receipt_ref"] == root["receipt_ref"]

    namespace = "triage-reply-receipt-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    for receipt <- [root, reply] do
      assert Bucketing.claim_receipt(namespace, receipt) == {:ok, :accepted, :canonical}
      assert Bucketing.append(namespace, receipt) == {:ok, :appended}
    end

    assert {:ok, bucket} = Bucketing.load(namespace, Bucketing.scope_key(root))

    assert Enum.map(bucket["open_receipts"], & &1["receipt_ref"]) ==
             [root["receipt_ref"], reply["receipt_ref"]]

    # A second physical copy of the SAME reply — a duplicate Slack envelope
    # under its own event id — stays durable audit without a second membership.
    assert {:ok, :created, copy} =
             ProviderReceipts.record_slack_triage_reply(
               authority,
               verified_reply(authority, "Ev-triage-reply-copy")
             )

    assert Bucketing.claim_receipt(namespace, copy) == {:ok, :accepted, :superseded}
    assert {:ok, unchanged} = Bucketing.load(namespace, Bucketing.scope_key(root))
    assert unchanged["open_receipts"] == bucket["open_receipts"]
  end

  # The ingress attempt for a reply can die between its durable receipt write
  # and its admission — that is exactly the window the recovery ring exists
  # for, and the ring's receipt scan is shape-agnostic, so a reply receipt is
  # replayed into the SAME bucket its root already opened.
  test "recovery replays a reply receipt missed at ingress into its root's bucket" do
    authority = seed_recovery_connect!()

    assert {:ok, :created, root} =
             ProviderReceipts.record_slack_triage_root(
               authority,
               verified_root(authority, "Ev-recovery-root")
             )

    assert {:ok, :created, reply} =
             ProviderReceipts.record_slack_triage_reply(
               authority,
               verified_reply(authority, "Ev-recovery-reply")
             )

    namespace = "triage-recovery-reply-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: namespace},
        id: SystemsRuntime.Proc.make_ref()
      )

    # Only the root reaches admission; the reply's ingress never got that far.
    assert {:ok, :accepted} = SalixIM.Triage.Runtime.accept_current(runtime, authority, root)

    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(root))
    assert {:ok, %{"open_receipts" => [^root]}} = CasRecord.get(bucket_key)

    recovery =
      start_supervised!(
        {SalixIM.Triage.ReceiptRecovery,
         name: nil,
         runtime: runtime,
         page_limit: 5,
         interval_ms: 1,
         full_ring_idle_ms: 5,
         held_poll_ms: 5,
         lease_key:
           "ctl/test/triage-recovery-reply/#{SystemsRuntime.Proc.unique_integer([:positive])}",
         lease_ttl_ms: 5_000},
        id: SystemsRuntime.Proc.make_ref()
      )

    assert eventually(fn ->
             match?({:ok, %{"open_receipts" => [^root, ^reply]}}, CasRecord.get(bucket_key))
           end),
           inspect(:sys.get_state(recovery, :infinity))

    assert SystemsRuntime.Proc.alive?(recovery)
  end

  # With one key per page, recovery must page past keys it cannot decode
  # (an invalid key, an empty folder marker, a trailing-space key) and still
  # reach the healthy receipt behind them.
  for {name, label, poison_objects} <- [
        {"recovery advances from an invalid-only page to a healthy typed receipt", "invalid-page",
         [{"!invalid-key", Jason.encode!(%{"raw" => "poison"})}]},
        {"recovery converges past a folder marker and a trailing-space key", "poison-keys",
         [{"", ""}, {"!poison ", Jason.encode!(%{"raw" => "poison"})}]}
      ] do
    @label label
    @poison_objects poison_objects
    test name do
      tenant_id = Ids.new_tenant_id()
      group_id = Ids.new_group_id(tenant_id)
      agent_id = Ids.new_agent_id(group_id)

      authority =
        authority()
        |> Map.put("tenant_id", tenant_id)
        |> Map.put("group_id", group_id)
        |> Map.put("connect_id", Ids.new_connect_id())
        |> Map.put("inbound_agent_id", agent_id)

      group = %{
        "tenant_id" => authority["tenant_id"],
        "group_id" => authority["group_id"],
        "router_agent_id" => authority["inbound_agent_id"],
        "router_conversation_id" => "conv-atlas"
      }

      connect =
        authority
        |> Map.put("bot_token", "xoxb-private")
        |> Map.put("disabled_at", nil)
        |> Map.put("deleted_at", nil)

      assert {:ok, ^group} = CasRecord.create(Keys.ctl_group(authority["group_id"]), group)

      assert {:ok, ^connect} =
               CasRecord.create(
                 Keys.ctl_im_connect(authority["group_id"], authority["connect_id"]),
                 connect
               )

      prefix = Keys.ctl_im_slack_event_receipts_prefix()

      for {suffix, body} <- @poison_objects do
        assert {:ok, _meta} = S3.put(prefix <> suffix, body, if_none_match: "*")
      end

      assert {:ok, :created, receipt} =
               ProviderReceipts.record_slack_triage_root(
                 authority,
                 verified_root(authority, "Ev-recovery-after-#{@label}")
               )

      namespace = "triage-recovery-#{@label}-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      runtime =
        start_supervised!(
          {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: namespace},
          id: SystemsRuntime.Proc.make_ref()
        )

      recovery =
        start_supervised!(
          {SalixIM.Triage.ReceiptRecovery,
           name: nil,
           runtime: runtime,
           page_limit: 1,
           interval_ms: 1,
           full_ring_idle_ms: 5,
           held_poll_ms: 5,
           lease_key:
             "ctl/test/triage-recovery-#{@label}/#{SystemsRuntime.Proc.unique_integer([:positive])}",
           lease_ttl_ms: 5_000},
          id: SystemsRuntime.Proc.make_ref()
        )

      bucket_key =
        SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(receipt))

      assert eventually(fn ->
               match?({:ok, %{"open_receipts" => [^receipt]}}, CasRecord.get(bucket_key))
             end),
             inspect(:sys.get_state(recovery, :infinity))

      assert SystemsRuntime.Proc.alive?(recovery)
    end
  end

  test "a duplicate connect discovered on a later authority page removes every channel authority" do
    connect_id = Ids.new_connect_id()

    identities =
      for _index <- 1..2 do
        tenant_id = Ids.new_tenant_id()
        group_id = Ids.new_group_id(tenant_id)
        agent_id = Ids.new_agent_id(group_id)
        %{tenant_id: tenant_id, group_id: group_id, agent_id: agent_id}
      end

    [first, second] = Enum.sort_by(identities, & &1.group_id)

    for identity <- [first, second] do
      group = %{
        "tenant_id" => identity.tenant_id,
        "group_id" => identity.group_id,
        "router_agent_id" => identity.agent_id,
        "router_conversation_id" => "conv-duplicate-recovery"
      }

      connect =
        authority()
        |> Map.put("tenant_id", identity.tenant_id)
        |> Map.put("group_id", identity.group_id)
        |> Map.put("connect_id", connect_id)
        |> Map.put("inbound_agent_id", identity.agent_id)
        |> Map.put("connect_generation", ULID.generate())
        |> Map.put("bot_token", "xoxb-private")
        |> Map.put("disabled_at", nil)
        |> Map.put("deleted_at", nil)

      assert {:ok, ^group} = CasRecord.create(Keys.ctl_group(identity.group_id), group)

      assert {:ok, ^connect} =
               CasRecord.create(Keys.ctl_im_connect(identity.group_id, connect_id), connect)
    end

    assert {:ok, first_connect} =
             CasRecord.get(Keys.ctl_im_connect(first.group_id, connect_id))

    first_authority = Map.take(first_connect, Map.keys(authority()))

    for index <- 1..999 do
      key =
        Keys.ctl_im_connects_prefix(first.group_id) <>
          "zz-filler-#{String.pad_leading(Integer.to_string(index), 4, "0")}.json"

      assert {:ok, _meta} = S3.put(key, "{}", if_none_match: "*")
    end

    assert {:ok, :created, receipt} =
             ProviderReceipts.record_slack_triage_root(
               first_authority,
               verified_root(first_authority, "Ev-duplicate-connect-across-pages")
             )

    authority_ref = {connect_id, first_authority["approved_channel_id"]}

    assert {:ok, first_page} =
             ProviderConnects.resolve_slack_triage_recovery_authority_refs([authority_ref])

    refute first_page.scan_complete
    assert is_map(first_page.authorities[authority_ref])

    assert {:ok, second_page} =
             ProviderConnects.resolve_slack_triage_recovery_authority_refs(
               [authority_ref],
               first_page.next_cursor
             )

    assert second_page.scan_complete
    assert second_page.seen_connect_ids == [connect_id]

    namespace =
      "triage-recovery-duplicate-connect-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: namespace},
        id: SystemsRuntime.Proc.make_ref()
      )

    recovery =
      start_supervised!(
        {SalixIM.Triage.ReceiptRecovery,
         name: nil,
         runtime: runtime,
         page_limit: 5,
         interval_ms: 25,
         full_ring_idle_ms: 100,
         held_poll_ms: 25,
         lease_key:
           "ctl/test/triage-recovery-duplicate/#{SystemsRuntime.Proc.unique_integer([:positive])}",
         lease_ttl_ms: 5_000},
        id: SystemsRuntime.Proc.make_ref()
      )

    assert eventually(fn ->
             state = :sys.get_state(recovery, :infinity)
             state.phase == :resolve and not is_nil(state.resolution)
           end)

    assert eventually(fn ->
             state = :sys.get_state(recovery, :infinity)
             state.phase == :list and is_nil(state.page) and not is_nil(state.lease)
           end)

    bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(receipt))

    assert CasRecord.get(bucket_key) == {:error, :not_found}
  end

  defp authority do
    %{
      "provider" => "slack",
      "tenant_id" => "tenant-atlas",
      "group_id" => "project-atlas",
      "connect_id" => "connect-atlas",
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_ATLAS",
      "approved_channel_id" => "C_ATLAS",
      "inbound_agent_id" => "agt1_atlas_router",
      "app_id" => "A_BFT",
      "bot_user_id" => "U_BFT",
      "bot_id" => "B_BFT",
      "oauth_completed_at" => 1,
      "triage_enabled" => true
    }
  end

  defp verified_root(authority, event_id \\ "Ev-triage-root") do
    %{
      "provider_event_id" => event_id,
      "callback_app_id" => authority["app_id"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => "1787019000.000001",
      "message_ts" => "1787019000.000001",
      "event_type" => "message",
      "actor_id" => "U_HUMAN",
      "actor_kind" => "human",
      "text" => "please review this update"
    }
  end

  # One durable group + connect pair the recovery ring can resolve a current
  # authority from, with ids unique to the calling test.
  defp seed_recovery_connect! do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)

    authority =
      authority()
      |> Map.put("tenant_id", tenant_id)
      |> Map.put("group_id", group_id)
      |> Map.put("connect_id", Ids.new_connect_id())
      |> Map.put("inbound_agent_id", agent_id)

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "router_agent_id" => agent_id,
      "router_conversation_id" => "conv-atlas"
    }

    connect =
      authority
      |> Map.put("bot_token", "xoxb-private")
      |> Map.put("disabled_at", nil)
      |> Map.put("deleted_at", nil)

    assert {:ok, ^group} = CasRecord.create(Keys.ctl_group(group_id), group)

    assert {:ok, ^connect} =
             CasRecord.create(Keys.ctl_im_connect(group_id, authority["connect_id"]), connect)

    authority
  end

  defp verified_reply(authority, event_id \\ "Ev-triage-reply") do
    authority
    |> verified_root(event_id)
    |> Map.put("message_ts", "1787019000.000002")
    |> Map.put("actor_id", "U_HUMAN_TWO")
    |> Map.put("text", "and the owner is still unclear")
  end

  defp verified_recheck_message(authority) do
    %{
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => "1787019000.000010",
      "message_ts" => "1787019000.000010",
      "actor_id" => "U_PATROL_HUMAN",
      "actor_kind" => "human",
      "text" => "who owns the Atlas login follow-up?"
    }
  end

  defp endpoint_revision!(authority) do
    {:ok, revision} = EndpointRevision.sha256(authority)
    revision
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
