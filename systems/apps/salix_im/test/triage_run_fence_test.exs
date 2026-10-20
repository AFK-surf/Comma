defmodule SalixIM.Triage.RunFenceTest do
  use SystemsClock.Case, async: false

  alias SalixIM.Triage.RunFence
  alias SalixStore.{CasRecord, S3, ULID}

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :triage_record_backend)
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    S3.Fake.reset()

    on_exit(fn ->
      if previous_backend do
        SystemsRuntime.put_env(:salix_store, :triage_record_backend, previous_backend)
      else
        SystemsRuntime.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    :ok
  end

  test "owns the identity fence key, initial bytes, and create-once CAS" do
    namespace = "triage-run-fence-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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

  test "owns active terminal CAS and returns the durable winner" do
    namespace = "triage-run-fence-terminal-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    scope = "legacy-scope"
    generation = ULID.generate()
    run_id = ULID.generate()
    now = SystemsClock.system_time(:millisecond)

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

  describe "release before transport" do
    test "an unused run is released and the next run replaces it under a new epoch" do
      {namespace, scope, generation, input, created, active} = open_identity_fence!()

      assert {:ok, released} = RunFence.release(active)
      assert RunFence.released?(released)
      assert released["identity_observation"]["released_from"] == "unused"
      assert released["terminal"] == nil
      assert RunFence.recovery_view(released) == {:identity, :released}
      assert RunFence.generation_status(namespace, scope, generation) == :released

      next_run_id = ULID.generate()
      now = SystemsClock.system_time(:millisecond)

      assert {:ok, {:won, replaced}} =
               RunFence.create(namespace, scope, next_run_id, input, now, now + 60_000)

      assert replaced.key == created.key
      assert replaced.record["run_id"] == next_run_id
      assert RunFence.fence_epoch(replaced.record) == 2
      assert replaced.record["identity_observation"]["state"] == "unused"
      assert {:ok, replaced.record} == CasRecord.get(created.key)
      assert RunFence.generation_status(namespace, scope, generation) == :present

      # Exactly one run owns the generation: a racing replacement loses.
      assert {:ok, :lost} =
               RunFence.create(namespace, scope, ULID.generate(), input, now, now + 60_000)
    end

    test "late writes from a released run are rejected before and after replacement" do
      {namespace, scope, _generation, input, created, active} = open_identity_fence!()

      assert :ok = RunFence.transition(active, :claim, source_claim())
      assert {:ok, released} = RunFence.release(active)
      assert released["identity_observation"]["released_from"] == "claimed"

      # The released record still names this run and epoch.
      assert {:error, :identity_fence_denied} = RunFence.transition(active, :mark_transport, nil)

      assert {:error, :identity_fence_released} =
               RunFence.terminalize(scope, active, failed_terminal(), :result)

      assert {:error, _reason} =
               RunFence.prepare_terminal_commit(
                 namespace,
                 scope,
                 active,
                 failed_terminal(),
                 :result
               )

      assert {:error, _reason} = RunFence.recover_open(namespace, released, :interrupted_worker)
      assert {:ok, released} == CasRecord.get(created.key)

      now = SystemsClock.system_time(:millisecond)

      assert {:ok, {:won, replaced}} =
               RunFence.create(namespace, scope, ULID.generate(), input, now, now + 60_000)

      # Against the replacement, the old run id and epoch are stale.
      assert {:error, :identity_fence_denied} =
               RunFence.transition(active, :claim, source_claim())

      assert {:error, :identity_diagnostic_invalid_fence} =
               RunFence.terminalize(scope, active, failed_terminal(), :result)

      assert {:error, :identity_fence_not_releasable} = RunFence.release(active)

      # A writer that knows the new run id but holds the old epoch is also stale.
      stale_epoch = %{active | run_id: replaced.record["run_id"]}

      assert {:error, :identity_fence_denied} =
               RunFence.transition(stale_epoch, :claim, source_claim())

      assert {:error, :identity_diagnostic_invalid_fence} =
               RunFence.terminalize(scope, stale_epoch, failed_terminal(), :result)

      assert {:ok, replaced.record} == CasRecord.get(created.key)
    end

    test "a run past transport is not releasable and still settles as a terminal failure" do
      {namespace, scope, generation, _input, created, active} = open_identity_fence!()

      assert :ok = RunFence.transition(active, :claim, source_claim())
      assert :proceed = RunFence.transition(active, :mark_transport, nil)
      assert {:error, :identity_fence_not_releasable} = RunFence.release(active)
      assert RunFence.generation_status(namespace, scope, generation) == :present

      assert {:ok, settlement} = RunFence.terminalize(scope, active, failed_terminal(), :result)
      assert settlement.outcome == :requested
      assert settlement.fence["terminal"]["status"] == "failed"
      assert {:ok, settlement.fence} == CasRecord.get(created.key)
      assert {:error, :identity_fence_not_releasable} = RunFence.release(active)
    end
  end

  defp open_identity_fence! do
    namespace = "triage-run-fence-release-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    generation = ULID.generate()
    run_id = ULID.generate()
    receipt = identity_receipt()
    scope = "generation-7:T_WORKSPACE:C_CHANNEL:200.000001"
    now = SystemsClock.system_time(:millisecond)

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
             RunFence.create(namespace, scope, run_id, input, now, now + 60_000)

    active = %{
      fence_key: created.key,
      generation: generation,
      run_id: run_id,
      fence_epoch: RunFence.fence_epoch(created.record),
      identity_base_input_sha256: canonical_sha256(created.record["input_snapshot"]),
      identity_transport_attempt_id: ULID.generate(),
      identity_winning_input: input
    }

    {namespace, scope, generation, input, created, active}
  end

  defp source_claim do
    %{
      "schema" => "comma.triage-source-observation-claim.v2",
      "identity_profile_sha256" => String.duplicate("1", 64),
      "request_selector_sha256" => String.duplicate("2", 64),
      "source_origin_sha256" => String.duplicate("3", 64),
      "source_observation_sha256" => String.duplicate("4", 64)
    }
  end

  defp failed_terminal do
    %{
      "status" => "failed",
      "decision" => %{"action" => "silence", "reason" => "identity_diagnostic_internal_error"},
      "evaluator" => %{},
      "settled_at" => SystemsClock.system_time(:millisecond)
    }
  end

  defp canonical_sha256(value) do
    value
    |> SalixIM.Triage.CanonicalJSON.encode!()
    |> SalixIM.Triage.CanonicalJSON.sha256()
  end

  defp identity_receipt do
    created_at = SystemsClock.system_time(:millisecond)

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
