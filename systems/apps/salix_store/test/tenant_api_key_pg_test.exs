defmodule SalixStore.TenantApiKeyPgTest do
  # Shares the node-global Fake bucket and control tables; keep serial.
  use ExUnit.Case, async: false

  alias SalixStore.{Keys, Repo, S3, TenantApiKeyCutover, TenantApiKeys}

  setup do
    %{rows: cutover_markers} =
      Repo.query!("SELECT name, completed_at, evidence FROM salix_cutover_markers")

    S3.Fake.reset()
    Repo.query!("TRUNCATE tenant_api_keys, salix_cutover_markers")

    # These tests run against the un-migrated state (marker truncated above).
    # Restore the exact shared baseline on exit so other suites in this VM do
    # not inherit a partially restored cutover table.
    on_exit(fn ->
      S3.Fake.reset()
      Repo.query!("TRUNCATE salix_cutover_markers")

      Enum.each(cutover_markers, fn [name, completed_at, evidence] ->
        Repo.query!(
          """
          INSERT INTO salix_cutover_markers (name, completed_at, evidence)
          VALUES ($1, $2, $3)
          """,
          [name, completed_at, evidence]
        )
      end)
    end)

    :ok
  end

  defp record(tenant_id, hash, attrs \\ %{}) do
    Map.merge(
      %{
        "key_hash" => hash,
        "tenant_id" => tenant_id,
        "name" => "test key",
        "created_at" => 1_753_300_000
      },
      attrs
    )
  end

  defp seed_s3(rec) do
    key = Keys.ctl_api_key(rec["tenant_id"], rec["key_hash"])
    {:ok, _} = S3.put(key, Jason.encode!(rec), [])
    key
  end

  describe "TenantApiKeys" do
    test "insert/get/list round-trip with field parity" do
      rec = record("ten_a", "hash_a1")
      assert {:ok, landed} = TenantApiKeys.insert(rec)
      assert landed == rec

      assert {:ok, ^rec} = TenantApiKeys.get_by_hash("hash_a1")

      {:ok, _} =
        TenantApiKeys.insert(record("ten_a", "hash_a2", %{"created_at" => 1_753_300_100}))

      assert ["hash_a2", "hash_a1"] =
               TenantApiKeys.list_by_tenant("ten_a") |> Enum.map(& &1["key_hash"])
    end

    test "delete is predicated on both tenant and hash" do
      {:ok, _} = TenantApiKeys.insert(record("ten_b", "hash_b1"))

      # Another tenant's delete request must not remove the row.
      assert :ok = TenantApiKeys.delete("ten_intruder", "hash_b1")
      assert {:ok, _} = TenantApiKeys.get_by_hash("hash_b1")

      assert :ok = TenantApiKeys.delete("ten_b", "hash_b1")
      assert {:error, :not_found} = TenantApiKeys.get_by_hash("hash_b1")

      # Idempotent on absent rows.
      assert :ok = TenantApiKeys.delete("ten_b", "hash_b1")
    end

    test "import_record accepts identical re-imports and rejects divergent rows" do
      rec = record("ten_c", "hash_c1")
      assert :ok = TenantApiKeys.import_record(rec)
      assert :ok = TenantApiKeys.import_record(rec)

      assert {:error, {:divergent_row, "hash_c1"}} =
               TenantApiKeys.import_record(record("ten_other", "hash_c1"))
    end
  end

  describe "cutover marker (readiness authority; request path never mints it)" do
    test "an absent marker reads as not-present even with an empty S3 prefix" do
      # marker_present?/0 is the readiness signal: absent (or unreadable) keeps
      # the pod out of service. An empty S3 LIST must never mint the marker.
      refute TenantApiKeyCutover.marker_present?()
    end

    test "legacy S3 records with no marker stay not-present" do
      seed_s3(record("ten_d", "hash_d1"))
      refute TenantApiKeyCutover.marker_present?()
    end

    test "the marker written by the cutover marks the node ready" do
      assert :ok = TenantApiKeyCutover.run()
      assert TenantApiKeyCutover.marker_present?()
    end

    test "marker_present? flips false -> true when the marker appears (readiness transition)" do
      refute TenantApiKeyCutover.marker_present?()

      Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('tenant_api_keys_v1', now(), '{"mode":"test"}'::jsonb)
      ON CONFLICT (name) DO NOTHING
      """)

      assert TenantApiKeyCutover.marker_present?()
    end
  end

  describe "importable_count (pre-cutover preflight)" do
    test "reports the S3 corpus size without requiring PG equality" do
      seed_s3(record("ten_p", "hash_p1"))
      seed_s3(record("ten_q", "hash_q1", %{"created_at" => 1_753_300_200}))

      # PG is empty (pre-cutover); the preflight must still succeed and count.
      assert {:ok, 2} = TenantApiKeyCutover.importable_count()
    end

    test "fails closed on a record whose body does not round-trip to its key" do
      key = Keys.ctl_api_key("ten_actual", "hash_m1")
      {:ok, _} = S3.put(key, Jason.encode!(record("ten_lie", "hash_m1")), [])

      assert {:error, {:enumerate_failed, ^key, :record_address_mismatch}} =
               TenantApiKeyCutover.importable_count()
    end

    test "fails closed on a non-integer created_at (would crash from_record arithmetic)" do
      key = Keys.ctl_api_key("ten_bad", "hash_str")

      {:ok, _} =
        S3.put(
          key,
          Jason.encode!(record("ten_bad", "hash_str", %{"created_at" => "2026-07-28T00:00:00Z"})),
          []
        )

      assert {:error, {:enumerate_failed, ^key, :invalid_record}} =
               TenantApiKeyCutover.importable_count()
    end

    test "fails closed on a negative created_at (not a valid creation timestamp)" do
      key = Keys.ctl_api_key("ten_neg", "hash_neg")

      {:ok, _} =
        S3.put(key, Jason.encode!(record("ten_neg", "hash_neg", %{"created_at" => -1})), [])

      assert {:error, {:enumerate_failed, ^key, :invalid_record}} =
               TenantApiKeyCutover.importable_count()
    end

    test "fails closed on an out-of-range created_at (would raise in from_record)" do
      key = Keys.ctl_api_key("ten_or", "hash_or")

      {:ok, _} =
        S3.put(
          key,
          Jason.encode!(record("ten_or", "hash_or", %{"created_at" => 253_402_300_800})),
          []
        )

      assert {:error, {:enumerate_failed, ^key, :invalid_record}} =
               TenantApiKeyCutover.importable_count()
    end

    test "fails closed on a non-map (top-level array) body, not a raise" do
      key = Keys.ctl_api_key("ten_arr", "hash_arr")
      {:ok, _} = S3.put(key, Jason.encode!([1, 2, 3]), [])

      assert {:error, {:enumerate_failed, ^key, :invalid_record}} =
               TenantApiKeyCutover.importable_count()
    end

    test "fails closed on a non-string name field" do
      key = Keys.ctl_api_key("ten_nm", "hash_nm")
      {:ok, _} = S3.put(key, Jason.encode!(record("ten_nm", "hash_nm", %{"name" => 42})), [])

      assert {:error, {:enumerate_failed, ^key, :invalid_record}} =
               TenantApiKeyCutover.importable_count()
    end
  end

  describe "cutover run fails closed with no partial import" do
    test "an out-of-range created_at sorting after a valid record leaves zero PG rows" do
      # ten_a sorts before ten_z; the valid record is enumerated first. The whole
      # enumeration must abort with no import (no partial write) and no marker.
      seed_s3(record("ten_a", "hash_a"))
      seed_s3(record("ten_z", "hash_z", %{"created_at" => 253_402_300_800}))

      assert {:error, {:enumerate_failed, _key, :invalid_record}} = TenantApiKeyCutover.run()
      refute TenantApiKeyCutover.marker_present?()
      assert {:error, :not_found} = TenantApiKeys.get_by_hash("hash_a")
    end
  end

  describe "cutover run" do
    test "imports the corpus, verifies equality, persists the marker, and re-runs" do
      rec1 = record("ten_e", "hash_e1")
      rec2 = record("ten_f", "hash_f1", %{"created_at" => 1_753_300_500})
      seed_s3(rec1)
      seed_s3(rec2)

      assert :ok = TenantApiKeyCutover.run()
      assert TenantApiKeyCutover.marker_present?()
      assert {:ok, ^rec1} = TenantApiKeys.get_by_hash("hash_e1")
      assert {:ok, ^rec2} = TenantApiKeys.get_by_hash("hash_f1")

      # Idempotent: the exact step retries cleanly.
      assert :ok = TenantApiKeyCutover.run()
    end

    test "a re-run after a PG-only delete does not resurrect the key (P1-1: terminal fence)" do
      # Exactly the reviewer's reproduction: cut over a legacy key, delete it
      # through the new PG path, then re-run the advertised-idempotent cutover.
      # The marker is terminal — re-run reads marker_status = :present and is a
      # no-op, never re-importing the still-present S3 object over the delete.
      seed_s3(record("ten_r", "hash_r1"))
      assert :ok = TenantApiKeyCutover.run()
      assert {:ok, _} = TenantApiKeys.get_by_hash("hash_r1")

      assert :ok = TenantApiKeys.delete("ten_r", "hash_r1")
      assert {:error, :not_found} = TenantApiKeys.get_by_hash("hash_r1")

      # S3 object is deliberately still there (PR-B clears it later).
      assert {:ok, _} = S3.get(Keys.ctl_api_key("ten_r", "hash_r1"))

      # Re-run the "idempotent" cutover: no-op, not a resurrection.
      assert :ok = TenantApiKeyCutover.run()
      assert {:error, :not_found} = TenantApiKeys.get_by_hash("hash_r1")
    end

    test "an unreadable marker aborts the run without importing (P1-1: no resurrection on DB fault)" do
      # The reviewer's transient-DB-fault variant: if the marker read fails,
      # run/0 must ABORT, never fall through to re-import the retained S3 corpus
      # (the old `certified?/0` folded the fault into `false` and re-imported).
      seed_s3(record("ten_x", "hash_x1"))

      # Make `SELECT ... FROM salix_cutover_markers` fault by renaming the table
      # away; RENAME preserves the exact schema for a clean restore.
      Repo.query!("ALTER TABLE salix_cutover_markers RENAME TO salix_cutover_markers_tmp")

      on_exit(fn ->
        Repo.query!("ALTER TABLE salix_cutover_markers_tmp RENAME TO salix_cutover_markers")
      end)

      assert {:error, {:marker_unreadable, _}} = TenantApiKeyCutover.run()
      # The corpus was NOT imported: the abort happened before any write.
      assert {:error, :not_found} = TenantApiKeys.get_by_hash("hash_x1")
    end

    test "a divergent pre-existing row aborts before the marker" do
      seed_s3(record("ten_g", "hash_g1"))
      {:ok, _} = TenantApiKeys.insert(record("ten_hijack", "hash_g1"))

      assert {:error, {:import_failed, {:divergent_row, "hash_g1"}}} = TenantApiKeyCutover.run()
      refute TenantApiKeyCutover.marker_present?()
    end

    test "a PG-only row fails the equality gate" do
      {:ok, _} = TenantApiKeys.insert(record("ten_h", "hash_h1"))

      assert {:error, {:mismatch, %{missing_in_s3: ["hash_h1"]}}} = TenantApiKeyCutover.run()
      refute TenantApiKeyCutover.marker_present?()
    end

    test "enumeration is fail-closed on LIST and GET faults" do
      key = seed_s3(record("ten_i", "hash_i1"))

      S3.Fake.set_fault({:fail, 503, :list, :any})
      assert {:error, _} = TenantApiKeyCutover.run()

      S3.Fake.set_fault({:fail, 503, :get, key})
      assert {:error, {:enumerate_failed, ^key, _}} = TenantApiKeyCutover.run()
      refute TenantApiKeyCutover.marker_present?()
    end

    test "a record whose body does not round-trip to its key aborts the cutover" do
      lying = record("ten_j", "hash_j1")
      key = Keys.ctl_api_key("ten_actual", "hash_j1")
      {:ok, _} = S3.put(key, Jason.encode!(lying), [])

      assert {:error, {:enumerate_failed, ^key, :record_address_mismatch}} =
               TenantApiKeyCutover.run()
    end
  end
end
