defmodule SalixStore.TriageRecordsTest do
  use ExUnit.Case, async: false

  @body_size_migration_version 20_260_826_000_102

  Code.require_file(
    "../priv/repo/migrations/20260826000102_add_triage_record_body_bytes.exs",
    __DIR__
  )

  alias SalixStore.{
    CasRecord,
    Crypto,
    Lease,
    Repo,
    S3,
    TriageKeys,
    TriageRecords,
    TriageTransactions
  }

  setup do
    previous_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :triage_record_backend, TriageRecords)

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
      triage_record_body_sizes,
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
        Application.put_env(:salix_store, :triage_record_backend, previous_backend)
      else
        Application.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    :ok
  end

  test "native Triage uses typed protocol tables instead of a mutable key-value table" do
    assert %Postgrex.Result{
             rows: [[nil, "triage_buckets", "triage_run_fences", "triage_runs", "triage_replays"]]
           } =
             Repo.query!("""
             SELECT
               to_regclass('triage_records')::text,
               to_regclass('triage_buckets')::text,
               to_regclass('triage_run_fences')::text,
               to_regclass('triage_runs')::text,
               to_regclass('triage_replays')::text
             """)

    assert %{rows: [[0]]} =
             Repo.query!("""
             SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'triage_recipient_aliases'
               AND column_name = 'addressing_kind'
             """)
  end

  test "status reads omit large evidence and check exact archived receipt membership" do
    key = TriageKeys.ctl_im_triage_bucket_seal("status-summary", "scope", "generation")
    bucket_key = TriageKeys.ctl_im_triage_bucket("status-summary", "scope")

    assert {:ok, _} =
             TriageRecords.put(bucket_key, Jason.encode!(bucket("scope", "next")),
               if_none_match: "*"
             )

    body = %{
      "schema" => "comma.triage-bucket-fence.v2",
      "bucket_scope" => "scope",
      "generation" => "generation",
      "run_id" => "run",
      "created_at" => 1,
      "deadline_at" => 2,
      "terminal" => %{"status" => "failed", "settled_at" => 3},
      "sealed_generation" => %{"sealed_at" => 1, "receipts" => [%{"receipt_ref" => "receipt"}]},
      # The real 250 ms status-read deadline must still hold when the stored
      # evidence is large. Repeated JSONB field extraction decompresses this
      # same value for each field and exhausts that deadline.
      "input_snapshot" => String.duplicate("private evidence", 3_000_000)
    }

    assert {:ok, _} = TriageRecords.put(key, Jason.encode!(body), if_none_match: "*")
    assert {:error, :too_large} = TriageRecords.get_bounded(key, 4 * 1024 * 1024)
    assert {:ok, summary} = TriageRecords.processing_fence(key, ["receipt"])
    assert summary["terminal"] == %{"status" => "failed", "settled_at" => 3}
    assert summary["archived_membership"] == true
    assert byte_size(Jason.encode!(summary)) < 1024
    refute inspect(summary) =~ "private evidence"

    assert {:ok, %{"archived_membership" => false}} =
             TriageRecords.processing_fence(key, ["another-receipt"])
  end

  test "status reads preserve an open evaluation" do
    namespace = "status-terminal"
    bucket_key = TriageKeys.ctl_im_triage_bucket(namespace, "scope")
    key = TriageKeys.ctl_im_triage_bucket_seal(namespace, "scope", "open")

    assert {:ok, _} =
             TriageRecords.put(bucket_key, Jason.encode!(bucket("scope", "next")),
               if_none_match: "*"
             )

    body = %{"schema" => "comma.triage-bucket-fence.v2", "run_id" => "run", "terminal" => nil}
    assert {:ok, _} = TriageRecords.put(key, Jason.encode!(body), if_none_match: "*")
    assert {:ok, summary} = TriageRecords.processing_fence(key, ["receipt"])
    assert summary["terminal"] == nil
  end

  @tag :recovery_query
  test "recovery pages return open fences and missing generations without completed history" do
    namespace = "pending-recovery"
    bucket_key = TriageKeys.ctl_im_triage_bucket(namespace, "scope-a")
    generations = for ordinal <- 1..24, do: "generation-#{ordinal}"
    sealed = Enum.map(generations, &%{"generation" => &1, "receipts" => [], "sealed_at" => 1})
    durable = Map.put(bucket("scope-a", "next-generation"), "sealed_generations", sealed)
    assert {:ok, _} = TriageRecords.put(bucket_key, Jason.encode!(durable), if_none_match: "*")

    open_keys =
      for {generation, ordinal} <- Enum.with_index(Enum.take(generations, 23), 1) do
        key = TriageKeys.ctl_im_triage_bucket_seal(namespace, "scope-a", generation)
        terminal = if ordinal <= 20, do: %{"status" => "evaluated"}, else: nil

        body = %{
          "schema" => "comma.triage-bucket-fence.v1",
          "run_id" => "run-#{ordinal}",
          "terminal" => terminal
        }

        assert {:ok, _} = TriageRecords.put(key, Jason.encode!(body), if_none_match: "*")
        if is_nil(terminal), do: key
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    prefix = TriageKeys.ctl_im_triage_bucket_seals_prefix(namespace)
    assert {:ok, %{records: first, next: next}} = TriageRecords.recovery_page(prefix, max_keys: 2)
    assert is_binary(next)
    assert Enum.map(first, &elem(&1, 0)) == Enum.take(open_keys, 2)
    assert Enum.all?(first, fn {_key, fence} -> is_nil(fence["terminal"]) end)

    assert {:ok, %{records: last, next: nil}} =
             TriageRecords.recovery_page(prefix, max_keys: 2, continuation_token: next)

    assert Enum.map(last, &elem(&1, 0)) == Enum.drop(open_keys, 2)

    assert {:ok, %{records: [{^bucket_key, pending}], next: nil}} =
             TriageRecords.recovery_page(TriageKeys.ctl_im_triage_buckets_prefix(namespace),
               max_keys: 24
             )

    assert pending == %{"bucket_scope" => "scope-a", "sealed_generations" => [List.last(sealed)]}
    assert {:ok, %{body: body}} = TriageRecords.get(bucket_key)
    assert Jason.decode!(body) == durable
    assert {:ok, %{objects: all_fences}} = TriageRecords.list(prefix, max_keys: 50)
    assert length(all_fences) == 23

    assert {:ok, %{records: [], next: nil}} =
             TriageRecords.recovery_page(TriageKeys.ctl_im_triage_bucket_seals_prefix("other"),
               max_keys: 2
             )
  end

  @tag :recovery_query
  test "one bucket's missing generations respect the recovery page budget" do
    namespace = "generation-page-budget"
    key = TriageKeys.ctl_im_triage_bucket(namespace, "busy-scope")
    prefix = TriageKeys.ctl_im_triage_buckets_prefix(namespace)
    sealed = for n <- 1..5, do: %{"generation" => "g-#{n}", "receipts" => [], "sealed_at" => n}
    body = Map.put(bucket("busy-scope", "next"), "sealed_generations", sealed)
    assert {:ok, _} = TriageRecords.put(key, Jason.encode!(body), if_none_match: "*")

    assert {:ok, %{records: [{^key, first}], next: next}} =
             TriageRecords.recovery_page(prefix, max_keys: 2)

    assert first["sealed_generations"] == Enum.take(sealed, 2)
    assert is_binary(next)

    assert {:ok, %{records: [{^key, second}], next: next}} =
             TriageRecords.recovery_page(prefix, max_keys: 2, continuation_token: next)

    assert second["sealed_generations"] == Enum.slice(sealed, 2, 2)
    assert is_binary(next)

    assert {:ok, %{records: [{^key, last}], next: nil}} =
             TriageRecords.recovery_page(prefix, max_keys: 2, continuation_token: next)

    assert last["sealed_generations"] == [List.last(sealed)]
  end

  @tag :recovery_query
  test "a malformed bucket history is counted and does not pin recovery" do
    namespace = "malformed-history-recovery"
    prefix = TriageKeys.ctl_im_triage_buckets_prefix(namespace)

    [{first_key, first_scope}, {last_key, last_scope}] =
      for scope <- ["malformed-a", "malformed-b"] do
        {TriageKeys.ctl_im_triage_bucket(namespace, scope), scope}
      end
      |> Enum.sort()

    for {key, scope, history} <- [{first_key, first_scope, %{}}, {last_key, last_scope, []}] do
      body = Map.put(bucket(scope, "next"), "sealed_generations", history)
      assert {:ok, _} = TriageRecords.put(key, Jason.encode!(body), if_none_match: "*")
    end

    assert {:ok, %{records: [], record_errors: 1, next: next}} =
             TriageRecords.recovery_page(prefix, max_keys: 2)

    assert is_binary(next)

    assert {:ok, %{records: [{^last_key, _}], next: nil}} =
             TriageRecords.recovery_page(prefix, max_keys: 2, continuation_token: next)
  end

  @tag :recovery_query
  test "an empty historical generation list does not block the next recovery page" do
    namespace = "empty-history-recovery"
    prefix = TriageKeys.ctl_im_triage_buckets_prefix(namespace)

    keys =
      for scope <- ["empty-a", "empty-b"] do
        key = TriageKeys.ctl_im_triage_bucket(namespace, scope)
        body = Map.put(bucket(scope, "next"), "sealed_generations", nil)
        assert {:ok, _} = TriageRecords.put(key, Jason.encode!(body), if_none_match: "*")
        key
      end
      |> Enum.sort()

    assert {:ok, %{records: [{first_key, first}], next: next}} =
             TriageRecords.recovery_page(prefix, max_keys: 1)

    assert first_key == hd(keys)
    assert first["sealed_generations"] == []
    assert is_binary(next)

    assert {:ok, %{records: [{last_key, last}], next: nil}} =
             TriageRecords.recovery_page(prefix, max_keys: 1, continuation_token: next)

    assert last_key == List.last(keys)
    assert last["sealed_generations"] == []
  end

  test "database foreign keys forbid recipient membership before receipt projection and bucket" do
    namespace_key = Crypto.hex("membership-fk")
    source_key = Crypto.hex("source-fk")
    recipient_key = Crypto.hex("recipient-fk")
    receipt_key = Crypto.hex("s3://receipt-fk")
    receipt_ref = "s3://receipt-fk"

    assert_raise Postgrex.Error, ~r/triage_recipient_aliases_receipt_fkey/, fn ->
      Repo.query!(
        """
        INSERT INTO triage_recipient_aliases
          (namespace_key, physical_source_key, recipient_key, receipt_key,
           canonical_receipt_ref)
        VALUES ($1, $2, $3, $4, $5)
        """,
        [namespace_key, source_key, recipient_key, receipt_key, receipt_ref]
      )
    end

    Repo.query!(
      """
      INSERT INTO triage_receipt_projections
        (record_key, namespace_key, receipt_key, receipt_ref, body)
      VALUES ($1, $2, $3, $4, $5)
      """,
      [
        "projection-fk",
        namespace_key,
        receipt_key,
        receipt_ref,
        %{
          "schema" => "comma.triage-receipt-projection.v1",
          "receipt_ref" => receipt_ref,
          "event_id" => "event-fk"
        }
      ]
    )

    Repo.query!(
      """
      INSERT INTO triage_recipient_aliases
        (namespace_key, physical_source_key, recipient_key, receipt_key,
         canonical_receipt_ref)
      VALUES ($1, $2, $3, $4, $5)
      """,
      [namespace_key, source_key, recipient_key, receipt_key, receipt_ref]
    )

    bucket_key = Crypto.hex("bucket-fk")

    Repo.query!(
      """
      INSERT INTO triage_buckets (record_key, namespace_key, bucket_key, body)
      VALUES ($1, $2, $3, $4)
      """,
      ["bucket-record-fk", namespace_key, bucket_key, bucket("bucket-fk", "generation-fk")]
    )

    assert_raise Postgrex.Error, ~r/triage_bucket_memberships_recipient_alias_fkey/, fn ->
      Repo.query!(
        """
        INSERT INTO triage_bucket_memberships
          (namespace_key, physical_source_key, recipient_key, bucket_key,
           canonical_receipt_ref, lane)
        VALUES ($1, $2, $3, $4, $5, 'directed')
        """,
        [
          namespace_key,
          source_key,
          recipient_key,
          bucket_key,
          "s3://different-receipt"
        ]
      )
    end

    assert_raise Postgrex.Error, ~r/triage_bucket_memberships_bucket_fkey/, fn ->
      Repo.query!(
        """
        INSERT INTO triage_bucket_memberships
          (namespace_key, physical_source_key, recipient_key, bucket_key,
           canonical_receipt_ref, lane)
        VALUES ($1, $2, $3, $4, $5, 'directed')
        """,
        [namespace_key, source_key, recipient_key, Crypto.hex("missing-bucket"), receipt_ref]
      )
    end
  end

  test "mutable bucket writes preserve create-once and revision-fenced CAS" do
    key = TriageKeys.ctl_im_triage_bucket("typed-cas", "scope-a")
    first = bucket("scope-a", "generation-a")
    second = %{first | "open_generation" => "generation-b"}

    assert {:ok, %{etag: first_etag}} =
             TriageRecords.put(key, Jason.encode!(first), if_none_match: "*")

    assert {:error, :precondition_failed} =
             TriageRecords.put(key, Jason.encode!(second), if_none_match: "*")

    assert {:ok, %{body: body, etag: ^first_etag}} = TriageRecords.get(key)
    assert Jason.decode!(body) == first

    assert {:ok, %{etag: second_etag}} =
             TriageRecords.put(key, Jason.encode!(second), if_match: first_etag)

    refute second_etag == first_etag

    assert {:error, :precondition_failed} =
             TriageRecords.put(key, Jason.encode!(first), if_match: first_etag)

    assert {:ok, %{body: body, etag: ^second_etag}} = TriageRecords.get(key)
    assert Jason.decode!(body) == second
  end

  test "bounded reads refuse an oversized typed body before returning it" do
    key = TriageKeys.ctl_im_triage_bucket("typed-bounded", "scope-bounded")
    record = bucket("scope-bounded", "generation-bounded")

    assert {:ok, _created} =
             TriageRecords.put(key, Jason.encode!(record), if_none_match: "*")

    assert {:ok, %{body: stored_body}} = TriageRecords.get(key)
    stored_size = byte_size(stored_body)

    assert {:ok, %{body: ^stored_body, size: ^stored_size}} =
             TriageRecords.get_bounded(key, stored_size)

    assert {:error, :too_large} = TriageRecords.get_bounded(key, stored_size - 1)
    assert {:error, :not_found} = TriageRecords.get_bounded(key <> "-missing", stored_size)

    # The bounded read trusts O(1) write-time metadata. It does not rediscover
    # the size by serializing the JSONB body on the request path.
    Repo.query!(
      "UPDATE triage_record_body_sizes SET body_bytes = $3 WHERE source_table = $1 AND record_key = $2",
      ["triage_buckets", key, stored_size + 1]
    )

    assert {:error, :too_large} = TriageRecords.get_bounded(key, stored_size)

    Repo.query!(
      "DELETE FROM triage_record_body_sizes WHERE source_table = $1 AND record_key = $2",
      ["triage_buckets", key]
    )

    assert {:error, :unavailable} = TriageRecords.get_bounded(key, stored_size)
  end

  test "bounded reads reject a compressed multi-megabyte PostgreSQL body from metadata" do
    key = TriageKeys.ctl_im_triage_bucket("typed-large", "scope-large")
    max_bytes = 4 * 1024 * 1024

    record =
      "scope-large"
      |> bucket("generation-large")
      |> Map.put("open_receipts", [
        %{"receipt_ref" => "large", "text" => String.duplicate("x", max_bytes + 1_024)}
      ])

    assert {:ok, _created} =
             TriageRecords.put(key, Jason.encode!(record), if_none_match: "*")

    assert %{rows: [[body_bytes, stored_bytes]]} =
             Repo.query!(
               "SELECT sizes.body_bytes, pg_column_size(records.body) FROM triage_buckets AS records JOIN triage_record_body_sizes AS sizes ON sizes.source_table = $1 AND sizes.record_key = records.record_key WHERE records.record_key = $2",
               ["triage_buckets", key]
             )

    assert body_bytes > max_bytes
    assert stored_bytes < body_bytes
    assert {:error, :too_large} = TriageRecords.get_bounded(key, max_bytes)
  end

  test "metadata-covered prefix lists fail closed before materializing missing or stale bodies" do
    namespace = "typed-list-bound"
    key = TriageKeys.ctl_im_triage_bucket(namespace, "scope-large")
    max_bytes = 4 * 1024 * 1024

    record =
      "scope-large"
      |> bucket("generation-large")
      |> Map.put("open_receipts", [
        %{"receipt_ref" => "large", "text" => String.duplicate("x", max_bytes + 1_024)}
      ])

    assert {:ok, _created} =
             TriageRecords.put(key, Jason.encode!(record), if_none_match: "*")

    prefix = TriageKeys.ctl_im_triage_buckets_prefix(namespace)

    assert %{rows: [[revision, body_bytes]]} =
             Repo.query!(
               "SELECT revision, body_bytes FROM triage_record_body_sizes WHERE source_table = 'triage_buckets' AND record_key = $1",
               [key]
             )

    assert body_bytes > max_bytes

    assert {:ok, %{objects: [%{key: ^key, size: ^body_bytes}], next: nil}} =
             TriageRecords.list(prefix, max_keys: 25)

    Repo.query!(
      "DELETE FROM triage_record_body_sizes WHERE source_table = 'triage_buckets' AND record_key = $1",
      [key]
    )

    assert {:error, :unavailable} = TriageRecords.list(prefix, max_keys: 25)

    Repo.query!(
      "INSERT INTO triage_record_body_sizes (source_table, record_key, revision, body_bytes) VALUES ('triage_buckets', $1, $2, $3)",
      [key, revision + 1, body_bytes]
    )

    assert {:error, :unavailable} = TriageRecords.list(prefix, max_keys: 25)
  end

  test "body-size migration backfills multiple pages and repairs a partial retry" do
    namespace_key = Crypto.hex("body-size-migration-upgrade")

    on_exit(fn ->
      ensure_body_size_migration!()

      Repo.query!("""
      TRUNCATE
        triage_record_body_sizes,
        triage_replays,
        triage_runs,
        triage_buckets
      CASCADE
      """)
    end)

    assert :ok =
             Ecto.Migrator.down(
               Repo,
               @body_size_migration_version,
               SalixStore.Repo.Migrations.AddTriageRecordBodyBytes,
               log: false
             )

    Repo.query!(
      """
      INSERT INTO triage_runs (record_key, namespace_key, run_id, body)
      SELECT
        'migration-upgrade/runs/' || series,
        $1,
        'migration-run-' || series,
        jsonb_build_object(
          'schema', 'comma.triage-run.v1',
          'run_id', 'migration-run-' || series,
          'authoritative', true,
          'created_at', series,
          'status', 'evaluated'
        )
      FROM generate_series(1, 205) AS series
      """,
      [namespace_key]
    )

    Repo.query!(
      """
      INSERT INTO triage_replays (record_key, namespace_key, run_id, body)
      SELECT
        'migration-upgrade/replays/' || series,
        $1,
        'migration-run-' || series,
        jsonb_build_object(
          'schema', 'comma.triage-replay.v1',
          'run_id', 'migration-run-' || series,
          'ledger_ref', 'migration-upgrade/runs/' || series,
          'run_sha256', repeat('a', 64)
        )
      FROM generate_series(1, 205) AS series
      """,
      [namespace_key]
    )

    source_hashes = migration_source_hashes(namespace_key)

    assert :ok =
             Ecto.Migrator.up(
               Repo,
               @body_size_migration_version,
               SalixStore.Repo.Migrations.AddTriageRecordBodyBytes,
               log: false
             )

    assert_body_size_metadata!(namespace_key, "triage_runs", 205)
    assert_body_size_metadata!(namespace_key, "triage_replays", 205)

    Repo.query!("""
    DELETE FROM triage_record_body_sizes
    WHERE (source_table, record_key) IN (
      SELECT source_table, record_key
      FROM triage_record_body_sizes
      WHERE source_table = 'triage_runs'
      ORDER BY record_key
      LIMIT 114
    )
    """)

    Repo.query!("""
    UPDATE triage_record_body_sizes
    SET body_bytes = body_bytes + 1
    WHERE source_table = 'triage_replays'
      AND record_key = 'migration-upgrade/replays/1'
    """)

    Repo.query!(
      "DELETE FROM salix_schema_migrations WHERE version = $1",
      [@body_size_migration_version]
    )

    assert :ok =
             Ecto.Migrator.up(
               Repo,
               @body_size_migration_version,
               SalixStore.Repo.Migrations.AddTriageRecordBodyBytes,
               log: false
             )

    assert_body_size_metadata!(namespace_key, "triage_runs", 205)
    assert_body_size_metadata!(namespace_key, "triage_replays", 205)
    assert migration_source_hashes(namespace_key) == source_hashes

    bucket_key = TriageKeys.ctl_im_triage_bucket("migration-upgrade", "scope")
    first = bucket("scope", "generation-1")
    second = %{first | "open_generation" => "generation-2"}

    assert {:ok, %{etag: first_etag}} =
             TriageRecords.put(bucket_key, Jason.encode!(first), if_none_match: "*")

    assert {:ok, _updated} =
             TriageRecords.put(bucket_key, Jason.encode!(second), if_match: first_etag)

    assert %{rows: [[2, current_bytes]]} =
             Repo.query!(
               "SELECT revision, body_bytes FROM triage_record_body_sizes WHERE source_table = 'triage_buckets' AND record_key = $1",
               [bucket_key]
             )

    assert %{num_rows: 0} =
             Repo.query!(
               """
               INSERT INTO triage_record_body_sizes
                 (source_table, record_key, revision, body_bytes)
               VALUES ('triage_buckets', $1, 1, 1)
               ON CONFLICT (source_table, record_key) DO UPDATE SET
                 revision = EXCLUDED.revision,
                 body_bytes = EXCLUDED.body_bytes,
                 updated_at = EXCLUDED.updated_at
               WHERE triage_record_body_sizes.revision <= EXCLUDED.revision
               """,
               [bucket_key]
             )

    assert %{rows: [[2, ^current_bytes]]} =
             Repo.query!(
               "SELECT revision, body_bytes FROM triage_record_body_sizes WHERE source_table = 'triage_buckets' AND record_key = $1",
               [bucket_key]
             )
  end

  test "evidence tables reject update and delete even for the table owner" do
    run_id = "run-immutable"
    key = TriageKeys.ctl_im_triage_ledger_run("immutable", run_id)
    run = run(run_id)

    assert {:ok, %{etag: etag}} =
             TriageRecords.put(key, Jason.encode!(run), if_none_match: "*")

    assert {:error, :precondition_failed} =
             TriageRecords.put(key, Jason.encode!(Map.put(run, "status", "changed")),
               if_match: etag
             )

    assert {:error, :invalid} = TriageRecords.delete(key, if_match: etag)

    assert_raise Postgrex.Error, ~r/native Triage evidence is append-only/, fn ->
      Repo.query!("UPDATE triage_runs SET body = body WHERE record_key = $1", [key])
    end
  end

  test "typed prefix pages are bytewise ordered, bounded, and resumable" do
    namespace = "typed-pages"

    for run_id <- ~w(c a b other-d) do
      key = TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)
      assert {:ok, _} = TriageRecords.put(key, Jason.encode!(run(run_id)), if_none_match: "*")
    end

    prefix = TriageKeys.ctl_im_triage_ledger_runs_prefix(namespace)

    assert {:ok, %{objects: [%{key: first}, %{key: second}], next: token}} =
             TriageRecords.list(prefix, max_keys: 2)

    assert [first, second] == [prefix <> "a.json", prefix <> "b.json"]
    assert is_binary(token)

    assert {:ok, %{objects: [%{key: third}, %{key: fourth}], next: nil}} =
             TriageRecords.list(prefix, continuation_token: token, max_keys: 2)

    assert [third, fourth] == [prefix <> "c.json", prefix <> "other-d.json"]

    assert {:ok, all} = TriageRecords.list_all(prefix)
    assert Enum.map(all, & &1.key) == [first, second, third, fourth]
  end

  test "recovery lease deletion is revision fenced" do
    key = TriageKeys.ctl_im_triage_receipt_recovery_lease("delete-lease")
    body = Jason.encode!(%{"holder" => "pod-a", "epoch" => 1, "lease_until" => 100})

    assert {:ok, %{etag: etag}} = TriageRecords.put(key, body, if_none_match: "*")
    assert {:error, :precondition_failed} = TriageRecords.delete(key, if_match: "pg:999")
    assert :ok = TriageRecords.delete(key, if_match: etag)
    assert {:error, :not_found} = TriageRecords.get(key)
  end

  test "CasRecord routes Triage-owned records to the typed bucket table, never S3" do
    key = TriageKeys.ctl_im_triage_bucket("cas-routing-test", "bucket-a")
    first = bucket("bucket-a", "generation-a")
    second = %{first | "open_generation" => "generation-b"}

    assert {:ok, ^first} = CasRecord.create(key, first)
    assert {:ok, ^second} = CasRecord.update(key, fn ^first -> second end)
    assert {:ok, ^second} = CasRecord.get(key)
    assert {:ok, %{body: body}} = TriageRecords.get(key)
    assert Jason.decode!(body) == second
    assert {:error, :not_found} = S3.get(key)
  end

  test "generic leases use the dedicated mutable recovery-lease table" do
    key = TriageKeys.ctl_im_triage_receipt_recovery_lease("lease-pg-test")

    assert {:ok, first} = Lease.acquire(key, "pod-a", now: 1_000, ttl_ms: 100)
    assert {:ok, %{body: body, etag: first_etag}} = TriageRecords.get(key)
    assert Jason.decode!(body) == %{"epoch" => 1, "holder" => "pod-a", "lease_until" => 1_100}
    assert first.etag == first_etag

    assert {:error, {:held_by, "pod-a", 1_100}} =
             Lease.acquire(key, "pod-b", now: 1_050, ttl_ms: 100)

    assert :ok = Lease.assert_owner(first)
    assert {:ok, renewed} = Lease.renew(first, now: 1_060, ttl_ms: 100)
    assert renewed.epoch == 1
    assert renewed.lease_until == 1_160

    assert :ok = Lease.release(renewed)
    assert {:error, :not_found} = TriageRecords.get(key)
  end

  test "channel completion preserves exact source, pending batches and open arrivals atomically" do
    namespace = "channel-archive"
    first = channel_receipt("archive-first")
    persist_receipt!(first)
    admission = admission(namespace, first, :ambient)
    assert {:ok, %{durable: initial}} = TriageTransactions.admit_receipt(admission)
    bucket_key = TriageKeys.ctl_im_triage_bucket(namespace, admission.bucket_identity)

    sealed = %{
      "generation" => initial["open_generation"],
      "receipts" => [first],
      "sealed_at" => 1
    }

    second = channel_receipt("archive-second", "1711000000.000002")
    third = channel_receipt("archive-third", "1711000000.000003")
    other = %{"generation" => "pending-generation", "receipts" => [second], "sealed_at" => 2}

    pending = %{
      initial
      | "open_generation" => "next-generation",
        "open_receipts" => [third],
        "sealed_generations" => [sealed, other]
    }

    assert {:ok, %{etag: bucket_etag}} = TriageRecords.get(bucket_key)
    assert {:ok, _} = TriageRecords.put(bucket_key, Jason.encode!(pending), if_match: bucket_etag)

    commit = authoritative_commit(namespace, "run-channel-archive")

    fence_key =
      TriageKeys.ctl_im_triage_bucket_seal(
        namespace,
        admission.bucket_identity,
        sealed["generation"]
      )

    fence =
      Map.merge(commit.fence, %{
        "bucket_scope" => admission.bucket_identity,
        "generation" => sealed["generation"],
        "input_snapshot" => %{"source_authority" => %{"scope_kind" => "channel"}},
        "sealed_generation" => sealed
      })

    commit = %{
      commit
      | fence_key: fence_key,
        fence: fence,
        obligation: Map.put(commit.obligation, "fence_key", fence_key)
    }

    assert {:ok, %{etag: etag}} =
             TriageRecords.put(
               fence_key,
               Jason.encode!(
                 fence
                 |> Map.put("terminal", nil)
                 |> Map.delete("sealed_generation")
               ),
               if_none_match: "*"
             )

    commit = %{commit | expected_etag: etag}

    assert {:error, :conflict} =
             TriageTransactions.commit_authoritative(%{commit | expected_etag: "pg:999"})

    assert {:ok, %{body: unchanged}} = TriageRecords.get(bucket_key)
    assert Jason.decode!(unchanged) == pending
    assert {:error, :not_found} = TriageRecords.get(commit.run_key)

    tampered = put_in(commit, [:fence, "sealed_generation", "receipts"], [])
    assert {:error, :conflict} = TriageTransactions.commit_authoritative(tampered)
    assert {:ok, %{body: ^unchanged}} = TriageRecords.get(bucket_key)

    owner = self()

    completion =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, result} = TriageTransactions.commit_authoritative(commit)
          send(owner, {:channel_completion_staged, self()})

          receive do
            :publish -> result
          after
            5_000 -> Repo.rollback(:completion_not_released)
          end
        end)
      end)

    assert_receive {:channel_completion_staged, completion_pid}, 5_000

    duplicate =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(owner, {:channel_duplicate_backend, backend_pid})
          TriageTransactions.admit_receipt(admission)
        end)
      end)

    assert_receive {:channel_duplicate_backend, backend_pid}, 5_000
    assert wait_for_bucket_lock(backend_pid, 200)
    send(completion_pid, :publish)
    assert {:ok, _} = Task.await(completion)
    assert {:ok, %{status: :duplicate, durable: duplicate_view}} = Task.await(duplicate)
    assert duplicate_view["open_receipts"] == [third]
    assert sealed in duplicate_view["sealed_generations"]

    assert {:ok, %{body: compacted}} = TriageRecords.get(bucket_key)
    assert Jason.decode!(compacted) == %{pending | "sealed_generations" => [other]}
    assert {:ok, %{body: archive}} = TriageRecords.get(fence_key)
    assert Jason.decode!(archive)["sealed_generation"] == sealed
    assert {:ok, _} = TriageTransactions.commit_authoritative(commit)
  end

  defp wait_for_bucket_lock(_backend_pid, 0), do: false

  defp wait_for_bucket_lock(backend_pid, attempts) do
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid]) do
      %{rows: [["Lock"]]} ->
        true

      _running ->
        Process.sleep(5)
        wait_for_bucket_lock(backend_pid, attempts - 1)
    end
  end

  test "channel capacity leaves the new receipt recoverable and permits a later retry" do
    for {kind, count} <- [{:open, 200}, {:pending, 10}] do
      namespace = "channel-capacity-#{kind}"
      first = channel_receipt("capacity-#{kind}-first")
      persist_receipt!(first)
      admission = admission(namespace, first, :ambient)
      assert {:ok, %{durable: initial}} = TriageTransactions.admit_receipt(admission)
      key = TriageKeys.ctl_im_triage_bucket(namespace, admission.bucket_identity)

      full =
        case kind do
          :open ->
            Map.put(initial, "open_receipts", List.duplicate(first, count))

          :pending ->
            Map.put(
              initial,
              "sealed_generations",
              for(
                ordinal <- 1..count,
                do: %{
                  "generation" => "g-#{ordinal}",
                  "receipts" => [first],
                  "sealed_at" => ordinal
                }
              )
            )
        end

      assert {:ok, %{etag: etag}} = TriageRecords.get(key)
      assert {:ok, _} = TriageRecords.put(key, Jason.encode!(full), if_match: etag)
      next = channel_receipt("capacity-#{kind}-next", "1711000000.000009")
      persist_receipt!(next)
      next_admission = admission(namespace, next, :ambient)
      assert {:error, :unavailable} = TriageTransactions.admit_receipt(next_admission)
      "s3://" <> receipt_key = next["receipt_ref"]
      assert {:ok, _} = S3.get(receipt_key)

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM triage_recipient_aliases WHERE canonical_receipt_ref = $1",
                 [next["receipt_ref"]]
               )

      assert {:ok, %{etag: full_etag}} = TriageRecords.get(key)
      assert {:ok, _} = TriageRecords.put(key, Jason.encode!(initial), if_match: full_etag)
      assert {:ok, %{status: :accepted}} = TriageTransactions.admit_receipt(next_admission)
    end
  end

  defp channel_receipt(event_id, message_ts \\ "1711000000.000001") do
    admission_receipt(event_id, "connect-channel", message_ts: message_ts)
    |> put_in(["triage_event", "bucket", "scope_kind"], "channel")
    |> put_in(["triage_event", "fast_path"], false)
  end

  test "terminal fence, run, replay and projection obligation commit atomically and retry idempotently" do
    create_bucket("atomic")
    commit = authoritative_commit("atomic", "run-atomic")

    assert {:ok, %{etag: open_etag}} =
             TriageRecords.put(
               commit.fence_key,
               Jason.encode!(Map.put(commit.fence, "terminal", nil)),
               if_none_match: "*"
             )

    commit = %{commit | expected_etag: open_etag}

    assert {:ok, %{fence_etag: terminal_etag}} =
             TriageTransactions.commit_authoritative(commit)

    assert terminal_etag != open_etag
    assert {:ok, %{body: fence_body}} = TriageRecords.get(commit.fence_key)
    assert Jason.decode!(fence_body) == commit.fence
    assert {:ok, %{body: run_body}} = TriageRecords.get(commit.run_key)
    assert Jason.decode!(run_body) == commit.run
    assert {:ok, %{body: replay_body}} = TriageRecords.get(commit.replay_key)
    assert Jason.decode!(replay_body) == commit.replay

    assert {:ok, %{body: ^fence_body}} =
             TriageRecords.get_bounded(commit.fence_key, 1_000_000)

    assert {:ok, %{body: ^run_body}} = TriageRecords.get_bounded(commit.run_key, 1_000_000)

    assert {:ok, %{body: ^replay_body}} =
             TriageRecords.get_bounded(commit.replay_key, 1_000_000)

    assert {:ok, [%{run_id: "run-atomic", attempts: 0}]} =
             TriageTransactions.pending_projection_obligations(10)

    assert {:ok, %{fence_etag: ^terminal_etag}} =
             TriageTransactions.commit_authoritative(commit)

    open_fence = Map.put(commit.fence, "terminal", nil)

    assert {:error, :invalid} =
             TriageRecords.put(commit.fence_key, Jason.encode!(open_fence),
               if_match: terminal_etag
             )

    assert_raise Postgrex.Error, ~r/native Triage fence terminal is monotonic/, fn ->
      Repo.query!("UPDATE triage_run_fences SET body = $2 WHERE record_key = $1", [
        commit.fence_key,
        open_fence
      ])
    end

    assert :ok =
             TriageTransactions.mark_projection_failed(
               namespace_key(commit.fence_key),
               "run-atomic",
               "projector offline"
             )

    assert {:ok, [%{run_id: "run-atomic", attempts: 1}]} =
             TriageTransactions.pending_projection_obligations(10)

    assert {:ok, %{body: run_body_after_failure}} = TriageRecords.get(commit.run_key)
    assert Jason.decode!(run_body_after_failure) == commit.run
  end

  test "product obligation joins the authoritative commit and exact retry" do
    create_bucket("product-atomic")

    commit =
      authoritative_commit("product-atomic", "run-product-atomic")
      |> then(fn commit ->
        obligation =
          commit
          |> product_obligation("product-atomic")
          |> Map.put("source_messages", [
            %{
              "actor_id" => "U_SOURCE",
              "actor_kind" => "human",
              "excerpt" => "Who owns the rollout?",
              "message_ts" => "1787900000.000001",
              "message_ts_us" => 1_787_900_000_000_001,
              "observed_version" => 3_575_800_000_000_002
            }
          ])

        %{commit | product_obligation: obligation}
      end)

    assert {:ok, %{etag: open_etag}} =
             TriageRecords.put(
               commit.fence_key,
               Jason.encode!(Map.put(commit.fence, "terminal", nil)),
               if_none_match: "*"
             )

    commit = %{commit | expected_etag: open_etag}

    assert {:ok, %{fence_etag: terminal_etag}} =
             TriageTransactions.commit_authoritative(commit)

    namespace_key = namespace_key(commit.fence_key)

    assert %{rows: [[payload, "pending", 0]]} =
             Repo.query!(
               """
               SELECT payload, state, attempts
               FROM triage_product_obligations
               WHERE namespace_key = $1 AND run_id = $2
               """,
               [namespace_key, "run-product-atomic"]
             )

    assert payload == commit.product_obligation

    assert {:ok, %{fence_etag: ^terminal_etag}} =
             TriageTransactions.commit_authoritative(commit)

    assert %{rows: [[1]]} =
             Repo.query!(
               """
               SELECT count(*)
               FROM triage_product_obligations
               WHERE namespace_key = $1 AND run_id = $2
               """,
               [namespace_key, "run-product-atomic"]
             )
  end

  @worker_expression %{
    "schema" => "comma.triage-expression-context.v1",
    "mode" => "project",
    "allow_reactions" => true,
    "allowed_emojis" => ["party_parrot"],
    "catalog" => %{
      "status" => "available",
      "complete?" => true,
      "custom_emojis" => ["party_parrot"]
    },
    "observed_reactions" => [],
    "guidance" => "Use the frozen palette."
  }
  @worker_context [
    %{
      "kind" => "retained_project_fact",
      "text" => "The project uses a staging workspace.",
      "source_ref" => "triage-context://project/fact"
    }
  ]

  for {name, extra} <- [
        {"expression", %{"expression_context" => @worker_expression}},
        {"context", %{"context_sources" => @worker_context}},
        {"both",
         %{"expression_context" => @worker_expression, "context_sources" => @worker_context}}
      ] do
    test "Worker #{name} survives the authoritative transaction and exact retry" do
      namespace = "worker-context-#{unquote(name)}"
      create_bucket(namespace)
      commit = authoritative_commit(namespace, "run-worker-context")

      obligation =
        product_obligation(commit, namespace) |> Map.merge(unquote(Macro.escape(extra)))

      commit = %{commit | product_obligation: obligation}

      assert {:ok, %{etag: open_etag}} =
               TriageRecords.put(
                 commit.fence_key,
                 Jason.encode!(Map.put(commit.fence, "terminal", nil)),
                 if_none_match: "*"
               )

      commit = %{commit | expected_etag: open_etag}
      assert {:ok, %{fence_etag: terminal_etag}} = TriageTransactions.commit_authoritative(commit)

      assert {:ok, %{fence_etag: ^terminal_etag}} =
               TriageTransactions.commit_authoritative(commit)

      assert %{rows: [[^obligation]]} =
               Repo.query!("SELECT payload FROM triage_product_obligations WHERE run_id = $1", [
                 "run-worker-context"
               ])

      for malformed <- [
            Map.put(obligation, "context_sources", List.duplicate(hd(@worker_context), 21)),
            Map.put(obligation, "context_sources", [
              %{"kind" => "private_note", "text" => "bad", "source_ref" => "other://ref"}
            ]),
            Map.put(obligation, "expression_context", %{"allowed_emojis" => ["invented"]})
          ] do
        assert {:error, :invalid} =
                 TriageTransactions.commit_authoritative(%{
                   commit
                   | product_obligation: malformed
                 })
      end
    end
  end

  test "primary and companion reaction obligations commit atomically" do
    create_bucket("product-companion")

    commit = authoritative_commit("product-companion", "run-product-companion")
    primary = product_obligation(commit, "product-companion")

    companion =
      primary
      |> Map.put("obligation_id", "triage-product-" <> String.duplicate("b", 64))
      |> Map.put("communication", %{
        "kind" => "reaction",
        "emoji" => "eyes",
        "source_refs" => ["slack://T-product/C-product/1787900000.000001"]
      })
      |> Map.put("reaction_authority", %{
        "schema" => "comma.triage-expression-context.v1",
        "mode" => "project",
        "allow_reactions" => true,
        "allowed_emojis" => ["+1", "eyes"],
        "catalog" => %{
          "status" => "available",
          "complete?" => true,
          "custom_emojis" => []
        },
        "observed_reactions" => [],
        "guidance" => "Use project reactions."
      })

    commit =
      commit
      |> Map.put(:product_obligation, primary)
      |> Map.put(:companion_product_obligation, companion)

    assert {:ok, %{etag: open_etag}} =
             TriageRecords.put(
               commit.fence_key,
               Jason.encode!(Map.put(commit.fence, "terminal", nil)),
               if_none_match: "*"
             )

    assert {:ok, %{fence_etag: terminal_etag}} =
             commit
             |> Map.put(:expected_etag, open_etag)
             |> TriageTransactions.commit_authoritative()

    namespace_key = namespace_key(commit.fence_key)

    assert %{rows: [[^companion, "pending", 0]]} =
             Repo.query!(
               """
               SELECT payload, state, attempts
               FROM triage_companion_reaction_obligations
               WHERE namespace_key = $1 AND run_id = $2
               """,
               [namespace_key, "run-product-companion"]
             )

    assert {:ok, %{fence_etag: ^terminal_etag}} =
             commit
             |> Map.put(:expected_etag, open_etag)
             |> TriageTransactions.commit_authoritative()
  end

  test "a rejected product obligation rolls the authoritative commit back" do
    create_bucket("product-rollback")

    commit =
      authoritative_commit("product-rollback", "run-product-rollback")
      |> then(fn commit ->
        obligation =
          commit
          |> product_obligation("product-rollback")
          |> Map.put("obligation_id", "triage-product-" <> String.duplicate("g", 64))

        %{commit | product_obligation: obligation}
      end)

    assert {:ok, %{etag: open_etag}} =
             TriageRecords.put(
               commit.fence_key,
               Jason.encode!(Map.put(commit.fence, "terminal", nil)),
               if_none_match: "*"
             )

    commit = %{commit | expected_etag: open_etag}

    assert {:error, :invalid} = TriageTransactions.commit_authoritative(commit)
    assert {:ok, %{body: fence_body, etag: ^open_etag}} = TriageRecords.get(commit.fence_key)
    assert Jason.decode!(fence_body)["terminal"] == nil
    assert {:error, :not_found} = TriageRecords.get(commit.run_key)
    assert {:error, :not_found} = TriageRecords.get(commit.replay_key)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM triage_product_obligations WHERE run_id = $1",
               ["run-product-rollback"]
             )
  end

  test "any invalid authoritative component rolls the terminal fence back" do
    create_bucket("rollback")
    commit = authoritative_commit("rollback", "run-rollback")

    assert {:ok, %{etag: open_etag}} =
             TriageRecords.put(
               commit.fence_key,
               Jason.encode!(Map.put(commit.fence, "terminal", nil)),
               if_none_match: "*"
             )

    invalid =
      commit
      |> Map.put(:expected_etag, open_etag)
      |> put_in([:replay, "schema"], "invalid")

    assert {:error, :invalid} = TriageTransactions.commit_authoritative(invalid)
    assert {:ok, %{body: fence_body, etag: ^open_etag}} = TriageRecords.get(commit.fence_key)
    assert Jason.decode!(fence_body)["terminal"] == nil
    assert {:error, :not_found} = TriageRecords.get(commit.run_key)
    assert {:error, :not_found} = TriageRecords.get(commit.replay_key)
    assert {:ok, []} = TriageTransactions.pending_projection_obligations(10)
  end

  test "an authoritative retry cannot materialize a missing fence" do
    create_bucket("missing-fence")
    commit = authoritative_commit("missing-fence", "run-missing-fence")

    assert {:error, :conflict} = TriageTransactions.commit_authoritative(commit)
    assert {:error, :not_found} = TriageRecords.get(commit.fence_key)
    assert {:error, :not_found} = TriageRecords.get(commit.run_key)
    assert {:error, :not_found} = TriageRecords.get(commit.replay_key)
    assert {:ok, []} = TriageTransactions.pending_projection_obligations(10)
  end

  test "receipt admission refuses to create runnable membership before its S3 evidence exists" do
    receipt = admission_receipt("missing-evidence", "connect-a")

    assert {:error, :receipt_unavailable} =
             TriageTransactions.admit_receipt(admission("missing-evidence", receipt, :ambient))

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM triage_bucket_memberships")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM triage_recipient_aliases")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM triage_buckets")
  end

  test "v1 receipt handoff accepts only the complete lossless v2 normalization" do
    normalized =
      admission_receipt("v1-handoff", "connect-a")
      |> put_in(["triage_event", "actor_kind"], "human")
      |> put_in(["triage_event", "text"], "Need context?")
      |> put_in(["triage_event", "event_type"], "message")
      |> put_in(["triage_event", "addressing_kind"], "ambient")
      |> put_in(["triage_event", "trigger_kind"], "question_heuristic")
      |> update_in(["triage_event"], &Map.delete(&1, "addressed_connect"))

    stored_v1 =
      normalized
      |> Map.put("schema", "comma.slack-triage-event-receipt.v1")
      |> update_in(["triage_event"], fn event ->
        Map.drop(event, ~w(actor_kind event_type addressing_kind trigger_kind))
      end)

    "s3://" <> key = normalized["receipt_ref"]
    assert {:ok, _result} = S3.put(key, Jason.encode!(stored_v1), if_none_match: "*")

    assert {:error, :receipt_unavailable} =
             normalized
             |> put_in(["triage_event", "text"], "different bytes?")
             |> then(&TriageTransactions.admit_receipt(admission("v1-handoff", &1, :ambient)))

    assert {:ok, %{status: :accepted, lane: :ambient}} =
             TriageTransactions.admit_receipt(admission("v1-handoff", normalized, :ambient))
  end

  test "recipient aliases admit one physical source once per addressed connect" do
    namespace = "recipient-fanout"
    first = admission_receipt("fanout-a", "connect-a")

    second =
      admission_receipt("fanout-b", "connect-b",
        message_ts: source_ts(first),
        generation: "01JQTRIAGEGENERATION000002"
      )

    persist_receipt!(first)
    persist_receipt!(second)

    assert {:ok, %{status: :accepted, lane: :directed, durable: first_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, first, :directed))

    assert {:ok, %{status: :accepted, lane: :directed, durable: second_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, second, :directed))

    assert first_bucket["open_receipts"] == [first]
    assert second_bucket["open_receipts"] == [second]

    namespace_key = TriageKeys.namespace_key(namespace)
    physical_source_key = Crypto.hex(physical_source(first))

    assert %{rows: rows} =
             Repo.query!(
               "SELECT recipient_key FROM triage_recipient_aliases WHERE namespace_key = $1 AND physical_source_key = $2 ORDER BY recipient_key",
               [namespace_key, physical_source_key]
             )

    assert rows ==
             Enum.sort([
               [Crypto.hex("connect-a")],
               [Crypto.hex("connect-b")]
             ])
  end

  test "ambient owner that is also addressed converges to one membership lane both" do
    namespace = "owner-addressed"
    receipt = admission_receipt("owner-both", "connect-a")
    persist_receipt!(receipt)

    assert {:ok, %{status: :accepted, lane: :both, durable: durable}} =
             TriageTransactions.admit_receipt(admission(namespace, receipt, :both))

    assert durable["open_receipts"] == [receipt]

    namespace_key = TriageKeys.namespace_key(namespace)
    physical_source_key = Crypto.hex(physical_source(receipt))
    recipient_key = Crypto.hex("connect-a")

    assert %{rows: [["both", ^recipient_key]]} =
             Repo.query!(
               "SELECT lane, recipient_key FROM triage_bucket_memberships WHERE namespace_key = $1 AND physical_source_key = $2",
               [namespace_key, physical_source_key]
             )

    assert %{rows: [[ambient_body]]} =
             Repo.query!(
               "SELECT body FROM triage_ambient_aliases WHERE namespace_key = $1 AND physical_source_key = $2",
               [namespace_key, physical_source_key]
             )

    assert ambient_body["recipient_key"] == recipient_key

    assert {:ok, %{status: :duplicate, lane: :both, durable: ^durable}} =
             TriageTransactions.admit_receipt(admission(namespace, receipt, :both))

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM triage_bucket_memberships")
  end

  test "a later directed copy upgrades one membership and returns its fast-path bucket" do
    namespace = "owner-addressed-late"

    ambient =
      admission_receipt("owner-ambient-first", "connect-a")
      |> put_in(["triage_event", "actor_kind"], "human")
      |> put_in(["triage_event", "addressing_kind"], "ambient")
      |> put_in(["triage_event", "trigger_kind"], "none")
      |> put_in(["triage_event", "fast_path"], false)
      |> update_in(["triage_event"], &Map.delete(&1, "addressed_connect"))

    directed =
      admission_receipt("owner-directed-second", "connect-a", message_ts: source_ts(ambient))

    persist_receipt!(ambient)
    persist_receipt!(directed)

    assert {:ok, %{status: :accepted, lane: :ambient, durable: first_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, ambient, :ambient))

    refute first_bucket["open_fast_path"]

    assert {:ok, %{status: :duplicate, lane: :both, durable: upgraded_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, directed, :directed))

    assert upgraded_bucket["open_fast_path"]

    assert Enum.map(upgraded_bucket["open_receipts"], & &1["receipt_ref"]) |> Enum.sort() ==
             Enum.sort([ambient["receipt_ref"], directed["receipt_ref"]])

    namespace_key = TriageKeys.namespace_key(namespace)
    physical_source_key = Crypto.hex(physical_source(ambient))
    recipient_key = Crypto.hex("connect-a")

    assert %{rows: [["both"]]} =
             Repo.query!(
               "SELECT lane FROM triage_bucket_memberships WHERE namespace_key = $1 AND physical_source_key = $2 AND recipient_key = $3",
               [namespace_key, physical_source_key, recipient_key]
             )

    ambient_receipt_ref = ambient["receipt_ref"]

    assert %{rows: [[^ambient_receipt_ref]]} =
             Repo.query!(
               "SELECT canonical_receipt_ref FROM triage_recipient_aliases WHERE namespace_key = $1 AND physical_source_key = $2 AND recipient_key = $3",
               [namespace_key, physical_source_key, recipient_key]
             )
  end

  test "a rotated ambient copy stays receipt-only behind the stable recipient alias" do
    namespace = "rotated-recipient-copy"

    first =
      admission_receipt("ambient-before-rotation", "connect-a")
      |> put_in(["triage_event", "actor_kind"], "human")
      |> put_in(["triage_event", "addressing_kind"], "ambient")
      |> put_in(["triage_event", "trigger_kind"], "none")
      |> put_in(["triage_event", "fast_path"], false)
      |> update_in(["triage_event"], &Map.delete(&1, "addressed_connect"))

    rotated =
      admission_receipt("ambient-after-rotation", "connect-a",
        generation: "01JQTRIAGEGENERATION000002",
        message_ts: source_ts(first)
      )
      |> put_in(["triage_event", "actor_kind"], "human")
      |> put_in(["triage_event", "addressing_kind"], "ambient")
      |> put_in(["triage_event", "trigger_kind"], "none")
      |> put_in(["triage_event", "fast_path"], false)
      |> update_in(["triage_event"], &Map.delete(&1, "addressed_connect"))

    persist_receipt!(first)
    persist_receipt!(rotated)

    assert {:ok, %{status: :accepted, lane: :ambient, durable: first_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, first, :ambient))

    assert {:ok, %{status: :duplicate, lane: :ambient, durable: ^first_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, rotated, :ambient))

    refute Enum.any?(first_bucket["open_receipts"], fn receipt ->
             receipt["receipt_ref"] == rotated["receipt_ref"]
           end)

    assert %{rows: [[2, 1, 1]]} =
             Repo.query!(
               "SELECT (SELECT count(*) FROM triage_receipt_projections), (SELECT count(*) FROM triage_recipient_aliases), (SELECT count(*) FROM triage_bucket_memberships)"
             )
  end

  test "a foreign ambient winner cannot suppress an explicitly addressed recipient" do
    namespace = "ambient-plus-directed"
    ambient = admission_receipt("ambient-winner", "connect-a")
    directed = admission_receipt("directed-peer", "connect-b", message_ts: source_ts(ambient))
    persist_receipt!(ambient)
    persist_receipt!(directed)

    assert {:ok, %{status: :accepted, lane: :ambient}} =
             TriageTransactions.admit_receipt(admission(namespace, ambient, :ambient))

    assert {:ok, %{status: :accepted, lane: :directed}} =
             TriageTransactions.admit_receipt(admission(namespace, directed, :both))

    namespace_key = TriageKeys.namespace_key(namespace)
    physical_source_key = Crypto.hex(physical_source(ambient))

    assert %{rows: rows} =
             Repo.query!(
               "SELECT recipient_key, lane FROM triage_bucket_memberships WHERE namespace_key = $1 AND physical_source_key = $2 ORDER BY recipient_key",
               [namespace_key, physical_source_key]
             )

    assert rows ==
             Enum.sort([
               [Crypto.hex("connect-a"), "ambient"],
               [Crypto.hex("connect-b"), "directed"]
             ])
  end

  test "intent settlement is a separate append-only exact record" do
    settlement = %{
      "schema" => "comma.slack-intent-settlement.v1",
      "connect_id" => "connect-a",
      "event_id" => "event-without-principal",
      "reason" => "missing_actor_id",
      "admission_ref" => "s3://ctl/im/receipts/slack/connect-a/event.json"
    }

    assert {:ok, :created} = TriageTransactions.record_intent_settlement(settlement)
    assert {:ok, :duplicate} = TriageTransactions.record_intent_settlement(settlement)

    assert {:error, :conflict} =
             TriageTransactions.record_intent_settlement(%{
               settlement
               | "reason" => "unsupported_message_shape"
             })

    assert_raise Postgrex.Error, ~r/native Triage evidence is append-only/, fn ->
      Repo.query!("DELETE FROM triage_intent_settlements")
    end
  end

  defp ensure_body_size_migration! do
    case Ecto.Migrator.up(
           Repo,
           @body_size_migration_version,
           SalixStore.Repo.Migrations.AddTriageRecordBodyBytes,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp assert_body_size_metadata!(namespace_key, source_table, expected_count)
       when source_table in ["triage_runs", "triage_replays"] do
    assert %{rows: [[^expected_count, 0]]} =
             Repo.query!(
               """
               SELECT
                 count(*),
                 count(*) FILTER (
                   WHERE sizes.revision IS DISTINCT FROM records.revision
                      OR sizes.body_bytes IS DISTINCT FROM octet_length(records.body::text)
                 )
               FROM #{source_table} AS records
               LEFT JOIN triage_record_body_sizes AS sizes
                 ON sizes.source_table = $2
                AND sizes.record_key = records.record_key
               WHERE records.namespace_key = $1
               """,
               [namespace_key, source_table]
             )
  end

  defp migration_source_hashes(namespace_key) do
    for source_table <- ["triage_runs", "triage_replays"], into: %{} do
      assert %{rows: [[hash]]} =
               Repo.query!(
                 """
                 SELECT md5(
                   coalesce(
                     string_agg(
                       record_key || ':' || revision::text || ':' || body::text,
                       '|' ORDER BY record_key
                     ),
                     ''
                   )
                 )
                 FROM #{source_table}
                 WHERE namespace_key = $1
                 """,
                 [namespace_key]
               )

      {source_table, hash}
    end
  end

  defp authoritative_commit(namespace, run_id) do
    fence_key = TriageKeys.ctl_im_triage_bucket_seal(namespace, "scope-a", "generation-a")
    run_key = TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)
    replay_key = TriageKeys.ctl_im_triage_replay(namespace, run_id)

    %{
      fence_key: fence_key,
      expected_etag: "pg:1",
      fence: %{
        "schema" => "comma.triage-bucket-fence.v1",
        "run_id" => run_id,
        "terminal" => %{"status" => "replied"}
      },
      run_key: run_key,
      run: run(run_id),
      replay_key: replay_key,
      replay: %{
        "schema" => "comma.triage-replay.v1",
        "run_id" => run_id,
        "ledger_ref" => "triage-record://" <> run_key,
        "run_sha256" => String.duplicate("a", 64)
      },
      obligation: %{
        "schema" => "comma.triage-projection-obligation.v1",
        "namespace" => namespace,
        "fence_key" => fence_key,
        "run_id" => run_id,
        "correlations" => [],
        "activity_required" => false,
        "time_required" => true
      },
      product_obligation: nil
    }
  end

  defp product_obligation(commit, namespace) do
    %{
      "schema" => "comma.triage-product-obligation.v1",
      "obligation_id" => "triage-product-" <> String.duplicate("a", 64),
      "namespace" => namespace,
      "fence_key" => commit.fence_key,
      "run_id" => commit.run["run_id"],
      "target" => %{
        "workspace_id" => "T-product",
        "channel_id" => "C-product",
        "thread_ts" => "1787900000.000001"
      },
      "product_identity" => %{"agent_id" => "agent-product"},
      "communication" => %{"action" => "silence", "reason" => "no_reply_needed"},
      "context_candidates" => [],
      "delegations" => [],
      "target_cutoff" => %{"latest_message_ts" => "1787900000.000001"},
      "settled_at" => 1_787_900_000_001
    }
  end

  defp admission(namespace, receipt, lane) do
    %{
      namespace: namespace,
      physical_source: physical_source(receipt),
      recipient: receipt["connect_id"],
      bucket_identity:
        Enum.join(
          [
            receipt["connect_generation"],
            get_in(receipt, ["triage_event", "bucket", "workspace_id"]),
            get_in(receipt, ["triage_event", "bucket", "channel_id"]),
            get_in(receipt, ["triage_event", "bucket", "thread_ts"])
          ],
          ":"
        ),
      lane: lane,
      receipt: receipt
    }
  end

  defp persist_receipt!(receipt) do
    "s3://" <> key = receipt["receipt_ref"]
    assert {:ok, _result} = S3.put(key, Jason.encode!(receipt), if_none_match: "*")
  end

  defp admission_receipt(event_id, connect_id, opts \\ []) do
    generation = Keyword.get(opts, :generation, "01JQTRIAGEGENERATION000001")
    message_ts = Keyword.get(opts, :message_ts, "1787019000.000001")
    root_ts = "1787019000.000000"
    key = "ctl/im/receipts/slack/#{connect_id}/#{event_id}.json"

    %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "connect_id" => connect_id,
      "event_id" => event_id,
      "connect_generation" => generation,
      "created_at" => 100,
      "receipt_ref" => "s3://" <> key,
      "source_message_ref" =>
        Enum.join([generation, "T_WORKSPACE", "C_CHANNEL", root_ts, message_ts], ":"),
      "triage_event" => %{
        "event_id" => event_id,
        "connect_generation" => generation,
        "message_ts" => message_ts,
        "actor_id" => "U_ACTOR",
        "actor_kind" => "agent",
        "text" => "review this",
        "event_type" => "message",
        "addressing_kind" => "directed",
        "trigger_kind" => "mention",
        "fast_path" => true,
        "addressed_connect" => connect_id,
        "bucket" => %{
          "workspace_id" => "T_WORKSPACE",
          "channel_id" => "C_CHANNEL",
          "thread_ts" => root_ts
        },
        "endpoint_provenance" => %{},
        "source_mode" => "callback"
      }
    }
  end

  defp physical_source(receipt) do
    event = receipt["triage_event"]
    bucket = event["bucket"]

    Enum.join(
      [bucket["workspace_id"], bucket["channel_id"], bucket["thread_ts"], event["message_ts"]],
      ":"
    )
  end

  defp source_ts(receipt), do: get_in(receipt, ["triage_event", "message_ts"])

  defp create_bucket(namespace) do
    key = TriageKeys.ctl_im_triage_bucket(namespace, "scope-a")

    assert {:ok, _result} =
             TriageRecords.put(key, Jason.encode!(bucket("scope-a", "generation-a")),
               if_none_match: "*"
             )
  end

  defp bucket(scope, generation) do
    %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope,
      "open_generation" => generation,
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => []
    }
  end

  defp run(run_id) do
    %{
      "schema" => "comma.triage-run.v1",
      "run_id" => run_id,
      "authoritative" => true,
      "created_at" => 1,
      "status" => "replied"
    }
  end

  defp namespace_key(key) do
    [_, namespace_key, _path] =
      Regex.run(~r/\Atriage\/engine-v2\/([0-9a-f]{64})\/(.+)\z/, key)

    namespace_key
  end
end
