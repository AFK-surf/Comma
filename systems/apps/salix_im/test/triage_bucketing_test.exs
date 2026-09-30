defmodule SalixIM.Triage.BucketingTest do
  use ExUnit.Case, async: false

  alias SalixIM.Triage.Bucketing
  alias SalixStore.{CasRecord, S3}

  @policy %{debounce_ms: 80, max_wait_ms: 500}
  @thread_ts "1787019000.000000"
  @generation "01JQTRIAGEGENERATION000001"

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_triage_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)

    if Process.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    on_exit(fn ->
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

  test "derives one stable scope key per connect generation and thread" do
    assert Bucketing.scope_key(receipt("r1", 100, "1787019000.000001", false)) ==
             "#{@generation}:T_WORKSPACE:C_CHANNEL:#{@thread_ts}"

    assert Bucketing.scope_key(receipt("r2", 100, "1787019000.000002", false)) ==
             Bucketing.scope_key(receipt("r1", 100, "1787019000.000001", false))

    sibling_thread =
      "r3"
      |> receipt(100, "1787019100.000001", false)
      |> put_in(["triage_event", "bucket", "thread_ts"], "1787019100.000000")

    refute Bucketing.scope_key(sibling_thread) ==
             Bucketing.scope_key(receipt("r1", 100, "1787019000.000001", false))
  end

  test "merges the current durable generation into one ordered local bucket" do
    first = receipt("r1", 100, "1787019000.000002", false)
    earlier = receipt("r2", 90, "1787019000.000001", true)

    durable = %{
      "open_generation" => "generation-open",
      "open_first_at" => 100,
      "open_last_at" => 100,
      "open_fast_path" => false,
      "open_receipts" => [first]
    }

    bucket = Bucketing.merge_local(durable, nil, earlier, 90, "local-token")

    assert bucket == %{
             token: "local-token",
             generation: "generation-open",
             first_at: 90,
             last_at: 100,
             fast_path?: true,
             receipts: [earlier, first]
           }

    assert Bucketing.merge_local(durable, bucket, earlier, 90, "unused-token") == bucket
    assert Bucketing.flush_delay(bucket, @policy, 90) == 0
  end

  test "channel scope groups sibling roots while keeping channels and connections separate" do
    first =
      receipt("r1", 100, "1787019000.000001", false)
      |> put_in(["triage_event", "bucket", "scope_kind"], "channel")

    sibling = put_in(first, ["triage_event", "bucket", "thread_ts"], "1787019100.000000")
    assert Bucketing.scope_key(first) == Bucketing.scope_key(sibling)
    refute Bucketing.source_key(first) == Bucketing.source_key(sibling)

    other_channel = put_in(first, ["triage_event", "bucket", "channel_id"], "C_OTHER")
    refute Bucketing.scope_key(first) == Bucketing.scope_key(other_channel)
    other_generation = put_in(first, ["triage_event", "connect_generation"], "another-generation")
    refute Bucketing.scope_key(first) == Bucketing.scope_key(other_generation)
  end

  test "three-minute debounce follows the last receipt without a fixed time cut" do
    server =
      start_supervised!(
        {SalixIM.Triage.Runtime,
         mode: :off,
         name: nil,
         namespace: "triage-default-debounce-#{System.unique_integer([:positive])}"}
      )

    policy = :sys.get_state(server)

    receipts =
      for index <- 0..4 do
        receipt(
          "r#{index}",
          100 + index * 120_000,
          "#{1_787_019_000 + index * 120}.000001",
          false
        )
      end

    bucket = Enum.reduce(receipts, nil, &Bucketing.append_durable(&2, &1, "generation-open"))

    assert Bucketing.durable_due_at(bucket, policy, 480_100) == 660_100

    assert {:unchanged, ^bucket} =
             Bucketing.append_durable(bucket, hd(receipts), "unused-generation")

    assert Bucketing.durable_due_at(bucket, policy, 600_000) == 660_100

    assert {:unchanged, ^bucket} =
             Bucketing.seal_durable(bucket, "generation-open", 660_099, policy, "next")

    sealed = Bucketing.seal_durable(bucket, "generation-open", 660_100, policy, "next")
    assert [%{"receipts" => ^receipts}] = sealed["sealed_generations"]
  end

  test "continuous activity still respects the source reader capacity" do
    policy = %{debounce_ms: 300_000, max_wait_ms: :infinity}
    bucket = %{first_at: 100, last_at: 500, fast_path?: false, receipts: List.duplicate(%{}, 200)}
    assert Bucketing.due_at(bucket, policy, 500) == 500

    assert Bucketing.due_at(%{bucket | receipts: Enum.take(bucket.receipts, 199)}, policy, 500) ==
             300_500
  end

  # Both timestamps come from receipt `created_at`, which is a REMOTE clock. A
  # forward-skewed one pushed `first_at + max_wait_ms` past the ceiling it
  # exists to enforce, so the max-wait guarantee — "no bucket waits longer than
  # max_wait from now" — silently stopped holding.
  test "a forward-skewed receipt clock cannot remove the max-wait ceiling" do
    now = 1_000
    skew = 10_000_000

    skewed = %{
      token: "skew-token",
      generation: "generation-open",
      first_at: now + skew,
      last_at: now + skew,
      fast_path?: false,
      receipts: [receipt("r1", now + skew, "1787019000.000001", false)]
    }

    assert Bucketing.due_at(skewed, @policy, now) == now + @policy.debounce_ms
    assert Bucketing.flush_delay(skewed, @policy, now) <= @policy.max_wait_ms

    durable = %{
      "open_generation" => "generation-open",
      "open_first_at" => now + skew,
      "open_last_at" => now + skew,
      "open_fast_path" => false,
      "open_receipts" => [receipt("r1", now + skew, "1787019000.000001", false)]
    }

    assert Bucketing.durable_due_at(durable, @policy, now) == now + @policy.debounce_ms

    # Ordinary past timestamps are untouched.
    ordinary = %{skewed | first_at: now - 500, last_at: now - 500}
    assert Bucketing.due_at(ordinary, @policy, now) == now - 500 + @policy.debounce_ms
  end

  test "appends once and seals only after the explicit due time" do
    first = receipt("r1", 100, "1787019000.000001", false)
    second = receipt("r2", 120, "1787019000.000002", false)

    current = Bucketing.append_durable(nil, first, "generation-open")
    current = Bucketing.append_durable(current, second, "unused-generation")

    assert {:unchanged, ^current} = Bucketing.append_durable(current, second, "unused-generation")

    assert {:unchanged, ^current} =
             Bucketing.seal_durable(current, "generation-open", 199, @policy, "generation-next")

    sealed =
      Bucketing.seal_durable(current, "generation-open", 200, @policy, "generation-next")

    assert sealed["open_generation"] == "generation-next"
    assert sealed["open_receipts"] == []
    assert sealed["open_first_at"] == nil
    assert sealed["open_last_at"] == nil

    assert [%{"generation" => "generation-open", "receipts" => [^first, ^second]}] =
             sealed["sealed_generations"]

    assert %{"generation" => "generation-open"} =
             Bucketing.sealed_or_wait(sealed, "generation-open", @policy, 200)

    assert Bucketing.sealed_or_wait(sealed, "generation-gone", @policy, 200) == :stale
  end

  test "owns durable append, load, deduplication, and generation seal CAS" do
    namespace = "triage-bucketing-#{System.unique_integer([:positive])}"
    first = receipt("r1", 100, "1787019000.000001", false)
    second = receipt("r2", 120, "1787019000.000002", false)
    scope = Bucketing.scope_key(first)

    assert {:ok, :appended} = Bucketing.append(namespace, first)
    assert {:ok, :appended} = Bucketing.append(namespace, second)

    durable = Bucketing.load!(namespace, scope)

    assert Map.keys(durable) |> Enum.sort() ==
             ~w(bucket_scope open_fast_path open_first_at open_generation open_last_at open_receipts schema sealed_generations)

    assert durable["schema"] == "comma.triage-durable-bucket.v1"
    assert durable["bucket_scope"] == scope
    assert durable["open_receipts"] == [first, second]
    assert durable["sealed_generations"] == []
    generation = durable["open_generation"]

    assert {:ok, {:wait, 1}} = Bucketing.seal(namespace, scope, generation, @policy, 199)

    assert {:ok, %{"generation" => ^generation, "receipts" => [^first, ^second]}} =
             Bucketing.seal(namespace, scope, generation, @policy, 200)

    # A sealed receipt is immutable evidence and never re-enters an open
    # generation, so replaying it settles as a duplicate.
    assert {:ok, :duplicate} = Bucketing.append(namespace, first)

    after_seal = Bucketing.load!(namespace, scope)
    assert after_seal["open_generation"] != generation
    assert after_seal["open_receipts"] == []

    assert [%{"generation" => ^generation, "receipts" => [^first, ^second], "sealed_at" => 200}] =
             after_seal["sealed_generations"]

    assert {:ok, %{"generation" => ^generation, "receipts" => [^first, ^second]}} =
             Bucketing.load_sealed_generation(namespace, scope, generation)

    assert {:error, :not_found} =
             Bucketing.load_sealed_generation(namespace, scope, after_seal["open_generation"])

    # The rotated open generation still accepts new physical roots.
    third = receipt("r3", 300, "1787019000.000003", false)
    assert {:ok, :appended} = Bucketing.append(namespace, third)

    reopened = Bucketing.load!(namespace, scope)
    assert reopened["open_receipts"] == [third]
    assert length(reopened["sealed_generations"]) == 1
  end

  test "owns receipt projection and canonical source admission CAS" do
    namespace = "triage-bucketing-admission-#{System.unique_integer([:positive])}"
    first = receipt("r1", 100, "1787019000.000001", false)

    # A second typed receipt for the exact same physical Slack root: a delayed
    # copy through a peer or rotated connect.
    superseding_copy =
      "r2"
      |> receipt(120, "1787019000.000001", false)
      |> Map.put("event_id", "event-r2")
      |> put_in(["triage_event", "event_id"], "event-r2")

    assert {:ok, :accepted, :canonical} = Bucketing.claim_receipt(namespace, first)
    assert {:ok, :duplicate, :canonical} = Bucketing.claim_receipt(namespace, first)
    assert {:ok, :accepted, :superseded} = Bucketing.claim_receipt(namespace, superseding_copy)

    projection_key =
      SalixStore.TriageKeys.ctl_im_triage_projection_marker(namespace, first["receipt_ref"])

    assert {:ok,
            %{
              "schema" => "comma.triage-receipt-projection.v1",
              "receipt_ref" => "r1",
              "event_id" => "event-r1"
            }} = CasRecord.get(projection_key)

    source_alias_key =
      SalixStore.TriageKeys.ctl_im_triage_source_alias(namespace, Bucketing.source_key(first))

    assert {:ok,
            %{
              "schema" => "comma.triage-source-alias.v1",
              "source_message_ref" => source_ref,
              "canonical_receipt_ref" => "r1"
            }} = CasRecord.get(source_alias_key)

    assert source_ref == first["source_message_ref"]
  end

  test "rejects an invalid receipt before any durable admission effect" do
    namespace = "triage-bucketing-invalid-#{System.unique_integer([:positive])}"
    invalid = Map.delete(receipt("r-invalid", 100, "1787019000.000001", false), "connect_id")

    assert {:error, :invalid_triage_receipt} = Bucketing.claim_receipt(namespace, invalid)
    assert {:error, :invalid_triage_receipt} = Bucketing.append(namespace, invalid)
    assert S3.Fake.put_log() == []
  end

  test "rejects a durable bucket carrying a malformed sealed generation" do
    namespace = "triage-bucketing-sealed-#{System.unique_integer([:positive])}"
    first = receipt("r1", 100, "1787019000.000001", false)
    scope = Bucketing.scope_key(first)

    poisoned = %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope,
      "open_generation" => @generation,
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => [%{"generation" => "g1", "receipts" => []}]
    }

    assert {:ok, ^poisoned} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope),
               poisoned
             )

    assert Bucketing.validate_durable_bucket(poisoned) ==
             {:error, :invalid_triage_bucket}

    assert Bucketing.append(namespace, first) == {:error, :invalid_triage_bucket}

    assert Bucketing.seal(namespace, scope, @generation, @policy, 200) ==
             {:error, :invalid_triage_bucket}
  end

  defp receipt(receipt_ref, created_at, message_ts, fast_path?) do
    addressing_evidence =
      if fast_path? do
        %{
          "event_type" => "app_mention",
          "addressing_kind" => "directed",
          "trigger_kind" => "mention",
          "addressed_connect" => "connect-1"
        }
      else
        %{
          "event_type" => "message",
          "addressing_kind" => "ambient",
          "trigger_kind" => "none"
        }
      end

    %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "receipt_ref" => receipt_ref,
      "connect_id" => "connect-1",
      "connect_generation" => @generation,
      "source_message_ref" => "source:#{message_ts}",
      "event_id" => "event-#{receipt_ref}",
      "created_at" => created_at,
      "triage_event" =>
        Map.merge(
          %{
            "event_id" => "event-#{receipt_ref}",
            "connect_generation" => @generation,
            "message_ts" => message_ts,
            "actor_id" => "U_HUMAN",
            "actor_kind" => "human",
            "text" => "please review #{receipt_ref}",
            "fast_path" => fast_path?,
            "source_mode" => "callback",
            "bucket" => %{
              "workspace_id" => "T_WORKSPACE",
              "channel_id" => "C_CHANNEL",
              "thread_ts" => @thread_ts
            },
            "endpoint_provenance" => %{
              "schema" => "comma.slack-endpoint-provenance.v1",
              "captured_at_ms" => created_at,
              "callback_api_app_id" => "A_BFT",
              "fast_path_bot_user_id" => "U_BFT",
              "endpoint_revision_sha256" => String.duplicate("a", 64)
            }
          },
          addressing_evidence
        )
    }
  end
end
