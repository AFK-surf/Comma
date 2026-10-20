defmodule SalixIM.TriagePostgresAuthoritativeCommitTest do
  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle
  import SalixIM.TriageEngineFixtures

  alias SalixIM.Triage
  alias SalixIM.Triage.{Admission, ProjectionProjector, RunFence, Runtime}
  alias SalixStore.{CasRecord, Repo, S3, TriageRecords, TriageTransactions, ULID}

  defmodule ForbiddenEvaluator do
    @moduledoc false
    @behaviour SalixIM.Ports.TriageEvaluator

    @impl true
    def evaluate(_input, _opts), do: {:error, :must_not_run}
  end

  defmodule BlockedProjectionStore do
    def get(key, opts) do
      result = SalixStore.TriageRecords.get(key, opts)

      with {prefix, owner, phase} <- blocked_phase(),
           true <- String.starts_with?(key, prefix),
           {:ok, %{body: body}} <- result,
           %{"terminal" => terminal} <- Jason.decode!(body),
           true <-
             (phase == :terminal and is_map(terminal)) or (phase == :open and is_nil(terminal)) do
        SystemsRuntime.Proc.send(owner, {:projection_read_blocked, SystemsRuntime.Proc.self()})

        SystemsClock.vreceive do
          :release_projection -> :ok
        after
          10_000 -> raise "projection test was not released"
        end
      end

      result
    end

    defp blocked_phase do
      case SystemsRuntime.PersistentTerm.get(__MODULE__, nil) do
        {prefix, owner} -> {prefix, owner, :terminal}
        configured -> configured
      end
    end

    defdelegate put(key, body, opts), to: SalixStore.TriageRecords
    defdelegate head(key), to: SalixStore.TriageRecords
    defdelegate list(prefix, opts), to: SalixStore.TriageRecords
    defdelegate recovery_page(prefix, opts), to: SalixStore.TriageRecords
    defdelegate commit_authoritative(commit), to: SalixStore.TriageRecords
    defdelegate admit_receipt(admission), to: SalixStore.TriageRecords
  end

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :triage_record_backend)
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, TriageRecords)

    Repo.query!("""
    TRUNCATE
      triage_companion_reaction_obligations,
      triage_product_effect_attempts,
      triage_product_obligations,
      triage_context_entries,
      triage_patrol_cursors,
      triage_projection_obligations,
      triage_recovery_leases,
      triage_intent_settlements,
      triage_late_results,
      triage_lifecycle_events,
      triage_activity_index_entries,
      triage_time_index_entries,
      triage_correlation_entries,
      triage_replays,
      triage_runs,
      triage_run_fences,
      triage_buckets,
      triage_bucket_memberships,
      triage_recipient_aliases,
      triage_ambient_aliases,
      triage_receipt_projections
    """)

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

  test "a drain-released run is evaluated again under a new fence with one authoritative run" do
    namespace = "triage-pg-release-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    authority = authority!()
    calls = :counters.new(1, [])

    # Draining starts after the first run won its fence.
    draining? = fn ->
      :counters.add(calls, 1, 1)
      :counters.get(calls, 1) > 1
    end

    opts = [
      name: nil,
      mode: :review,
      namespace: namespace,
      debounce_ms: 10,
      max_wait_ms: 40,
      evaluation_timeout_ms: 1_000,
      recovery_idle_ms: 50,
      evaluator_port: {ForbiddenEvaluator, []}
    ]

    draining =
      start_supervised!(
        {Runtime, opts ++ [restart: :temporary, draining?: draining?]},
        id: SystemsRuntime.Proc.make_ref()
      )

    admit!(draining, authority, "Ev-pg-release", text: "release before transport")

    released_query = """
    SELECT count(*) FROM triage_run_fences
    WHERE body @> '{"terminal": null, "identity_observation": {"state": "released"}}'::jsonb
    """

    assert true =
             eventually(fn ->
               match?(%Postgrex.Result{rows: [[1]]}, Repo.query!(released_query))
             end)

    assert Triage.ledger_records(draining) == []
    :ok = GenServer.stop(draining)

    serving = start_supervised!({Runtime, opts}, id: SystemsRuntime.Proc.make_ref())

    assert [%{"authoritative" => true, "status" => "failed"} = run] =
             eventually(fn -> Triage.ledger_records(serving) end)

    assert %Postgrex.Result{rows: [[1, 2, run_id, 1]]} =
             Repo.query!("""
             SELECT
               (SELECT count(*) FROM triage_run_fences),
               (SELECT (body ->> 'fence_epoch')::int FROM triage_run_fences),
               (SELECT body ->> 'run_id' FROM triage_run_fences),
               (SELECT count(*) FROM triage_runs)
             """)

    assert run_id == run["run_id"]
  end

  test "the production runtime commits authority before its idempotent projector converges" do
    namespace = "triage-pg-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    authority = authority!()

    server =
      start_supervised!(
        {Runtime,
         name: nil,
         mode: :review,
         namespace: namespace,
         debounce_ms: 10,
         max_wait_ms: 40,
         evaluation_timeout_ms: 100,
         recovery_idle_ms: 200,
         evaluator_port: {ForbiddenEvaluator, []}},
        id: SystemsRuntime.Proc.make_ref()
      )

    admit!(server, authority, "Ev-pg-atomic", text: "verify the atomic terminal")

    assert [%{"authoritative" => true} = run] =
             eventually(fn -> Triage.ledger_records(server) end)

    assert %Postgrex.Result{rows: [[1, 1, 1]]} =
             Repo.query!("""
             SELECT
               (SELECT count(*) FROM triage_run_fences WHERE body -> 'terminal' <> 'null'::jsonb),
               (SELECT count(*) FROM triage_runs),
               (SELECT count(*) FROM triage_replays)
             """)

    assert true =
             eventually(fn ->
               match?(
                 %Postgrex.Result{rows: [[1, 1, 0]]},
                 Repo.query!("""
                 SELECT
                   (SELECT count(*) FROM triage_projection_obligations WHERE state = 'applied'),
                   (SELECT count(*) FROM triage_time_index_entries),
                   (SELECT count(*) FROM triage_projection_obligations WHERE state = 'pending')
                 """)
               )
             end)

    assert %Postgrex.Result{rows: [[namespace_key]]} =
             Repo.query!(
               "SELECT namespace_key FROM triage_projection_obligations WHERE run_id = $1",
               [run["run_id"]]
             )

    assert {:ok, ^run} = Triage.replay(server, run["run_id"])
    assert {:ok, []} = TriageTransactions.pending_projection_obligations(10)

    assert {:ok, %{fetched: 0, applied: 0, failed: 0}} =
             ProjectionProjector.converge(namespace, 10)

    assert %Postgrex.Result{rows: [[1, 1]]} =
             Repo.query!("""
             SELECT
               (SELECT count(*) FROM triage_projection_obligations WHERE state = 'applied'),
               (SELECT count(*) FROM triage_time_index_entries)
             """)

    assert is_binary(namespace_key)
  end

  test "expired open fence recovery yields the mailbox and commits atomically" do
    namespace = "triage-pg-recovery-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    authority = authority!()
    generation = ULID.generate()
    run_id = ULID.generate()
    now = SystemsClock.system_time(:millisecond)

    receipt =
      thread_receipt!(authority, "Ev-pg-recovery", "1787019000.000002",
        actor_kind: "agent",
        event_type: "app_mention",
        text: "<@#{authority["bot_user_id"]}> recover this run"
      )

    scope = SalixIM.Triage.Bucketing.scope_key(receipt)

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
        "connect_generation" => authority["connect_generation"],
        "workspace_id" => authority["workspace_id"],
        "channel_id" => authority["approved_channel_id"],
        "thread_ts" => get_in(receipt, ["triage_event", "bucket", "thread_ts"])
      },
      "source_mode" => "callback"
    }

    assert {:ok, {:won, created}} =
             RunFence.create(namespace, scope, run_id, input, now - 2_000, now - 1_000)

    SystemsRuntime.PersistentTerm.put(
      BlockedProjectionStore,
      {created.key, SystemsRuntime.Proc.self(), :open}
    )

    SystemsRuntime.put_env(:salix_store, :triage_record_backend, BlockedProjectionStore)
    on_exit(fn -> SystemsRuntime.PersistentTerm.erase(BlockedProjectionStore) end)

    server =
      start_supervised!(
        {Runtime,
         name: nil,
         mode: :review,
         namespace: namespace,
         recovery_idle_ms: 200,
         evaluator_port: {ForbiddenEvaluator, []}},
        id: SystemsRuntime.Proc.make_ref()
      )

    settle_receive({:projection_read_blocked, recovery})
    assert %{namespace: ^namespace} = GenServer.call(server, :status, 250)
    assert recovery != server
    SystemsRuntime.PersistentTerm.erase(BlockedProjectionStore)
    SystemsRuntime.Proc.send(recovery, :release_projection)

    assert true =
             eventually(fn ->
               match?(
                 %Postgrex.Result{rows: [[1, 1, 1, 1]]},
                 Repo.query!("""
                 SELECT
                   (SELECT count(*) FROM triage_run_fences WHERE body -> 'terminal' <> 'null'::jsonb),
                   (SELECT count(*) FROM triage_runs),
                   (SELECT count(*) FROM triage_replays),
                   (SELECT count(*) FROM triage_projection_obligations)
                 """)
               )
             end)

    assert {:ok, recovered} = CasRecord.get(created.key)

    assert recovered["terminal"]["decision"] == %{
             "action" => "silence",
             "reason" => "identity_diagnostic_interrupted_before_transport"
           }

    assert [run] = Triage.ledger_records(server)
    assert run["run_id"] == run_id
    assert {:ok, ^run} = Triage.replay(server, run_id)
  end

  test "settled thread generations leave the bucket and late duplicates stay settled" do
    namespace = "triage-pg-thread-archive-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    authority = authority!()

    server =
      start_supervised!(
        {Runtime,
         name: nil,
         mode: :review,
         namespace: namespace,
         debounce_ms: 10,
         max_wait_ms: 40,
         evaluation_timeout_ms: 100,
         recovery_idle_ms: 200,
         evaluator_port: {ForbiddenEvaluator, []}},
        id: SystemsRuntime.Proc.make_ref()
      )

    first = admit!(server, authority, "Ev-pg-thread-archive-1")
    assert [_run] = eventually(fn -> Triage.ledger_records(server) end)
    scope = SalixIM.Triage.Bucketing.scope_key(first)
    assert {:ok, %{"sealed_generations" => []}} = SalixIM.Triage.Bucketing.load(namespace, scope)

    # Recreate the data an older release left behind: the settled generation
    # stays in the thread bucket, its fence has no sealed copy, and its
    # membership never learned the generation.
    namespace_key = SalixStore.TriageKeys.namespace_key(namespace)
    bucket_key = SalixStore.Crypto.hex(scope)

    %Postgrex.Result{rows: [[legacy]]} =
      Repo.query!(
        "SELECT body -> 'sealed_generation' FROM triage_run_fences WHERE namespace_key = $1 AND bucket_key = $2",
        [namespace_key, bucket_key]
      )

    Repo.query!(
      """
      UPDATE triage_buckets
      SET body = jsonb_set(body, '{sealed_generations}', jsonb_build_array($3::jsonb))
      WHERE namespace_key = $1 AND bucket_key = $2
      """,
      [namespace_key, bucket_key, legacy]
    )

    Repo.query!(
      "UPDATE triage_bucket_memberships SET generation = NULL WHERE namespace_key = $1",
      [namespace_key]
    )

    Repo.query!(
      "UPDATE triage_run_fences SET body = body - 'sealed_generation' WHERE namespace_key = $1",
      [namespace_key]
    )

    second =
      thread_receipt!(authority, "Ev-pg-thread-archive-2", "1787019000.000009")

    accept!(server, authority, second)

    assert true =
             eventually(fn -> length(Triage.ledger_records(server)) == 2 end)

    # The second settlement archives its own generation and the legacy one.
    assert {:ok, %{"sealed_generations" => []}} = SalixIM.Triage.Bucketing.load(namespace, scope)

    # The legacy fence received the exact copy, so the archive stays readable.
    assert {:ok, ^legacy} =
             SalixIM.Triage.Bucketing.load_sealed_generation(
               namespace,
               scope,
               legacy["generation"]
             )

    assert %Postgrex.Result{rows: [[0, 2]]} =
             Repo.query!(
               """
               SELECT count(*) FILTER (WHERE generation IS NULL), count(*)
               FROM triage_bucket_memberships WHERE namespace_key = $1
               """,
               [namespace_key]
             )

    # A late duplicate of the archived first message resolves through the
    # archive; it does not re-enter the bucket as new work.
    assert {:ok, :duplicate, durable} = Admission.accept_membership(namespace, authority, first)
    refute Enum.any?(durable["open_receipts"], &(&1["receipt_ref"] == first["receipt_ref"]))
  end
end
