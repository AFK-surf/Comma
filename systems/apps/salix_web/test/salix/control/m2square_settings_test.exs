defmodule Salix.Control.M2squareSettingsTest do
  use SystemsClock.Case, async: false

  alias Salix.Control.M2squareSettings
  alias SalixStore.{Keys, S3}

  defmodule FakeS3Wrapper do
    def get(key, opts) do
      case handler() do
        {:get, fun} -> fun.(key, opts)
        {:both, get_fun, _put_fun} -> get_fun.(key, opts)
        _ -> S3.Fake.get(key, opts)
      end
    end

    def put(key, body, opts) do
      case handler() do
        {:put, fun} -> fun.(key, body, opts)
        {:both, _get_fun, put_fun} -> put_fun.(key, body, opts)
        _ -> S3.Fake.put(key, body, opts)
      end
    end

    def delete(key, opts), do: S3.Fake.delete(key, opts)
    def head(key), do: S3.Fake.head(key)
    def list(prefix, opts), do: S3.Fake.list(prefix, opts)

    defp handler, do: SystemsRuntime.get_env(:salix_web, :m2square_settings_test_s3_handler)
  end

  setup do
    orig_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    SystemsRuntime.delete_env(:salix_web, :m2square_settings_test_s3_handler)
    _ = S3.delete(Keys.ctl_system_m2square_settings())

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_web, :m2square_settings_test_s3_handler)
      SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
      _ = S3.delete(Keys.ctl_system_m2square_settings())

      if orig_backend do
        SystemsRuntime.put_env(:salix_store, :s3_backend, orig_backend)
      end
    end)

    :ok
  end

  defp valid_countries(overrides \\ %{}) do
    base = M2squareSettings.default_all_disabled_countries()
    Map.merge(base, overrides)
  end

  test "unconfigured state returns :unconfigured for get/0 and all-disabled defaults with sentinel etag for get_for_admin/0" do
    assert {:ok, :unconfigured} = M2squareSettings.get()

    assert {:ok, %{configured?: false, countries: countries, etag: "__unconfigured__"}} =
             M2squareSettings.get_for_admin()

    assert Map.keys(countries) |> Enum.sort() == ["BR", "CL", "EC", "PE"]

    for code <- ["PE", "EC", "BR", "CL"] do
      assert countries[code]["enabled"] == false
      assert is_list(countries[code]["payment_types"])
      assert countries[code]["payment_types"] != []
    end
  end

  test "valid put/2 from __unconfigured__ saves normalized canonical order and updates etag" do
    input =
      valid_countries(%{
        "PE" => %{"enabled" => true, "payment_types" => ["TC", "NET_BANKING", "TC"]},
        "EC" => %{"enabled" => true, "payment_types" => ["CASH"]}
      })

    assert {:ok, {:saved, saved, etag1}} =
             M2squareSettings.put(input, M2squareSettings.unconfigured_etag())

    assert is_binary(etag1) and etag1 != ""
    assert saved["PE"] == %{"enabled" => true, "payment_types" => ["NET_BANKING", "TC"]}
    assert saved["EC"] == %{"enabled" => true, "payment_types" => ["CASH"]}
    assert saved["BR"]["enabled"] == false
    assert saved["CL"]["enabled"] == false

    assert {:ok, {:configured, ^saved}} = M2squareSettings.get()

    assert {:ok, %{configured?: true, countries: ^saved, etag: ^etag1}} =
             M2squareSettings.get_for_admin()

    # Concurrent first save with stale "__unconfigured__" fails with :conflict
    assert {:error, :conflict} =
             M2squareSettings.put(valid_countries(), M2squareSettings.unconfigured_etag())

    # Update with current etag succeeds; stale etag fails with :conflict
    updated_input =
      Map.put(saved, "BR", %{"enabled" => true, "payment_types" => ["PIX"]})

    assert {:ok, {:saved, saved2, etag2}} = M2squareSettings.put(updated_input, etag1)
    assert etag2 != etag1
    assert saved2["BR"]["enabled"] == true

    assert {:error, :conflict} = M2squareSettings.put(saved, etag1)
  end

  test "validation rejects enabled country with empty payment_types or invalid etag without writing S3" do
    bad_input = valid_countries(%{"PE" => %{"enabled" => true, "payment_types" => []}})

    assert {:error, {:validation, %{"PE" => :payment_types_required_when_enabled}}} =
             M2squareSettings.put(bad_input, "__unconfigured__")

    assert {:ok, :unconfigured} = M2squareSettings.get()

    assert {:error, :invalid_etag} = M2squareSettings.put(valid_countries(), nil)
    assert {:error, :invalid_etag} = M2squareSettings.put(valid_countries(), "")
  end

  test "ambiguous S3 put settles all four read-back outcomes exhaustively" do
    SystemsRuntime.put_env(:salix_store, :s3_backend, FakeS3Wrapper)
    target = valid_countries(%{"EC" => %{"enabled" => true, "payment_types" => ["CASH"]}})

    # 1. Read-back sees unconfigured -> {:error, {:unconfigured_after_ambiguous, state}}
    SystemsRuntime.put_env(
      :salix_web,
      :m2square_settings_test_s3_handler,
      {:put, fn _key, _body, _opts -> {:error, {:ambiguous, :timeout}} end}
    )

    assert {:error,
            {:unconfigured_after_ambiguous, %{configured?: false, etag: "__unconfigured__"}}} =
             M2squareSettings.put(target, "__unconfigured__")

    # 2. Read-back sees configured & matching -> {:ok, {:already_applied, countries, live_etag}}
    SystemsRuntime.put_env(
      :salix_web,
      :m2square_settings_test_s3_handler,
      {:put,
       fn key, body, opts ->
         {:ok, _} = S3.Fake.put(key, body, opts)
         {:error, {:ambiguous, :timeout}}
       end}
    )

    assert {:ok, {:already_applied, ^target, live_etag}} =
             M2squareSettings.put(target, "__unconfigured__")

    assert is_binary(live_etag) and live_etag != ""

    # 3. Read-back sees configured & differing -> {:error, {:conflict_settled, live_state}}
    other = valid_countries(%{"BR" => %{"enabled" => true, "payment_types" => ["PIX"]}})

    SystemsRuntime.put_env(
      :salix_web,
      :m2square_settings_test_s3_handler,
      {:put, fn _key, _body, _opts -> {:error, {:ambiguous, :timeout}} end}
    )

    assert {:error,
            {:conflict_settled, %{configured?: true, countries: ^target, etag: ^live_etag}}} =
             M2squareSettings.put(other, live_etag)

    # 4. Read-back itself fails -> {:error, :ambiguous_unconfirmed}
    SystemsRuntime.put_env(
      :salix_web,
      :m2square_settings_test_s3_handler,
      {:both, fn _key, _opts -> {:error, :s3_down} end,
       fn _key, _body, _opts -> {:error, {:ambiguous, :timeout}} end}
    )

    assert {:error, :ambiguous_unconfirmed} = M2squareSettings.put(other, live_etag)
  end

  test "corrupt or schema-violating S3 payloads fail closed with :invalid_m2square_settings" do
    key = Keys.ctl_system_m2square_settings()

    valid_ts = "2026-11-20T00:00:00Z"

    bad_payloads = [
      "not-json",
      Jason.encode!(%{
        "version" => 2,
        "countries" => valid_countries(),
        "updated_at" => valid_ts
      }),
      Jason.encode!(%{
        "version" => 1,
        "countries" => Map.delete(valid_countries(), "CL"),
        "updated_at" => valid_ts
      }),
      Jason.encode!(%{
        "version" => 1,
        "countries" => valid_countries(%{"PE" => %{"enabled" => true, "payment_types" => []}}),
        "updated_at" => valid_ts
      }),
      Jason.encode!(%{
        "version" => 1,
        "countries" =>
          valid_countries(%{
            "PE" => %{"enabled" => true, "payment_types" => ["TC", "NET_BANKING"]}
          }),
        "updated_at" => valid_ts
      }),
      # Missing updated_at
      Jason.encode!(%{"version" => 1, "countries" => valid_countries()}),
      # Non-string updated_at
      Jason.encode!(%{"version" => 1, "countries" => valid_countries(), "updated_at" => 12345}),
      # Invalid ISO-8601 updated_at
      Jason.encode!(%{
        "version" => 1,
        "countries" => valid_countries(),
        "updated_at" => "not-iso8601"
      }),
      # Unknown top-level key
      Jason.encode!(%{
        "version" => 1,
        "countries" => valid_countries(),
        "updated_at" => valid_ts,
        "extra" => true
      })
    ]

    for body <- bad_payloads do
      {:ok, _} = S3.put(key, body, [])
      assert {:error, :invalid_m2square_settings} = M2squareSettings.get()
      assert {:error, :invalid_m2square_settings} = M2squareSettings.get_for_admin()
    end
  end
end
