defmodule SalixStore.ProviderCredentialsCutoverTest do
  # Shares the node-global Fake bucket and control tables; keep serial.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SalixStore.{
    ComposioSettings,
    FeishuTenantApps,
    Keys,
    ProviderCredentialsCutover,
    Repo,
    S3
  }

  setup do
    S3.Fake.reset()
    Repo.query!("TRUNCATE composio_settings, feishu_tenant_apps")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'provider_credentials_v1'")

    on_exit(fn ->
      S3.Fake.reset()

      Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('provider_credentials_v1', now(), '{"mode":"test-baseline"}'::jsonb)
      ON CONFLICT (name) DO NOTHING
      """)
    end)

    :ok
  end

  defp seed_composio_tenant(tenant_id, api_key, attrs \\ %{}) do
    rec =
      Map.merge(
        %{
          "tenant_id" => tenant_id,
          "api_key" => api_key,
          "base_url" => "",
          "enabled" => true,
          "updated_at" => 1_753_300_000
        },
        attrs
      )

    {:ok, _} = S3.put(Keys.ctl_composio_settings(tenant_id), Jason.encode!(rec), [])
    rec
  end

  defp seed_composio_default(api_key) do
    rec = %{
      "api_key" => api_key,
      "base_url" => "",
      "enabled" => true,
      "updated_at" => 1_753_300_050
    }

    {:ok, _} = S3.put(Keys.ctl_composio_default_settings(), Jason.encode!(rec), [])
    rec
  end

  defp seed_feishu(tenant_id, app_id) do
    rec = %{
      "tenant_id" => tenant_id,
      "app_id" => app_id,
      "app_secret" => "secret-#{app_id}",
      "verification_token" => "vt-#{app_id}",
      "encrypt_key" => "ek-#{app_id}",
      "updated_at" => 1_753_300_100
    }

    {:ok, _} = S3.put(Keys.ctl_feishu_tenant_app(tenant_id), Jason.encode!(rec), [])
    rec
  end

  test "imports both classes, verifies equality, persists the marker, and re-runs" do
    seed_composio_tenant("ten_a", "ck_a")
    seed_composio_default("ck_default")
    seed_feishu("ten_a", "cli_a")

    assert :ok = ProviderCredentialsCutover.run()
    assert ProviderCredentialsCutover.marker_present?()

    assert {:ok, %{"api_key" => "ck_a"}} = ComposioSettings.get("ten_a")

    assert {:ok, %{"api_key" => "ck_default"}} =
             ComposioSettings.get(ComposioSettings.default_scope())

    assert {:ok, %{"app_id" => "cli_a"}} = FeishuTenantApps.get("ten_a")

    # Idempotent: the exact step retries cleanly.
    assert :ok = ProviderCredentialsCutover.run()
  end

  test "an empty control store cuts over to a trivially-equal marker" do
    assert :ok = ProviderCredentialsCutover.run()
    assert ProviderCredentialsCutover.marker_present?()

    assert {:ok, %{"composio" => 0, "feishu" => 0}} =
             ProviderCredentialsCutover.importable_count()
  end

  test "a re-run after a PG-only delete does not resurrect the record (terminal fence)" do
    seed_feishu("ten_r", "cli_r")
    assert :ok = ProviderCredentialsCutover.run()
    assert {:ok, _} = FeishuTenantApps.get("ten_r")

    assert :ok = FeishuTenantApps.delete("ten_r")
    assert {:error, :not_found} = FeishuTenantApps.get("ten_r")
    # S3 object is deliberately still present (PR-B clears it later).
    assert {:ok, _} = S3.get(Keys.ctl_feishu_tenant_app("ten_r"))

    assert :ok = ProviderCredentialsCutover.run()
    assert {:error, :not_found} = FeishuTenantApps.get("ten_r")
  end

  test "an unreadable marker aborts the run without importing" do
    seed_feishu("ten_x", "cli_x")

    Repo.query!("ALTER TABLE salix_cutover_markers RENAME TO salix_cutover_markers_tmp")

    on_exit(fn ->
      Repo.query!("ALTER TABLE salix_cutover_markers_tmp RENAME TO salix_cutover_markers")
    end)

    assert {:error, {:marker_unreadable, _}} = ProviderCredentialsCutover.run()
    assert {:error, :not_found} = FeishuTenantApps.get("ten_x")
  end

  # {name, key function and args, stored body, expected enumerate reason}
  @invalid_records [
    {"a composio record whose body does not round-trip to its key aborts the cutover",
     {:ctl_composio_settings, ["ten_actual"]},
     %{
       "tenant_id" => "ten_other",
       "api_key" => "ck",
       "base_url" => "",
       "enabled" => true,
       "updated_at" => 1
     }, :record_address_mismatch},
    {"a composio tenant record with a non-integer updated_at fails closed",
     {:ctl_composio_settings, ["ten_bad"]},
     %{
       "tenant_id" => "ten_bad",
       "api_key" => "ck_bad",
       "base_url" => "",
       "enabled" => true,
       "updated_at" => "2026-07-28T00:00:00Z"
     }, :invalid_record},
    {"the composio default record with a non-integer updated_at fails closed",
     {:ctl_composio_default_settings, []},
     %{"api_key" => "ck_default", "base_url" => "", "enabled" => true, "updated_at" => "nope"},
     :invalid_record},
    {"a feishu record with a non-integer updated_at fails closed",
     {:ctl_feishu_tenant_app, ["ten_bad"]},
     %{
       "tenant_id" => "ten_bad",
       "app_id" => "cli_bad",
       "app_secret" => "s",
       "verification_token" => "",
       "encrypt_key" => "",
       "updated_at" => "2026-07-28T00:00:00Z"
     }, :invalid_record},
    {"a non-map (top-level array) body fails closed as enumerate_failed, not a raise",
     {:ctl_composio_settings, ["ten_arr"]}, [1, 2, 3], :invalid_record},
    {"a non-string typed field (feishu app_secret as a number) fails closed",
     {:ctl_feishu_tenant_app, ["ten_ns"]},
     %{
       "tenant_id" => "ten_ns",
       "app_id" => "cli",
       "app_secret" => 12_345,
       "verification_token" => "",
       "encrypt_key" => "",
       "updated_at" => 1_753_300_100
     }, :invalid_record}
  ]

  for {name, {key_fun, key_args}, body, reason} <- @invalid_records do
    test "#{name} (audit + run, no crash, no marker)" do
      key = apply(Keys, unquote(key_fun), unquote(key_args))
      {:ok, _} = S3.put(key, Jason.encode!(unquote(Macro.escape(body))), [])

      assert {:error, {:enumerate_failed, ^key, unquote(reason)}} =
               ProviderCredentialsCutover.importable_count()

      assert {:error, {:enumerate_failed, ^key, unquote(reason)}} =
               ProviderCredentialsCutover.run()

      refute ProviderCredentialsCutover.marker_present?()
    end
  end

  test "a malformed updated_at aborts run/0 before any PG write (no partial import)" do
    # A valid feishu record plus a malformed composio record. Enumeration of the
    # composio class aborts, so import_* never runs and the valid feishu record
    # must not land in Postgres.
    seed_feishu("ten_ok", "cli_ok")
    seed_composio_tenant("ten_bad", "ck_bad", %{"updated_at" => "2026-07-28T00:00:00Z"})

    assert {:error, {:enumerate_failed, _key, :invalid_record}} = ProviderCredentialsCutover.run()
    refute ProviderCredentialsCutover.marker_present?()
    assert {:error, :not_found} = FeishuTenantApps.get("ten_ok")
  end

  test "an out-of-range (ms-magnitude) updated_at fails closed with no partial import" do
    # Valid record first, out-of-range record sorting after it (253_402_300_800 =
    # one second past the DateTime range). from_record would raise ArgumentError;
    # enumeration must reject it so import never runs and ten_a does not land.
    seed_composio_tenant("ten_a", "ck_a")
    seed_composio_tenant("ten_z", "ck_z", %{"updated_at" => 253_402_300_800})

    assert {:error, {:enumerate_failed, _key, :invalid_record}} =
             ProviderCredentialsCutover.importable_count()

    assert {:error, {:enumerate_failed, _key, :invalid_record}} = ProviderCredentialsCutover.run()
    refute ProviderCredentialsCutover.marker_present?()
    assert {:error, :not_found} = ComposioSettings.get("ten_a")
  end

  test "enumeration is fail-closed on a GET fault" do
    key = Keys.ctl_feishu_tenant_app("ten_i")
    seed_feishu("ten_i", "cli_i")

    S3.Fake.set_fault({:fail, 503, :get, key})
    assert {:error, {:enumerate_failed, ^key, _}} = ProviderCredentialsCutover.run()
    refute ProviderCredentialsCutover.marker_present?()
  end

  test "a PG-only row fails the equality gate" do
    :ok = FeishuTenantApps.import_record(seed_pg_only_feishu())
    # S3 is empty for feishu, PG has one row -> mismatch.
    assert {:error, {:mismatch, :feishu}} = ProviderCredentialsCutover.run()
    refute ProviderCredentialsCutover.marker_present?()
  end

  test "secret fields never reach the Ecto query log" do
    log =
      capture_log([level: :debug], fn ->
        {:ok, _} =
          ComposioSettings.put("ten_log", %{
            "api_key" => "COMPOSIO_SECRET_KEY",
            "base_url" => "",
            "enabled" => true,
            "updated_at" => 1
          })

        {:ok, _} =
          FeishuTenantApps.put(%{
            "tenant_id" => "ten_log",
            "app_id" => "cli",
            "app_secret" => "FEISHU_APP_SECRET",
            "verification_token" => "FEISHU_VT",
            "encrypt_key" => "FEISHU_EK",
            "updated_at" => 1
          })

        :ok =
          ComposioSettings.import_record("ten_imp", %{
            "api_key" => "COMPOSIO_IMPORT_SECRET",
            "base_url" => "",
            "enabled" => true,
            "updated_at" => 1
          })

        :ok =
          FeishuTenantApps.import_record(%{
            "tenant_id" => "ten_imp",
            "app_id" => "cli",
            "app_secret" => "FEISHU_IMPORT_SECRET",
            "verification_token" => "",
            "encrypt_key" => "",
            "updated_at" => 1
          })
      end)

    for secret <- [
          "COMPOSIO_SECRET_KEY",
          "FEISHU_APP_SECRET",
          "FEISHU_VT",
          "FEISHU_EK",
          "COMPOSIO_IMPORT_SECRET",
          "FEISHU_IMPORT_SECRET"
        ] do
      refute log =~ secret, "secret #{secret} leaked into the query log"
    end
  end

  defp seed_pg_only_feishu do
    %{
      "tenant_id" => "ten_pg_only",
      "app_id" => "cli_pg",
      "app_secret" => "s",
      "verification_token" => "",
      "encrypt_key" => "",
      "updated_at" => 1_753_300_100
    }
  end
end
