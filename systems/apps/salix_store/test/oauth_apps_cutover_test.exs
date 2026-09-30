defmodule SalixStore.OAuthAppsCutoverTest do
  # Shares the node-global Fake bucket and control tables; keep serial.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SalixStore.{Keys, OAuthAppsCutover, OAuthProviderApps, Repo, S3}

  setup do
    S3.Fake.reset()
    Repo.query!("TRUNCATE oauth_provider_apps")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'oauth_apps_v1'")

    on_exit(fn ->
      S3.Fake.reset()

      Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('oauth_apps_v1', now(), '{"mode":"test-baseline"}'::jsonb)
      ON CONFLICT (name) DO NOTHING
      """)
    end)

    :ok
  end

  defp seed_provider_app(tenant_id, provider, attrs \\ %{}) do
    rec =
      Map.merge(
        %{
          "tenant_id" => tenant_id,
          "provider" => provider,
          "client_id" => "cid-#{provider}",
          "client_secret" => "secret-#{provider}",
          "updated_at" => 1_753_300_000
        },
        attrs
      )

    {:ok, _} = S3.put(Keys.ctl_oauth_provider_app(tenant_id, provider), Jason.encode!(rec), [])
    rec
  end

  defp seed_default_app(provider) do
    rec = %{
      "provider" => provider,
      "client_id" => "def-cid-#{provider}",
      "client_secret" => "def-secret-#{provider}",
      "updated_at" => 1_753_300_050
    }

    {:ok, _} = S3.put(Keys.ctl_oauth_default_app(provider), Jason.encode!(rec), [])
    rec
  end

  test "imports provider apps + defaults, verifies equality, persists the marker, and re-runs" do
    seed_provider_app("ten_a", "github")
    seed_default_app("google")

    assert :ok = OAuthAppsCutover.run()
    assert OAuthAppsCutover.marker_present?()

    assert {:ok, %{"client_id" => "cid-github"}} = OAuthProviderApps.get("ten_a", "github")

    assert {:ok, %{"client_id" => "def-cid-google"}} =
             OAuthProviderApps.get(OAuthProviderApps.default_scope(), "google")

    # Idempotent: the exact step retries cleanly.
    assert :ok = OAuthAppsCutover.run()
  end

  test "an empty control store cuts over to a trivially-equal marker" do
    assert :ok = OAuthAppsCutover.run()
    assert OAuthAppsCutover.marker_present?()
    assert {:ok, %{"provider_apps" => 0}} = OAuthAppsCutover.importable_count()
  end

  test "a re-run after a PG-only delete does not resurrect the record (terminal fence)" do
    seed_provider_app("ten_r", "github")
    assert :ok = OAuthAppsCutover.run()
    assert {:ok, _} = OAuthProviderApps.get("ten_r", "github")

    assert :ok = OAuthProviderApps.delete("ten_r", "github")
    assert {:error, :not_found} = OAuthProviderApps.get("ten_r", "github")
    # S3 object is deliberately still present (PR-B clears it later).
    assert {:ok, _} = S3.get(Keys.ctl_oauth_provider_app("ten_r", "github"))

    assert :ok = OAuthAppsCutover.run()
    assert {:error, :not_found} = OAuthProviderApps.get("ten_r", "github")
  end

  test "an unreadable marker aborts the run without importing" do
    seed_provider_app("ten_x", "github")

    Repo.query!("ALTER TABLE salix_cutover_markers RENAME TO salix_cutover_markers_tmp")

    on_exit(fn ->
      Repo.query!("ALTER TABLE salix_cutover_markers_tmp RENAME TO salix_cutover_markers")
    end)

    assert {:error, {:marker_unreadable, _}} = OAuthAppsCutover.run()
    assert {:error, :not_found} = OAuthProviderApps.get("ten_x", "github")
  end

  test "a provider-app body whose provider does not round-trip to its key aborts" do
    lying = %{
      "tenant_id" => "ten_a",
      "provider" => "google",
      "client_id" => "x",
      "client_secret" => "y",
      "updated_at" => 1
    }

    key = Keys.ctl_oauth_provider_app("ten_a", "github")
    {:ok, _} = S3.put(key, Jason.encode!(lying), [])

    assert {:error, {:enumerate_failed, ^key, :record_address_mismatch}} = OAuthAppsCutover.run()
  end

  test "enumeration is fail-closed on a GET fault" do
    key = Keys.ctl_oauth_provider_app("ten_i", "github")
    seed_provider_app("ten_i", "github")

    S3.Fake.set_fault({:fail, 503, :get, key})
    assert {:error, {:enumerate_failed, ^key, _}} = OAuthAppsCutover.run()
    refute OAuthAppsCutover.marker_present?()
  end

  test "a PG-only row fails the equality gate" do
    :ok =
      OAuthProviderApps.import_record("ten_pg", %{
        "provider" => "github",
        "client_id" => "x",
        "client_secret" => "y",
        "updated_at" => 1_753_300_000
      })

    # S3 is empty, PG has one row -> mismatch.
    assert {:error, {:mismatch, :provider_apps}} = OAuthAppsCutover.run()
    refute OAuthAppsCutover.marker_present?()
  end

  test "a marker-insert failure rolls back the imported rows (atomic: zero rows, no marker)" do
    seed_provider_app("ten_a", "github")

    Repo.query!("""
    CREATE OR REPLACE FUNCTION _test_fail_marker_insert() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'injected marker insert failure'; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER _test_fail_marker BEFORE INSERT ON salix_cutover_markers FOR EACH ROW EXECUTE FUNCTION _test_fail_marker_insert()"
    )

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS _test_fail_marker ON salix_cutover_markers")
      Repo.query!("DROP FUNCTION IF EXISTS _test_fail_marker_insert()")
    end)

    assert {:error, _} = OAuthAppsCutover.run()
    refute OAuthAppsCutover.marker_present?()
    # Atomic: the imported secret-bearing rows were rolled back with the marker.
    assert [] = OAuthProviderApps.all_scoped_records()
  end

  defmodule SlowGetBackend do
    @moduledoc false
    # Delegates every backend callback to the shared Fake, but stalls each GET —
    # a slow object store during enumeration, which happens OUTSIDE the PG
    # transaction and so is invisible to transaction/statement timeouts.
    alias SalixStore.S3.Fake

    def get(key, opts) do
      Process.sleep(400)
      Fake.get(key, opts)
    end

    defdelegate put(key, body, opts), to: Fake
    defdelegate put_stream(key, stream, opts), to: Fake
    defdelegate head(key), to: Fake
    defdelegate delete(key, opts), to: Fake
    defdelegate list(prefix, opts), to: Fake
    defdelegate stream(key, opts), to: Fake
  end

  test "a slow S3 GET past the outer budget fails closed: no rows, no marker" do
    # The reviewer's reproduction: the enumeration lives outside the PG
    # transaction, so transaction/statement timeouts alone never see a slow
    # object store. The outer monotonic deadline must kill the whole step.
    seed_provider_app("ten_slow", "github")
    Application.put_env(:salix_store, :oauth_apps_cutover_timeout_ms, 100)
    Application.put_env(:salix_store, :s3_backend, SlowGetBackend)

    on_exit(fn ->
      Application.delete_env(:salix_store, :oauth_apps_cutover_timeout_ms)
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    end)

    assert {:error, {:budget_exceeded, 100}} = OAuthAppsCutover.run()
    assert [] = OAuthProviderApps.all_scoped_records()

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    refute OAuthAppsCutover.marker_present?()
  end

  test "a lock-blocked marker read past the outer budget fails closed: no rows, no marker" do
    # The reviewer's reproduction: the three-state marker SELECT runs before
    # the enumeration, so it too must live inside the outer deadline — an
    # ACCESS EXCLUSIVE lock on the marker table stalls it past the budget.
    seed_provider_app("ten_locked", "github")
    Application.put_env(:salix_store, :oauth_apps_cutover_timeout_ms, 100)
    on_exit(fn -> Application.delete_env(:salix_store, :oauth_apps_cutover_timeout_ms) end)

    parent = self()

    locker =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            Repo.query!("LOCK TABLE salix_cutover_markers IN ACCESS EXCLUSIVE MODE")
            send(parent, :locked)
            Process.sleep(500)
          end,
          timeout: 10_000
        )
      end)

    assert_receive :locked, 2_000
    assert {:error, {:budget_exceeded, 100}} = OAuthAppsCutover.run()
    Task.await(locker, 10_000)

    assert [] = OAuthProviderApps.all_scoped_records()
    refute OAuthAppsCutover.marker_present?()
  end

  test "an importable count above the preflight bound aborts before any PG write" do
    seed_provider_app("ten_a", "github")
    seed_provider_app("ten_b", "github")
    Application.put_env(:salix_store, :oauth_apps_cutover_max_objects, 1)
    on_exit(fn -> Application.delete_env(:salix_store, :oauth_apps_cutover_max_objects) end)

    assert {:error, {:preflight_bound_exceeded, 2, 1}} = OAuthAppsCutover.run()
    assert [] = OAuthProviderApps.all_scoped_records()
    refute OAuthAppsCutover.marker_present?()
  end

  test "a slow marker insert within the budget still commits (long transaction timeout)" do
    seed_provider_app("ten_a", "github")
    Application.put_env(:salix_store, :oauth_apps_cutover_timeout_ms, 30_000)
    on_exit(fn -> Application.delete_env(:salix_store, :oauth_apps_cutover_timeout_ms) end)

    install_marker_insert_delay("0.5")

    assert :ok = OAuthAppsCutover.run()
    assert OAuthAppsCutover.marker_present?()
  end

  test "a marker insert exceeding the configured timeout fails closed with rollback" do
    seed_provider_app("ten_b", "github")
    # 200ms budget vs a ~1s marker insert delay: the query times out, and the
    # whole transaction rolls back — no marker, no imported rows (default Ecto's
    # 15s timeout would instead let this commit, which is exactly the P1).
    Application.put_env(:salix_store, :oauth_apps_cutover_timeout_ms, 200)
    on_exit(fn -> Application.delete_env(:salix_store, :oauth_apps_cutover_timeout_ms) end)

    install_marker_insert_delay("1")

    assert {:error, _} = OAuthAppsCutover.run()
    refute OAuthAppsCutover.marker_present?()
    assert [] = OAuthProviderApps.all_scoped_records()
  end

  # A BEFORE INSERT trigger that sleeps `seconds` on the marker table, to
  # exercise the cutover transaction/statement timeout.
  defp install_marker_insert_delay(seconds) do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION _test_delay_marker_insert() RETURNS trigger AS $$
    BEGIN PERFORM pg_sleep(#{seconds}); RETURN NEW; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER _test_delay_marker BEFORE INSERT ON salix_cutover_markers FOR EACH ROW EXECUTE FUNCTION _test_delay_marker_insert()"
    )

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS _test_delay_marker ON salix_cutover_markers")
      Repo.query!("DROP FUNCTION IF EXISTS _test_delay_marker_insert()")
    end)
  end

  # --- fail-closed envelope validation (baked in from the start, per #654/#656) ---

  test "an out-of-range updated_at fails closed with no partial import" do
    # ten_a sorts before ten_z; the valid record is enumerated first. The
    # out-of-range value would raise ArgumentError in from_record; enumeration
    # must reject it so import never runs and ten_a does not land.
    seed_provider_app("ten_a", "github")
    seed_provider_app("ten_z", "github", %{"updated_at" => 253_402_300_800})

    assert {:error, {:enumerate_failed, _key, :invalid_record}} =
             OAuthAppsCutover.importable_count()

    assert {:error, {:enumerate_failed, _key, :invalid_record}} = OAuthAppsCutover.run()
    refute OAuthAppsCutover.marker_present?()
    assert {:error, :not_found} = OAuthProviderApps.get("ten_a", "github")
  end

  test "a non-map (top-level array) body fails closed as enumerate_failed, not a raise" do
    key = Keys.ctl_oauth_provider_app("ten_arr", "github")
    {:ok, _} = S3.put(key, Jason.encode!([1, 2, 3]), [])

    assert {:error, {:enumerate_failed, ^key, :invalid_record}} =
             OAuthAppsCutover.importable_count()

    assert {:error, {:enumerate_failed, ^key, :invalid_record}} = OAuthAppsCutover.run()
    refute OAuthAppsCutover.marker_present?()
  end

  test "a non-string typed field (client_secret as a number) fails closed" do
    key = Keys.ctl_oauth_provider_app("ten_ns", "github")

    bad = %{
      "tenant_id" => "ten_ns",
      "provider" => "github",
      "client_id" => "x",
      "client_secret" => 12_345,
      "updated_at" => 1_753_300_000
    }

    {:ok, _} = S3.put(key, Jason.encode!(bad), [])

    assert {:error, {:enumerate_failed, ^key, :invalid_record}} = OAuthAppsCutover.run()
    refute OAuthAppsCutover.marker_present?()
  end

  test "a non-canonical S3 key (no .json suffix) is not imported and writes no marker" do
    # A backup/variant object under the prefix whose path does not round-trip to
    # a canonical Keys path must fail closed — never become an active credential.
    no_suffix = "ctl/oauth/provider_apps/ten_a/github"

    {:ok, _} =
      S3.put(
        no_suffix,
        Jason.encode!(%{
          "tenant_id" => "ten_a",
          "provider" => "github",
          "client_id" => "x",
          "client_secret" => "y",
          "updated_at" => 1_753_300_000
        }),
        []
      )

    assert {:error, {:enumerate_failed, ^no_suffix, :record_address_mismatch}} =
             OAuthAppsCutover.importable_count()

    assert {:error, {:enumerate_failed, ^no_suffix, :record_address_mismatch}} =
             OAuthAppsCutover.run()

    refute OAuthAppsCutover.marker_present?()
    assert {:error, :not_found} = OAuthProviderApps.get("ten_a", "github")
  end

  test "a tenant-path object under the reserved default scope fails closed" do
    # The tenant segment becomes the PG scope, which is also where the
    # deployment default lives. Importing it would publish one tenant's
    # credentials as the deployment-wide fallback for every other tenant.
    scope = OAuthProviderApps.default_scope()

    {:ok, _} =
      S3.put(
        Keys.ctl_oauth_provider_app(scope, "github"),
        Jason.encode!(%{
          "tenant_id" => scope,
          "provider" => "github",
          "client_id" => "promoted-cid",
          "client_secret" => "promoted-secret",
          "updated_at" => 1_753_300_000
        }),
        []
      )

    assert {:error, {:enumerate_failed, _key, :record_address_mismatch}} =
             OAuthAppsCutover.run()

    assert [] = OAuthProviderApps.all_scoped_records()
    assert :absent = OAuthAppsCutover.marker_status()
    assert {:error, :not_configured} = Salix.Control.OAuthApps.get_default("github")

    # the preflight audit fails at the same point
    assert {:error, {:enumerate_failed, _, :record_address_mismatch}} =
             OAuthAppsCutover.importable_count()
  end

  test "a non-canonical default-app key (no .json suffix) fails closed" do
    no_suffix = "ctl/oauth/default_apps/google"

    {:ok, _} =
      S3.put(
        no_suffix,
        Jason.encode!(%{
          "provider" => "google",
          "client_id" => "x",
          "client_secret" => "y",
          "updated_at" => 1
        }),
        []
      )

    assert {:error, {:enumerate_failed, ^no_suffix, :record_address_mismatch}} =
             OAuthAppsCutover.run()

    refute OAuthAppsCutover.marker_present?()
  end

  test "marker_status distinguishes absent, present, and unreadable" do
    assert :absent = OAuthAppsCutover.marker_status()

    assert :ok = OAuthAppsCutover.run()
    assert :present = OAuthAppsCutover.marker_status()

    Repo.query!("ALTER TABLE salix_cutover_markers RENAME TO salix_cutover_markers_tmp")

    on_exit(fn ->
      Repo.query!("ALTER TABLE salix_cutover_markers_tmp RENAME TO salix_cutover_markers")
    end)

    assert {:error, _} = OAuthAppsCutover.marker_status()
  end

  test "client secrets never reach the Ecto query log" do
    log =
      capture_log([level: :debug], fn ->
        {:ok, _} =
          OAuthProviderApps.put("ten_log", %{
            "provider" => "github",
            "client_id" => "cid",
            "client_secret" => "PROVIDER_APP_SECRET",
            "updated_at" => 1
          })
      end)

    refute log =~ "PROVIDER_APP_SECRET"
  end
end
