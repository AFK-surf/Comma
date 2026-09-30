defmodule SalixStore.TenantConfigsCutoverTest do
  # Shares the node-global Fake bucket and control tables; keep serial.
  use ExUnit.Case, async: false

  alias SalixStore.{Keys, Repo, S3, TenantConfigs, TenantConfigsCutover}

  setup do
    S3.Fake.reset()
    Repo.query!("TRUNCATE tenant_configs")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'tenant_configs_v1'")

    on_exit(fn ->
      S3.Fake.reset()

      Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('tenant_configs_v1', now(), '{"mode":"test-baseline"}'::jsonb)
      ON CONFLICT (name) DO NOTHING
      """)
    end)

    :ok
  end

  defp seed(tenant_id, name, value) do
    rec = %{
      "tenant_id" => tenant_id,
      "name" => name,
      "value" => value,
      "updated_at" => 1_753_300_000
    }

    {:ok, _} = S3.put(Keys.ctl_tenant_config(tenant_id, name), Jason.encode!(rec), [])
    rec
  end

  test "imports, verifies equality, persists the marker, and re-runs (idempotent)" do
    # Rich JSON payloads: the equality gate compares decoded maps, so a bool,
    # float, and nested map must round-trip through jsonb unchanged.
    seed("ten_a", "trajectory_eval", %{
      "judge_enabled" => true,
      "sample_rate" => 0.25,
      "nested" => %{"provider" => "anthropic"}
    })

    seed("ten_a", "conversation_links", %{"conversation_url_template" => "https://x/{id}"})
    seed("ten_b", "conversation_links", %{"conversation_url_template" => "https://y/{id}"})

    assert :ok = TenantConfigsCutover.run()
    assert TenantConfigsCutover.marker_present?()

    assert {:ok, %{"value" => %{"judge_enabled" => true, "sample_rate" => 0.25}}} =
             TenantConfigs.get("ten_a", "trajectory_eval")

    assert {:ok, %{"value" => %{"conversation_url_template" => "https://y/{id}"}}} =
             TenantConfigs.get("ten_b", "conversation_links")

    # Idempotent: the exact step retries cleanly.
    assert :ok = TenantConfigsCutover.run()
  end

  test "an empty control store cuts over to a trivially-equal marker" do
    assert :ok = TenantConfigsCutover.run()
    assert TenantConfigsCutover.marker_present?()
    assert {:ok, %{"tenant_configs" => 0}} = TenantConfigsCutover.importable_count()
  end

  test "a re-run after a PG-only delete does not resurrect the record (terminal fence)" do
    seed("ten_r", "conversation_links", %{"conversation_url_template" => "https://r/{id}"})
    assert :ok = TenantConfigsCutover.run()
    assert {:ok, _} = TenantConfigs.get("ten_r", "conversation_links")

    assert :ok = TenantConfigs.delete("ten_r", "conversation_links")
    assert {:error, :not_found} = TenantConfigs.get("ten_r", "conversation_links")
    # S3 object is deliberately still present (PR-B clears it later).
    assert {:ok, _} = S3.get(Keys.ctl_tenant_config("ten_r", "conversation_links"))

    assert :ok = TenantConfigsCutover.run()
    assert {:error, :not_found} = TenantConfigs.get("ten_r", "conversation_links")
  end

  test "an unreadable marker aborts the run without importing" do
    seed("ten_x", "conversation_links", %{"conversation_url_template" => "https://x/{id}"})

    Repo.query!("ALTER TABLE salix_cutover_markers RENAME TO salix_cutover_markers_tmp")

    on_exit(fn ->
      Repo.query!("ALTER TABLE salix_cutover_markers_tmp RENAME TO salix_cutover_markers")
    end)

    assert {:error, {:marker_unreadable, _}} = TenantConfigsCutover.run()
    assert {:error, :not_found} = TenantConfigs.get("ten_x", "conversation_links")
  end

  test "a body whose tenant_id does not round-trip to its key aborts the cutover" do
    lying = %{
      "tenant_id" => "ten_other",
      "name" => "conversation_links",
      "value" => %{"conversation_url_template" => "https://x/{id}"},
      "updated_at" => 1
    }

    key = Keys.ctl_tenant_config("ten_actual", "conversation_links")
    {:ok, _} = S3.put(key, Jason.encode!(lying), [])

    assert {:error, {:enumerate_failed, ^key, :record_address_mismatch}} =
             TenantConfigsCutover.run()
  end

  test "a non-map value aborts the cutover fail-closed" do
    key = Keys.ctl_tenant_config("ten_scalar", "weird")

    body = %{
      "tenant_id" => "ten_scalar",
      "name" => "weird",
      "value" => "not-a-map",
      "updated_at" => 1
    }

    {:ok, _} = S3.put(key, Jason.encode!(body), [])

    assert {:error, {:enumerate_failed, ^key, :invalid_record}} = TenantConfigsCutover.run()
  end

  test "a non-integer updated_at fails the audit preflight closed (no crash)" do
    key = Keys.ctl_tenant_config("ten_bad", "conversation_links")

    body = %{
      "tenant_id" => "ten_bad",
      "name" => "conversation_links",
      "value" => %{"conversation_url_template" => "https://b/{id}"},
      # Legacy/malformed shape: an ISO-8601 string where epoch seconds are
      # expected. from_record/1 would do arithmetic on this and raise.
      "updated_at" => "2026-07-28T00:00:00Z"
    }

    {:ok, _} = S3.put(key, Jason.encode!(body), [])

    # importable_count/0 backs the audit preflight: it must fail closed, not
    # report the record as importable and let run/0 crash later.
    assert {:error, {:enumerate_failed, ^key, :invalid_record}} =
             TenantConfigsCutover.importable_count()
  end

  test "a malformed updated_at aborts run/0 before any PG write, even when it sorts after a valid record" do
    # ten_a sorts before ten_z, so the valid record is enumerated first; the
    # whole enumeration must still abort with zero PG writes (no partial import).
    seed("ten_a", "conversation_links", %{"conversation_url_template" => "https://a/{id}"})

    bad_key = Keys.ctl_tenant_config("ten_z", "conversation_links")

    {:ok, _} =
      S3.put(
        bad_key,
        Jason.encode!(%{
          "tenant_id" => "ten_z",
          "name" => "conversation_links",
          "value" => %{"conversation_url_template" => "https://z/{id}"},
          "updated_at" => "2026-07-28T00:00:00Z"
        }),
        []
      )

    assert {:error, {:enumerate_failed, ^bad_key, :invalid_record}} = TenantConfigsCutover.run()
    refute TenantConfigsCutover.marker_present?()
    # No partial import: the valid record must not have landed.
    assert {:error, :not_found} = TenantConfigs.get("ten_a", "conversation_links")
  end

  test "enumeration is fail-closed on a GET fault" do
    key = Keys.ctl_tenant_config("ten_i", "conversation_links")
    seed("ten_i", "conversation_links", %{"conversation_url_template" => "https://i/{id}"})

    S3.Fake.set_fault({:fail, 503, :get, key})
    assert {:error, {:enumerate_failed, ^key, _}} = TenantConfigsCutover.run()
    refute TenantConfigsCutover.marker_present?()
  end

  test "a PG-only row fails the equality gate" do
    :ok =
      TenantConfigs.import_record(%{
        "tenant_id" => "ten_pg_only",
        "name" => "conversation_links",
        "value" => %{"conversation_url_template" => "https://pg/{id}"},
        "updated_at" => 1_753_300_000
      })

    # S3 is empty, PG has one row -> mismatch.
    assert {:error, {:mismatch, :tenant_configs}} = TenantConfigsCutover.run()
    refute TenantConfigsCutover.marker_present?()
  end

  test "an out-of-range (ms-magnitude) updated_at fails closed with no partial import" do
    # ten_a sorts before ten_z; the valid record is enumerated first. The
    # out-of-range value (253_402_300_800 = one second past the DateTime range)
    # would raise ArgumentError in from_record; enumeration must reject it so
    # import never runs and ten_a does not land.
    seed("ten_a", "conversation_links", %{"conversation_url_template" => "https://a/{id}"})

    bad_key = Keys.ctl_tenant_config("ten_z", "conversation_links")

    {:ok, _} =
      S3.put(
        bad_key,
        Jason.encode!(%{
          "tenant_id" => "ten_z",
          "name" => "conversation_links",
          "value" => %{"conversation_url_template" => "https://z/{id}"},
          "updated_at" => 253_402_300_800
        }),
        []
      )

    assert {:error, {:enumerate_failed, ^bad_key, :invalid_record}} =
             TenantConfigsCutover.importable_count()

    assert {:error, {:enumerate_failed, ^bad_key, :invalid_record}} = TenantConfigsCutover.run()
    refute TenantConfigsCutover.marker_present?()
    assert {:error, :not_found} = TenantConfigs.get("ten_a", "conversation_links")
  end

  test "a non-map (top-level array) body fails closed as enumerate_failed, not a raise" do
    key = Keys.ctl_tenant_config("ten_arr", "conversation_links")
    {:ok, _} = S3.put(key, Jason.encode!([1, 2, 3]), [])

    assert {:error, {:enumerate_failed, ^key, :invalid_record}} =
             TenantConfigsCutover.importable_count()

    assert {:error, {:enumerate_failed, ^key, :invalid_record}} = TenantConfigsCutover.run()
    refute TenantConfigsCutover.marker_present?()
  end
end
