defmodule SalixIM.SlackTriageReceiptTest do
  use ExUnit.Case, async: false

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

    @impl true
    def get(key, opts) do
      ReceiptReadProbe.begin_get()
      Process.sleep(20)

      try do
        SalixStore.S3.Fake.get(key, opts)
      after
        ReceiptReadProbe.end_get()
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
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_triage_backend = Application.get_env(:salix_store, :triage_record_backend)
    previous_channel_mode = SlackTriageChannelCutover.mode()
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    use_legacy_channel_authority!()

    if Process.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    unless Process.whereis(Ids), do: start_supervised!(Ids)

    on_exit(fn ->
      if previous_channel_mode == :projected do
        enable_projected_channel_authority!()
      end

      if is_nil(previous_backend) do
        Application.delete_env(:salix_store, :s3_backend)
      else
        Application.put_env(:salix_store, :s3_backend, previous_backend)
      end

      if is_nil(previous_triage_backend) do
        Application.delete_env(:salix_store, :triage_record_backend)
      else
        Application.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
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

  test "endpoint revision preserves the reviewed nine-field canonical identity" do
    authority = authority()

    canonical_bytes =
      ~s({"app_id":"A_BFT","bot_user_id":"U_BFT","connect_generation":"#{authority["connect_generation"]}","connect_id":"connect-atlas","group_id":"project-atlas","inbound_agent_id":"agt1_atlas_router","provider":"slack","tenant_id":"tenant-atlas","workspace_id":"T_ATLAS"})

    expected = CanonicalJSON.sha256(canonical_bytes)

    assert EndpointRevision.sha256(authority) == {:ok, expected}

    refute expected =~ authority["approved_channel_id"]
    refute expected =~ "secret"

    assert authority
           |> Map.put("bot_token", "xoxb-secret-must-not-affect-revision")
           |> EndpointRevision.sha256() == {:ok, expected}

    assert authority
           |> Map.delete("app_id")
           |> EndpointRevision.sha256() == {:error, :invalid_slack_endpoint_identity}

    assert ProviderReceipts.record_slack_triage_root(
             Map.put(authority, "triage_enabled", false),
             verified_root(authority)
           ) == {:error, :invalid_slack_triage_root}
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

  test "typed reply receipt is durable, exact-duplicate idempotent, and payload drift conflicts" do
    authority = authority()
    verified_reply = verified_reply(authority)

    assert {:ok, :created, receipt} =
             ProviderReceipts.record_slack_triage_reply(authority, verified_reply)

    assert Map.keys(receipt) |> Enum.sort() ==
             ~w(connect_generation connect_id created_at event_id receipt_ref schema source_message_ref triage_event)

    assert receipt["schema"] == "comma.slack-triage-event-receipt.v2"

    # The bucket keeps the ROOT thread, the event keeps the REPLY message, and
    # the source ref binds both — that pair is the whole reply contract.
    assert receipt["triage_event"] == %{
             "event_id" => verified_reply["provider_event_id"],
             "connect_generation" => authority["connect_generation"],
             "message_ts" => verified_reply["message_ts"],
             "actor_id" => verified_reply["actor_id"],
             "actor_kind" => "human",
             "text" => verified_reply["text"],
             "event_type" => "message",
             "addressing_kind" => "ambient",
             "trigger_kind" => "none",
             "fast_path" => false,
             "bucket" => %{
               "workspace_id" => authority["workspace_id"],
               "channel_id" => authority["approved_channel_id"],
               "thread_ts" => verified_reply["root_thread_ts"]
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

    assert receipt["source_message_ref"] ==
             Enum.join(
               [
                 authority["connect_generation"],
                 authority["workspace_id"],
                 authority["approved_channel_id"],
                 verified_reply["root_thread_ts"],
                 verified_reply["message_ts"]
               ],
               ":"
             )

    assert ProviderReceipts.verify_slack_triage_receipt(authority, receipt) == :ok

    assert {:ok, :duplicate, duplicate} =
             ProviderReceipts.record_slack_triage_reply(authority, verified_reply)

    assert duplicate == receipt

    assert ProviderReceipts.record_slack_triage_reply(
             authority,
             Map.put(verified_reply, "text", "different callback payload")
           ) == {:error, :triage_duplicate_payload_drift}

    key =
      Keys.ctl_im_slack_event_receipt(
        authority["connect_id"],
        verified_reply["provider_event_id"]
      )

    assert CasRecord.get(key) == {:ok, receipt}
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

    namespace = "triage-scheduled-recheck-#{System.unique_integer([:positive])}"

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

    namespace = "triage-reply-receipt-#{System.unique_integer([:positive])}"

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

  test "an explicit @bot reply is recorded as a fast-path receipt" do
    authority = authority()

    mention =
      authority
      |> verified_reply("Ev-triage-reply-mention")
      |> Map.put("event_type", "app_mention")
      |> Map.put("text", "<@#{authority["bot_user_id"]}> please take over")

    assert {:ok, :created, receipt} =
             ProviderReceipts.record_slack_triage_reply(authority, mention)

    assert receipt["triage_event"]["fast_path"]
    assert receipt["triage_event"]["event_type"] == "app_mention"
    assert receipt["triage_event"]["addressing_kind"] == "directed"
    assert receipt["triage_event"]["trigger_kind"] == "mention"
    assert receipt["triage_event"]["addressed_connect"] == authority["connect_id"]

    # An `app_mention` whose rendered text lost the token is still the explicit
    # intent: Slack delivers that callback only to the mentioned app.
    assert {:ok, :created, tokenless} =
             ProviderReceipts.record_slack_triage_reply(
               authority,
               mention
               |> Map.put("provider_event_id", "Ev-triage-reply-tokenless")
               |> Map.put("text", "please take over")
             )

    assert tokenless["triage_event"]["fast_path"]
    assert tokenless["triage_event"]["addressing_kind"] == "directed"
    assert tokenless["triage_event"]["addressed_connect"] == authority["connect_id"]

    message_callback =
      mention
      |> Map.put("provider_event_id", "Ev-mentioned-message-callback")
      |> Map.put("event_type", "message")

    assert {:ok, :created, message_directed} =
             ProviderReceipts.record_slack_triage_reply(authority, message_callback)

    assert message_directed["triage_event"]["event_type"] == "message"
    assert message_directed["triage_event"]["addressing_kind"] == "directed"
    assert message_directed["triage_event"]["trigger_kind"] == "mention"
    assert message_directed["triage_event"]["addressed_connect"] == authority["connect_id"]
    assert message_directed["triage_event"]["fast_path"]

    # An ordinary reply that ends in a question keeps the root's own
    # direct-question fast path.
    assert {:ok, :created, question} =
             ProviderReceipts.record_slack_triage_reply(
               authority,
               authority
               |> verified_reply("Ev-triage-reply-question")
               |> Map.put("text", "谁在跟进？")
             )

    assert question["triage_event"]["fast_path"]
    assert question["triage_event"]["event_type"] == "message"
    assert question["triage_event"]["addressing_kind"] == "ambient"
    assert question["triage_event"]["trigger_kind"] == "question_heuristic"
    refute Map.has_key?(question["triage_event"], "addressed_connect")

    # And an ordinary one is not fast-pathed just for being a reply.
    assert {:ok, :created, ordinary} =
             ProviderReceipts.record_slack_triage_reply(
               authority,
               verified_reply(authority, "Ev-triage-reply-ordinary")
             )

    refute ordinary["triage_event"]["fast_path"]
    assert ordinary["triage_event"]["trigger_kind"] == "none"
  end

  test "an agent question is ambient context while a tokenless app mention is directed" do
    authority = authority()

    agent_question =
      authority
      |> verified_reply("Ev-agent-question-evidence")
      |> Map.put("actor_id", "U_AGENT")
      |> Map.put("actor_kind", "agent")
      |> Map.put("text", "build failed; retry?")

    assert {:ok, :created, ambient} =
             ProviderReceipts.record_slack_triage_reply(authority, agent_question)

    assert ambient["triage_event"]["addressing_kind"] == "ambient"
    assert ambient["triage_event"]["trigger_kind"] == "none"
    refute ambient["triage_event"]["fast_path"]
    refute Map.has_key?(ambient["triage_event"], "addressed_connect")

    directed =
      agent_question
      |> Map.put("provider_event_id", "Ev-agent-directed-evidence")
      |> Map.put("event_type", "app_mention")
      |> Map.put("text", "review this")

    assert {:ok, :created, directed_receipt} =
             ProviderReceipts.record_slack_triage_reply(authority, directed)

    assert directed_receipt["triage_event"]["addressing_kind"] == "directed"
    assert directed_receipt["triage_event"]["trigger_kind"] == "mention"
    assert directed_receipt["triage_event"]["addressed_connect"] == authority["connect_id"]
    assert directed_receipt["triage_event"]["fast_path"]
  end

  test "v2 addressing evidence rejects impossible field combinations" do
    authority = authority()

    mention =
      authority
      |> verified_reply("Ev-invalid-addressing-evidence")
      |> Map.put("event_type", "app_mention")
      |> Map.put("text", "tokenless but directed")

    assert {:ok, :created, receipt} =
             ProviderReceipts.record_slack_triage_reply(authority, mention)

    event = receipt["triage_event"]

    invalid_events = [
      Map.delete(event, "addressed_connect"),
      Map.put(event, "event_type", "message"),
      Map.put(event, "addressing_kind", "ambient"),
      Map.put(event, "trigger_kind", "none"),
      Map.put(event, "fast_path", false),
      event
      |> Map.delete("addressed_connect")
      |> Map.merge(%{
        "addressing_kind" => "ambient",
        "event_type" => "app_mention",
        "trigger_kind" => "none",
        "fast_path" => false
      }),
      event
      |> Map.delete("addressed_connect")
      |> Map.merge(%{
        "actor_kind" => "agent",
        "addressing_kind" => "ambient",
        "event_type" => "message",
        "text" => "retry?",
        "trigger_kind" => "question_heuristic",
        "fast_path" => true
      })
    ]

    for invalid_event <- invalid_events do
      invalid_receipt = Map.put(receipt, "triage_event", invalid_event)

      assert AddressingEvidence.validate_shape_only(invalid_event) ==
               {:error, :invalid_addressing_evidence}

      assert AddressingEvidence.validate(invalid_event, authority["connect_id"]) ==
               {:error, :invalid_addressing_evidence}

      assert ProviderReceipts.verify_slack_triage_receipt(
               authority,
               invalid_receipt
             ) == {:error, :invalid_slack_triage_receipt}

      assert Bucketing.validate_receipt(invalid_receipt) ==
               {:error, :invalid_triage_receipt}
    end

    wrong_recipient = Map.put(event, "addressed_connect", "connect-other")
    wrong_recipient_receipt = Map.put(receipt, "triage_event", wrong_recipient)

    assert AddressingEvidence.validate_shape_only(wrong_recipient) == :ok

    assert AddressingEvidence.validate(wrong_recipient, authority["connect_id"]) ==
             {:error, :invalid_addressing_evidence}

    assert ProviderReceipts.verify_slack_triage_receipt(authority, wrong_recipient_receipt) ==
             {:error, :invalid_slack_triage_receipt}

    assert Bucketing.validate_receipt(wrong_recipient_receipt) ==
             {:error, :invalid_triage_receipt}
  end

  test "root and reply shapes are not interchangeable" do
    authority = authority()

    # A root's identity (message_ts == root_thread_ts) is not a reply.
    assert ProviderReceipts.record_slack_triage_reply(authority, verified_root(authority)) ==
             {:error, :invalid_slack_triage_reply}

    # A reply's identity (message_ts inside the thread) is not a root.
    assert ProviderReceipts.record_slack_triage_root(authority, verified_reply(authority)) ==
             {:error, :invalid_slack_triage_root}

    for invalid <- [
          Map.put(verified_reply(authority), "message_ts", "not-a-slack-ts"),
          Map.put(verified_reply(authority), "root_thread_ts", "not-a-slack-ts"),
          Map.put(verified_reply(authority), "text", ""),
          Map.put(verified_reply(authority), "actor_id", ""),
          Map.put(verified_reply(authority), "event_type", "member_joined_channel"),
          Map.put(verified_reply(authority), "channel_id", "C_OTHER"),
          Map.put(verified_reply(authority), "callback_app_id", "A_OTHER"),
          Map.put(verified_reply(authority), "workspace_id", "T_OTHER"),
          Map.delete(verified_reply(authority), "text"),
          Map.put(verified_reply(authority), "extra_key", "nope")
        ] do
      assert ProviderReceipts.record_slack_triage_reply(authority, invalid) ==
               {:error, :invalid_slack_triage_reply}
    end

    assert ProviderReceipts.record_slack_triage_reply(
             Map.put(authority, "triage_enabled", false),
             verified_reply(authority)
           ) == {:error, :invalid_slack_triage_reply}

    assert ProviderReceipts.record_slack_triage_reply(authority, "not-a-map") ==
             {:error, :invalid_slack_triage_reply}
  end

  test "legacy conflicts and ambiguous receipt writes converge without delete or overwrite" do
    authority = authority()
    legacy_root = verified_root(authority, "Ev-legacy-conflict")

    assert ProviderReceipts.record_slack(
             authority["connect_id"],
             legacy_root["provider_event_id"]
           ) ==
             {:ok, true}

    assert ProviderReceipts.record_slack_triage_root(authority, legacy_root) ==
             {:error, :receipt_type_conflict}

    ambiguous_root = verified_root(authority, "Ev-ambiguous-after")

    ambiguous_key =
      Keys.ctl_im_slack_event_receipt(
        authority["connect_id"],
        ambiguous_root["provider_event_id"]
      )

    :ok = S3.Fake.set_fault({:ambiguous_after, :put, ambiguous_key})

    assert {:ok, :created, ambiguous_receipt} =
             ProviderReceipts.record_slack_triage_root(authority, ambiguous_root)

    assert CasRecord.get(ambiguous_key) == {:ok, ambiguous_receipt}
  end

  test "global recovery page advances past legacy malformed and unavailable objects" do
    authority = authority()

    assert {:ok, :created, healthy} =
             ProviderReceipts.record_slack_triage_root(
               authority,
               verified_root(authority, "Ev-page-healthy")
             )

    assert {:ok, true} = ProviderReceipts.record_slack(authority["connect_id"], "Ev-page-legacy")

    malformed_event_id = "Ev-page-malformed"
    malformed_key = Keys.ctl_im_slack_event_receipt(authority["connect_id"], malformed_event_id)

    malformed =
      healthy
      |> Map.put("event_id", malformed_event_id)
      |> Map.put("receipt_ref", "s3://" <> malformed_key)
      |> put_in(["triage_event", "event_id"], malformed_event_id)
      |> Map.put("unexpected", "private")

    assert {:ok, ^malformed} = CasRecord.create(malformed_key, malformed)

    assert {:ok, :created, unavailable} =
             ProviderReceipts.record_slack_triage_root(
               authority,
               verified_root(authority, "Ev-page-unavailable")
             )

    unavailable_key =
      Keys.ctl_im_slack_event_receipt(authority["connect_id"], unavailable["event_id"])

    assert :ok = S3.Fake.set_fault({:fail, 503, :get, unavailable_key})

    assert {:ok, page} = ProviderReceipts.list_slack_triage_page(:all, nil, 25)
    assert page.receipts == [healthy]
    assert page.connect_ids == [authority["connect_id"]]
    assert page.scanned_count == 4
    assert page.legacy_count == 1
    assert page.invalid_count == 1
    assert page.unavailable_count == 1
    assert page.scan_complete
    assert page.next_cursor == nil

    assert {:ok, next_ring} = ProviderReceipts.list_slack_triage_page(:all, nil, 25)

    assert Enum.sort(Enum.map(next_ring.receipts, & &1["event_id"])) ==
             Enum.sort([healthy["event_id"], unavailable["event_id"]])
  end

  test "bounded receipt pages hydrate remote records concurrently" do
    authority = authority()

    for index <- 1..8 do
      assert {:ok, :created, _receipt} =
               ProviderReceipts.record_slack_triage_root(
                 authority,
                 verified_root(authority, "Ev-concurrent-page-#{index}")
               )
    end

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    start_supervised!(ReceiptReadProbe)
    ReceiptReadProbe.reset()
    Application.put_env(:salix_store, :s3_backend, InstrumentedReceiptS3)

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    assert {:ok, page} = ProviderReceipts.list_slack_triage_page(:all, nil, 25)
    assert length(page.receipts) == 8
    assert ReceiptReadProbe.snapshot().max_active == 8
  end

  test "opaque cursor advances past an invalid raw key to a healthy later page" do
    prefix = Keys.ctl_im_slack_event_receipts_prefix()
    invalid_key = prefix <> "!invalid-key"

    assert {:ok, _meta} =
             S3.put(invalid_key, Jason.encode!(%{"raw" => "poison"}), if_none_match: "*")

    authority = authority()

    assert {:ok, :created, healthy} =
             ProviderReceipts.record_slack_triage_root(
               authority,
               verified_root(authority, "Ev-after-invalid-key")
             )

    assert {:ok, first} = ProviderReceipts.list_slack_triage_page(:all, nil, 1)
    assert first.receipts == []
    assert first.invalid_count == 1
    assert first.scanned_count == 1
    refute first.scan_complete
    assert is_binary(first.next_cursor)

    assert {:ok, second} =
             ProviderReceipts.list_slack_triage_page(:all, first.next_cursor, 1)

    assert second.receipts == [healthy]
    assert second.invalid_count == 0
    assert second.scan_complete
    assert second.next_cursor == nil
  end

  test "a folder marker and a trailing-space key are counted without pinning the page" do
    prefix = Keys.ctl_im_slack_event_receipts_prefix()

    assert {:ok, _marker} = S3.put(prefix, "", if_none_match: "*")

    assert {:ok, _poison} =
             S3.put(prefix <> "!poison ", Jason.encode!(%{"raw" => "poison"}), if_none_match: "*")

    authority = authority()

    assert {:ok, :created, healthy} =
             ProviderReceipts.record_slack_triage_root(
               authority,
               verified_root(authority, "Ev-after-poison-keys")
             )

    assert {:ok, page} = ProviderReceipts.list_slack_triage_page(:all, nil, 25)
    assert page.receipts == [healthy]
    assert page.scanned_count == 3
    assert page.invalid_count == 2
    assert page.scan_complete
    assert page.next_cursor == nil
  end

  test "the opaque cursor advances through a folder marker and a trailing-space key" do
    prefix = Keys.ctl_im_slack_event_receipts_prefix()

    assert {:ok, _marker} = S3.put(prefix, "", if_none_match: "*")

    assert {:ok, _poison} =
             S3.put(prefix <> "!poison ", Jason.encode!(%{"raw" => "poison"}), if_none_match: "*")

    authority = authority()

    assert {:ok, :created, healthy} =
             ProviderReceipts.record_slack_triage_root(
               authority,
               verified_root(authority, "Ev-after-poison-cursor")
             )

    assert {:ok, first} = ProviderReceipts.list_slack_triage_page(:all, nil, 1)
    assert first.receipts == []
    assert first.invalid_count == 1
    refute first.scan_complete
    assert is_binary(first.next_cursor)

    assert {:ok, second} = ProviderReceipts.list_slack_triage_page(:all, first.next_cursor, 1)
    assert second.receipts == []
    assert second.invalid_count == 1
    refute second.scan_complete
    assert is_binary(second.next_cursor)

    assert {:ok, third} = ProviderReceipts.list_slack_triage_page(:all, second.next_cursor, 1)
    assert third.receipts == [healthy]
    assert third.invalid_count == 0
    assert third.scan_complete
    assert third.next_cursor == nil
  end

  test "authority resolution continues beyond the first thousand connect records" do
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

    assert ProviderConnects.get_slack_triage_authority(
             authority["tenant_id"],
             authority["group_id"],
             authority["connect_id"]
           ) == {:ok, authority}

    Enum.each(1..1_000, fn index ->
      id = String.pad_leading(Integer.to_string(index), 4, "0")
      connect_id = "dummy-connect-#{id}"
      group_id = "0000-dummy-group-#{id}"

      assert {:ok, _record} =
               CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
                 "provider" => "slack",
                 "group_id" => group_id,
                 "connect_id" => connect_id
               })
    end)

    assert {:ok, first} =
             ProviderConnects.resolve_slack_triage_recovery_authorities([
               authority["connect_id"]
             ])

    assert first.authorities == %{}
    assert first.seen_connect_ids == []
    refute first.scan_complete
    assert is_binary(first.next_cursor)

    assert {:ok, second} =
             ProviderConnects.resolve_slack_triage_recovery_authorities(
               [authority["connect_id"]],
               first.next_cursor
             )

    assert second.authorities == %{authority["connect_id"] => authority}
    assert second.seen_connect_ids == [authority["connect_id"]]
    assert second.unavailable_connect_ids == []
    assert second.scan_complete
    assert second.next_cursor == nil
  end

  test "authority resolution skips poison keys under the connect prefix" do
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

    prefix = Keys.ctl_im_connects_all_prefix()

    assert {:ok, _meta} = S3.put(prefix, "{}", if_none_match: "*")

    assert {:ok, _meta} =
             S3.put(prefix <> "!poison ", Jason.encode!(%{"raw" => "poison"}), if_none_match: "*")

    assert {:ok, page} =
             ProviderConnects.resolve_slack_triage_recovery_authorities([
               authority["connect_id"]
             ])

    assert page.authorities == %{authority["connect_id"] => authority}
    assert page.seen_connect_ids == [authority["connect_id"]]
    assert page.unavailable_connect_ids == []
    assert page.scan_complete
  end

  test "an empty typed receipt page resolves without scanning connect authority" do
    assert ProviderConnects.resolve_slack_triage_recovery_authorities([]) ==
             {:ok,
              %{
                authorities: %{},
                seen_connect_ids: [],
                unavailable_connect_ids: [],
                next_cursor: nil,
                scan_complete: true
              }}

    refute Enum.any?(S3.Fake.read_log(), fn
             {:list, prefix, _opts} -> prefix == Keys.ctl_im_connects_all_prefix()
             _other -> false
           end)
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

    namespace = "triage-recovery-reply-#{System.unique_integer([:positive])}"

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: namespace},
        id: make_ref()
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
         lease_key: "ctl/test/triage-recovery-reply/#{System.unique_integer([:positive])}",
         lease_ttl_ms: 5_000},
        id: make_ref()
      )

    assert eventually(fn ->
             match?({:ok, %{"open_receipts" => [^root, ^reply]}}, CasRecord.get(bucket_key))
           end),
           inspect(:sys.get_state(recovery))

    assert Process.alive?(recovery)
  end

  test "v1 receipts recover as human v2 evidence into the fresh namespace" do
    authority = seed_recovery_connect!()

    assert {:ok, :created, v2} =
             ProviderReceipts.record_slack_triage_root(
               authority,
               verified_root(authority, "Ev-v1-rolling-recovery")
             )

    v1 =
      v2
      |> Map.put("schema", "comma.slack-triage-event-receipt.v1")
      |> update_in(["triage_event"], fn event ->
        Map.drop(
          event,
          ~w(actor_kind event_type addressing_kind trigger_kind addressed_connect)
        )
      end)

    assert :ok = ProviderReceipts.delete_slack(v1["connect_id"], v1["event_id"])

    receipt_key = Keys.ctl_im_slack_event_receipt(v1["connect_id"], v1["event_id"])
    assert {:ok, ^v1} = CasRecord.create(receipt_key, v1)

    assert {:ok, normalized} = ProviderReceipts.normalize_slack_triage_receipt(v1)
    assert normalized["schema"] == "comma.slack-triage-event-receipt.v2"
    assert normalized["triage_event"]["actor_kind"] == "human"
    assert normalized["triage_event"]["event_type"] == "message"
    assert normalized["triage_event"]["addressing_kind"] == "ambient"
    assert normalized["triage_event"]["trigger_kind"] == "none"
    refute Map.has_key?(normalized["triage_event"], "addressed_connect")
    assert ProviderReceipts.verify_slack_triage_receipt(authority, v1) == :ok
    assert Bucketing.validate_receipt(v1) == :ok

    assert {:ok, :duplicate, ^normalized} =
             ProviderReceipts.record_slack_triage_root(
               authority,
               verified_root(authority, "Ev-v1-rolling-recovery")
             )

    assert {:error, :triage_duplicate_payload_drift} =
             ProviderReceipts.record_slack_triage_root(
               authority,
               authority
               |> verified_root("Ev-v1-rolling-recovery")
               |> Map.put("text", "different historical bytes")
             )

    question_v1 =
      v1
      |> put_in(["triage_event", "text"], "who owns this?")
      |> put_in(["triage_event", "fast_path"], true)

    assert {:ok, normalized_question} =
             ProviderReceipts.normalize_slack_triage_receipt(question_v1)

    assert normalized_question["triage_event"]["addressing_kind"] == "ambient"
    assert normalized_question["triage_event"]["trigger_kind"] == "question_heuristic"
    refute Map.has_key?(normalized_question["triage_event"], "addressed_connect")

    assert ProviderReceipts.normalize_slack_triage_receipt(
             put_in(question_v1, ["triage_event", "text"], "not actually a question")
           ) == {:error, :invalid_slack_triage_receipt}

    namespace = "triage-rolling-#{System.unique_integer([:positive])}"

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: namespace},
        id: make_ref()
      )

    recovery =
      start_supervised!(
        {SalixIM.Triage.ReceiptRecovery,
         name: nil,
         runtime: runtime,
         page_limit: 5,
         interval_ms: 1,
         full_ring_idle_ms: 5,
         held_poll_ms: 5,
         lease_key: "ctl/test/triage-v1-recovery/#{System.unique_integer([:positive])}",
         lease_ttl_ms: 5_000},
        id: make_ref()
      )

    bucket_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(normalized))

    assert eventually(fn ->
             case CasRecord.get(bucket_key) do
               {:ok,
                %{
                  "open_receipts" => [
                    %{"schema" => "comma.slack-triage-event-receipt.v2"}
                  ]
                }} ->
                 true

               _other ->
                 false
             end
           end),
           inspect(:sys.get_state(recovery))

    assert Process.alive?(recovery)
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

      namespace = "triage-recovery-#{@label}-#{System.unique_integer([:positive])}"

      runtime =
        start_supervised!(
          {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: namespace},
          id: make_ref()
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
           lease_key: "ctl/test/triage-recovery-#{@label}/#{System.unique_integer([:positive])}",
           lease_ttl_ms: 5_000},
          id: make_ref()
        )

      bucket_key =
        SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(receipt))

      assert eventually(fn ->
               match?({:ok, %{"open_receipts" => [^receipt]}}, CasRecord.get(bucket_key))
             end),
             inspect(:sys.get_state(recovery))

      assert Process.alive?(recovery)
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

    namespace = "triage-recovery-duplicate-connect-#{System.unique_integer([:positive])}"

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime, name: nil, mode: :review, namespace: namespace},
        id: make_ref()
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
         lease_key: "ctl/test/triage-recovery-duplicate/#{System.unique_integer([:positive])}",
         lease_ttl_ms: 5_000},
        id: make_ref()
      )

    assert eventually(fn ->
             state = :sys.get_state(recovery)
             state.phase == :resolve and not is_nil(state.resolution)
           end)

    assert eventually(fn ->
             state = :sys.get_state(recovery)
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

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
