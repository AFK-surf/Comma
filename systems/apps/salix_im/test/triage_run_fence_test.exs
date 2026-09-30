defmodule SalixIM.Triage.RunFenceTest do
  use ExUnit.Case, async: false

  alias SalixIM.Triage.RunFence
  alias SalixStore.{CasRecord, S3, ULID}

  setup do
    previous_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    S3.Fake.reset()

    on_exit(fn ->
      if previous_backend do
        Application.put_env(:salix_store, :triage_record_backend, previous_backend)
      else
        Application.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    :ok
  end

  test "accepts only the exact protocol conversions of the bounded read-tool disclosure" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "tool" => %{"type" => "string", "enum" => ["web.read_pages"]},
        "params" => %{"type" => "object"}
      },
      "required" => ["tool", "params"]
    }

    internal = %{
      "name" => "call",
      "description" => "bounded read",
      "input_schema" => schema,
      "auto_wait_timeout_seconds" => 30
    }

    chat = %{
      "type" => "function",
      "function" => %{
        "name" => "call",
        "description" => "bounded read",
        "parameters" => schema
      }
    }

    responses = %{
      "type" => "function",
      "name" => "call",
      "description" => "bounded read",
      "parameters" => schema
    }

    anthropic = %{
      "name" => "call",
      "description" => "bounded read",
      "input_schema" => schema
    }

    assert RunFence.valid_read_tool_disclosure?([internal])
    assert RunFence.valid_read_tool_disclosure?([chat])
    assert RunFence.valid_read_tool_disclosure?([responses])
    assert RunFence.valid_read_tool_disclosure?([anthropic])

    refute RunFence.valid_read_tool_disclosure?([
             put_in(chat, ["function", "name"], "web.read_pages")
           ])

    refute RunFence.valid_read_tool_disclosure?([
             put_in(responses, ["parameters", "required"], ["tool"])
           ])

    refute RunFence.valid_read_tool_disclosure?([Map.put(anthropic, "extra", true)])
  end

  test "owns the identity fence key, initial bytes, and create-once CAS" do
    namespace = "triage-run-fence-#{System.unique_integer([:positive])}"
    scope = "generation:T_WORKSPACE:C_CHANNEL:__channel__"
    generation = ULID.generate()
    run_id = ULID.generate()

    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "generation" => generation,
      "events" => [
        %{
          "actor_kind" => "human",
          "event_type" => "message",
          "addressing_kind" => "ambient",
          "trigger_kind" => "none",
          "fast_path" => false
        }
      ],
      "receipt_refs" => ["private-receipt-ref"],
      "source_authority" => %{
        "connect_id" => "private-connect",
        "connect_generation" => "private-generation",
        "workspace_id" => "T_WORKSPACE",
        "channel_id" => "C_CHANNEL",
        "thread_ts" => "__channel__",
        "scope_kind" => "channel"
      },
      "source_mode" => "callback"
    }

    assert {:ok, {:won, created}} =
             RunFence.create(namespace, scope, run_id, input, 1_000, 2_000)

    assert created.identity? == true
    assert created.record["schema"] == "comma.triage-bucket-fence.v2"
    assert created.record["bucket_scope"] == scope
    assert created.record["generation"] == generation
    assert created.record["run_id"] == run_id
    assert created.record["created_at"] == 1_000
    assert created.record["deadline_at"] == 2_000
    assert created.record["input_snapshot"] == RunFence.base_projection(input)

    assert created.record["identity_observation"] == %{
             "schema" => "comma.triage-identity-observation.v1",
             "state" => "unused"
           }

    record = created.record
    assert {:ok, ^record} = CasRecord.get(created.key)
    assert {:identity, :open} = RunFence.recovery_view(record)

    pending = %{
      fence_key: created.key,
      fence_ref_sha256: sha256(created.key),
      generation: generation,
      run_id: run_id
    }

    assert {:ok, interrupted_key, ^record} = RunFence.lookup_interrupted(namespace, pending)
    assert interrupted_key == created.key

    assert {:error, :identity_diagnostic_invalid_fence} ==
             RunFence.lookup_interrupted(
               namespace,
               %{pending | fence_ref_sha256: String.duplicate("0", 64)}
             )

    assert {:ok, :lost} =
             RunFence.create(namespace, scope, run_id, input, 1_000, 2_000)

    assert {:ok, :lost} =
             RunFence.create(namespace, scope, ULID.generate(), input, 1_000, 2_000)
  end

  test "owns legacy frozen-input binding CAS" do
    namespace = "triage-run-fence-legacy-bind-#{System.unique_integer([:positive])}"
    scope = "legacy-scope"
    generation = ULID.generate()
    run_id = ULID.generate()
    now = System.system_time(:millisecond)

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "generation" => generation,
      "events" => [],
      "receipt_refs" => [],
      "source_authority" => %{}
    }

    model_input = %{
      "schema" => "comma.triage-model-input.v1",
      "snapshot" => %{"schema" => "comma.triage-context-snapshot.v1"},
      "canonical_snapshot_bytes" => "{}",
      "canonical_snapshot_sha256" => String.duplicate("a", 64),
      "source_refs" => [],
      "source_refs_canonical_bytes" => "[]",
      "source_refs_sha256" => String.duplicate("b", 64)
    }

    assert {:ok, {:won, created}} =
             RunFence.create(namespace, scope, run_id, input, now, now + 60_000)

    assert {:legacy, :open} = RunFence.recovery_view(created.record)

    assert :ok = RunFence.bind_compatibility_snapshot(created.key, input, model_input)

    assert {:ok, %{"input_snapshot" => ^model_input, "terminal" => nil}} =
             CasRecord.get(created.key)
  end

  test "ledger projection preserves why an event triggered, not only its fast-path bit" do
    base = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "generation" => ULID.generate(),
      "receipt_refs" => ["private-receipt-ref"],
      "source_authority" => %{
        "workspace_id" => "T_WORKSPACE",
        "channel_id" => "C_CHANNEL",
        "thread_ts" => "200.000001"
      },
      "source_mode" => "callback"
    }

    ambient_event = %{
      "actor_kind" => "human",
      "event_type" => "message",
      "addressing_kind" => "ambient",
      "trigger_kind" => "question_heuristic",
      "fast_path" => true
    }

    directed_event = %{
      ambient_event
      | "event_type" => "app_mention",
        "addressing_kind" => "directed",
        "trigger_kind" => "mention"
    }

    ambient = RunFence.base_projection(Map.put(base, "events", [ambient_event]))
    directed = RunFence.base_projection(Map.put(base, "events", [directed_event]))

    assert ambient["schema"] == "comma.triage-ledger-input-projection.v2"
    assert get_in(ambient, ["events", Access.at(0), "addressing_kind"]) == "ambient"
    assert get_in(ambient, ["events", Access.at(0), "trigger_kind"]) == "question_heuristic"
    refute Map.has_key?(hd(ambient["events"]), "addressed_recipient_ref")

    assert get_in(directed, ["events", Access.at(0), "addressing_kind"]) == "directed"
    assert get_in(directed, ["events", Access.at(0), "trigger_kind"]) == "mention"

    assert get_in(directed, ["events", Access.at(0), "addressed_recipient_ref"]) ==
             "endpoint://run/self"

    refute ambient == directed

    invalid_fence = %{
      "schema" => "comma.triage-bucket-fence.v2",
      "bucket_scope" => "scope",
      "public_bucket_ref" => "bucket://run/scope",
      "generation" => base["generation"],
      "run_id" => ULID.generate(),
      "created_at" => 1,
      "deadline_at" => 2,
      "input_snapshot" =>
        directed
        |> put_in(["events", Access.at(0), "addressing_kind"], "ambient"),
      "identity_observation" => %{
        "schema" => "comma.triage-identity-observation.v1",
        "state" => "unused"
      },
      "terminal" => nil
    }

    assert RunFence.recovery_view(invalid_fence) == :invalid
  end

  test "legacy v1 ledger projections remain strict read-only recovery inputs" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "generation" => ULID.generate(),
      "events" => [
        %{
          "actor_kind" => "agent",
          "event_type" => "app_mention",
          "addressing_kind" => "directed",
          "trigger_kind" => "mention",
          "fast_path" => true
        }
      ],
      "receipt_refs" => ["private-receipt-ref"],
      "source_authority" => %{
        "workspace_id" => "T_WORKSPACE",
        "channel_id" => "C_CHANNEL",
        "thread_ts" => "200.000001"
      },
      "source_mode" => "callback"
    }

    assert {:ok, {:won, created}} =
             RunFence.create(
               "legacy-projection-#{System.unique_integer([:positive])}",
               "scope",
               ULID.generate(),
               input,
               1,
               2
             )

    legacy_projection = %{
      RunFence.base_projection(input)
      | "schema" => "comma.triage-ledger-input-projection.v1",
        "events" => [
          %{"event_ref" => "event://run/e001", "ordinal" => 1, "fast_path" => true}
        ]
    }

    legacy_fence = put_in(created.record, ["input_snapshot"], legacy_projection)

    assert RunFence.recovery_view(legacy_fence) == {:identity, :open}
    assert RunFence.validate_chain(legacy_fence, input) == :ok
    refute RunFence.base_projection(input)["schema"] == legacy_projection["schema"]
  end

  test "owns expired identity recovery CAS and its stage-derived terminal" do
    namespace = "triage-run-fence-recovery-#{System.unique_integer([:positive])}"
    generation = ULID.generate()
    run_id = ULID.generate()
    receipt = identity_receipt()
    scope = "generation-7:T_WORKSPACE:C_CHANNEL:200.000001"
    now = System.system_time(:millisecond)

    bucket = %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope,
      "open_generation" => ULID.generate(),
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => [
        %{"generation" => generation, "receipts" => [receipt], "sealed_at" => now}
      ]
    }

    assert {:ok, ^bucket} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope),
               bucket
             )

    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "generation" => generation,
      "events" => [receipt["triage_event"]],
      "receipt_refs" => [receipt["receipt_ref"]],
      "source_authority" => %{
        "connect_id" => receipt["connect_id"],
        "connect_generation" => "generation-7",
        "workspace_id" => "T_WORKSPACE",
        "channel_id" => "C_CHANNEL",
        "thread_ts" => "200.000001"
      },
      "source_mode" => "historical_thread_reenactment"
    }

    assert {:ok, {:won, created}} =
             RunFence.create(namespace, scope, run_id, input, now - 2_000, now - 1_000)

    assert {:ok, recovered} = RunFence.recover_open(namespace, created.record, :deadline)

    assert recovered["identity_observation"]["state"] == "unused"
    assert recovered["terminal"]["status"] == "failed"

    assert recovered["terminal"]["decision"] == %{
             "action" => "silence",
             "reason" => "identity_diagnostic_interrupted_before_transport"
           }

    assert recovered["terminal"]["evaluator"] == %{}
    assert ULID.valid?(recovered["terminal"]["terminal_id"])
    assert {:ok, ^recovered} = CasRecord.get(created.key)
  end

  test "owns active terminal CAS and returns the durable winner" do
    namespace = "triage-run-fence-terminal-#{System.unique_integer([:positive])}"
    scope = "legacy-scope"
    generation = ULID.generate()
    run_id = ULID.generate()
    now = System.system_time(:millisecond)

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "generation" => generation,
      "events" => [],
      "receipt_refs" => [],
      "source_authority" => %{}
    }

    assert {:ok, {:won, created}} =
             RunFence.create(namespace, scope, run_id, input, now, now + 60_000)

    active = %{fence_key: created.key, generation: generation, run_id: run_id}

    requested = %{
      "status" => "failed",
      "decision" => %{
        "action" => "silence",
        "reason" => "identity_diagnostic_internal_error"
      },
      "evaluator" => %{},
      "settled_at" => now
    }

    assert {:ok, first} = RunFence.terminalize(scope, active, requested, :result)
    assert first.outcome == :requested
    assert first.fence["terminal"]["status"] == "failed"
    assert first.fence["terminal"]["decision"] == requested["decision"]
    assert ULID.valid?(first.fence["terminal"]["terminal_id"])

    competing = put_in(requested, ["decision", "reason"], "transport_error")

    assert {:ok, second} = RunFence.terminalize(scope, active, competing, :result)
    assert second.outcome == :existing
    assert second.fence == first.fence
    assert {:ok, first.fence} == CasRecord.get(created.key)
  end

  test "owns physical generation existence lookup" do
    namespace = "triage-run-fence-status-#{System.unique_integer([:positive])}"
    scope = "generation:T_WORKSPACE:C_CHANNEL:__channel__"
    generation = ULID.generate()
    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

    assert :missing = RunFence.generation_status(namespace, scope, generation)
    assert {:ok, %{}} = CasRecord.create(fence_key, %{})
    assert :present = RunFence.generation_status(namespace, scope, generation)
  end

  defp identity_receipt do
    created_at = System.system_time(:millisecond)

    %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "receipt_ref" => "s3://receipt/run-fence-recovery-r001",
      "connect_id" => "connect-atlas",
      "connect_generation" => "generation-7",
      "created_at" => created_at,
      "event_id" => "event-run-fence-recovery",
      "source_message_ref" => "generation-7:T_WORKSPACE:C_CHANNEL:200.000001:200.000001",
      "triage_event" => %{
        "event_id" => "event-run-fence-recovery",
        "connect_generation" => "generation-7",
        "message_ts" => "200.000001",
        "actor_id" => "U_PENG",
        "actor_kind" => "human",
        "text" => "Who are you?",
        "event_type" => "message",
        "addressing_kind" => "ambient",
        "trigger_kind" => "question_heuristic",
        "fast_path" => true,
        "bucket" => %{
          "workspace_id" => "T_WORKSPACE",
          "channel_id" => "C_CHANNEL",
          "thread_ts" => "200.000001"
        },
        "endpoint_provenance" => %{
          "schema" => "comma.slack-endpoint-provenance.v1",
          "captured_at_ms" => created_at,
          "callback_api_app_id" => "A_BFT",
          "fast_path_bot_user_id" => "U_BFT",
          "endpoint_revision_sha256" => String.duplicate("a", 64)
        },
        "source_mode" => "historical_thread_reenactment"
      }
    }
  end

  defp sha256(value),
    do:
      value |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
