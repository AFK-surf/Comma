defmodule SalixIM.TriageIdentityFenceTest do
  use ExUnit.Case, async: false

  alias SalixIM.Triage.{
    Bucketing,
    CanonicalJSON,
    ExpressionContext,
    IdentityContract,
    IdentityFenceHandle,
    Pipeline,
    ProductDecision,
    RunFence,
    Runtime
  }

  alias SalixStore.{CasRecord, Keys, ULID}

  @origin_sha256 String.duplicate("c", 64)
  @production_link_url "https://docs.example.test/triage"
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @raw_provider_id ~r/\b[ABCGTUW][A-Z0-9]{8,}\b/
  @raw_uuid ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/i
  @raw_uri ~r/\b[a-z][a-z0-9+.-]*:\/\/[^\s<>"']+/i
  @raw_email ~r/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
  @raw_path ~r/(?<![\p{L}\p{N}_])\/(?:[^\s\/<>"']+\/)*[^\s<>"']+/u
  @raw_mention ~r/<@[A-Z0-9_]+>/
  @credential_literal_patterns [
    ~r/\bBearer\s+\S+/i,
    ~r/\bxox[baprs]-[A-Za-z0-9-]+\b/i,
    ~r/\bsk-(?:live|test)-[A-Za-z0-9_-]+\b/i,
    ~r/\bsk-[A-Za-z0-9_-]{12,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/
  ]

  @recovery_cases [
    {"projection_bound", "identity_diagnostic_interrupted_after_read"},
    {"snapshot_bound", "identity_diagnostic_indeterminate_model"},
    {"committed_attempted_error", "decode_error"},
    {"committed_attempted_error_v2", "decode_error"},
    {"committed_local_rejected", "identity_projection_privacy_rejected"}
  ]

  @missing_durable_winner_states ~w(unused claimed transport_maybe_started committed_success)

  defmodule SlowRecoveryStore do
    def list(prefix, opts) do
      {history_prefix, owner} = :persistent_term.get(__MODULE__)
      if String.starts_with?(history_prefix, prefix), do: send(owner, :recovery_page_started)
      SalixStore.S3.list(prefix, opts)
    end

    def get(key, opts) do
      {history_prefix, owner} = :persistent_term.get(__MODULE__)

      if String.starts_with?(key, history_prefix) do
        Process.sleep(120)
        send(owner, {:recovery_record_read, key})
      end

      SalixStore.S3.get(key, opts)
    end

    defdelegate put(key, body, opts), to: SalixStore.S3
    defdelegate head(key), to: SalixStore.S3
  end

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_triage_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    :ok = SalixStore.S3.Fake.reset()

    on_exit(fn ->
      case previous_backend do
        nil -> Application.delete_env(:salix_store, :s3_backend)
        backend -> Application.put_env(:salix_store, :s3_backend, backend)
      end

      case previous_triage_backend do
        nil -> Application.delete_env(:salix_store, :triage_record_backend)
        backend -> Application.put_env(:salix_store, :triage_record_backend, backend)
      end
    end)

    :ok
  end

  test "provider payload snapshot binding accepts exact message and text-block shapes only" do
    snapshot = ~s({"schema":"comma.triage-context-snapshot.v5"})

    assert RunFence.payload_has_exact_message_content?(
             %{"messages" => [%{"role" => "user", "content" => snapshot}]},
             snapshot
           )

    assert RunFence.payload_has_exact_message_content?(
             %{
               "input" => [
                 %{
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => snapshot}]
                 }
               ]
             },
             snapshot
           )

    refute RunFence.payload_has_exact_message_content?(
             %{"metadata" => %{"text" => snapshot}},
             snapshot
           )

    refute RunFence.payload_has_exact_message_content?(
             %{"input" => [%{"type" => "input_text", "text" => snapshot <> " trailing"}]},
             snapshot
           )
  end

  test "provider proof recognizes the Anthropic tool-use exchange emitted by the supported adapter" do
    call = %{
      "tool" => "web.read_pages",
      "params" => %{"urls" => ["link://run/l001"]}
    }

    receipt = %{"call_id" => "triage-read-call-1"}
    result = %{"content" => ~s({"status":"ok"})}

    payload = %{
      "messages" => [
        %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => receipt["call_id"],
              "name" => "call",
              "input" => call
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => receipt["call_id"],
              "content" => result["content"]
            }
          ]
        }
      ]
    }

    assert RunFence.provider_payload_has_tool_exchange?(payload, receipt, call, result)

    refute RunFence.provider_payload_has_tool_exchange?(
             put_in(
               payload,
               ["messages", Access.at(1), "content", Access.at(0), "tool_use_id"],
               "foreign"
             ),
             receipt,
             call,
             result
           )
  end

  test "a forged identity fence capability is denied before storage" do
    runtime =
      start_supervised!(
        {Runtime,
         name: nil,
         namespace: "identity-fence-forged-#{System.unique_integer([:positive])}",
         mode: :review,
         evaluator_port: {__MODULE__.ForbiddenEvaluator, []}},
        id: make_ref()
      )

    handle = %IdentityFenceHandle{runtime: runtime, capability: make_ref()}

    assert {:error, :identity_fence_denied} =
             Runtime.claim_identity_observation(handle, %{
               "schema" => "comma.triage-identity-observation-claim.v1",
               "identity_profile_sha256" => String.duplicate("a", 64),
               "request_selector_sha256" => String.duplicate("b", 64),
               "slack_api_origin_sha256" => String.duplicate("c", 64),
               "source_observation_sha256" => String.duplicate("d", 64)
             })
  end

  test "a historical recovery page cannot time out a live worker's model authorization" do
    namespace = namespace("recovery-live-authorization")
    runtime = start_identity_test_runtime(namespace, recovery_idle_ms: 60_000)

    %{handle: handle, fence_key: fence_key, snapshot_bound_fence: fence} =
      seed_active_snapshot_bound(runtime, namespace, ULID.generate(), ULID.generate())

    history_prefix =
      SalixStore.TriageKeys.ctl_im_triage_bucket_seals_prefix(namespace) <> "000-history-"

    for ordinal <- 1..50 do
      assert {:ok, _record} =
               CasRecord.create(history_prefix <> String.pad_leading("#{ordinal}", 2, "0"), %{})
    end

    :persistent_term.put(SlowRecoveryStore, {history_prefix, self()})
    Application.put_env(:salix_store, :triage_record_backend, SlowRecoveryStore)
    on_exit(fn -> :persistent_term.erase(SlowRecoveryStore) end)
    send(runtime, :recover_open_fences)
    assert_receive :recovery_page_started, 1_000

    # The worker owns a real snapshot-bound capability. A page of 50 x 120ms
    # reads used to hold Runtime beyond this call's unchanged 5-second timeout.
    assert :proceed = Runtime.authorize_identity_model(handle)
    assert {:error, :identity_fence_denied} = Runtime.authorize_identity_model(handle)
    assert {:ok, ^fence} = CasRecord.get(fence_key)

    # Recovery must still finish its page after serving the live capability.
    for _ordinal <- 1..50, do: assert_receive({:recovery_record_read, _key}, 1_000)
  end

  test "duplicate recovery requests share one reader which stops with Runtime" do
    namespace = namespace("recovery-reader-lifetime")
    prefix = SalixStore.TriageKeys.ctl_im_triage_bucket_seals_prefix(namespace)

    for ordinal <- 1..50, do: CasRecord.create(prefix <> "#{ordinal}", %{})
    :persistent_term.put(SlowRecoveryStore, {prefix, self()})
    Application.put_env(:salix_store, :triage_record_backend, SlowRecoveryStore)
    on_exit(fn -> :persistent_term.erase(SlowRecoveryStore) end)
    {:ok, runtime} = Runtime.start_link(namespace: namespace, mode: :off)
    send(runtime, :recover_open_fences)
    assert_receive :recovery_page_started, 1_000

    for _tick <- 1..100 do
      send(runtime, :recover_open_fences)
      send(runtime, :converge_triage_recovery)
    end

    state = :sys.get_state(runtime)
    reader = state.recovery_work.pid
    assert Task.Supervisor.children(state.background_supervisor) == [reader]
    monitor = Process.monitor(reader)
    assert :ok = GenServer.stop(runtime)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _reason}, 1_000
    refute Process.alive?(state.background_supervisor)
  end

  @tag :v2_rejection_receipt
  test "attempted decode commits accept historical v1 and exact v2 rejection receipts only" do
    Enum.each([:v1, :v2], fn receipt_version ->
      namespace = namespace("attempted-decode-receipt")
      generation = ULID.generate()
      run_id = ULID.generate()
      runtime = start_identity_test_runtime(namespace)

      %{handle: handle, fence_key: fence_key, fence: original_fence} =
        seed_active_transport_started(runtime, namespace, generation, run_id)

      claim = original_fence["identity_observation"]["claim"]

      receipt =
        "decode_error"
        |> slack_read_receipt(nil)
        |> Map.put("request_selector_sha256", claim["request_selector_sha256"])
        |> Map.put("slack_api_origin_sha256", claim["slack_api_origin_sha256"])
        |> maybe_v2_rejection_receipt(receipt_version)

      transport_result = attempted_error_transport_result("decode_error", receipt)

      assert Runtime.commit_identity_transport(handle, transport_result) == :ok,
             "#{receipt_version} attempted decode receipt must commit"

      assert {:ok, fence} = CasRecord.get(fence_key)
      assert get_in(fence, ["identity_observation", "state"]) == "committed"
      assert get_in(fence, ["identity_observation", "transport_result"]) == transport_result
    end)

    namespace = namespace("non-decode-v2-rejection")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{handle: handle, fence_key: fence_key, fence: original_fence} =
      seed_active_transport_started(runtime, namespace, generation, run_id)

    claim = original_fence["identity_observation"]["claim"]

    invalid_receipt =
      "decode_error"
      |> slack_read_receipt(nil)
      |> Map.put("request_selector_sha256", claim["request_selector_sha256"])
      |> Map.put("slack_api_origin_sha256", claim["slack_api_origin_sha256"])
      |> maybe_v2_rejection_receipt(:v2)
      |> Map.put("outcome", "rate_limited")
      |> Map.put("typed_reason", "rate_limited")

    assert {:error, :identity_fence_denied} =
             Runtime.commit_identity_transport(
               handle,
               attempted_error_transport_result("rate_limited", invalid_receipt)
             )

    assert {:ok, ^original_fence} = CasRecord.get(fence_key)
  end

  test "recovery quarantines a terminal v2 fence with raw extra fields" do
    sentinel = "U_RAW_SENTINEL_TERMINAL_V2"
    namespace = namespace("terminal-invalid")
    scope = "generation-7:T_ATLAS:C_ATLAS:1787019000.000001"
    generation = ULID.generate()
    run_id = ULID.generate()

    fence =
      valid_v2_fence(scope, generation, run_id)
      |> put_in(["input_snapshot", "raw_sentinel"], sentinel)
      |> Map.put("terminal", %{
        "terminal_id" => ULID.generate(),
        "status" => "evaluated",
        "decision" => %{"action" => "silence", "raw_sentinel" => sentinel},
        "evaluator" => %{},
        "settled_at" => System.system_time(:millisecond),
        "raw_sentinel" => sentinel
      })

    assert_invalid_v2_quarantined(namespace, scope, generation, run_id, fence, sentinel)
  end

  test "recovery quarantines an open v2 fence with malformed extra fields" do
    sentinel = "U_RAW_SENTINEL_OPEN_V2"
    namespace = namespace("open-invalid")
    scope = "generation-7:T_ATLAS:C_ATLAS:1787019000.000001"
    generation = ULID.generate()
    run_id = ULID.generate()

    fence =
      valid_v2_fence(scope, generation, run_id)
      |> put_in(["input_snapshot", "raw_sentinel"], sentinel)
      |> Map.put("unexpected_private_field", sentinel)
      |> Map.put("deadline_at", System.system_time(:millisecond) - 1)

    assert_invalid_v2_quarantined(namespace, scope, generation, run_id, fence, sentinel)
  end

  @tag :p0_snapshot_privacy
  test "recovery quarantines an exact-key snapshot-bound v2 fence whose hashes preserve raw" do
    sentinel = "U_RAW_SENTINEL_SNAPSHOT_BOUND_V3"
    namespace = namespace("snapshot-bound-raw")
    scope = "generation-7:T_ATLAS:C_ATLAS:1787019000.000001"
    generation = ULID.generate()
    run_id = ULID.generate()
    model_input = recovery_model_input(sentinel)

    observation =
      recovery_observation("projection_bound", sentinel)
      |> Map.put("state", "snapshot_bound")
      |> Map.put("canonical_snapshot_sha256", model_input["canonical_snapshot_sha256"])
      |> Map.put("snapshot_bound_at_ms", System.system_time(:millisecond))

    fence =
      valid_v2_fence(scope, generation, run_id)
      |> Map.put("identity_observation", observation)
      |> Map.put("input_snapshot", model_input)
      |> Map.put("deadline_at", System.system_time(:millisecond))

    assert_invalid_v2_quarantined(namespace, scope, generation, run_id, fence, sentinel)
  end

  @tag :p0_run_binding
  test "an active evaluation cannot settle a valid foreign run fence" do
    namespace = namespace("foreign-run-settlement")
    generation = ULID.generate()
    original_run_id = ULID.generate()
    foreign_run_id = ULID.generate()

    {scope, sentinel, observation, input_snapshot, durable_bucket} =
      production_bound_recovery_fixture("projection_bound", generation)

    foreign_fence =
      valid_v2_fence(scope, generation, foreign_run_id)
      |> Map.put("identity_observation", observation)
      |> Map.put("input_snapshot", input_snapshot)

    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    original_ledger_key =
      SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, original_run_id)

    foreign_ledger_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, foreign_run_id)
    original_replay_key = SalixStore.TriageKeys.ctl_im_triage_replay(namespace, original_run_id)
    foreign_replay_key = SalixStore.TriageKeys.ctl_im_triage_replay(namespace, foreign_run_id)

    runtime =
      start_supervised!(
        {Runtime,
         name: nil,
         namespace: namespace,
         mode: :review,
         context_port: {__MODULE__.ForbiddenContext, test_pid: self()},
         evaluator_port: {__MODULE__.ForbiddenEvaluator, test_pid: self()}},
        id: make_ref()
      )

    # Drain startup recovery/convergence before installing the deliberately split authority.
    Process.sleep(120)
    assert [] = Runtime.ledger_records(runtime)
    :ok = :sys.suspend(runtime)

    assert {:ok, ^durable_bucket} = CasRecord.create(bucket_key, durable_bucket)
    assert {:ok, ^foreign_fence} = CasRecord.create(fence_key, foreign_fence)

    winning_input =
      production_winning_input(
        generation,
        hd(durable_bucket["sealed_generations"])["receipts"]
      )

    timeout_ref = Process.send_after(self(), :unused_active_timeout, 60_000)
    capability = make_ref()
    result_capability = make_ref()

    active = %{
      generation: generation,
      run_id: original_run_id,
      fence_key: fence_key,
      monitor_ref: nil,
      timeout_ref: timeout_ref,
      worker_pid: self(),
      identity_capability: capability,
      identity_result_capability: result_capability,
      identity_transport_attempt_id: ULID.generate(),
      identity_transport_permission: :consumed,
      identity_model_permission: :available,
      identity_read_tool_permission: :available,
      identity_base_input_sha256: CanonicalJSON.sha256(CanonicalJSON.encode!(input_snapshot)),
      identity_winning_input: winning_input,
      identity_winning_source_anchor: %{
        "schema" => "comma.triage-winning-source-anchor.v1",
        "generation" => generation,
        "source_mode" => "historical_thread_reenactment",
        "sealed_events" => winning_input["events"],
        "source_authority" => winning_input["source_authority"]
      }
    }

    :sys.replace_state(runtime, fn state ->
      %{state | active: Map.put(state.active, scope, active)}
    end)

    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = SalixStore.S3.Fake.reset_read_log()
    :ok = :sys.resume(runtime)

    evaluation_message =
      {:triage_evaluation_result, scope, generation, original_run_id, result_capability,
       {:error, :identity_projection_invalid}}

    send(runtime, evaluation_message)
    _ = Runtime.ledger_records(runtime)

    runtime_state = :sys.get_state(runtime)
    {:messages, queued_messages} = Process.info(runtime, :messages)

    public_bodies =
      SalixStore.S3.Fake.dump()
      |> Map.take([
        original_ledger_key,
        foreign_ledger_key,
        original_replay_key,
        foreign_replay_key
      ])
      |> Map.values()
      |> Enum.map(& &1.body)

    refute_received :context_called
    refute_received :evaluator_called
    refute Map.has_key?(runtime_state.active, scope)
    refute evaluation_message in queued_messages

    assert %{
             fence: ^foreign_fence,
             original_replay: {:error, :not_found},
             foreign_replay: {:error, :not_found},
             ledger_records: [],
             namespace_puts: [],
             leaked_raw_sentinel?: false
           } = %{
             fence: unwrap(CasRecord.get(fence_key)),
             original_replay: Runtime.replay(runtime, original_run_id),
             foreign_replay: Runtime.replay(runtime, foreign_run_id),
             ledger_records: Runtime.ledger_records(runtime),
             namespace_puts: namespace_put_log(namespace),
             leaked_raw_sentinel?: Enum.any?(public_bodies, &String.contains?(&1, sentinel))
           }
  end

  @tag :p0_snapshot_handle
  test "a worker binds the exact snapshot through its opaque runtime handle" do
    namespace = namespace("snapshot-handle")
    generation = ULID.generate()
    run_id = ULID.generate()

    runtime = start_identity_test_runtime(namespace)

    %{handle: handle, fence_key: fence_key, observation: observation} =
      seed_active_projection_bound(runtime, namespace, generation, run_id, run_id)

    {:ok, %{projected_context: projected_context}} =
      IdentityContract.recompute_projected_context(observation["private_projection"])

    model_input = production_model_input(projected_context)

    assert :ok = Runtime.bind_identity_snapshot(handle, model_input)
    assert {:ok, snapshot_bound_fence} = CasRecord.get(fence_key)

    assert snapshot_bound_fence["terminal"] == nil
    assert snapshot_bound_fence["input_snapshot"] == model_input

    assert %{
             "state" => "snapshot_bound",
             "canonical_snapshot_sha256" => canonical_snapshot_sha256,
             "snapshot_bound_at_ms" => snapshot_bound_at_ms
           } = snapshot_bound_fence["identity_observation"]

    assert canonical_snapshot_sha256 == model_input["canonical_snapshot_sha256"]
    assert is_integer(snapshot_bound_at_ms) and snapshot_bound_at_ms > 0

    :ok = SalixStore.S3.Fake.reset_put_log()

    assert {:error, :identity_fence_denied} =
             Runtime.bind_identity_snapshot(handle, model_input)

    assert Process.alive?(runtime)
    assert {:ok, ^snapshot_bound_fence} = CasRecord.get(fence_key)
    assert namespace_put_log(namespace) == []
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_read_tool_authority
  test "Pipeline owns bounded read-tool policy over a RunFence-authorized snapshot" do
    namespace = namespace("pipeline-read-tool-authority")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{scope: scope} = seed_active_snapshot_bound(runtime, namespace, generation, run_id)
    active = :sys.get_state(runtime).active[scope]

    assert {:proceed, authorization} = Pipeline.authorize_read_tool(namespace, active)

    assert authorization == %{
             "schema" => "comma.triage-read-tool-authorization.v1",
             "tool_name" => "web.read_pages",
             "agent_id" => "agt1_atlas_router",
             "session_id" => run_id,
             "tenant_id" => "tenant-atlas",
             "group_id" => "project-atlas",
             "role" => "router",
             "runtime_kind" => "internal",
             "link_targets" => [
               %{
                 "link_ref" => "link://run/l001",
                 "resolved_url" => @production_link_url,
                 "source_refs" => ["source://run/s004"]
               }
             ]
           }

    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_read_tool_authority
  test "a snapshot-bound worker receives one Runtime-owned read-only link authorization" do
    namespace = namespace("read-tool-authority")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{handle: handle, fence_key: fence_key, snapshot_bound_fence: original_fence} =
      seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert :proceed = Runtime.authorize_identity_model(handle)
    :ok = SalixStore.S3.Fake.reset_put_log()

    assert {:proceed, authorization} = Runtime.authorize_identity_read_tool(handle)

    assert Map.keys(authorization) |> Enum.sort() ==
             ~w(agent_id group_id link_targets role runtime_kind schema session_id tenant_id tool_name)

    assert authorization == %{
             "schema" => "comma.triage-read-tool-authorization.v1",
             "tool_name" => "web.read_pages",
             "agent_id" => "agt1_atlas_router",
             "session_id" => run_id,
             "tenant_id" => "tenant-atlas",
             "group_id" => "project-atlas",
             "role" => "router",
             "runtime_kind" => "internal",
             "link_targets" => [
               %{
                 "link_ref" => "link://run/l001",
                 "resolved_url" => @production_link_url,
                 "source_refs" => ["source://run/s004"]
               }
             ]
           }

    assert {:error, :identity_fence_denied} = Runtime.authorize_identity_read_tool(handle)
    assert Process.alive?(runtime)
    assert {:ok, ^original_fence} = CasRecord.get(fence_key)
    assert namespace_put_log(namespace) == []
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_read_tool_commit
  test "Pipeline validates and commits one source-bound read-tool result" do
    namespace = namespace("pipeline-read-tool-commit")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{scope: scope, fence_key: fence_key} =
      seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    active = :sys.get_state(runtime).active[scope]
    assert {:proceed, authorization} = Pipeline.authorize_read_tool(namespace, active)

    call_bytes =
      CanonicalJSON.encode!(%{
        "tool" => "web.read_pages",
        "params" => %{"urls" => ["link://run/l001"]}
      })

    result_bytes =
      CanonicalJSON.encode!(%{
        "content" =>
          Jason.encode!(%{
            "count" => 1,
            "results" => [
              %{
                "url" => "link://run/l001",
                "text" => "The launch is approved for Tuesday."
              }
            ]
          })
      })

    receipt = %{
      "schema" => "comma.triage-read-tool-receipt.v1",
      "call_id" => "triage-read-call-pipeline-1",
      "tool_name" => "web.read_pages",
      "canonical_call_bytes" => call_bytes,
      "call_sha256" => CanonicalJSON.sha256(call_bytes),
      "status" => "completed",
      "error" => false,
      "error_class" => nil,
      "canonical_result_bytes" => result_bytes,
      "result_sha256" => CanonicalJSON.sha256(result_bytes)
    }

    assert :ok = Pipeline.commit_read_tool(active, authorization, receipt)
    assert {:ok, committed_fence} = CasRecord.get(fence_key)

    assert %{
             "schema" => "comma.triage-read-tool-observation.v1",
             "tool_name" => "web.read_pages",
             "link_ref" => "link://run/l001",
             "source_refs" => ["source://run/s004"],
             "receipt" => ^receipt
           } = get_in(committed_fence, ["identity_observation", "read_tool_result"])

    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_read_tool_commit
  test "a worker freezes one source-bound read-tool result before continuing the model" do
    namespace = namespace("read-tool-commit")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{handle: handle, fence_key: fence_key} =
      seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert :proceed = Runtime.authorize_identity_model(handle)
    assert {:proceed, _authorization} = Runtime.authorize_identity_read_tool(handle)

    call_bytes =
      CanonicalJSON.encode!(%{
        "tool" => "web.read_pages",
        "params" => %{"urls" => ["link://run/l001"]}
      })

    result_bytes =
      CanonicalJSON.encode!(%{
        "content" =>
          Jason.encode!(%{
            "count" => 1,
            "results" => [
              %{
                "url" => "link://run/l001",
                "text" => "The launch is approved for Tuesday."
              }
            ]
          })
      })

    receipt = %{
      "schema" => "comma.triage-read-tool-receipt.v1",
      "call_id" => "triage-read-call-1",
      "tool_name" => "web.read_pages",
      "canonical_call_bytes" => call_bytes,
      "call_sha256" => CanonicalJSON.sha256(call_bytes),
      "status" => "completed",
      "error" => false,
      "error_class" => nil,
      "canonical_result_bytes" => result_bytes,
      "result_sha256" => CanonicalJSON.sha256(result_bytes)
    }

    {:ok, original_fence} = CasRecord.get(fence_key)

    raw_url_result_bytes =
      CanonicalJSON.encode!(%{
        "content" =>
          Jason.encode!(%{
            "count" => 1,
            "results" => [
              %{
                "url" => "https://DOCS.EXAMPLE.TEST:443/triage#details",
                "text" =>
                  "The launch is approved for Tuesday; see https://redirect.example.test/next."
              }
            ]
          })
      })

    wrong_link_call_bytes =
      CanonicalJSON.encode!(%{
        "tool" => "web.read_pages",
        "params" => %{"urls" => ["link://run/l999"]}
      })

    invalid_receipts = [
      {"call hash drift", Map.put(receipt, "call_sha256", String.duplicate("0", 64))},
      {"source-bound link drift",
       receipt
       |> Map.put("canonical_call_bytes", wrong_link_call_bytes)
       |> Map.put("call_sha256", CanonicalJSON.sha256(wrong_link_call_bytes))},
      {"result hash drift", Map.put(receipt, "result_sha256", String.duplicate("f", 64))},
      {"raw URL retention",
       receipt
       |> Map.put("canonical_result_bytes", raw_url_result_bytes)
       |> Map.put("result_sha256", CanonicalJSON.sha256(raw_url_result_bytes))},
      {"status/error mismatch",
       Map.merge(receipt, %{"error" => true, "error_class" => "tool_error"})},
      {"unknown receipt key", Map.put(receipt, "transport", "caller-controlled")}
    ]

    :ok = SalixStore.S3.Fake.reset_put_log()

    Enum.each(invalid_receipts, fn {label, invalid_receipt} ->
      assert {:error, :identity_fence_denied} =
               Runtime.commit_identity_read_tool(handle, invalid_receipt),
             label

      assert Process.alive?(runtime), label
      assert {:ok, ^original_fence} = CasRecord.get(fence_key), label
      assert namespace_put_log(namespace) == [], label
    end)

    assert :ok = Runtime.commit_identity_read_tool(handle, receipt)
    assert {:ok, committed_fence} = CasRecord.get(fence_key)

    assert %{
             "schema" => "comma.triage-read-tool-observation.v1",
             "tool_name" => "web.read_pages",
             "link_ref" => "link://run/l001",
             "source_refs" => ["source://run/s004"],
             "receipt" => ^receipt,
             "committed_at_ms" => committed_at_ms
           } = get_in(committed_fence, ["identity_observation", "read_tool_result"])

    assert is_integer(committed_at_ms) and committed_at_ms > 0

    :ok = SalixStore.S3.Fake.reset_put_log()

    assert {:error, :identity_fence_denied} = Runtime.commit_identity_read_tool(handle, receipt)
    assert Process.alive?(runtime)
    assert {:ok, ^committed_fence} = CasRecord.get(fence_key)
    assert namespace_put_log(namespace) == []

    refute committed_fence
           |> get_in(["identity_observation", "read_tool_result"])
           |> CanonicalJSON.encode!() =~ @production_link_url
  end

  @tag :p0_snapshot_handle
  test "snapshot binding denies the reversed call from an unused fence without crashing runtime" do
    namespace = namespace("snapshot-handle-unused")
    generation = ULID.generate()
    run_id = ULID.generate()

    runtime = start_identity_test_runtime(namespace)

    %{
      handle: handle,
      fence_key: fence_key,
      fence: projection_bound_fence,
      observation: projection_bound_observation
    } = seed_active_projection_bound(runtime, namespace, generation, run_id, run_id)

    {:ok, %{projected_context: projected_context}} =
      IdentityContract.recompute_projected_context(
        projection_bound_observation["private_projection"]
      )

    model_input = production_model_input(projected_context)

    unused_fence =
      projection_bound_fence
      |> Map.put("identity_observation", %{
        "schema" => "comma.triage-identity-observation.v1",
        "state" => "unused"
      })
      |> Map.put("input_snapshot", valid_base_projection())

    assert {:ok, ^unused_fence} = CasRecord.update(fence_key, fn _current -> unused_fence end)
    :ok = SalixStore.S3.Fake.reset_put_log()

    assert {:error, :identity_fence_denied} =
             Runtime.bind_identity_snapshot(handle, model_input)

    assert Process.alive?(runtime)
    assert {:ok, ^unused_fence} = CasRecord.get(fence_key)
    assert namespace_put_log(namespace) == []
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_snapshot_handle
  test "snapshot binding denies a handle whose active run differs from the physical fence" do
    namespace = namespace("snapshot-handle-foreign-run")
    generation = ULID.generate()
    active_run_id = ULID.generate()
    foreign_run_id = ULID.generate()

    runtime = start_identity_test_runtime(namespace)

    %{
      handle: handle,
      fence_key: fence_key,
      fence: foreign_fence,
      observation: observation
    } =
      seed_active_projection_bound(
        runtime,
        namespace,
        generation,
        active_run_id,
        foreign_run_id
      )

    {:ok, %{projected_context: projected_context}} =
      IdentityContract.recompute_projected_context(observation["private_projection"])

    model_input = production_model_input(projected_context)
    :ok = SalixStore.S3.Fake.reset_put_log()

    assert {:error, :identity_fence_denied} =
             Runtime.bind_identity_snapshot(handle, model_input)

    assert {:ok, ^foreign_fence} = CasRecord.get(fence_key)
    assert namespace_put_log(namespace) == []
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p1_identity_predecessor_authority
  test "a finalized identity predecessor with a drifted proof cannot release the next generation" do
    namespace = namespace("invalid-finalized-predecessor")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      fence_key: fence_key,
      model_input: model_input,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    test_pid = self()

    :sys.replace_state(runtime, fn state ->
      %{
        state
        | debounce_ms: 0,
          max_wait_ms: 0,
          context_port: {__MODULE__.NextGenerationContext, test_pid: test_pid},
          evaluator_port: {__MODULE__.NextGenerationEvaluator, test_pid: test_pid}
      }
    end)

    receipt =
      next_generation_receipt(
        "Ev-invalid-predecessor-#{System.unique_integer([:positive])}",
        "must wait for a valid predecessor"
      )

    assert :ok = queue_next_generation(runtime, namespace, receipt)
    Process.sleep(25)

    queued_state = :sys.get_state(runtime)
    assert queued_state.active[scope].run_id == run_id
    next_generation = queued_state.buckets[scope].generation
    refute next_generation == generation

    invalid_terminal =
      model_input
      |> production_evaluated_terminal()
      |> put_in(["evaluator", "canonical_snapshot_sha256"], String.duplicate("0", 64))

    invalid_predecessor =
      snapshot_bound_fence
      |> put_in(["identity_observation", "state"], "finalized")
      |> put_in(
        ["identity_observation", "finalized_at_ms"],
        System.system_time(:millisecond)
      )
      |> Map.put("terminal", invalid_terminal)

    assert {:ok, ^invalid_predecessor} =
             CasRecord.update(fence_key, fn _current -> invalid_predecessor end, create: false)

    send(runtime, {:triage_evaluation_timeout, scope, generation, run_id})
    _ = Runtime.ledger_records(runtime)

    refute_receive {:next_generation_context, ^next_generation}, 275
    refute_receive {:next_generation_evaluator, ^next_generation}, 50
    assert {:ok, ^invalid_predecessor} = CasRecord.get(fence_key)

    assert {:error, :not_found} =
             CasRecord.get(
               SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, next_generation)
             )

    state = :sys.get_state(runtime)
    assert map_size(state.active) == 0
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p1_identity_handoff_timer_dedup
  test "terminal convergence schedules one pending flush for an open identity successor" do
    namespace = namespace("terminal-convergence-flush-dedup")
    runtime = start_identity_test_runtime(namespace)

    on_exit(fn ->
      if Process.alive?(runtime), do: :sys.resume(runtime)
    end)

    histories = finalized_histories(2)

    [first, second] = histories
    assert first.scope == second.scope
    scope = first.scope
    successor_generation = ULID.generate()

    durable_bucket = %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope,
      "open_generation" => successor_generation,
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => Enum.map(histories, & &1.sealed)
    }

    assert {:ok, ^durable_bucket} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope),
               durable_bucket
             )

    Enum.each(histories, fn history ->
      fence_key =
        SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, history.generation)

      assert {:ok, history.fence} == CasRecord.create(fence_key, history.fence)
    end)

    :sys.replace_state(runtime, fn state ->
      %{state | debounce_ms: 1_500, max_wait_ms: 1_500}
    end)

    :ok = :sys.resume(runtime)

    receipt =
      next_generation_receipt(
        "Ev-terminal-convergence-#{System.unique_integer([:positive])}",
        "queue one non-fast successor"
      )

    assert receipt["triage_event"]["fast_path"] == false
    assert :ok = queue_next_generation(runtime, namespace, receipt)

    queued = :sys.get_state(runtime)
    bucket = queued.buckets[scope]
    assert bucket.generation == successor_generation
    due_at = min(bucket.last_at + queued.debounce_ms, bucket.first_at + queued.max_wait_ms)
    assert due_at - System.system_time(:millisecond) > 1_000

    expected_run_ids = histories |> Enum.map(& &1.run_id) |> Enum.sort()

    Enum.each(1..2, fn _tick ->
      send(runtime, :converge_terminal_projections)

      assert eventually(fn ->
               expected_run_ids ==
                 runtime
                 |> Runtime.ledger_records()
                 |> Enum.map(& &1["run_id"])
                 |> Enum.sort()
             end)
    end)

    scheduled = :sys.get_state(runtime)

    assert %{
             token: scheduled_token,
             generation: ^successor_generation
           } = scheduled.flush_schedules[scope]

    assert scheduled_token == bucket.token
    assert map_size(scheduled.flush_schedules) == 1

    :ok = :sys.suspend(runtime)
    Process.sleep(max(0, due_at - System.system_time(:millisecond) + 50))

    {:messages, messages} = Process.info(runtime, :messages)

    matching_flushes =
      Enum.count(messages, fn
        {:flush, ^scope, token, generation, schedule_id} when is_reference(schedule_id) ->
          token == bucket.token and generation == successor_generation

        _other ->
          false
      end)

    assert matching_flushes <= 1
  end

  @tag :p1_identity_terminal_projection_authority
  test "terminal projection rereads the durable identity fence before publishing" do
    namespace = namespace("terminal-projection-durable-readback")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      fence_key: fence_key,
      model_input: model_input,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    message_only_view =
      snapshot_bound_fence
      |> Map.put("terminal", production_evaluated_terminal(model_input))
      |> Map.update!("identity_observation", fn observation ->
        observation
        |> Map.put("state", "finalized")
        |> Map.put("finalized_at_ms", System.system_time(:millisecond))
      end)

    :ok = SalixStore.S3.Fake.reset_put_log()
    send(runtime, {:project_terminal, message_only_view})

    assert Runtime.ledger_records(runtime) == []
    assert Process.alive?(runtime)
    assert {:ok, ^snapshot_bound_fence} = CasRecord.get(fence_key)
    assert {:error, :not_found} = Runtime.replay(runtime, run_id)
    assert namespace_put_log(namespace) == []
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p1_identity_terminal_projection_retry_dedup
  test "terminal projection retries retain their global budget across an asynchronous recovery page" do
    namespace = namespace("terminal-projection-budget")
    runtime = start_identity_test_runtime(namespace, recovery_idle_ms: 60_000)
    histories = finalized_histories(20)
    scope = hd(histories).scope

    bucket = %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope,
      "open_generation" => ULID.generate(),
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => Enum.map(histories, & &1.sealed)
    }

    assert {:ok, _} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope),
               bucket
             )

    for history <- histories do
      key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, history.generation)
      assert {:ok, _} = CasRecord.create(key, history.fence)
    end

    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, :any})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)
    :ok = :sys.resume(runtime)
    send(runtime, :converge_terminal_projections)

    state =
      eventually(
        fn ->
          state = :sys.get_state(runtime)

          if is_nil(state.recovery_work) and map_size(state.terminal_projection_schedules) >= 16,
            do: state,
            else: false
        end,
        500
      )

    assert map_size(state.terminal_projection_schedules) == 16
    assert Process.alive?(runtime)
  end

  @tag :p1_identity_terminal_projection_retry_dedup
  test "terminal convergence keeps one projection retry per durable fence" do
    namespace = namespace("terminal-projection-retry-dedup")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    on_exit(fn ->
      :ok = SalixStore.S3.Fake.clear_blackhole()
      if Process.alive?(runtime), do: :sys.resume(runtime)
    end)

    %{
      fence_key: fence_key,
      model_input: model_input,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    finalized_fence =
      snapshot_bound_fence
      |> Map.put("terminal", production_evaluated_terminal(model_input))
      |> Map.update!("identity_observation", fn observation ->
        observation
        |> Map.put("state", "finalized")
        |> Map.put("finalized_at_ms", System.system_time(:millisecond))
      end)

    assert {:ok, ^finalized_fence} =
             CasRecord.update(fence_key, fn _current -> finalized_fence end, create: false)

    ledger_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)
    replay_key = SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run_id)

    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, ledger_key})
    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, replay_key})
    :ok = :sys.resume(runtime)

    Enum.each(1..3, fn _tick ->
      send(runtime, :converge_terminal_projections)

      # Page reads run outside Runtime; a mailbox round-trip no longer waits
      # for projection. The durable result must remain unavailable throughout.
      assert Runtime.ledger_records(runtime) == []
      assert Runtime.ledger_records(runtime) == []
    end)

    assert {:error, :not_found} = Runtime.replay(runtime, run_id)

    scheduled =
      eventually(fn ->
        state = :sys.get_state(runtime)
        if state.terminal_projection_schedules[fence_key], do: state, else: false
      end)

    assert %{id: schedule_id} = scheduled.terminal_projection_schedules[fence_key]
    assert is_reference(schedule_id)
    assert map_size(scheduled.terminal_projection_schedules) == 1

    :ok = :sys.suspend(runtime)
    Process.sleep(75)

    {:messages, messages} = Process.info(runtime, :messages)

    matching_projection_retries =
      Enum.count(messages, fn
        {:project_terminal, ^fence_key, retry_id} when is_reference(retry_id) -> true
        _other -> false
      end)

    assert {:ok, ^finalized_fence} = CasRecord.get(fence_key)

    public_keys = SalixStore.S3.Fake.dump() |> Map.keys()
    refute ledger_key in public_keys
    refute replay_key in public_keys

    attempted_puts = namespace_put_log(namespace)
    assert attempted_puts != []
    assert Enum.all?(attempted_puts, &(&1 in [ledger_key, replay_key]))
    assert matching_projection_retries <= 1
  end

  @tag :p1_identity_generation_handoff_recovery
  test "deadline recovery wakes a queued generation after interrupted retries are exhausted" do
    namespace = namespace("exhausted-recovery-next-generation")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert :proceed = Runtime.authorize_identity_model(handle)

    first_worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    test_pid = self()

    :sys.replace_state(runtime, fn state ->
      active = state.active[scope]
      monitor_ref = Process.monitor(first_worker)

      %{
        state
        | debounce_ms: 0,
          max_wait_ms: 0,
          context_port: {__MODULE__.NextGenerationContext, test_pid: test_pid},
          evaluator_port: {__MODULE__.NextGenerationEvaluator, test_pid: test_pid},
          active:
            Map.put(state.active, scope, %{
              active
              | worker_pid: first_worker,
                monitor_ref: monitor_ref
            })
      }
    end)

    receipt =
      next_generation_receipt(
        "Ev-recovered-next-generation-#{System.unique_integer([:positive])}",
        "queued through predecessor recovery"
      )

    assert :ok = queue_next_generation(runtime, namespace, receipt)
    Process.sleep(25)

    queued_state = :sys.get_state(runtime)
    next_generation = queued_state.buckets[scope].generation
    refute next_generation == generation
    refute_received {:next_generation_context, _generation}
    refute_received {:next_generation_evaluator, _generation}

    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, fence_key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)
    Process.exit(first_worker, :kill)

    assert eventually(fn ->
             state = :sys.get_state(runtime)
             map_size(state.active) == 0 and map_size(state.identity_recovery_retries) == 0
           end)

    :ok = SalixStore.S3.Fake.clear_blackhole()
    deadline_at = System.system_time(:millisecond) - 1

    assert {:ok, %{"deadline_at" => ^deadline_at}} =
             CasRecord.update(
               fence_key,
               &Map.put(&1, "deadline_at", deadline_at),
               create: false
             )

    send(runtime, :converge_terminal_projections)

    assert {:ok, finalized_fence} =
             eventually(fn ->
               case CasRecord.get(fence_key) do
                 {:ok, %{"identity_observation" => %{"state" => "finalized"}}} = result ->
                   result

                 _other ->
                   false
               end
             end)

    assert get_in(finalized_fence, ["terminal", "status"]) == "failed"
    # The successor generation is released exactly once: it seals and takes its
    # own durable run fence.
    # L3: the released generation reaches a *stub* context/evaluator port only
    # once the BridgeForTeams context seam lands. Every receipt main's callback
    # route writes is endpoint-provenanced, so the successor is an identity run
    # and `Pipeline.validate_context_port/2` admits only the production port.
    successor_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, next_generation)

    assert {:ok, successor_fence} =
             eventually(fn ->
               case CasRecord.get(successor_key) do
                 {:ok, _fence} = result -> result
                 _other -> false
               end
             end)

    assert successor_fence["generation"] == next_generation
    assert successor_fence["bucket_scope"] == scope
    refute_received {:next_generation_context, _generation}
    refute_received {:next_generation_evaluator, _generation}
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_model_authority
  test "RunFence owns durable model authorization for the matching snapshot" do
    namespace = namespace("run-fence-model-authority")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{scope: scope} = seed_active_snapshot_bound(runtime, namespace, generation, run_id)
    active = :sys.get_state(runtime).active[scope]

    assert :proceed = RunFence.authorize_model(namespace, active)
    assert {:ok, _fence} = CasRecord.get(active.fence_key)
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_decision_authority
  test "RunFence owns bound decision validation for the matching snapshot" do
    namespace = namespace("run-fence-decision-authority")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{scope: scope, model_input: model_input} =
      seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    active = :sys.get_state(runtime).active[scope]
    decision = production_evaluated_terminal(model_input)["decision"]

    assert :ok = RunFence.validate_model_decision(namespace, active, decision)

    assert {:error, :identity_projection_invalid} =
             RunFence.validate_model_decision(
               namespace,
               %{active | run_id: ULID.generate()},
               decision
             )

    assert {:ok, _fence} = CasRecord.get(active.fence_key)
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_chain_authority
  test "RunFence owns durable winning-input chain validation" do
    namespace = namespace("run-fence-chain-authority")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{snapshot_bound_fence: fence} =
      seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert :ok = RunFence.validate_chain_from_storage(namespace, fence)

    assert {:error, :identity_diagnostic_invalid_fence} =
             RunFence.validate_chain_from_storage(
               namespace,
               put_in(fence, ["input_snapshot", "snapshot", "events"], [])
             )

    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_projection_authority
  test "RunFence owns terminal projection authorization from the physical fence key" do
    namespace = namespace("run-fence-projection-authority")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      fence_key: fence_key,
      model_input: model_input,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    # This assertion owns finalization; recovery is covered by separate runtime tests.
    :ok = :sys.suspend(runtime)

    terminal_fence =
      Map.put(snapshot_bound_fence, "terminal", production_evaluated_terminal(model_input))

    assert {:ok, ^terminal_fence} =
             CasRecord.update(fence_key, fn _current -> terminal_fence end, create: false)

    assert {:ok, %RunFence.AuthorizedProjection{fence: finalized_fence}} =
             RunFence.authorize_projection_from_key(namespace, fence_key)

    assert get_in(finalized_fence, ["identity_observation", "state"]) == "finalized"
    assert finalized_fence["terminal"] == terminal_fence["terminal"]

    assert {:error, :identity_diagnostic_invalid_fence} =
             RunFence.authorize_projection_from_key(namespace, fence_key <> ".foreign")

    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_interrupted_recovery_authority
  test "RunFence owns the physical read and settlement for an interrupted active run" do
    namespace = namespace("run-fence-interrupted-authority")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{scope: scope, fence_key: fence_key} =
      seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    # This assertion exercises RunFence as the sole settlement owner. Keep the
    # live Runtime from concurrently finalizing the same durable fence.
    :ok = :sys.suspend(runtime)
    on_exit(fn -> if Process.alive?(runtime), do: :sys.resume(runtime) end)

    active = :sys.get_state(runtime).active[scope]

    assert {:ok, recovered_fence} =
             RunFence.recover_interrupted(namespace, scope, active)

    assert recovered_fence["terminal"]["status"] == "failed"

    assert recovered_fence["terminal"]["decision"] == %{
             "action" => "silence",
             "reason" => "identity_diagnostic_indeterminate_model"
           }

    assert {:ok, ^recovered_fence} = CasRecord.get(fence_key)

    assert {:error, :identity_diagnostic_invalid_fence} =
             RunFence.recover_interrupted(namespace, scope <> ":foreign", active)

    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_model_authority
  test "model authority proceeds exactly once for the matching snapshot-bound active run" do
    namespace = namespace("model-authority-once")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      handle: handle,
      fence_key: fence_key,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    :ok = SalixStore.S3.Fake.reset_put_log()

    assert :proceed = Runtime.authorize_identity_model(handle)

    assert {:ok,
            %{
              "schema" => "comma.triage-model-runtime-authorization.v1",
              "agent_id" => "agt1_atlas_router",
              "identity_revision_sha256" => identity_revision
            }} = SalixIM.Triage.IdentityFence.model_runtime(handle)

    assert is_binary(identity_revision) and byte_size(identity_revision) == 64
    assert {:error, :identity_fence_denied} = Runtime.authorize_identity_model(handle)
    assert Process.alive?(runtime)
    assert {:ok, ^snapshot_bound_fence} = CasRecord.get(fence_key)
    assert namespace_put_log(namespace) == []
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_active_snapshot_recovery
  test "recovery convergence leaves an active authorized snapshot-bound model run open" do
    namespace = namespace("active-snapshot-recovery")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert snapshot_bound_fence["deadline_at"] > System.system_time(:millisecond) + 30_000
    assert :proceed = Runtime.authorize_identity_model(handle)

    # Keep the handle-owning worker (this test process) alive without returning a result
    # across more than two 100 ms recovery-convergence ticks.
    Process.sleep(275)
    _ = Runtime.ledger_records(runtime)

    assert {:ok, current_fence} = CasRecord.get(fence_key)
    assert current_fence["terminal"] == nil
    assert get_in(current_fence, ["identity_observation", "state"]) == "snapshot_bound"
    assert Runtime.ledger_records(runtime) == []
    assert Runtime.replay(runtime, run_id) == {:error, :not_found}

    state = :sys.get_state(runtime)
    assert Map.has_key?(state.active, scope)
    assert state.active[scope].run_id == run_id
    assert state.active[scope].identity_model_permission == :consumed
    assert {:error, :identity_fence_denied} = Runtime.authorize_identity_model(handle)
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_identity_down_storage_retry
  test "abnormal snapshot-bound worker DOWN retries a transient terminal write before deadline" do
    namespace = namespace("snapshot-bound-down-storage-retry")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    on_exit(fn -> SalixStore.S3.Fake.reset() end)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key,
      model_input: model_input,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    deadline_at = snapshot_bound_fence["deadline_at"]
    assert deadline_at > System.system_time(:millisecond) + 30_000
    test_pid = self()

    worker_pid =
      spawn(fn ->
        receive do
          {:authorize_then_wait, ^handle, ^model_input} ->
            send(test_pid, {:identity_evaluator_received_v3, self(), model_input})
            authorization = Runtime.authorize_identity_model(handle)
            send(test_pid, {:identity_model_authorization, self(), authorization})

            if authorization == :proceed do
              send(test_pid, {:identity_model_attempt, self()})
            end

            receive do
              :kill_after_snapshot -> Process.exit(self(), :kill)
            end
        end
      end)

    state =
      :sys.replace_state(runtime, fn state ->
        active = state.active[scope]
        monitor_ref = Process.monitor(worker_pid)

        %{
          state
          | active:
              Map.put(state.active, scope, %{
                active
                | worker_pid: worker_pid,
                  monitor_ref: monitor_ref
              })
        }
      end)

    monitor_ref = state.active[scope].monitor_ref
    send(worker_pid, {:authorize_then_wait, handle, model_input})

    assert_receive {:identity_evaluator_received_v3, ^worker_pid, ^model_input}, 500
    assert_receive {:identity_model_authorization, ^worker_pid, :proceed}, 500
    assert_receive {:identity_model_attempt, ^worker_pid}, 500

    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = :sys.suspend(runtime)
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, fence_key})
    send(worker_pid, :kill_after_snapshot)
    assert eventually(fn -> not Process.alive?(worker_pid) end)

    assert eventually(fn ->
             {:messages, messages} = Process.info(runtime, :messages)

             Enum.any?(messages, fn
               {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} -> true
               _other -> false
             end)
           end)

    :ok = :sys.resume(runtime)
    state_after_down = :sys.get_state(runtime)

    # Count-only assertions avoid rendering private active data on RED.
    assert map_size(state_after_down.active) == 0
    assert map_size(state_after_down.late_wait) == 0
    assert Enum.count(SalixStore.S3.Fake.put_log(), &(&1 == fence_key)) == 1
    assert System.system_time(:millisecond) < deadline_at

    assert {:error, :identity_fence_denied} = Runtime.authorize_identity_model(handle)
    refute_receive {:identity_model_attempt, _pid}, 50

    # More than two 100 ms convergence ticks must retry the interrupted close,
    # even though the production deadline remains far in the future.
    Process.sleep(275)
    _ = Runtime.ledger_records(runtime)
    assert System.system_time(:millisecond) < deadline_at
    assert {:ok, finalized_fence} = CasRecord.get(fence_key)

    assert %{
             state: "finalized",
             status: "failed",
             reason: "identity_diagnostic_indeterminate_model"
           } == %{
             state: get_in(finalized_fence, ["identity_observation", "state"]),
             status: get_in(finalized_fence, ["terminal", "status"]),
             reason: get_in(finalized_fence, ["terminal", "decision", "reason"])
           }

    assert get_in(finalized_fence, ["terminal", "evaluator"]) == %{}

    assert [run] = Runtime.ledger_records(runtime)
    assert run["run_id"] == run_id
    assert run["status"] == "failed"
    assert run["decision"] == finalized_fence["terminal"]["decision"]
    assert run["evaluator"] == %{}
    assert {:ok, ^run} = Runtime.replay(runtime, run_id)

    final_state = :sys.get_state(runtime)
    assert map_size(final_state.active) == 0
    assert map_size(final_state.late_wait) == 0
    refute_receive {:identity_model_attempt, _pid}, 50
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p1_identity_recovery_retry_authority
  test "an unregistered recovery retry message cannot close an active identity run" do
    namespace = namespace("forged-interrupted-recovery-retry")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      fence_key: fence_key,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert snapshot_bound_fence["deadline_at"] > System.system_time(:millisecond) + 30_000
    state_before = :sys.get_state(runtime)
    assert state_before.active[scope].run_id == run_id
    assert state_before.active[scope].identity_model_permission == :available
    :ok = SalixStore.S3.Fake.reset_put_log()

    send(runtime, {:retry_interrupted_identity_recovery, run_id, 1_000_000})

    # This synchronous call is a same-sender FIFO barrier for the forged message.
    assert [] = Runtime.ledger_records(runtime)
    assert Process.alive?(runtime)
    assert {:ok, ^snapshot_bound_fence} = CasRecord.get(fence_key)
    assert {:error, :not_found} = Runtime.replay(runtime, run_id)

    state_after = :sys.get_state(runtime)
    assert state_after.active[scope].run_id == run_id
    assert state_after.active[scope].identity_model_permission == :available
    assert namespace_put_log(namespace) == []
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_cross_runtime_snapshot_recovery
  test "a second runtime cannot recover another runtime's active snapshot-bound model run" do
    namespace = namespace("cross-runtime-active-snapshot")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime_a = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime_a, namespace, generation, run_id)

    assert snapshot_bound_fence["deadline_at"] > System.system_time(:millisecond) + 30_000
    assert :proceed = Runtime.authorize_identity_model(handle)

    runtime_b =
      start_supervised!(
        {Runtime,
         name: nil,
         namespace: namespace,
         mode: :review,
         context_port: {__MODULE__.ForbiddenContext, test_pid: self()},
         evaluator_port: {__MODULE__.ForbiddenEvaluator, test_pid: self()}},
        id: make_ref()
      )

    Process.sleep(275)
    _ = Runtime.ledger_records(runtime_b)

    assert {:ok, current_fence} = CasRecord.get(fence_key)
    assert current_fence["terminal"] == nil
    assert get_in(current_fence, ["identity_observation", "state"]) == "snapshot_bound"
    assert Runtime.ledger_records(runtime_a) == []
    assert Runtime.ledger_records(runtime_b) == []
    assert Runtime.replay(runtime_a, run_id) == {:error, :not_found}
    assert Runtime.replay(runtime_b, run_id) == {:error, :not_found}

    state_a = :sys.get_state(runtime_a)
    assert Map.has_key?(state_a.active, scope)
    assert state_a.active[scope].run_id == run_id
    assert state_a.active[scope].identity_model_permission == :consumed
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_identity_existing_timeout_terminal
  test "timeout keeps a concurrent legal terminal and only retains slim identity late state" do
    namespace = namespace("existing-timeout-terminal")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert :proceed = Runtime.authorize_identity_model(handle)

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(worker_pid, :stop) end)

    active_state =
      :sys.replace_state(runtime, fn state ->
        active = state.active[scope]
        monitor_ref = Process.monitor(worker_pid)

        %{
          state
          | active:
              Map.put(state.active, scope, %{
                active
                | worker_pid: worker_pid,
                  monitor_ref: monitor_ref
              })
        }
      end)

    assert active_state.active[scope].identity_model_permission == :consumed
    assert Process.alive?(worker_pid)

    settled_at = System.system_time(:millisecond)

    physical_terminal = %{
      "terminal_id" => ULID.generate(),
      "status" => "skipped_timeout",
      "decision" => %{"action" => "silence"},
      "evaluator" => %{},
      "settled_at" => settled_at
    }

    physical_terminal_bytes = CanonicalJSON.encode!(physical_terminal)

    assert {:ok, physical_fence} =
             CasRecord.update(
               fence_key,
               fn current ->
                 current
                 |> Map.put("deadline_at", settled_at)
                 |> Map.put("terminal", physical_terminal)
               end,
               create: false
             )

    assert physical_fence["terminal"] == physical_terminal
    assert get_in(physical_fence, ["identity_observation", "state"]) == "snapshot_bound"

    send(runtime, {:triage_evaluation_timeout, scope, generation, run_id})

    assert {:ok, finalized_fence} =
             eventually(fn ->
               case CasRecord.get(fence_key) do
                 {:ok, %{"identity_observation" => %{"state" => "finalized"}}} = result ->
                   result

                 _other ->
                   false
               end
             end)

    assert CanonicalJSON.encode!(finalized_fence["terminal"]) == physical_terminal_bytes
    assert finalized_fence["terminal"] == physical_terminal

    assert [run] =
             eventually(fn ->
               case Runtime.ledger_records(runtime) do
                 [_run] = records -> records
                 _other -> false
               end
             end)

    assert run["run_id"] == run_id
    assert run["status"] == "skipped_timeout"
    assert run["decision"] == physical_terminal["decision"]
    assert run["evaluator"] == %{}
    assert {:ok, ^run} = Runtime.replay(runtime, run_id)

    state_after_timeout = :sys.get_state(runtime)
    assert map_size(state_after_timeout.active) == 0
    assert map_size(state_after_timeout.late_wait) in [0, 1]

    case state_after_timeout.late_wait[run_id] do
      nil ->
        :ok

      late ->
        assert Map.keys(late) |> Enum.sort() ==
                 Enum.sort(
                   ~w(authority_status generation identity_late_result? monitor_ref result_capability run_id scope_ref_sha256 worker_pid)a
                 )

        assert late.run_id == run_id
        assert late.generation == generation
        assert late.authority_status == "skipped_timeout"
        assert late.identity_late_result?
        assert late.worker_pid == worker_pid
        assert is_reference(late.monitor_ref)
        assert is_reference(late.result_capability)
        assert late.scope_ref_sha256 == CanonicalJSON.sha256(CanonicalJSON.encode!(scope))

        collect_terms = fn collect_terms, value ->
          cond do
            is_map(value) ->
              Enum.flat_map(value, fn {key, child} ->
                collect_terms.(collect_terms, key) ++ collect_terms.(collect_terms, child)
              end)

            is_list(value) ->
              Enum.flat_map(value, &collect_terms.(collect_terms, &1))

            is_tuple(value) ->
              value
              |> Tuple.to_list()
              |> Enum.flat_map(&collect_terms.(collect_terms, &1))

            true ->
              [value]
          end
        end

        late_terms = collect_terms.(collect_terms, late)
        refute handle.capability in late_terms

        Enum.each(
          [
            :identity_capability,
            :identity_winning_input,
            :identity_winning_source_anchor,
            "source_authority",
            "T_ATLAS",
            "C_ATLAS",
            "U_PENG",
            "U_BFT",
            "B_BFT",
            "connect-atlas",
            "project-atlas"
          ],
          &refute(&1 in late_terms)
        )
    end

    assert Process.alive?(worker_pid)
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_identity_late_result
  test "a timed-out snapshot-bound identity run records one linked inert late result" do
    namespace = namespace("snapshot-bound-late-result")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert :proceed = Runtime.authorize_identity_model(handle)

    :sys.replace_state(runtime, fn state ->
      active = Map.put(state.active[scope], :monitor_ref, make_ref())
      %{state | active: Map.put(state.active, scope, active)}
    end)

    result_capability =
      :sys.get_state(runtime).active[scope].identity_result_capability

    deadline_at = System.system_time(:millisecond)

    assert {:ok, %{"deadline_at" => ^deadline_at}} =
             CasRecord.update(
               fence_key,
               &Map.put(&1, "deadline_at", deadline_at),
               create: false
             )

    send(runtime, {:triage_evaluation_timeout, scope, generation, run_id})

    assert {:ok, finalized_fence} =
             eventually(fn ->
               case CasRecord.get(fence_key) do
                 {:ok, %{"identity_observation" => %{"state" => "finalized"}}} = result ->
                   result

                 _other ->
                   false
               end
             end)

    terminal = finalized_fence["terminal"]
    assert terminal["status"] == "failed"

    assert terminal["decision"] == %{
             "action" => "silence",
             "reason" => "identity_diagnostic_indeterminate_model"
           }

    assert terminal["evaluator"] == %{}

    assert [authoritative] =
             eventually(fn ->
               case Runtime.ledger_records(runtime) do
                 [%{"authoritative" => true} = run] -> [run]
                 _other -> false
               end
             end)

    assert authoritative["run_id"] == run_id
    assert authoritative["status"] == "failed"
    assert authoritative["decision"] == terminal["decision"]
    assert {:ok, ^authoritative} = Runtime.replay(runtime, run_id)

    state_after_timeout = :sys.get_state(runtime)
    assert map_size(state_after_timeout.active) == 0
    assert map_size(state_after_timeout.late_wait) == 1

    send(
      runtime,
      {:triage_evaluation_result, scope, generation, run_id, result_capability,
       {:error, :identity_decision_invalid}}
    )

    assert [_, _] =
             records =
             eventually(fn ->
               case Runtime.ledger_records(runtime) do
                 [_, _] = records -> records
                 _other -> false
               end
             end)

    late = Enum.find(records, &(&1["authoritative"] == false))
    assert late["schema"] == "comma.triage-late-result.v1"
    assert late["linked_run_id"] == run_id
    assert late["status"] == "failed"

    assert late["decision"] == %{
             "action" => "silence",
             "reason" => "identity_decision_invalid"
           }

    assert late["evaluator"] == %{}
    assert late["authority_status"] == "failed"

    final_state = :sys.get_state(runtime)
    assert map_size(final_state.active) == 0
    assert map_size(final_state.late_wait) == 0

    public_bytes =
      CanonicalJSON.encode!(%{
        "terminal" => terminal,
        "authoritative" => authoritative,
        "late" => late,
        "replay" => unwrap(Runtime.replay(runtime, run_id))
      })

    Enum.each(
      [
        "U_PENG",
        "U_BFT",
        "B_BFT",
        "T_ATLAS",
        "C_ATLAS",
        "connect-atlas",
        "project-atlas",
        "identity_capability",
        "identity_fence_handle",
        "transport_attempt_id"
      ],
      &refute(String.contains?(public_bytes, &1))
    )

    refute_received :context_called
    refute_received :evaluator_called
  end

  test "a structurally valid late v3 result cannot replace the expired authoritative outcome" do
    namespace = namespace("late-participation-result")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)
    fixture = seed_active_snapshot_bound(runtime, namespace, generation, run_id)
    assert :proceed = Runtime.authorize_identity_model(fixture.handle)

    :sys.replace_state(runtime, fn state ->
      put_in(state, [:active, fixture.scope, :monitor_ref], make_ref())
    end)

    capability = :sys.get_state(runtime).active[fixture.scope].identity_result_capability

    assert {:ok, _} =
             CasRecord.update(
               fixture.fence_key,
               &Map.put(&1, "deadline_at", System.system_time(:millisecond))
             )

    send(runtime, {:triage_evaluation_timeout, fixture.scope, generation, run_id})

    assert [authoritative] =
             eventually(fn ->
               case Runtime.ledger_records(runtime) do
                 [%{"authoritative" => true} = run] -> [run]
                 _ -> false
               end
             end)

    assert authoritative["status"] == "failed"

    {decision, proof} = late_participation_result(fixture.model_input)
    assert Pipeline.valid_identity_late_result?({:ok, decision, proof})

    send(
      runtime,
      {:triage_evaluation_result, fixture.scope, generation, run_id, capability,
       {:ok, decision, proof}}
    )

    assert [_, _] =
             records =
             eventually(fn ->
               case Runtime.ledger_records(runtime) do
                 [_, _] = records -> records
                 _ -> false
               end
             end)

    assert Enum.find(records, &(&1["authoritative"] == true)) == authoritative
    late = Enum.find(records, &(&1["authoritative"] == false))
    assert late["status"] == "evaluated"
    assert late["decision"] == decision
    assert late["evaluator"] == proof
    assert late["authority_status"] == "failed"
    assert {:ok, ^authoritative} = Runtime.replay(runtime, run_id)
    assert map_size(:sys.get_state(runtime).active) == 0
    refute_received :evaluator_called
  end

  defp late_participation_result(input) do
    selection = %{
      "communication" => "reply",
      "investigate" => true,
      "reason" => "This is a late diagnostic fixture, never publication authority."
    }

    first = production_evaluated_terminal(input)["evaluator"]
    payload = Jason.decode!(first["provider_payload_bytes"])

    rendered =
      Map.update!(
        payload,
        "messages",
        &(&1 ++
            [
              %{
                "role" => "user",
                "content" => SalixIM.Triage.ParticipationDecision.render_instruction(selection)
              }
            ])
      )

    bytes = CanonicalJSON.encode!(rendered)
    hash = CanonicalJSON.sha256(bytes)

    chain =
      for value <- [first["provider_payload_bytes"], bytes],
          do: %{
            "payload_bytes" => value,
            "observer_payload_sha256" => CanonicalJSON.sha256(value),
            "transport_payload_sha256" => CanonicalJSON.sha256(value)
          }

    proof =
      Map.merge(first, %{
        "schema" => "comma.triage-model-proof.v3",
        "request_count" => 2,
        "provider_payload_bytes" => bytes,
        "provider_payload_sha256" => hash,
        "observer_payload_sha256" => hash,
        "transport_payload_sha256" => hash,
        "provider_payload_chain" => chain,
        "participation_decision" => selection,
        "tool_call_count" => 0,
        "tool_names" => [],
        "tool_receipts" => []
      })

    decision = %{
      "schema" => "comma.triage-product-decision.v2",
      "communication" => %{
        "kind" => "reply",
        "text" => "This late result must remain diagnostic.",
        "source_refs" => [hd(input["source_refs"])]
      },
      "companion_reaction" => nil,
      "context_candidates" => [],
      "delegations" => [
        %{
          "task" => "This late investigation must not be created.",
          "source_refs" => [hd(input["source_refs"])]
        }
      ],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    {decision, proof}
  end

  @tag :p1_identity_late_result_authority
  test "a forged late identity result cannot consume the run-owned late slot" do
    namespace = namespace("forged-snapshot-bound-late-result")
    generation = ULID.generate()
    run_id = ULID.generate()
    # This window measures writes caused by the forged result. Keep periodic
    # replay of the already-authorized terminal outside that window; recovery
    # is exercised separately and may legitimately rewrite derived projections.
    runtime = start_identity_test_runtime(namespace, recovery_idle_ms: 60_000)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert :proceed = Runtime.authorize_identity_model(handle)

    :sys.replace_state(runtime, fn state ->
      active = Map.put(state.active[scope], :monitor_ref, make_ref())
      %{state | active: Map.put(state.active, scope, active)}
    end)

    deadline_at = System.system_time(:millisecond) - 1

    assert {:ok, %{"deadline_at" => ^deadline_at}} =
             CasRecord.update(
               fence_key,
               &Map.put(&1, "deadline_at", deadline_at),
               create: false
             )

    send(runtime, {:triage_evaluation_timeout, scope, generation, run_id})

    assert {:ok, finalized_fence} =
             eventually(fn ->
               case CasRecord.get(fence_key) do
                 {:ok, %{"identity_observation" => %{"state" => "finalized"}}} = result ->
                   result

                 _other ->
                   false
               end
             end)

    assert [authoritative] = Runtime.ledger_records(runtime)
    assert {:ok, ^authoritative} = Runtime.replay(runtime, run_id)
    late_before = :sys.get_state(runtime).late_wait[run_id]
    assert is_map(late_before)
    :ok = SalixStore.S3.Fake.reset_put_log()

    forged_marker = "U_FORGED_LATE_RESULT"

    send(
      runtime,
      {:triage_evaluation_result, "forged-safe-scope", ULID.generate(), run_id,
       {:ok, %{"action" => "reply", "text" => forged_marker}, %{"sentinel" => forged_marker}}}
    )

    # This synchronous call is a same-sender FIFO barrier for the forged message.
    assert [^authoritative] = Runtime.ledger_records(runtime)
    assert Process.alive?(runtime)
    assert :sys.get_state(runtime).late_wait[run_id] == late_before
    assert {:ok, ^finalized_fence} = CasRecord.get(fence_key)
    assert {:ok, ^authoritative} = Runtime.replay(runtime, run_id)
    assert namespace_put_log(namespace) == []

    public_bytes = CanonicalJSON.encode!(%{"ledger" => Runtime.ledger_records(runtime)})
    refute String.contains?(public_bytes, forged_marker)
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_identity_generation_handoff
  test "an abnormal identity worker exit starts the queued next generation exactly once" do
    namespace = namespace("abnormal-down-next-generation")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    assert :proceed = Runtime.authorize_identity_model(handle)

    first_worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    test_pid = self()

    :sys.replace_state(runtime, fn state ->
      active = state.active[scope]
      monitor_ref = Process.monitor(first_worker)

      %{
        state
        | debounce_ms: 0,
          max_wait_ms: 0,
          context_port: {__MODULE__.NextGenerationContext, test_pid: test_pid},
          evaluator_port: {__MODULE__.NextGenerationEvaluator, test_pid: test_pid},
          active:
            Map.put(state.active, scope, %{
              active
              | worker_pid: first_worker,
                monitor_ref: monitor_ref
            })
      }
    end)

    receipt =
      next_generation_receipt(
        "Ev-next-generation-#{System.unique_integer([:positive])}",
        "queued next generation"
      )

    assert Map.has_key?(receipt["triage_event"], "endpoint_provenance")
    assert :ok = queue_next_generation(runtime, namespace, receipt)

    Process.sleep(25)
    queued_state = :sys.get_state(runtime)
    assert queued_state.active[scope].run_id == run_id
    assert Map.has_key?(queued_state.buckets, scope)
    next_generation = queued_state.buckets[scope].generation
    refute next_generation == generation
    refute_received {:next_generation_context, _generation}
    refute_received {:next_generation_evaluator, _generation}

    Process.exit(first_worker, :kill)

    assert {:ok, finalized_fence} =
             eventually(fn ->
               case CasRecord.get(fence_key) do
                 {:ok, %{"identity_observation" => %{"state" => "finalized"}}} = result ->
                   result

                 _other ->
                   false
               end
             end)

    assert get_in(finalized_fence, ["terminal", "status"]) == "failed"

    assert get_in(finalized_fence, ["terminal", "decision"]) == %{
             "action" => "silence",
             "reason" => "identity_diagnostic_indeterminate_model"
           }

    # The successor generation is released exactly once: it seals and takes its
    # own durable run fence.
    # L3: the released generation reaches a *stub* context/evaluator port only
    # once the BridgeForTeams context seam lands. Every receipt main's callback
    # route writes is endpoint-provenanced, so the successor is an identity run
    # and `Pipeline.validate_context_port/2` admits only the production port.
    successor_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, next_generation)

    assert {:ok, successor_fence} =
             eventually(fn ->
               case CasRecord.get(successor_key) do
                 {:ok, _fence} = result -> result
                 _other -> false
               end
             end)

    assert successor_fence["generation"] == next_generation
    assert successor_fence["bucket_scope"] == scope
    refute_received {:next_generation_context, _generation}
    refute_received {:next_generation_evaluator, _generation}
    refute_received :context_called
    refute_received :evaluator_called
  end

  @tag :p0_model_authority
  test "model authority denies a projection-bound wrong state without side effects" do
    namespace = namespace("model-authority-wrong-state")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{handle: handle, fence_key: fence_key, fence: projection_bound_fence} =
      seed_active_projection_bound(runtime, namespace, generation, run_id, run_id)

    assert_model_authority_denied(
      runtime,
      handle,
      fence_key,
      projection_bound_fence,
      namespace
    )
  end

  @tag :p0_model_authority
  test "model authority denies a foreign active run without side effects" do
    namespace = namespace("model-authority-foreign-run")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    :sys.replace_state(runtime, fn state ->
      active = Map.put(state.active[scope], :run_id, ULID.generate())
      %{state | active: Map.put(state.active, scope, active)}
    end)

    assert_model_authority_denied(runtime, handle, fence_key, snapshot_bound_fence, namespace)
  end

  @tag :p0_model_authority
  test "model authority denies a terminal snapshot-bound fence without side effects" do
    namespace = namespace("model-authority-terminal")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{handle: handle, fence_key: fence_key, snapshot_bound_fence: snapshot_bound_fence} =
      seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    terminal_fence =
      Map.put(snapshot_bound_fence, "terminal", %{
        "terminal_id" => ULID.generate(),
        "status" => "failed",
        "decision" => %{"action" => "silence", "reason" => "identity_projection_invalid"},
        "evaluator" => %{},
        "settled_at" => System.system_time(:millisecond)
      })

    assert {:ok, ^terminal_fence} = CasRecord.update(fence_key, fn _ -> terminal_fence end)
    assert_model_authority_denied(runtime, handle, fence_key, terminal_fence, namespace)
  end

  @tag :p0_model_authority
  test "model authority denies a bound-chain drift without side effects" do
    namespace = namespace("model-authority-chain-drift")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key,
      snapshot_bound_fence: snapshot_bound_fence
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    :sys.replace_state(runtime, fn state ->
      active =
        update_in(
          state.active[scope].identity_winning_input,
          ["events", Access.at(0), "text"],
          fn _ -> "coherently different winning source" end
        )
        |> then(&Map.put(state.active[scope], :identity_winning_input, &1))

      %{state | active: Map.put(state.active, scope, active)}
    end)

    assert_model_authority_denied(runtime, handle, fence_key, snapshot_bound_fence, namespace)
  end

  for observation_state <- @missing_durable_winner_states do
    test "recovery quarantines exact #{observation_state} without a durable winner" do
      observation_state = unquote(observation_state)
      sentinel = "U_RAW_MISSING_DURABLE_#{String.upcase(observation_state)}"
      namespace = namespace("missing-durable-#{observation_state}")
      scope = "generation-7:T_ATLAS:C_ATLAS:1787019000.000001"
      generation = ULID.generate()
      run_id = ULID.generate()

      fence =
        valid_v2_fence(scope, generation, run_id)
        |> Map.put("identity_observation", recovery_observation(observation_state, sentinel))
        |> Map.put("deadline_at", System.system_time(:millisecond))

      assert_missing_durable_winner_quarantined(
        namespace,
        scope,
        generation,
        run_id,
        fence,
        sentinel
      )
    end
  end

  for {observation_state, expected_reason} <- @recovery_cases do
    test "restart closes exact #{observation_state} identity observation without external work" do
      observation_state = unquote(observation_state)
      expected_reason = unquote(expected_reason)
      sentinel = "U_RAW_RECOVERY_#{String.upcase(observation_state)}"
      namespace = namespace("recovery-#{observation_state}")
      generation = ULID.generate()
      run_id = ULID.generate()

      {scope, sentinel, observation, input_snapshot, durable_bucket} =
        case observation_state do
          state when state in ~w(projection_bound snapshot_bound) ->
            production_bound_recovery_fixture(observation_state, generation)

          state
          when state in ~w(committed_attempted_error committed_attempted_error_v2 committed_local_rejected) ->
            scope = "generation-7:T_ATLAS:C_ATLAS:1787019000.000001"

            {:ok, endpoint_revision} =
              IdentityContract.endpoint_revision_sha256(production_connect_identity())

            durable_bucket =
              production_durable_bucket(
                scope,
                generation,
                production_sealed_event(endpoint_revision)
              )

            {scope, sentinel, recovery_observation(observation_state, sentinel),
             recovery_input(observation_state), durable_bucket}
        end

      fence =
        valid_v2_fence(scope, generation, run_id)
        |> Map.put("identity_observation", observation)
        |> Map.put("input_snapshot", input_snapshot)
        |> Map.put("deadline_at", System.system_time(:millisecond))

      assert_exact_v2_recovery(
        namespace,
        scope,
        generation,
        run_id,
        fence,
        expected_reason,
        sentinel,
        durable_bucket
      )
    end
  end

  for chain_reason <- ~w(page_budget_exceeded chain_deadline_exceeded lease_denied) do
    test "recovery settles a chain-only #{chain_reason} observation as a valid terminal" do
      chain_reason = unquote(chain_reason)
      namespace = namespace("chain-recovery-#{chain_reason}")
      scope = "generation-7:T_ATLAS:C_ATLAS:1787019000.000001"
      generation = ULID.generate()
      next_generation = ULID.generate()
      run_id = ULID.generate()

      {:ok, endpoint_revision} =
        IdentityContract.endpoint_revision_sha256(production_connect_identity())

      durable_bucket =
        production_durable_bucket(
          scope,
          generation,
          production_sealed_event(endpoint_revision)
        )

      # A second sealed generation makes the recovered fence the immediate
      # durable predecessor, so a wedged bucket is observable as an admission
      # refusal and not only as a missing Ledger record.
      durable_bucket =
        Map.update!(durable_bucket, "sealed_generations", fn [sealed] ->
          [sealed, Map.put(sealed, "generation", next_generation)]
        end)

      fence =
        valid_v2_fence(scope, generation, run_id)
        |> Map.put(
          "identity_observation",
          committed_observation(chain_attempted_error_transport_result(chain_reason))
        )
        |> Map.put("deadline_at", System.system_time(:millisecond))

      bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)
      fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

      assert {:ok, ^durable_bucket} = CasRecord.create(bucket_key, durable_bucket)
      assert {:ok, ^fence} = CasRecord.create(fence_key, fence)

      assert {:ok, recovered} = RunFence.recover_open(namespace, fence, :deadline)

      assert recovered["terminal"]["status"] == "failed"

      assert recovered["terminal"]["decision"] == %{
               "action" => "silence",
               "reason" => chain_reason
             }

      assert RunFence.valid_terminal?(recovered["terminal"])
      assert RunFence.valid_record?(recovered)

      assert {:ok, stored} = CasRecord.get(fence_key)
      assert RunFence.valid_record?(stored)

      assert {:ok, _authorized} = RunFence.authorize_projection_from_key(namespace, fence_key)
      assert RunFence.predecessor_authoritative?(namespace, scope, next_generation)
    end
  end

  # Chain page coverage is only ever validated for a v2 result, and no writer
  # produces a v1 result carrying a chain receipt — so admitting the combination
  # let a forged record smuggle in pages nothing verified. The same forgery must
  # also fail the bound recompute (see
  # `SalixIM.TriageIdentityProjectionRecomputeTest`).
  test "a fence admits an honest chain and refuses every forged chain claim" do
    scope = "generation-7:T_ATLAS:C_ATLAS:1787019000.000001"

    fence =
      fn result ->
        scope
        |> valid_v2_fence(ULID.generate(), ULID.generate())
        |> Map.put("identity_observation", committed_observation(result))
      end

    honest = chain_success_transport_result("visible thread text")
    assert RunFence.valid_record?(fence.(honest))

    v1_with_chain_receipt =
      honest
      |> Map.put("schema", "comma.triage-identity-transport-result.v1")
      |> Map.drop(~w(canonical_page_chain_bytes canonical_page_chain_sha256))

    refute RunFence.valid_record?(fence.(v1_with_chain_receipt))

    # No authorized read can spend more exchanges — or return more objects —
    # than its own bounds allow.
    refute RunFence.valid_record?(fence.(put_in(honest, ["receipt", "page_budget"], 64)))
    refute RunFence.valid_record?(fence.(put_in(honest, ["receipt", "message_count"], 201)))

    refute RunFence.valid_record?(
             fence.(
               put_in(
                 honest,
                 ["receipt", "exchanges", Access.at(0), "message_count"],
                 201
               )
             )
           )
  end

  test "identity freeze admits an answered recheck so the product skip can settle" do
    {private_projection, projected_context} = production_answered_projection_fixture()

    runtime = start_supervised!(__MODULE__.ConsentingFenceRuntime, id: make_ref())
    handle = %IdentityFenceHandle{runtime: runtime, capability: make_ref()}

    {:ok, endpoint_revision} =
      IdentityContract.endpoint_revision_sha256(production_connect_identity())

    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "generation" => ULID.generate(),
      "source_mode" => "historical_thread_reenactment",
      "events" => [production_sealed_event(endpoint_revision)],
      "receipt_refs" => ["s3://receipt/answered-r001"],
      "source_authority" => production_source_authority()
    }

    port =
      {__MODULE__.StubProjectedContext,
       identity_fence_handle: handle,
       frozen: projected_context,
       private_projection: private_projection}

    assert {:ok, model_input} = Pipeline.freeze(input, port)

    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    assert raw_bundle["schema"] == "comma.triage-private-source-bundle.v3"
    refute Map.has_key?(raw_bundle["raw_context"]["slack_context"], "expression_context")
    assert model_input["schema"] == "comma.triage-model-input.v3"
    assert get_in(model_input, ["snapshot", "schema"]) == "comma.triage-context-snapshot.v5"
    refute Map.has_key?(get_in(model_input, ["snapshot", "slack_context"]), "expression_context")

    # The clean product skip is a decision, not a projection error: the frozen
    # snapshot has to carry `answered => true` all the way to the gate that
    # settles `skipped_already_answered`.
    assert get_in(model_input, ["snapshot", "answered_recheck"]) == %{"answered" => true}
  end

  test "an answered recheck settles the product skip as a valid ledger terminal" do
    namespace = namespace("human-answered-skip")
    scope = "generation-1:T_ATLAS:C_ATLAS:200.001"
    generation = ULID.generate()
    now = System.system_time(:millisecond)

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "generation" => generation,
      "events" => [%{"event_id" => "answered-event"}],
      "receipt_refs" => [],
      "source_authority" => %{}
    }

    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

    fence = %{
      "schema" => "comma.triage-bucket-fence.v1",
      "bucket_scope" => scope,
      "generation" => generation,
      "run_id" => ULID.generate(),
      "created_at" => now,
      "deadline_at" => now + 60_000,
      "input_snapshot" => input,
      "terminal" => nil
    }

    assert {:ok, ^fence} = CasRecord.create(fence_key, fence)

    assert {:terminal, terminal} =
             Pipeline.run_compatibility(
               input,
               {__MODULE__.AnsweredContext, []},
               {__MODULE__.ForbiddenEvaluator, test_pid: self()},
               :none,
               fence_key
             )

    assert terminal["status"] == "skipped_already_answered"
    assert terminal["decision"] == %{"action" => "silence"}
    assert terminal["evaluator"] == %{"schema" => "comma.triage-answered-skip.v1"}

    # The gate's terminal is the record the fence CAS stores, so it must pass
    # the closed ledger schema once the fence mints its terminal id.
    assert RunFence.valid_terminal?(Map.put(terminal, "terminal_id", ULID.generate()))
    assert Pipeline.valid_identity_late_result?({:terminal, terminal})
    refute_received :evaluator_called
  end

  @tag :p0_identity_finalization
  test "RunFence owns snapshot-bound finalization CAS" do
    namespace = namespace("run-fence-finalize")
    generation = ULID.generate()
    run_id = ULID.generate()

    {scope, _sentinel, observation, model_input, durable_bucket} =
      production_bound_recovery_fixture("snapshot_bound", generation)

    terminal = production_evaluated_terminal(model_input)

    fence =
      valid_v2_fence(scope, generation, run_id)
      |> Map.put("identity_observation", observation)
      |> Map.put("input_snapshot", model_input)
      |> Map.put("terminal", terminal)

    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)
    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

    assert {:ok, ^durable_bucket} = CasRecord.create(bucket_key, durable_bucket)
    assert {:ok, ^fence} = CasRecord.create(fence_key, fence)
    assert {:ok, finalized} = RunFence.finalize(namespace, fence)

    assert finalized["terminal"] == terminal
    assert finalized["identity_observation"]["state"] == "finalized"
    assert is_integer(finalized["identity_observation"]["finalized_at_ms"])
    assert {:ok, ^finalized} = CasRecord.get(fence_key)
  end

  @tag :p0_identity_finalization
  test "restart finalizes an exact snapshot-bound evaluated terminal before projection" do
    namespace = namespace("finalize-terminal-restart")
    generation = ULID.generate()
    run_id = ULID.generate()

    {scope, sentinel, observation, model_input, durable_bucket} =
      production_bound_recovery_fixture("snapshot_bound", generation)

    terminal = production_evaluated_terminal(model_input)

    fence =
      valid_v2_fence(scope, generation, run_id)
      |> Map.put("identity_observation", observation)
      |> Map.put("input_snapshot", model_input)
      |> Map.put("terminal", terminal)

    assert_terminal_v2_restart_finalized(
      namespace,
      scope,
      generation,
      run_id,
      fence,
      terminal,
      sentinel,
      durable_bucket
    )
  end

  @tag :p0_identity_finalization
  test "restart quarantines finalized terminal proof and snapshot single-field drift" do
    Enum.each(~w(terminal proof snapshot), fn drift ->
      namespace = namespace("finalized-#{drift}-drift")
      generation = ULID.generate()
      run_id = ULID.generate()

      {scope, sentinel, observation, model_input, durable_bucket} =
        production_bound_recovery_fixture("snapshot_bound", generation)

      terminal = production_evaluated_terminal(model_input)

      finalized_fence =
        valid_v2_fence(scope, generation, run_id)
        |> Map.put(
          "identity_observation",
          observation
          |> Map.put("state", "finalized")
          |> Map.put("finalized_at_ms", System.system_time(:millisecond))
        )
        |> Map.put("input_snapshot", model_input)
        |> Map.put("terminal", terminal)

      drifted_fence =
        case drift do
          "terminal" ->
            put_in(
              finalized_fence,
              ["terminal", "decision", "identity_interpretation", "referenced_principal_refs"],
              ["principal://run/p999"]
            )

          "proof" ->
            put_in(
              finalized_fence,
              ["terminal", "evaluator", "canonical_snapshot_sha256"],
              String.duplicate("0", 64)
            )

          "snapshot" ->
            put_in(
              finalized_fence,
              ["input_snapshot", "canonical_snapshot_sha256"],
              String.duplicate("0", 64)
            )
        end

      assert_invalid_v2_quarantined(
        namespace,
        scope,
        generation,
        run_id,
        drifted_fence,
        sentinel,
        durable_bucket
      )
    end)
  end

  test "fresh intake rejects direct reactions while historical replay keeps its frozen catalog" do
    {private_projection, projected_context, raw_bundle} =
      production_custom_reaction_projection_fixture()

    {claim, transport_result, winning_source_anchor} =
      production_binding_fixture(raw_bundle, ULID.generate())

    winning_source_anchor = Map.put(winning_source_anchor, "source_mode", "periodic_patrol")
    [target_source_ref] = get_in(projected_context, ["slack_context", "source_refs"])

    decision = %{
      "schema" => "comma.triage-product-decision.v2",
      "communication" => %{
        "kind" => "reaction",
        "emoji" => "party_parrot",
        "source_refs" => [target_source_ref]
      },
      "companion_reaction" => nil,
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert {:error, :identity_decision_invalid} =
             IdentityContract.validate_bound_decision(
               decision,
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )

    assert :ok =
             IdentityContract.validate_replayed_bound_decision(
               decision,
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )

    assert {:error, :identity_decision_invalid} =
             IdentityContract.validate_replayed_bound_decision(
               put_in(decision, ["communication", "emoji"], "invented_custom"),
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )

    legacy_decision =
      decision
      |> Map.put("schema", "comma.triage-product-decision.v1")
      |> Map.delete("reaction")
      |> Map.put("communication", %{
        "kind" => "reaction",
        "emoji" => "eyes",
        "source_refs" => [target_source_ref]
      })

    assert {:error, :identity_decision_invalid} =
             IdentityContract.validate_bound_decision(
               legacy_decision,
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )
  end

  test "a v3 private bundle rejects a structurally valid v2 decision" do
    {private_projection, projected_context, raw_bundle} = production_projection_fixture()
    {:ok, alias_map} = Jason.decode(private_projection["alias_map_bytes"])

    raw_bundle =
      raw_bundle
      |> put_in(["sealed_events", Access.at(0), "source_mode"], "periodic_patrol")
      |> put_in(["raw_identity_context", "source_mode"], "periodic_patrol")
      |> put_in(["raw_context", "identity_context", "source_mode"], "periodic_patrol")

    projected_context =
      put_in(projected_context, ["identity_context", "source_mode"], "periodic_patrol")

    private_projection =
      production_private_projection(
        raw_bundle,
        raw_bundle["raw_context"],
        alias_map,
        projected_context
      )

    {claim, transport_result, winning_source_anchor} =
      production_binding_fixture(raw_bundle, ULID.generate())

    winning_source_anchor = Map.put(winning_source_anchor, "source_mode", "periodic_patrol")
    [target_source_ref] = get_in(projected_context, ["slack_context", "source_refs"])

    decision = %{
      "schema" => ProductDecision.schema(),
      "communication" => %{
        "kind" => "reply",
        "text" => "I will follow up.",
        "source_refs" => [target_source_ref]
      },
      "companion_reaction" => %{
        "kind" => "reaction",
        "emoji" => "eyes",
        "source_refs" => [target_source_ref]
      },
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    # The old private bundle fails closed at the pure identity boundary, before
    # any durable obligation or provider-effect path is reachable. Mixed-version
    # calls may be retried after rollout; no dual reader or compatibility state is required.
    assert ProductDecision.structurally_valid?(decision)

    assert {:error, :identity_decision_invalid} =
             IdentityContract.validate_bound_decision(
               decision,
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )
  end

  test "legacy v2 decisions replay only after the exact terminal is stored" do
    namespace = namespace("legacy-product-replay")
    generation = ULID.generate()

    {scope, _sentinel, observation, model_input, durable_bucket} =
      production_bound_recovery_fixture("snapshot_bound", generation, "callback")

    decision = %{
      "schema" => "comma.triage-product-decision.v2",
      "communication" => %{"kind" => "silence", "reason" => "duplicate", "source_refs" => []},
      "companion_reaction" => nil,
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    terminal = Map.put(production_evaluated_terminal(model_input), "decision", decision)

    open_fence =
      valid_v2_fence(scope, generation, ULID.generate())
      |> Map.put("identity_observation", observation)
      |> Map.put("input_snapshot", model_input)

    saved_fence =
      open_fence
      |> Map.put("terminal", terminal)
      |> put_in(["identity_observation", "state"], "finalized")
      |> put_in(["identity_observation", "finalized_at_ms"], System.system_time(:millisecond))

    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)
    assert {:ok, _} = CasRecord.create(bucket_key, durable_bucket)
    assert {:ok, _} = CasRecord.create(fence_key, open_fence)

    assert {:error, :identity_diagnostic_invalid_fence} =
             RunFence.authorize_projection_from_storage(namespace, saved_fence)

    assert {:ok, ^saved_fence} = CasRecord.update(fence_key, fn _ -> saved_fence end)

    assert {:ok, authorization} =
             RunFence.authorize_projection_from_storage(namespace, saved_fence)

    assert authorization.fence == saved_fence

    changed =
      put_in(saved_fence, ["terminal", "decision", "communication", "reason"], "no_reply_needed")

    assert {:error, :identity_diagnostic_invalid_fence} =
             RunFence.authorize_projection_from_storage(namespace, changed)

    assert {:ok, ^saved_fence} = CasRecord.get(fence_key)
  end

  test "the durable identity fence accepts v4/v6 and rejects crossed snapshot tags" do
    {private_projection, projected_context, raw_bundle} =
      production_custom_reaction_projection_fixture()

    generation = ULID.generate()
    run_id = ULID.generate()

    {claim, transport_result, _winning_source_anchor} =
      production_binding_fixture(raw_bundle, generation)

    assert {:ok, %{sha256: projected_sha256}} =
             IdentityContract.recompute_projected_context(private_projection)

    model_input =
      production_model_input(projected_context, "comma.triage-context-snapshot.v6")

    now = System.system_time(:millisecond)

    observation = %{
      "schema" => "comma.triage-identity-observation.v1",
      "state" => "snapshot_bound",
      "claim" => claim,
      "claimed_at_ms" => now,
      "transport_attempt_id" => ULID.generate(),
      "transport_marked_at_ms" => now,
      "transport_result" => transport_result,
      "committed_at_ms" => now,
      "private_projection" => private_projection,
      "pseudonymous_context_sha256" => projected_sha256,
      "projection_bound_at_ms" => now,
      "canonical_snapshot_sha256" => model_input["canonical_snapshot_sha256"],
      "snapshot_bound_at_ms" => now
    }

    fence =
      valid_v2_fence("expression-scope", generation, run_id)
      |> Map.put("identity_observation", observation)
      |> Map.put("input_snapshot", model_input)

    assert RunFence.valid_record?(fence)

    crossed_input =
      with_snapshot_schema(model_input, "comma.triage-context-snapshot.v5")

    crossed_fence =
      fence
      |> Map.put("input_snapshot", crossed_input)
      |> put_in(
        ["identity_observation", "canonical_snapshot_sha256"],
        crossed_input["canonical_snapshot_sha256"]
      )

    refute RunFence.valid_record?(crossed_fence)

    legacy_generation = ULID.generate()

    {legacy_scope, _sentinel, legacy_observation, legacy_input, _durable_bucket} =
      production_bound_recovery_fixture("snapshot_bound", legacy_generation)

    legacy_fence =
      valid_v2_fence(legacy_scope, legacy_generation, ULID.generate())
      |> Map.put("identity_observation", legacy_observation)
      |> Map.put("input_snapshot", legacy_input)

    assert RunFence.valid_record?(legacy_fence)

    legacy_crossed_input =
      with_snapshot_schema(legacy_input, "comma.triage-context-snapshot.v6")

    legacy_crossed_fence =
      legacy_fence
      |> Map.put("input_snapshot", legacy_crossed_input)
      |> put_in(
        ["identity_observation", "canonical_snapshot_sha256"],
        legacy_crossed_input["canonical_snapshot_sha256"]
      )

    refute RunFence.valid_record?(legacy_crossed_fence)
  end

  for order <- [:down_then_timeout, :timeout_then_down] do
    @tag :p0_identity_finalization
    test "snapshot-bound worker crash closes safely for #{order}" do
      assert_snapshot_bound_worker_crash_recovery(unquote(order))
    end
  end

  defp assert_invalid_v2_quarantined(
         namespace,
         scope,
         generation,
         run_id,
         fence,
         sentinel,
         durable_bucket \\ nil
       ) do
    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
    ledger_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)
    replay_key = SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run_id)

    if durable_bucket do
      bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)
      assert {:ok, ^durable_bucket} = CasRecord.create(bucket_key, durable_bucket)
    end

    assert {:ok, ^fence} = CasRecord.create(fence_key, fence)
    fence_body_before = SalixStore.S3.Fake.dump()[fence_key].body
    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = SalixStore.S3.Fake.reset_read_log()

    runtime =
      start_supervised!(
        {Runtime,
         name: nil,
         namespace: namespace,
         mode: :review,
         evaluator_port: {__MODULE__.ForbiddenEvaluator, test_pid: self()}},
        id: make_ref()
      )

    assert eventually(fn ->
             Enum.member?(SalixStore.S3.Fake.read_log(), {:get, fence_key})
           end)

    # A public call is also a mailbox barrier for the startup recovery pass.
    _ = Runtime.ledger_records(runtime)
    Process.sleep(25)

    public_bodies =
      SalixStore.S3.Fake.dump()
      |> Map.take([ledger_key, replay_key])
      |> Map.values()
      |> Enum.map(& &1.body)

    relevant_puts =
      SalixStore.S3.Fake.put_log()
      |> Enum.filter(fn key ->
        key == fence_key or key == replay_key or
          String.starts_with?(
            key,
            SalixStore.TriageKeys.ctl_im_triage_ledger_runs_prefix(namespace)
          )
      end)

    refute_received :evaluator_called

    assert %{
             fence: ^fence,
             fence_body: ^fence_body_before,
             ledger_records: [],
             replay: {:error, :not_found},
             relevant_puts: [],
             leaked_raw_sentinel?: false
           } = %{
             fence: unwrap(CasRecord.get(fence_key)),
             fence_body: SalixStore.S3.Fake.dump()[fence_key].body,
             ledger_records: Runtime.ledger_records(runtime),
             replay: Runtime.replay(runtime, run_id),
             relevant_puts: relevant_puts,
             leaked_raw_sentinel?: Enum.any?(public_bodies, &String.contains?(&1, sentinel))
           }
  end

  defp assert_missing_durable_winner_quarantined(
         namespace,
         scope,
         generation,
         run_id,
         fence,
         sentinel
       ) do
    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
    ledger_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)
    replay_key = SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run_id)

    assert {:ok, ^fence} = CasRecord.create(fence_key, fence)
    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = SalixStore.S3.Fake.reset_read_log()

    unrelated_recovery_lease_key =
      SalixStore.TriageKeys.ctl_im_triage_receipt_recovery_lease(
        namespace("unrelated-receipt-recovery")
      )

    assert {:ok, _lease} =
             SalixStore.Lease.acquire(
               unrelated_recovery_lease_key,
               "identity-fence-test-unrelated-recovery"
             )

    assert unrelated_recovery_lease_key in SalixStore.S3.Fake.put_log()

    runtime =
      start_supervised!(
        {Runtime,
         name: nil,
         namespace: namespace,
         mode: :review,
         context_port: {__MODULE__.ForbiddenContext, test_pid: self()},
         evaluator_port: {__MODULE__.ForbiddenEvaluator, test_pid: self()}},
        id: make_ref()
      )

    assert eventually(fn ->
             Enum.member?(SalixStore.S3.Fake.read_log(), {:get, fence_key})
           end)

    _ = Runtime.ledger_records(runtime)
    Process.sleep(25)

    public_bodies =
      SalixStore.S3.Fake.dump()
      |> Map.take([ledger_key, replay_key])
      |> Map.values()
      |> Enum.map(& &1.body)

    refute_received :context_called
    refute_received :evaluator_called

    assert %{
             fence: ^fence,
             terminal: nil,
             ledger_records: [],
             replay: {:error, :not_found},
             namespace_puts: [],
             leaked_raw_sentinel?: false
           } = %{
             fence: unwrap(CasRecord.get(fence_key)),
             terminal: unwrap(CasRecord.get(fence_key))["terminal"],
             ledger_records: Runtime.ledger_records(runtime),
             replay: Runtime.replay(runtime, run_id),
             namespace_puts: namespace_put_log(namespace),
             leaked_raw_sentinel?: Enum.any?(public_bodies, &String.contains?(&1, sentinel))
           }
  end

  defp namespace_put_log(namespace) do
    namespace_prefix =
      namespace
      |> SalixStore.TriageKeys.ctl_im_triage_buckets_prefix()
      |> String.replace_suffix("buckets/", "")

    Enum.filter(SalixStore.S3.Fake.put_log(), &String.starts_with?(&1, namespace_prefix))
  end

  # Main's Slack callback route admits only verified thread roots through
  # `ProviderReceipts.record_slack_triage_root/2`, and those receipts are
  # bound to one durable connect authority. These cases are about what the
  # engine does with a *successor* generation once one already exists, not
  # about admission, so they write the exact typed receipt bytes and hand them
  # to the Runtime through the same durable append the admission path uses.
  defp next_generation_receipt(event_id, text) do
    event_id = "#{event_id}-#{System.unique_integer([:positive])}"
    created_at = System.system_time(:millisecond)
    key = Keys.ctl_im_slack_event_receipt("connect-atlas", event_id)

    %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "connect_id" => "connect-atlas",
      "event_id" => event_id,
      "connect_generation" => "generation-7",
      "created_at" => created_at,
      "receipt_ref" => "s3://" <> key,
      "source_message_ref" => "generation-7:T_ATLAS:C_ATLAS:1787019000.000001:1787019000.000002",
      "triage_event" => %{
        "event_id" => event_id,
        "connect_generation" => "generation-7",
        "message_ts" => "1787019000.000002",
        "actor_id" => "U_NEXT",
        "actor_kind" => "human",
        "text" => text,
        "event_type" => "message",
        "addressing_kind" => "ambient",
        "trigger_kind" => "none",
        "fast_path" => false,
        "source_mode" => "callback",
        "bucket" => %{
          "workspace_id" => "T_ATLAS",
          "channel_id" => "C_ATLAS",
          "thread_ts" => "1787019000.000001"
        },
        "endpoint_provenance" => %{
          "schema" => "comma.slack-endpoint-provenance.v1",
          "captured_at_ms" => created_at,
          "callback_api_app_id" => "A_BFT",
          "fast_path_bot_user_id" => "U_BFT",
          "endpoint_revision_sha256" => String.duplicate("e", 64)
        }
      }
    }
  end

  # The seeded production bucket is fence-shaped evidence rather than a record
  # this suite re-admits, so the successor receipt is handed to the engine
  # against the durable bucket as read, exactly as `accept_current/3` does once
  # admission has already claimed and appended it.
  defp queue_next_generation(runtime, namespace, receipt) do
    assert {:ok, :appended, durable} = Bucketing.append_membership(namespace, receipt)

    GenServer.cast(
      runtime,
      {:admitted, receipt, durable, SystemsObservability.Context.capture()}
    )

    # The arming notification is asynchronous; sync on the engine's mailbox
    # before asserting on the local view it produces.
    _ = :sys.get_state(runtime)
    :ok
  end

  defp finalized_histories(count) do
    1..count
    |> Enum.map(&{ULID.generate(), &1})
    |> Enum.map(fn {generation, ordinal} ->
      {scope, _sentinel, observation, model_input, durable_bucket} =
        production_bound_recovery_fixture("snapshot_bound", generation)

      sealed =
        durable_bucket["sealed_generations"]
        |> hd()
        |> update_in(["receipts"], fn [receipt] ->
          [
            Map.put(
              receipt,
              "receipt_ref",
              "s3://receipt/terminal-convergence-r#{ordinal |> Integer.to_string() |> String.pad_leading(3, "0")}"
            )
          ]
        end)

      run_id = ULID.generate()

      fence =
        valid_v2_fence(scope, generation, run_id)
        |> Map.put(
          "identity_observation",
          observation
          |> Map.put("state", "finalized")
          |> Map.put("finalized_at_ms", System.system_time(:millisecond))
        )
        |> Map.put("input_snapshot", model_input)
        |> Map.put("terminal", production_evaluated_terminal(model_input))

      %{
        scope: scope,
        generation: generation,
        run_id: run_id,
        sealed: sealed,
        fence: fence
      }
    end)
  end

  defp start_identity_test_runtime(namespace, opts \\ []) do
    runtime =
      start_supervised!(
        {Runtime,
         name: nil,
         namespace: namespace,
         mode: :review,
         recovery_idle_ms: Keyword.get(opts, :recovery_idle_ms, 100),
         context_port: {__MODULE__.ForbiddenContext, test_pid: self()},
         evaluator_port: {__MODULE__.ForbiddenEvaluator, test_pid: self()}},
        id: make_ref()
      )

    Process.sleep(120)
    assert [] = Runtime.ledger_records(runtime)
    :ok = :sys.suspend(runtime)
    runtime
  end

  defp seed_active_projection_bound(
         runtime,
         namespace,
         generation,
         active_run_id,
         physical_run_id
       ) do
    {scope, _sentinel, observation, input_snapshot, durable_bucket} =
      production_bound_recovery_fixture("projection_bound", generation)

    fence =
      valid_v2_fence(scope, generation, physical_run_id)
      |> Map.put("identity_observation", observation)
      |> Map.put("input_snapshot", input_snapshot)

    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    assert {:ok, ^durable_bucket} = CasRecord.create(bucket_key, durable_bucket)
    assert {:ok, ^fence} = CasRecord.create(fence_key, fence)

    winning_input =
      production_winning_input(
        generation,
        hd(durable_bucket["sealed_generations"])["receipts"]
      )

    capability = make_ref()
    result_capability = make_ref()
    timeout_ref = Process.send_after(self(), :unused_snapshot_handle_timeout, 60_000)

    active = %{
      generation: generation,
      run_id: active_run_id,
      fence_key: fence_key,
      monitor_ref: nil,
      timeout_ref: timeout_ref,
      worker_pid: self(),
      identity_capability: capability,
      identity_result_capability: result_capability,
      identity_transport_attempt_id: ULID.generate(),
      identity_transport_permission: :consumed,
      identity_model_permission: :available,
      identity_read_tool_permission: :available,
      identity_base_input_sha256: CanonicalJSON.sha256(CanonicalJSON.encode!(input_snapshot)),
      identity_winning_input: winning_input,
      identity_winning_source_anchor: %{
        "schema" => "comma.triage-winning-source-anchor.v1",
        "generation" => generation,
        "source_mode" => "historical_thread_reenactment",
        "sealed_events" => winning_input["events"],
        "source_authority" => winning_input["source_authority"]
      }
    }

    :sys.replace_state(runtime, fn state ->
      %{state | active: Map.put(state.active, scope, active)}
    end)

    :ok = :sys.resume(runtime)

    %{
      scope: scope,
      handle: %IdentityFenceHandle{runtime: runtime, capability: capability},
      result_capability: result_capability,
      fence_key: fence_key,
      fence: fence,
      observation: observation
    }
  end

  defp seed_active_snapshot_bound(runtime, namespace, generation, run_id) do
    fixture = seed_active_projection_bound(runtime, namespace, generation, run_id, run_id)

    {:ok, %{projected_context: projected_context}} =
      IdentityContract.recompute_projected_context(fixture.observation["private_projection"])

    model_input = production_model_input(projected_context)
    assert :ok = Runtime.bind_identity_snapshot(fixture.handle, model_input)
    assert {:ok, snapshot_bound_fence} = CasRecord.get(fixture.fence_key)

    Map.merge(fixture, %{
      model_input: model_input,
      snapshot_bound_fence: snapshot_bound_fence
    })
  end

  defp seed_active_transport_started(runtime, namespace, generation, run_id) do
    fixture = seed_active_projection_bound(runtime, namespace, generation, run_id, run_id)
    active = :sys.get_state(runtime).active[fixture.scope]

    observation = %{
      "schema" => "comma.triage-identity-observation.v1",
      "state" => "transport_maybe_started",
      "claim" => fixture.observation["claim"],
      "claimed_at_ms" => fixture.observation["claimed_at_ms"],
      "transport_attempt_id" => active.identity_transport_attempt_id,
      "transport_marked_at_ms" => System.system_time(:millisecond)
    }

    fence = Map.put(fixture.fence, "identity_observation", observation)

    assert {:ok, ^fence} = CasRecord.update(fixture.fence_key, fn _current -> fence end)
    Map.put(fixture, :fence, fence)
  end

  defp assert_model_authority_denied(runtime, handle, fence_key, expected_fence, namespace) do
    :ok = SalixStore.S3.Fake.reset_put_log()

    assert {:error, :identity_fence_denied} = Runtime.authorize_identity_model(handle)
    assert Process.alive?(runtime)
    assert {:ok, ^expected_fence} = CasRecord.get(fence_key)
    assert namespace_put_log(namespace) == []
    refute_received :context_called
    refute_received :evaluator_called
  end

  defp assert_exact_v2_recovery(
         namespace,
         scope,
         generation,
         run_id,
         fence,
         expected_reason,
         sentinel,
         durable_bucket
       ) do
    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

    if durable_bucket do
      bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)
      assert {:ok, ^durable_bucket} = CasRecord.create(bucket_key, durable_bucket)
    end

    assert {:ok, ^fence} = CasRecord.create(fence_key, fence)

    runtime =
      start_supervised!(
        {Runtime,
         name: nil,
         namespace: namespace,
         mode: :review,
         context_port: {__MODULE__.ForbiddenContext, test_pid: self()},
         evaluator_port: {__MODULE__.ForbiddenEvaluator, test_pid: self()}},
        id: make_ref()
      )

    assert [run] =
             eventually(fn ->
               case Runtime.ledger_records(runtime) do
                 [_run] = records -> records
                 _other -> false
               end
             end)

    assert {:ok, recovered_fence} = CasRecord.get(fence_key)
    terminal = recovered_fence["terminal"]

    if get_in(fence, ["identity_observation", "state"]) == "snapshot_bound" do
      assert %{
               "state" => "finalized",
               "finalized_at_ms" => finalized_at_ms
             } = recovered_fence["identity_observation"]

      assert is_integer(finalized_at_ms) and finalized_at_ms > 0
    end

    assert Map.keys(terminal) |> Enum.sort() ==
             Enum.sort(~w(terminal_id status decision evaluator settled_at))

    assert terminal["status"] == "failed"
    assert terminal["decision"] == %{"action" => "silence", "reason" => expected_reason}
    assert terminal["evaluator"] == %{}
    assert ULID.valid?(terminal["terminal_id"])
    assert is_integer(terminal["settled_at"]) and terminal["settled_at"] > 0

    expected_run_keys =
      if get_in(fence, ["input_snapshot", "schema"]) == "comma.triage-model-input.v3" do
        ~w(
          schema run_id bucket generation authoritative created_at status
          input_receipt_refs input_snapshot input_snapshot_sha256 decision evaluator
          canonical_snapshot_bytes context_sha256 source_refs
          source_refs_canonical_bytes source_refs_sha256
        )
      else
        ~w(
          schema run_id bucket generation authoritative created_at status
          input_receipt_refs input_snapshot input_snapshot_sha256 decision evaluator
        )
      end

    assert Map.keys(run) |> Enum.sort() == Enum.sort(expected_run_keys)
    assert run["bucket"] == "bucket://run/scope"
    assert run["status"] == "failed"
    assert run["decision"] == terminal["decision"]
    assert run["evaluator"] == %{}
    assert {:ok, ^run} = Runtime.replay(runtime, run_id)

    public_bytes = Jason.encode!([terminal, run, unwrap(Runtime.replay(runtime, run_id))])
    refute String.contains?(public_bytes, sentinel)
    refute_received :context_called
    refute_received :evaluator_called
  end

  defp assert_terminal_v2_restart_finalized(
         namespace,
         scope,
         generation,
         run_id,
         fence,
         terminal,
         sentinel,
         durable_bucket
       ) do
    fence_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    assert {:ok, ^durable_bucket} = CasRecord.create(bucket_key, durable_bucket)
    assert {:ok, ^fence} = CasRecord.create(fence_key, fence)

    runtime =
      start_supervised!(
        {Runtime,
         name: nil,
         namespace: namespace,
         mode: :review,
         context_port: {__MODULE__.ForbiddenContext, test_pid: self()},
         evaluator_port: {__MODULE__.ForbiddenEvaluator, test_pid: self()}},
        id: make_ref()
      )

    assert [run] =
             eventually(fn ->
               case Runtime.ledger_records(runtime) do
                 [_run] = records -> records
                 _other -> false
               end
             end)

    assert {:ok, finalized_fence} = CasRecord.get(fence_key)
    assert finalized_fence["terminal"] == terminal

    assert %{
             "state" => "finalized",
             "finalized_at_ms" => finalized_at_ms
           } = finalized_fence["identity_observation"]

    assert is_integer(finalized_at_ms) and finalized_at_ms > 0
    assert run["status"] == "evaluated"
    assert run["decision"] == terminal["decision"]
    assert run["evaluator"] == terminal["evaluator"]
    assert {:ok, ^run} = Runtime.replay(runtime, run_id)

    public_bytes = Jason.encode!([terminal, run, unwrap(Runtime.replay(runtime, run_id))])
    refute String.contains?(public_bytes, sentinel)
    refute_received :context_called
    refute_received :evaluator_called
  end

  defp assert_snapshot_bound_worker_crash_recovery(order) do
    namespace = namespace("worker-crash-#{order}")
    generation = ULID.generate()
    run_id = ULID.generate()
    runtime = start_identity_test_runtime(namespace)

    %{
      scope: scope,
      handle: handle,
      fence_key: fence_key,
      model_input: model_input
    } = seed_active_snapshot_bound(runtime, namespace, generation, run_id)

    test_pid = self()

    worker_pid =
      spawn(fn ->
        receive do
          {:authorize_then_crash, ^handle, ^model_input} ->
            send(test_pid, {:identity_evaluator_received_v3, self(), model_input})
            authorization = Runtime.authorize_identity_model(handle)
            send(test_pid, {:identity_model_authorization, self(), authorization})

            if authorization == :proceed do
              send(test_pid, {:identity_model_attempt, self()})
            end

            receive do
              :kill_after_snapshot -> Process.exit(self(), :kill)
            end
        end
      end)

    state =
      :sys.replace_state(runtime, fn state ->
        active = state.active[scope]
        monitor_ref = Process.monitor(worker_pid)

        %{
          state
          | active:
              Map.put(state.active, scope, %{
                active
                | worker_pid: worker_pid,
                  monitor_ref: monitor_ref
              })
        }
      end)

    monitor_ref = state.active[scope].monitor_ref
    send(worker_pid, {:authorize_then_crash, handle, model_input})

    assert_receive {:identity_evaluator_received_v3, ^worker_pid, ^model_input}, 500
    assert_receive {:identity_model_authorization, ^worker_pid, :proceed}, 500
    assert_receive {:identity_model_attempt, ^worker_pid}, 500

    deadline_at = System.system_time(:millisecond) + 250

    assert {:ok, %{"deadline_at" => ^deadline_at}} =
             CasRecord.update(
               fence_key,
               &Map.put(&1, "deadline_at", deadline_at),
               create: false
             )

    timeout_message = {:triage_evaluation_timeout, scope, generation, run_id}

    case order do
      :down_then_timeout ->
        :ok = :sys.suspend(runtime)
        send(worker_pid, :kill_after_snapshot)
        assert eventually(fn -> not Process.alive?(worker_pid) end)

        assert eventually(fn ->
                 {:messages, messages} = Process.info(runtime, :messages)

                 Enum.any?(messages, fn
                   {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} -> true
                   _other -> false
                 end)
               end)

        :ok = :sys.resume(runtime)
        _ = :sys.get_state(runtime)

        assert {:ok, %{"identity_observation" => %{"state" => "finalized"}}} =
                 eventually(
                   fn ->
                     case CasRecord.get(fence_key) do
                       {:ok, %{"identity_observation" => %{"state" => "finalized"}}} = result ->
                         result

                       _other ->
                         false
                     end
                   end,
                   10
                 )

        state_after_down = :sys.get_state(runtime)
        assert map_size(state_after_down.active) == 0
        assert map_size(state_after_down.late_wait) == 0
        assert System.system_time(:millisecond) < deadline_at

        wait_until_ms(deadline_at)
        send(runtime, timeout_message)

      :timeout_then_down ->
        wait_until_ms(deadline_at)
        send(runtime, timeout_message)

        assert eventually(fn ->
                 state = :sys.get_state(runtime)
                 not Map.has_key?(state.active, scope)
               end)

        send(worker_pid, :kill_after_snapshot)
        assert eventually(fn -> not Process.alive?(worker_pid) end)
        Process.sleep(20)
        _ = :sys.get_state(runtime)
    end

    assert {:ok, finalized_fence} =
             eventually(fn ->
               case CasRecord.get(fence_key) do
                 {:ok, %{"identity_observation" => %{"state" => "finalized"}}} = result ->
                   result

                 _other ->
                   false
               end
             end)

    assert [run] =
             eventually(fn ->
               case Runtime.ledger_records(runtime) do
                 [_run] = records -> records
                 _other -> false
               end
             end)

    retry_caller =
      spawn(fn ->
        result = Runtime.authorize_identity_model(handle)
        send(test_pid, {:identity_model_retry_authorization, result})

        if result == :proceed do
          send(test_pid, {:identity_model_attempt, self()})
        end
      end)

    assert_receive {:identity_model_retry_authorization, {:error, :identity_fence_denied}},
                   500

    refute Process.alive?(retry_caller)

    state = :sys.get_state(runtime)

    # Count-only assertions avoid dumping the private active/late maps on RED.
    assert map_size(state.active) == 0
    assert map_size(state.late_wait) == 0

    terminal = finalized_fence["terminal"]
    assert terminal["status"] == "failed"

    assert terminal["decision"] == %{
             "action" => "silence",
             "reason" => "identity_diagnostic_indeterminate_model"
           }

    assert terminal["evaluator"] == %{}
    assert run["status"] == "failed"
    assert run["decision"] == terminal["decision"]
    assert run["evaluator"] == %{}
    assert {:ok, ^run} = Runtime.replay(runtime, run_id)
    refute_receive {:identity_model_attempt, _pid}, 50
    refute_received :context_called
    refute_received :evaluator_called
  end

  defp production_evaluated_terminal(model_input) do
    provider = "fake-finalization-provider"
    model = "fake-finalization-model-v1"
    prompt_bytes = "identity finalization prompt v1"
    policy_bytes = "identity finalization policy v1"

    payload_bytes =
      CanonicalJSON.encode!(%{
        "model" => model,
        "messages" => [
          %{"role" => "user", "content" => model_input["canonical_snapshot_bytes"]}
        ]
      })

    payload_sha256 = CanonicalJSON.sha256(payload_bytes)

    %{
      "terminal_id" => ULID.generate(),
      "status" => "evaluated",
      "decision" => %{
        "action" => "silence",
        "identity_interpretation" => %{
          "topic" => "self_identity",
          "referenced_principal_refs" => ["principal://run/self"]
        },
        "source_refs" => []
      },
      "evaluator" => %{
        "schema" => "comma.triage-model-proof.v1",
        "provider" => provider,
        "model" => model,
        "provider_sha256" => CanonicalJSON.sha256(provider),
        "model_sha256" => CanonicalJSON.sha256(model),
        "prompt_sha256" => CanonicalJSON.sha256(prompt_bytes),
        "policy_sha256" => CanonicalJSON.sha256(policy_bytes),
        "provider_payload_bytes" => payload_bytes,
        "provider_payload_sha256" => payload_sha256,
        "observer_payload_sha256" => payload_sha256,
        "transport_payload_sha256" => payload_sha256,
        "request_count" => 1,
        "retry" => false,
        "canonical_snapshot_sha256" => model_input["canonical_snapshot_sha256"],
        "source_refs_sha256" => model_input["source_refs_sha256"]
      },
      "settled_at" => System.system_time(:millisecond)
    }
  end

  defp wait_until_ms(deadline_at) do
    Process.sleep(max(0, deadline_at - System.system_time(:millisecond) + 5))
  end

  defp recovery_observation("unused", _sentinel) do
    %{"schema" => "comma.triage-identity-observation.v1", "state" => "unused"}
  end

  defp recovery_observation("claimed", _sentinel) do
    claimed_observation()
  end

  defp recovery_observation("transport_maybe_started", _sentinel) do
    transport_observation()
  end

  defp recovery_observation("committed_success", sentinel) do
    committed_observation(success_transport_result(sentinel))
  end

  defp recovery_observation("projection_bound", sentinel) do
    committed_observation(success_transport_result(sentinel))
    |> Map.put("state", "projection_bound")
    |> Map.put("private_projection", private_projection(sentinel))
    |> Map.put("pseudonymous_context_sha256", String.duplicate("9", 64))
    |> Map.put("projection_bound_at_ms", System.system_time(:millisecond))
  end

  defp recovery_observation("snapshot_bound", sentinel) do
    recovery_observation("projection_bound", sentinel)
    |> Map.put("state", "snapshot_bound")
    |> Map.put("canonical_snapshot_sha256", recovery_model_input()["canonical_snapshot_sha256"])
    |> Map.put("snapshot_bound_at_ms", System.system_time(:millisecond))
  end

  defp recovery_observation("committed_attempted_error", _sentinel) do
    committed_observation(attempted_error_transport_result("decode_error"))
  end

  defp recovery_observation("committed_attempted_error_v2", _sentinel) do
    receipt =
      "decode_error"
      |> slack_read_receipt(nil)
      |> maybe_v2_rejection_receipt(:v2)

    committed_observation(attempted_error_transport_result("decode_error", receipt))
  end

  defp recovery_observation("committed_local_rejected", _sentinel) do
    committed_observation(local_rejected_transport_result())
  end

  defp production_bound_recovery_fixture(observation_state, generation, source_mode \\ nil) do
    scope = "generation-7:T_ATLAS:C_ATLAS:1787019000.000001"
    sentinel = "U_PENG"
    {private_projection, projected_context, raw_bundle} = production_projection_fixture()

    {private_projection, projected_context, raw_bundle} =
      if source_mode do
        aliases = Jason.decode!(private_projection["alias_map_bytes"])

        raw_bundle =
          raw_bundle
          |> put_in(["sealed_events", Access.at(0), "source_mode"], source_mode)
          |> put_in(["raw_identity_context", "source_mode"], source_mode)
          |> put_in(["raw_context", "identity_context", "source_mode"], source_mode)

        projected_context =
          put_in(projected_context, ["identity_context", "source_mode"], source_mode)

        private_projection =
          production_private_projection(
            raw_bundle,
            raw_bundle["raw_context"],
            aliases,
            projected_context
          )

        {private_projection, projected_context, raw_bundle}
      else
        {private_projection, projected_context, raw_bundle}
      end

    {claim, transport_result, winning_source_anchor} =
      production_binding_fixture(raw_bundle, generation)

    winning_source_anchor =
      Map.put(
        winning_source_anchor,
        "source_mode",
        raw_bundle["raw_identity_context"]["source_mode"]
      )

    assert {:ok, %{projected_context: ^projected_context, sha256: projected_sha256}} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )

    now = System.system_time(:millisecond)

    observation = %{
      "schema" => "comma.triage-identity-observation.v1",
      "state" => "projection_bound",
      "claim" => claim,
      "claimed_at_ms" => now,
      "transport_attempt_id" => ULID.generate(),
      "transport_marked_at_ms" => now,
      "transport_result" => transport_result,
      "committed_at_ms" => now,
      "private_projection" => private_projection,
      "pseudonymous_context_sha256" => projected_sha256,
      "projection_bound_at_ms" => now
    }

    {observation, input_snapshot} =
      if observation_state == "snapshot_bound" do
        model_input = production_model_input(projected_context)

        observation =
          observation
          |> Map.put("state", "snapshot_bound")
          |> Map.put("canonical_snapshot_sha256", model_input["canonical_snapshot_sha256"])
          |> Map.put("snapshot_bound_at_ms", now)

        {observation, model_input}
      else
        {observation, valid_base_projection()}
      end

    durable_bucket = production_durable_bucket(scope, generation, hd(raw_bundle["sealed_events"]))
    {scope, sentinel, observation, input_snapshot, durable_bucket}
  end

  defp production_projection_fixture do
    project_ref = "bft://projects/project-atlas"
    agent_ref = "bft://projects/project-atlas/agents/agent-router"
    endpoint_ref = "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
    message_ref = "slack://T_ATLAS/C_ATLAS/1787019000.000001/1787019000.000001"
    connect = production_connect_identity()
    product = production_product_identity()

    agent = %{
      "source_ref" => agent_ref,
      "principal_ref" => "comma-agent://agt1_atlas_router",
      "agent_id" => "agt1_atlas_router",
      "role" => "router",
      "display_name" => "BFT",
      "persona_revision_sha256" => String.duplicate("a", 64)
    }

    {:ok, identity_revision} = IdentityContract.identity_revision_sha256(agent)
    {:ok, endpoint_revision} = IdentityContract.endpoint_revision_sha256(connect)

    raw_identity = %{
      "schema" => "comma.triage-identity-context.v1",
      "source_mode" => "historical_thread_reenactment",
      "self_agent" => Map.put(agent, "identity_revision_sha256", identity_revision),
      "self_endpoint" => %{
        "source_ref" => endpoint_ref,
        "provider" => "slack",
        "workspace_id" => "T_ATLAS",
        "connect_id" => "connect-atlas",
        "connect_generation" => "generation-7",
        "provider_app_id" => "A_BFT",
        "bot_user_id" => "U_BFT",
        "bot_id" => "B_BFT",
        "display_aliases" => ["Zeta", "Alpha"],
        "represents_principal_ref" => "comma-agent://agt1_atlas_router",
        "revision_sha256" => endpoint_revision,
        "revision_status" => "exact"
      },
      "observed_principals" => [],
      "mention_evidence" => []
    }

    raw_identity =
      raw_identity
      |> Map.put("principal_refs", IdentityContract.principal_refs(raw_identity))
      |> Map.put(
        "remember_forbidden_source_refs",
        IdentityContract.remember_forbidden_source_refs(raw_identity)
      )
      |> Map.put("source_refs", IdentityContract.source_refs(raw_identity))

    product_context = %{
      "project" => %{
        "key" => "project-atlas",
        "name" => "Atlas",
        "status" => "active",
        "source_ref" => project_ref
      },
      "members" => [],
      "member_roster" => production_member_roster(),
      "facts" => [],
      "source_refs" => [project_ref]
    }

    raw_message = %{
      "actor_id" => "U_PENG",
      "actor_kind" => "human",
      "message_ts" => "1787019000.000001",
      "text" => "Who are you? #{@production_link_url}",
      "source_ref" => message_ref
    }

    raw_context = %{
      "slack_context" => %{"messages" => [raw_message], "source_refs" => [message_ref]},
      "team_project_memory" => product_context,
      "answered_recheck" => %{
        "answered" => false,
        "checked_at" => "2026-08-15T00:00:00.000Z",
        "source_refs" => [message_ref]
      },
      "identity_context" => raw_identity
    }

    source_observation = production_source_observation()

    raw_bundle = %{
      "schema" => "comma.triage-private-source-bundle.v3",
      "sealed_events" => [production_sealed_event(endpoint_revision)],
      "slack_page" => %{
        "messages" => [
          %{
            "ts" => "1787019000.000001",
            "user" => "U_PENG",
            "text" => "Who are you? #{@production_link_url}"
          }
        ],
        "next_cursor" => ""
      },
      "source_authority" => production_source_authority(),
      "root_ts" => "1787019000.000001",
      "source_observation" => source_observation,
      "connect_identity" => connect,
      "product_identity" => product,
      "product_context" => product_context,
      "raw_context" => raw_context,
      "raw_identity_context" => raw_identity,
      "target_cutoff" => %{"event_message_timestamps" => ["1787019000.000001"]}
    }

    source_aliases =
      [project_ref, agent_ref, endpoint_ref, message_ref]
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Map.new(fn {ref, index} ->
        ordinal = index |> Integer.to_string() |> String.pad_leading(3, "0")
        {ref, "source://run/s#{ordinal}"}
      end)

    alias_map = %{
      "principals" => %{"comma-agent://agt1_atlas_router" => "principal://run/self"},
      "provider_principals" => %{"U_BFT" => "principal://run/self"},
      "participants" => %{"U_PENG" => "participant://run/u001"},
      "sources" => source_aliases,
      "messages" => %{message_ref => "message://run/m001"},
      "links" => %{@production_link_url => "link://run/l001"},
      "members" => %{},
      "project" => %{project_ref => "project://run/p001"}
    }

    projected_identity = production_projected_identity(source_aliases, agent_ref, endpoint_ref)
    projected_slack = production_projected_slack(source_aliases, message_ref)
    projected_memory = production_projected_memory(source_aliases, project_ref)

    projected_context = %{
      "slack_context" => projected_slack,
      "identity_context" => projected_identity,
      "team_project_memory" => projected_memory,
      "answered_recheck" => %{"answered" => false},
      "decision_contract" => %{
        "source_refs" =>
          (projected_slack["source_refs"] ++
             projected_identity["source_refs"] ++ projected_memory["source_refs"])
          |> Enum.uniq()
          |> Enum.sort(),
        "principal_refs" => projected_identity["principal_refs"],
        "remember_forbidden_source_refs" => projected_identity["remember_forbidden_source_refs"]
      }
    }

    private_projection =
      production_private_projection(raw_bundle, raw_context, alias_map, projected_context)

    {private_projection, projected_context, raw_bundle}
  end

  defp production_custom_reaction_projection_fixture do
    {private_projection, projected_context, raw_bundle} = production_projection_fixture()
    {:ok, alias_map} = Jason.decode(private_projection["alias_map_bytes"])

    raw_message =
      raw_bundle
      |> get_in(["raw_context", "slack_context", "messages", Access.at(0)])
      |> Map.put("reactions", [])

    {:ok, expression_context} =
      ExpressionContext.build(
        "social",
        {:ok, %{"party_parrot" => "https://emoji.invalid/party"}},
        [raw_message]
      )

    raw_bundle =
      raw_bundle
      |> Map.put("schema", "comma.triage-private-source-bundle.v4")
      |> put_in(["sealed_events", Access.at(0), "source_mode"], "periodic_patrol")
      |> put_in(["raw_identity_context", "source_mode"], "periodic_patrol")
      |> put_in(["raw_context", "identity_context", "source_mode"], "periodic_patrol")
      |> put_in(["raw_context", "slack_context", "messages"], [raw_message])
      |> put_in(
        ["raw_context", "slack_context", "expression_context"],
        expression_context
      )
      |> update_in(["slack_page", "messages"], fn messages ->
        Enum.map(messages, &Map.put(&1, "reactions", []))
      end)
      |> update_in(["source_observation", "modules"], fn modules ->
        List.insert_at(modules, 3, %{
          "module" => "Elixir.SalixIM.Triage.ExpressionContext",
          "object_code_sha256" => String.duplicate("5", 64)
        })
      end)

    projected_context =
      projected_context
      |> put_in(["identity_context", "source_mode"], "periodic_patrol")
      |> put_in(["slack_context", "expression_context"], expression_context)
      |> update_in(["slack_context", "messages"], fn messages ->
        Enum.map(messages, &Map.put(&1, "observed_reactions", []))
      end)

    {
      production_private_projection(
        raw_bundle,
        raw_bundle["raw_context"],
        alias_map,
        projected_context
      ),
      projected_context,
      raw_bundle
    }
  end

  # The same production projection with one later human message on the observed
  # page, so the fresh recheck legitimately answers `true`.
  defp production_answered_projection_fixture do
    {private_projection, projected_context, raw_bundle} = production_projection_fixture()

    message_ref = "slack://T_ATLAS/C_ATLAS/1787019000.000001/1787019000.000001"
    answer_ref = "slack://T_ATLAS/C_ATLAS/1787019000.000001/1787019000.000002"

    raw_bundle =
      raw_bundle
      |> update_in(
        ["slack_page", "messages"],
        &(&1 ++
            [%{"ts" => "1787019000.000002", "user" => "U_HUMAN", "text" => "already answered"}])
      )
      |> put_in(["raw_context", "answered_recheck"], %{
        "answered" => true,
        "checked_at" => "2026-08-15T00:00:00.000Z",
        "source_refs" => [message_ref, answer_ref],
        "answer_source_ref" => answer_ref
      })

    projected_context = Map.put(projected_context, "answered_recheck", %{"answered" => true})
    {:ok, alias_map} = Jason.decode(private_projection["alias_map_bytes"])

    {production_private_projection(
       raw_bundle,
       raw_bundle["raw_context"],
       alias_map,
       projected_context
     ), projected_context}
  end

  defp production_projected_identity(sources, agent_ref, endpoint_ref) do
    agent_source = sources[agent_ref]
    endpoint_source = sources[endpoint_ref]

    %{
      "schema" => "comma.triage-identity-model-context.v1",
      "source_mode" => "historical_thread_reenactment",
      "self_agent" => %{
        "principal_ref" => "principal://run/self",
        "display_alias" => "@self",
        "role" => "router",
        "source_ref" => agent_source
      },
      "self_endpoint" => %{
        "endpoint_ref" => "endpoint://run/self",
        "provider" => "slack",
        "display_aliases" => ["@self", "Alpha", "Zeta"],
        "represents_principal_ref" => "principal://run/self",
        "revision_status" => "exact",
        "source_ref" => endpoint_source
      },
      "observed_principals" => [],
      "mention_evidence" => [],
      "principal_refs" => ["principal://run/self"],
      "remember_forbidden_source_refs" =>
        [agent_source, endpoint_source, "principal://run/self"] |> Enum.sort(),
      "source_refs" => [agent_source, endpoint_source] |> Enum.sort()
    }
  end

  defp production_projected_slack(sources, message_ref) do
    %{
      "messages" => [
        %{
          "ordinal" => 1,
          "actor_ref" => "participant://run/u001",
          "actor_kind" => "human",
          "message_ref" => "message://run/m001",
          "text" => "Who are you? @link:l001",
          "source_ref" => sources[message_ref]
        }
      ],
      "links" => [
        %{
          "link_ref" => "link://run/l001",
          "display_alias" => "@link:l001",
          "message_refs" => ["message://run/m001"],
          "source_refs" => [sources[message_ref]]
        }
      ],
      "decision_target" => %{
        "ordinal" => 1,
        "message_ref" => "message://run/m001",
        "source_ref" => sources[message_ref],
        "link_refs" => ["link://run/l001"],
        "syntactic_addressee" => "none"
      },
      "source_refs" => [sources[message_ref]]
    }
  end

  defp production_projected_memory(sources, project_ref) do
    %{
      "project" => %{
        "entity_ref" => "project://run/p001",
        "display_alias" => "@project:p001",
        "status" => "active",
        "source_ref" => sources[project_ref]
      },
      "members" => [],
      "member_roster" => production_member_roster(),
      "facts" => [],
      "source_refs" => [sources[project_ref]]
    }
  end

  defp production_member_roster do
    %{
      "completeness" => "complete",
      "truncated" => false,
      "limit" => 25,
      "returned_count" => 0
    }
  end

  defp production_binding_fixture(raw_bundle, generation) do
    profile = production_identity_profile(raw_bundle)
    {:ok, profile_bytes} = CanonicalJSON.encode(profile)
    {:ok, selector_bytes} = CanonicalJSON.encode(production_request_selector(raw_bundle))
    {:ok, observation_bytes} = CanonicalJSON.encode(raw_bundle["source_observation"])
    {:ok, page_bytes} = CanonicalJSON.encode(raw_bundle["slack_page"])
    page_sha256 = CanonicalJSON.sha256(page_bytes)

    classified =
      Enum.map(raw_bundle["slack_page"]["messages"], &Map.put(&1, "actor_kind", "human"))

    {:ok, classified_bytes} = CanonicalJSON.encode(classified)

    claim = %{
      "schema" => "comma.triage-identity-observation-claim.v1",
      "identity_profile_sha256" => CanonicalJSON.sha256(profile_bytes),
      "request_selector_sha256" => CanonicalJSON.sha256(selector_bytes),
      "slack_api_origin_sha256" => @origin_sha256,
      "source_observation_sha256" => CanonicalJSON.sha256(observation_bytes)
    }

    receipt = %{
      "schema" => "comma.slack-read-receipt.v1",
      "operation" => "conversations.replies",
      "method" => "GET",
      "request_selector_sha256" => claim["request_selector_sha256"],
      "slack_api_origin_sha256" => @origin_sha256,
      "transport_invocation_count" => 1,
      "retry" => false,
      "redirect" => false,
      "outcome" => "success",
      "typed_reason" => nil,
      "http_status" => 200,
      "canonical_page_sha256" => page_sha256,
      "message_count" => 1,
      "next_cursor_empty" => true,
      "slack_request_id_sha256" => nil
    }

    transport_result = %{
      "schema" => "comma.triage-identity-transport-result.v1",
      "kind" => "success",
      "receipt" => receipt,
      "canonical_page_bytes" => page_bytes,
      "canonical_page_sha256" => page_sha256,
      "classified_private_messages_sha256" => CanonicalJSON.sha256(classified_bytes),
      "reason_code" => nil
    }

    winning_source_anchor = %{
      "schema" => "comma.triage-winning-source-anchor.v1",
      "generation" => generation,
      "source_mode" => "historical_thread_reenactment",
      "sealed_events" => raw_bundle["sealed_events"],
      "source_authority" => raw_bundle["source_authority"]
    }

    {claim, transport_result, winning_source_anchor}
  end

  defp production_private_projection(raw_bundle, raw_context, alias_map, projected_context) do
    {:ok, raw_bundle_bytes} = CanonicalJSON.encode(raw_bundle)
    {:ok, raw_context_bytes} = CanonicalJSON.encode(raw_context)
    {:ok, alias_map_bytes} = CanonicalJSON.encode(alias_map)
    {:ok, projected_bytes} = CanonicalJSON.encode(projected_context)

    {:ok, policy_bytes} =
      CanonicalJSON.encode(%{
        "schema" => "comma.triage-identity-projection-policy.v1",
        "target" => "provider_safe_context"
      })

    profile = production_identity_profile(raw_bundle)

    %{
      "schema" => "comma.triage-private-projection-control.v1",
      "raw_source_bundle_bytes" => raw_bundle_bytes,
      "raw_source_bundle_sha256" => CanonicalJSON.sha256(raw_bundle_bytes),
      "raw_context_sha256" => CanonicalJSON.sha256(raw_context_bytes),
      "alias_map_bytes" => alias_map_bytes,
      "alias_map_sha256" => CanonicalJSON.sha256(alias_map_bytes),
      "projection_policy_sha256" => CanonicalJSON.sha256(policy_bytes),
      "projected_context_sha256" => CanonicalJSON.sha256(projected_bytes),
      "raw_deny_literals" => production_raw_deny_literals(raw_bundle, profile)
    }
  end

  defp production_identity_profile(raw_bundle) do
    connect = raw_bundle["connect_identity"]
    product = raw_bundle["product_identity"]
    {:ok, endpoint_revision} = IdentityContract.endpoint_revision_sha256(connect)

    %{
      "schema" => "comma.triage-identity-selector.v1",
      "provider" => connect["provider"],
      "operation" => "conversations.replies",
      "tenant_id" => connect["tenant_id"],
      "group_id" => connect["group_id"],
      "connect_id" => connect["connect_id"],
      "connect_generation" => connect["connect_generation"],
      "workspace_id" => connect["workspace_id"],
      "approved_channel_id" => connect["approved_channel_id"],
      "root_ts" => raw_bundle["root_ts"],
      "inbound_agent_id" => connect["inbound_agent_id"],
      "app_id" => connect["app_id"],
      "bot_user_id" => connect["bot_user_id"],
      "bot_id" => connect["bot_id"],
      "endpoint_revision_sha256" => endpoint_revision,
      "project_id" => product["project_id"],
      "project_status" => product["project_status"],
      "agent_id" => product["salix_agent_id"],
      "agent_role" => product["agent_role"],
      "agent_name" => product["agent_name"],
      "self_agent_identity_revision_sha256" =>
        get_in(raw_bundle, ["raw_identity_context", "self_agent", "identity_revision_sha256"]),
      "slack_api_origin_sha256" => @origin_sha256
    }
  end

  defp production_request_selector(raw_bundle) do
    %{
      "operation" => "conversations.replies",
      "channel_id" => raw_bundle["source_authority"]["channel_id"],
      "thread_ts" => raw_bundle["source_authority"]["thread_ts"],
      "limit" => 200,
      "cursor" => ""
    }
  end

  defp production_model_input(
         projected_context,
         snapshot_schema \\ "comma.triage-context-snapshot.v5"
       ) do
    base =
      valid_base_projection()
      |> Map.put("source_mode", get_in(projected_context, ["identity_context", "source_mode"]))

    snapshot =
      %{
        "schema" => snapshot_schema,
        "generation_ref" => "generation://run/current",
        "events" => base["events"],
        "receipt_refs" => base["receipt_refs"],
        "source_authority" => base["source_authority"]
      }
      |> Map.merge(projected_context)

    source_refs = projected_context["decision_contract"]["source_refs"]
    {:ok, snapshot_bytes} = CanonicalJSON.encode(snapshot)
    {:ok, source_refs_bytes} = CanonicalJSON.encode(source_refs)

    %{
      "schema" => "comma.triage-model-input.v3",
      "snapshot" => snapshot,
      "canonical_snapshot_bytes" => snapshot_bytes,
      "canonical_snapshot_sha256" => CanonicalJSON.sha256(snapshot_bytes),
      "source_refs" => source_refs,
      "source_refs_canonical_bytes" => source_refs_bytes,
      "source_refs_sha256" => CanonicalJSON.sha256(source_refs_bytes)
    }
  end

  defp with_snapshot_schema(model_input, snapshot_schema) do
    model_input = put_in(model_input, ["snapshot", "schema"], snapshot_schema)
    {:ok, snapshot_bytes} = CanonicalJSON.encode(model_input["snapshot"])

    model_input
    |> Map.put("canonical_snapshot_bytes", snapshot_bytes)
    |> Map.put("canonical_snapshot_sha256", CanonicalJSON.sha256(snapshot_bytes))
  end

  defp production_durable_bucket(scope, generation, sealed_event) do
    now = System.system_time(:millisecond)

    receipt = %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "receipt_ref" => "s3://receipt/production-bound-r001",
      "connect_id" => "connect-atlas",
      "connect_generation" => sealed_event["connect_generation"],
      "created_at" => sealed_event["endpoint_provenance"]["captured_at_ms"],
      "event_id" => sealed_event["event_id"],
      "source_message_ref" =>
        Enum.join(
          [
            sealed_event["connect_generation"],
            sealed_event["bucket"]["workspace_id"],
            sealed_event["bucket"]["channel_id"],
            sealed_event["bucket"]["thread_ts"],
            sealed_event["message_ts"]
          ],
          ":"
        ),
      "triage_event" => sealed_event
    }

    # An open generation with no receipts carries no deadline of its own.
    %{
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
  end

  defp production_winning_input(generation, receipts) do
    %{
      "schema" => "comma.triage-input-snapshot.v2",
      "generation" => generation,
      "events" => Enum.map(receipts, & &1["triage_event"]),
      "receipt_refs" => Enum.map(receipts, & &1["receipt_ref"]),
      "source_authority" => production_source_authority(),
      "source_mode" => "historical_thread_reenactment"
    }
  end

  defp production_source_observation do
    %{
      "schema" => "comma.triage-source-observation.v1",
      "modules" =>
        [
          "Elixir.BridgeForTeams.TriageContext",
          "Elixir.BridgeForTeams.TriageContext.ProductSource",
          "Elixir.SalixIM.ProviderConnects",
          "Elixir.Salix.Bindings.SlackTriageThreadReader"
        ]
        |> Enum.with_index(1)
        |> Enum.map(fn {module, index} ->
          %{
            "module" => module,
            "object_code_sha256" => String.duplicate(Integer.to_string(index), 64)
          }
        end)
    }
  end

  defp production_sealed_event(endpoint_revision) do
    %{
      "event_id" => "Ev1",
      "connect_generation" => "generation-7",
      "message_ts" => "1787019000.000001",
      "actor_id" => "U_PENG",
      "actor_kind" => "human",
      "text" => "Who are you? #{@production_link_url}",
      "event_type" => "message",
      "addressing_kind" => "ambient",
      "trigger_kind" => "none",
      "fast_path" => false,
      "bucket" => %{
        "workspace_id" => "T_ATLAS",
        "channel_id" => "C_ATLAS",
        "thread_ts" => "1787019000.000001"
      },
      "endpoint_provenance" => %{
        "schema" => "comma.slack-endpoint-provenance.v1",
        "captured_at_ms" => 1_780_000_000_000,
        "callback_api_app_id" => "A_BFT",
        "fast_path_bot_user_id" => "U_BFT",
        "endpoint_revision_sha256" => endpoint_revision
      },
      "source_mode" => "historical_thread_reenactment"
    }
  end

  defp production_source_authority do
    %{
      "connect_id" => "connect-atlas",
      "connect_generation" => "generation-7",
      "workspace_id" => "T_ATLAS",
      "channel_id" => "C_ATLAS",
      "thread_ts" => "1787019000.000001"
    }
  end

  defp production_connect_identity do
    %{
      "provider" => "slack",
      "tenant_id" => "tenant-atlas",
      "group_id" => "project-atlas",
      "connect_id" => "connect-atlas",
      "connect_generation" => "generation-7",
      "workspace_id" => "T_ATLAS",
      "approved_channel_id" => "C_ATLAS",
      "inbound_agent_id" => "agt1_atlas_router",
      "app_id" => "A_BFT",
      "bot_user_id" => "U_BFT",
      "bot_id" => "B_BFT"
    }
  end

  defp production_product_identity do
    %{
      "project_id" => "project-atlas",
      "project_status" => "active",
      "project_archived_at" => nil,
      "project_salix_group_id" => "project-atlas",
      "agent_id" => "agent-router",
      "agent_project_id" => "project-atlas",
      "salix_agent_id" => "agt1_atlas_router",
      "agent_status" => "active",
      "agent_archived_at" => nil,
      "agent_role" => "router",
      "agent_name" => "BFT"
    }
  end

  defp production_raw_deny_literals(raw_bundle, profile) do
    [raw_bundle, profile]
    |> collect_production_private_literals(false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp collect_production_private_literals(value, sensitive?) when is_map(value) do
    Enum.flat_map(value, fn {key, child} ->
      collect_production_private_literals(child, sensitive? or production_private_key?(key))
    end)
  end

  defp collect_production_private_literals(value, sensitive?) when is_list(value),
    do: Enum.flat_map(value, &collect_production_private_literals(&1, sensitive?))

  defp collect_production_private_literals(value, sensitive?) when is_binary(value) do
    if(sensitive?, do: [value], else: []) ++ production_private_fragments(value)
  end

  defp collect_production_private_literals(_value, _sensitive?), do: []

  defp production_private_key?(key) when is_binary(key) do
    key in ~w(key user module checked_at connect_generation) or
      Regex.match?(~r/(?:^|_)(?:id|ids|ref|refs|sha256|ts|timestamps)\z/, key)
  end

  defp production_private_key?(_key), do: true

  defp production_private_fragments(value) do
    ([
       @raw_provider_id,
       @raw_uuid,
       @raw_uri,
       @raw_email,
       @raw_path,
       @raw_mention,
       @sha256
     ] ++ @credential_literal_patterns)
    |> Enum.flat_map(fn regex ->
      regex
      |> Regex.scan(value, capture: :first)
      |> Enum.map(&hd/1)
    end)
  end

  defp claimed_observation do
    %{
      "schema" => "comma.triage-identity-observation.v1",
      "state" => "claimed",
      "claim" => identity_claim(),
      "claimed_at_ms" => System.system_time(:millisecond)
    }
  end

  defp transport_observation do
    claimed_observation()
    |> Map.put("state", "transport_maybe_started")
    |> Map.put("transport_attempt_id", ULID.generate())
    |> Map.put("transport_marked_at_ms", System.system_time(:millisecond))
  end

  defp committed_observation(result) do
    transport_observation()
    |> Map.put("state", "committed")
    |> Map.put("transport_result", result)
    |> Map.put("committed_at_ms", System.system_time(:millisecond))
  end

  defp identity_claim do
    %{
      "schema" => "comma.triage-identity-observation-claim.v1",
      "identity_profile_sha256" => String.duplicate("a", 64),
      "request_selector_sha256" => String.duplicate("b", 64),
      "slack_api_origin_sha256" => String.duplicate("c", 64),
      "source_observation_sha256" => String.duplicate("d", 64)
    }
  end

  defp success_transport_result(sentinel) do
    {:ok, page_bytes} = CanonicalJSON.encode(%{"messages" => [%{"text" => sentinel}]})
    page_sha256 = CanonicalJSON.sha256(page_bytes)

    %{
      "schema" => "comma.triage-identity-transport-result.v1",
      "kind" => "success",
      "receipt" => slack_read_receipt("success", page_sha256),
      "canonical_page_bytes" => page_bytes,
      "canonical_page_sha256" => page_sha256,
      "classified_private_messages_sha256" => String.duplicate("e", 64),
      "reason_code" => nil
    }
  end

  defp attempted_error_transport_result(reason, receipt \\ nil) do
    %{
      "schema" => "comma.triage-identity-transport-result.v1",
      "kind" => "attempted_error",
      "receipt" => receipt || slack_read_receipt(reason, nil),
      "canonical_page_bytes" => nil,
      "canonical_page_sha256" => nil,
      "classified_private_messages_sha256" => nil,
      "reason_code" => reason
    }
  end

  # A chain-only refusal: every exchange succeeded, the tail still had a cursor,
  # and the read stopped without deciding. Only the v2 transport result can
  # carry it, and the reader commits it verbatim.
  defp chain_attempted_error_transport_result(reason) do
    exchange =
      "success"
      |> slack_read_receipt(String.duplicate("a", 64))
      |> Map.put("next_cursor_empty", false)

    receipt = %{
      "schema" => "comma.slack-read-receipt-chain.v1",
      "operation" => "conversations.replies",
      "method" => "GET",
      "request_selector_sha256" => identity_claim()["request_selector_sha256"],
      "slack_api_origin_sha256" => identity_claim()["slack_api_origin_sha256"],
      "transport_invocation_count" => 1,
      "retry" => false,
      "redirect" => false,
      "outcome" => reason,
      "typed_reason" => reason,
      "http_status" => nil,
      "canonical_page_sha256" => nil,
      "message_count" => nil,
      "next_cursor_empty" => nil,
      "slack_request_id_sha256" => nil,
      "page_budget" => 1,
      "canonical_page_chain_sha256" => nil,
      "rejection" => nil,
      "exchanges" => [exchange]
    }

    %{
      "schema" => "comma.triage-identity-transport-result.v2",
      "kind" => "attempted_error",
      "receipt" => receipt,
      "canonical_page_bytes" => nil,
      "canonical_page_sha256" => nil,
      "canonical_page_chain_bytes" => nil,
      "canonical_page_chain_sha256" => nil,
      "classified_private_messages_sha256" => nil,
      "reason_code" => reason
    }
  end

  # One honest single-exchange success chain: the shape admission must accept,
  # and the base every forged variant below is mutated from.
  defp chain_success_transport_result(sentinel) do
    page = %{"messages" => [%{"text" => sentinel}]}
    {:ok, page_bytes} = CanonicalJSON.encode(page)
    page_sha256 = CanonicalJSON.sha256(page_bytes)

    {:ok, chain_bytes} =
      CanonicalJSON.encode(%{"schema" => "comma.slack-read-page-chain.v1", "pages" => [page]})

    chain_sha256 = CanonicalJSON.sha256(chain_bytes)

    receipt =
      "success"
      |> slack_read_receipt(page_sha256)
      |> Map.put("schema", "comma.slack-read-receipt-chain.v1")
      |> Map.put("page_budget", 14)
      |> Map.put("canonical_page_chain_sha256", chain_sha256)
      |> Map.put("rejection", nil)
      |> Map.put("exchanges", [slack_read_receipt("success", page_sha256)])

    %{
      "schema" => "comma.triage-identity-transport-result.v2",
      "kind" => "success",
      "receipt" => receipt,
      "canonical_page_bytes" => page_bytes,
      "canonical_page_sha256" => page_sha256,
      "canonical_page_chain_bytes" => chain_bytes,
      "canonical_page_chain_sha256" => chain_sha256,
      "classified_private_messages_sha256" => String.duplicate("e", 64),
      "reason_code" => nil
    }
  end

  defp local_rejected_transport_result do
    page_sha256 = String.duplicate("f", 64)

    %{
      "schema" => "comma.triage-identity-transport-result.v1",
      "kind" => "local_rejected",
      "receipt" => slack_read_receipt("success", page_sha256),
      "canonical_page_bytes" => nil,
      "canonical_page_sha256" => page_sha256,
      "classified_private_messages_sha256" => nil,
      "reason_code" => "identity_projection_privacy_rejected"
    }
  end

  defp slack_read_receipt(outcome, page_sha256) do
    success? = outcome == "success"

    %{
      "schema" => "comma.slack-read-receipt.v1",
      "operation" => "conversations.replies",
      "method" => "GET",
      "request_selector_sha256" => identity_claim()["request_selector_sha256"],
      "slack_api_origin_sha256" => identity_claim()["slack_api_origin_sha256"],
      "transport_invocation_count" => 1,
      "retry" => false,
      "redirect" => false,
      "outcome" => outcome,
      "typed_reason" => if(success?, do: nil, else: outcome),
      "http_status" => if(success?, do: 200, else: nil),
      "canonical_page_sha256" => page_sha256,
      "message_count" => if(success?, do: 1, else: nil),
      "next_cursor_empty" => if(success?, do: true, else: nil),
      "slack_request_id_sha256" => nil
    }
  end

  defp maybe_v2_rejection_receipt(receipt, :v1), do: receipt

  defp maybe_v2_rejection_receipt(receipt, :v2) do
    receipt
    |> Map.put("schema", "comma.slack-read-receipt.v2")
    |> Map.put("rejection", %{
      "schema" => "comma.slack-read-rejection.v1",
      "stage" => "message_unknown_keys",
      "path" => "messages[]",
      "unknown_keys" => ["metadata"]
    })
  end

  defp private_projection(sentinel) do
    raw_bundle_bytes = Jason.encode!(%{"private" => sentinel})
    alias_map_bytes = Jason.encode!(%{})

    %{
      "schema" => "comma.triage-private-projection-control.v1",
      "raw_source_bundle_bytes" => raw_bundle_bytes,
      "raw_source_bundle_sha256" => CanonicalJSON.sha256(raw_bundle_bytes),
      "raw_context_sha256" => String.duplicate("1", 64),
      "alias_map_bytes" => alias_map_bytes,
      "alias_map_sha256" => CanonicalJSON.sha256(alias_map_bytes),
      "projection_policy_sha256" => String.duplicate("2", 64),
      "projected_context_sha256" => String.duplicate("9", 64),
      "raw_deny_literals" => [sentinel]
    }
  end

  defp recovery_input("snapshot_bound"), do: recovery_model_input()
  defp recovery_input(_observation_state), do: valid_base_projection()

  defp recovery_model_input(raw_sentinel \\ nil) do
    identity_context =
      %{"principal_refs" => ["principal://run/self"]}
      |> maybe_put_raw_sentinel(raw_sentinel)

    snapshot = %{
      "schema" => "comma.triage-context-snapshot.v5",
      "receipt_refs" => ["receipt://run/r001"],
      "identity_context" => identity_context
    }

    source_refs = ["source://run/s001"]
    {:ok, snapshot_bytes} = CanonicalJSON.encode(snapshot)
    {:ok, source_refs_bytes} = CanonicalJSON.encode(source_refs)

    %{
      "schema" => "comma.triage-model-input.v3",
      "snapshot" => snapshot,
      "canonical_snapshot_bytes" => snapshot_bytes,
      "canonical_snapshot_sha256" => CanonicalJSON.sha256(snapshot_bytes),
      "source_refs" => source_refs,
      "source_refs_canonical_bytes" => source_refs_bytes,
      "source_refs_sha256" => CanonicalJSON.sha256(source_refs_bytes)
    }
  end

  defp maybe_put_raw_sentinel(context, nil), do: context
  defp maybe_put_raw_sentinel(context, sentinel), do: Map.put(context, "display_alias", sentinel)

  defp valid_v2_fence(scope, generation, run_id) do
    now = System.system_time(:millisecond)

    %{
      "schema" => "comma.triage-bucket-fence.v2",
      "bucket_scope" => scope,
      "public_bucket_ref" => "bucket://run/scope",
      "generation" => generation,
      "run_id" => run_id,
      "created_at" => now,
      "deadline_at" => now + 60_000,
      "input_snapshot" => valid_base_projection(),
      "identity_observation" => %{
        "schema" => "comma.triage-identity-observation.v1",
        "state" => "unused"
      },
      "terminal" => nil
    }
  end

  defp valid_base_projection do
    %{
      "schema" => "comma.triage-ledger-input-projection.v2",
      "source_mode" => "historical_thread_reenactment",
      "event_count" => 1,
      "receipt_count" => 1,
      "events" => [
        %{
          "event_ref" => "event://run/e001",
          "ordinal" => 1,
          "actor_kind" => "human",
          "event_type" => "message",
          "addressing_kind" => "ambient",
          "trigger_kind" => "none",
          "fast_path" => false
        }
      ],
      "receipt_refs" => ["receipt://run/r001"],
      "source_authority" => %{
        "provider" => "slack",
        "scope_kind" => "thread",
        "workspace_ref" => "workspace://run/self",
        "bucket_ref" => "bucket://run/scope",
        "endpoint_ref" => "endpoint://run/self"
      }
    }
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(error), do: error

  defp namespace(label),
    do: "identity-fence-#{label}-#{System.unique_integer([:positive])}"

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defmodule ForbiddenEvaluator do
    def evaluate(_input, opts) do
      if opts[:test_pid], do: send(opts[:test_pid], :evaluator_called)
      raise "evaluator must not run"
    end
  end

  # A fence that has already granted the projection binding, so `Pipeline.freeze/2`
  # can be driven on its own without a durable run behind it.
  defmodule ConsentingFenceRuntime do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_arg), do: {:ok, nil}

    @impl true
    def handle_call({:identity_fence, _handle, :bind_projection, _payload}, _from, state),
      do: {:reply, :ok, state}
  end

  defmodule StubProjectedContext do
    def freeze(_input, opts),
      do: {:ok, Keyword.fetch!(opts, :frozen), Keyword.fetch!(opts, :private_projection)}
  end

  defmodule AnsweredContext do
    def freeze(_input, _opts) do
      {:ok,
       %{
         "slack_context" => %{"messages" => []},
         "team_project_memory" => %{"facts" => []},
         "answered_recheck" => %{"answered" => true, "checked_at" => "2026-08-15T00:00:00Z"}
       }}
    end
  end

  defmodule ForbiddenContext do
    def freeze(_input, opts) do
      if opts[:test_pid], do: send(opts[:test_pid], :context_called)
      raise "context and Slack must not run"
    end
  end

  defmodule NextGenerationContext do
    def freeze(input, opts) do
      send(opts[:test_pid], {:next_generation_context, input["generation"]})

      {:ok,
       %{
         "slack_context" => %{"messages" => []},
         "team_project_memory" => %{"facts" => []},
         "answered_recheck" => %{"answered" => false}
       }}
    end
  end

  defmodule NextGenerationEvaluator do
    def evaluate(input, opts) do
      send(opts[:test_pid], {:next_generation_evaluator, input["generation"]})
      {:error, :generation_probe_complete}
    end
  end
end
