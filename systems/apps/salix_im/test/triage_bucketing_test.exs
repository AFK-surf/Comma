defmodule SalixIM.Triage.BucketingTest do
  use SystemsClock.Case, async: false

  alias SalixIM.Triage.Bucketing
  alias SalixStore.{CasRecord, S3}

  @policy %{debounce_ms: 80, max_wait_ms: 500}
  @thread_ts "1787019000.000000"
  @generation "01JQTRIAGEGENERATION000001"

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_triage_backend = SystemsRuntime.get_env(:salix_store, :triage_record_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, SalixStore.S3)

    if SystemsRuntime.Proc.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    on_exit(fn ->
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
    namespace = "triage-bucketing-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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
