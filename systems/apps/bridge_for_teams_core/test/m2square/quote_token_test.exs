defmodule BridgeForTeams.M2square.QuoteTokenTest do
  use SystemsClock.Case, async: false

  alias BridgeForTeams.M2square.{Config, FX, QuoteToken}

  defmodule FakeFX do
    @behaviour BridgeForTeams.M2square.FX.Provider

    @impl true
    def fetch_usd_base_rates(currencies, _opts) do
      case SystemsRuntime.get_env(:bridge_for_teams_core, :quote_token_test_fx_handler) do
        fun when is_function(fun, 1) ->
          fun.(currencies)

        _ ->
          {:ok,
           %{
             "BRL" => Decimal.new("0.20"),
             "CLP" => Decimal.new("0.00105"),
             "PEN" => Decimal.new("0.27")
           }}
      end
    end
  end

  defmodule FakeSalixClient do
    def get_m2square_settings do
      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :quote_token_test_console_settings,
        {:ok, :unconfigured}
      )
    end
  end

  setup tags do
    if epoch = tags[:clock] do
      :ok = SystemsClock.manual(epoch: epoch)
      on_exit(&SystemsClock.reset/0)
    end

    orig_secret = SystemsRuntime.get_env(:bridge_for_teams_core, :quote_signing_secret)
    orig_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    orig_m2 = SystemsRuntime.get_env(:bridge_for_teams_core, :m2square)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :quote_signing_secret,
      "test_quote_signing_secret_0123456789abcdef0123456789abcdef"
    )

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, FakeSalixClient)
    SystemsRuntime.delete_env(:bridge_for_teams_core, :quote_token_test_fx_handler)
    FX.clear_cache()

    on_exit(fn ->
      FX.clear_cache()
      SystemsRuntime.delete_env(:bridge_for_teams_core, :quote_token_test_fx_handler)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :quote_token_test_console_settings)

      if orig_secret,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :quote_signing_secret, orig_secret)

      if orig_client,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, orig_client)

      if orig_m2,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :m2square, orig_m2)
    end)

    :ok
  end

  defp sample_countries do
    [
      %{
        "code" => "CL",
        "name_en" => "Chile",
        "name_zh" => "智利",
        "currency" => "CLP",
        "display_currency" => "CLP",
        "scale" => 0,
        "min_seats" => 30,
        "max_seats" => 33,
        "sample_min_amount" => "7142858",
        "fee_rate" => "0.04",
        "fx_rate" => "0.00105",
        "fx_source" => "stripe_fx_quotes",
        "markup_rate" => "0",
        "payment_types" => ["NET_BANKING", "TD"],
        "id_types" => ["RUT", "PP"]
      },
      %{
        "code" => "PE",
        "name_en" => "Peru",
        "name_zh" => "秘鲁",
        "currency" => "PEN",
        "display_currency" => "PEN",
        "scale" => 2,
        "min_seats" => 30,
        "max_seats" => 48,
        "sample_min_amount" => "27777.78",
        "fee_rate" => "0.04",
        "fx_rate" => "0.27",
        "fx_source" => "stripe_fx_quotes",
        "markup_rate" => "0",
        "payment_types" => ["NET_BANKING", "TD", "TC"],
        "id_types" => ["DNI", "CE", "RUC", "PAS"]
      }
    ]
  end

  @tag clock: ~U[2026-11-20 12:00:00Z]
  test "issue and verify enforce exact 1-hour boundary, scope, signature integrity, and pure view reconstruction" do
    now = SystemsClock.utc_now()
    scope = "signup:11111111-1111-1111-1111-111111111111"

    assert {:ok, %{token: token, issued_at: issued_at, expires_at: expires_at, snapshot: snap}} =
             QuoteToken.issue(scope, 100, sample_countries(), now)

    assert expires_at == issued_at + 3_600

    # At expires_at - 1s: still valid
    at_minus_1 = DateTime.add(now, 3_599, :second)
    assert {:ok, verified} = QuoteToken.verify(token, scope, at_minus_1)
    assert verified == snap
    assert QuoteToken.unexpired?(verified, at_minus_1) == true

    # At exact expires_at: expired!
    at_expiry = DateTime.add(now, 3_600, :second)
    assert {:error, :quote_expired} = QuoteToken.verify(token, scope, at_expiry)
    assert QuoteToken.unexpired?(verified, at_expiry) == false

    # Cross-scope rejected
    assert {:error, :invalid_quote_token} =
             QuoteToken.verify(token, "renew:11111111-1111-1111-1111-111111111111", now)

    # Tampered signature or payload rejected
    [payload_b64, sig_b64] = String.split(token, ".", parts: 2)
    tampered_sig = payload_b64 <> "." <> String.reverse(sig_b64)
    assert {:error, :invalid_quote_token} = QuoteToken.verify(tampered_sig, scope, now)
    assert {:error, :invalid_quote_token} = QuoteToken.verify("not.valid.token", scope, now)

    # countries_for_view restores canonical Config.country_order() ("PE" before "CL") and name_en/name_zh
    view = QuoteToken.countries_for_view(verified)
    assert Enum.map(view, & &1["code"]) == ["PE", "CL"]
    assert Enum.at(view, 0)["name_en"] == "Peru"
    assert Enum.at(view, 0)["name_zh"] == "秘鲁"
    assert Enum.at(view, 1)["name_en"] == "Chile"
    assert Enum.at(view, 1)["name_zh"] == "智利"
  end

  test "missing or short quote_signing_secret fails closed with :quote_signing_unconfigured" do
    SystemsRuntime.put_env(:bridge_for_teams_core, :quote_signing_secret, "too_short")
    assert {:error, :quote_signing_unconfigured} = QuoteToken.issue("signup:x", 100, [])
    assert {:error, :quote_signing_unconfigured} = QuoteToken.verify("a.b", "signup:x")
  end

  @tag clock: ~U[2026-11-19 13:00:00Z]
  test "prepare_payment_window anchors FX deadline and expires_at to shared entry clock across 5s fetch lag, and keeps EC independent" do
    SystemsRuntime.put_env(:bridge_for_teams_core, :m2square, %{
      mch_id: "mch-test-1",
      secret_key: "secret-test-key",
      fx_provider: FakeFX
    })

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :quote_token_test_console_settings,
      {:ok,
       {:configured,
        %{
          "PE" => %{"enabled" => true, "payment_types" => ["NET_BANKING"]},
          "EC" => %{"enabled" => true, "payment_types" => ["NET_BANKING"]},
          "BR" => %{"enabled" => true, "payment_types" => ["PIX"]},
          "CL" => %{"enabled" => false, "payment_types" => ["NET_BANKING"]}
        }}}
    )

    # Populate FX cache at 2026-11-19 13:00:00Z -> 24h hard TTL expires at 2026-11-20 13:00:00Z.
    assert {:ok, _} = FX.rate_for_currency("PEN")

    # Advance 23h to 2026-11-20 12:00:00Z: cached PEN has exactly 3600s remaining (until 13:00:00Z).
    SystemsClock.advance(23 * 3_600_000)

    # Simulate 5s passing during fetch of another currency / slow upstream by advancing clock 5s
    # while checking BRL via a custom wrapper: clear cache? No, keep PEN cached at 23h and advance
    # 5s during the async/sync work by overriding SalixClient to advance 5s after reading settings.
    # Actually: if we advance 5s inside FakeSalixClient AFTER entry_now is sampled in prepare_payment_window,
    # Config.available_countries runs at 12:00:05 while entry_now was 12:00:00 and required_until_ms was 13:00:00!
    defmodule LaggingSalixClient do
      def get_m2square_settings do
        SystemsClock.advance(5_000)

        {:ok,
         {:configured,
          %{
            "PE" => %{"enabled" => true, "payment_types" => ["NET_BANKING"]},
            "EC" => %{"enabled" => true, "payment_types" => ["NET_BANKING"]},
            "BR" => %{"enabled" => true, "payment_types" => ["PIX"]},
            "CL" => %{"enabled" => false, "payment_types" => ["NET_BANKING"]}
          }}}
      end
    end

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, LaggingSalixClient)

    scope = "signup:22222222-2222-2222-2222-222222222222"

    assert {:ok, window} = QuoteToken.prepare_payment_window(scope, 100)

    # Anchor is 12:00:00Z -> expires_at MUST be 13:00:00Z (NOT 13:00:05Z), ttl_seconds == 3595!
    expected_issued = DateTime.to_unix(~U[2026-11-20 12:00:00Z], :second)
    expected_expires = DateTime.to_unix(~U[2026-11-20 13:00:00Z], :second)
    assert window.issued_at == expected_issued
    assert window.expires_at == expected_expires
    assert window.ttl_seconds == 3_595
    assert Enum.map(window.countries, & &1["code"]) == ["PE", "EC", "BR"]

    # Advancing to 13:00:00Z (3595s more) makes the token strictly :quote_expired
    SystemsClock.advance(3_595_000)
    assert {:error, :quote_expired} = QuoteToken.verify(window.token, scope)

    # Even when non-USD FX fails completely, EC 1:1 USD peg remains independently available!
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :quote_token_test_fx_handler,
      fn _ -> {:error, :fx_down} end
    )

    FX.clear_cache()
    assert {:ok, ec_only} = QuoteToken.prepare_payment_window(scope, 100)
    assert Enum.map(ec_only.countries, & &1["code"]) == ["EC"]
    assert Config.credentials_configured?() == true
  end

  @tag clock: ~U[2026-11-20 12:00:00Z]
  test "prepare_payment_window drops countries below min_m2_seats floor and aligns min_seats and sample_min_amount across countries and snapshot" do
    SystemsRuntime.put_env(:bridge_for_teams_core, :m2square, %{
      mch_id: "mch-test-1",
      secret_key: "secret-test-key",
      fx_provider: FakeFX
    })

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :quote_token_test_console_settings,
      {:ok,
       {:configured,
        %{
          "PE" => %{"enabled" => true, "payment_types" => ["NET_BANKING"]},
          "EC" => %{"enabled" => true, "payment_types" => ["NET_BANKING"]},
          "BR" => %{"enabled" => true, "payment_types" => ["PIX"]},
          "CL" => %{"enabled" => true, "payment_types" => ["NET_BANKING"]}
        }}}
    )

    scope = "renew:33333333-3333-3333-3333-333333333333"
    assert {:ok, window} = QuoteToken.prepare_payment_window(scope, 100, min_m2_seats: 40)

    # At FakeFX rates (PE max 43, BR max 40, EC max 39, CL max 33), EC and CL are dropped.
    assert Enum.map(window.countries, & &1["code"]) == ["PE", "BR"]
    assert window.snapshot["countries"] |> Map.keys() |> Enum.sort() == ["BR", "PE"]

    [pe_country, br_country] = window.countries
    pe_snap = window.snapshot["countries"]["PE"]
    br_snap = window.snapshot["countries"]["BR"]
    assert pe_country["min_seats"] == 40
    assert pe_snap["min_seats"] == 40
    assert br_country["min_seats"] == 40
    assert br_country["max_seats"] == 40
    assert br_snap["min_seats"] == 40
    assert br_snap["max_seats"] == 40

    {:ok, pe_cfg} = Config.country("PE")

    {:ok, expected_40_quote} =
      BridgeForTeams.M2square.Pricing.quote_order(pe_cfg, 40, Decimal.new("0.27"), "0")

    assert pe_country["sample_min_amount"] == expected_40_quote.formatted_amount
    assert pe_snap["sample_min_amount"] == expected_40_quote.formatted_amount

    assert {:ok, window_41} = QuoteToken.prepare_payment_window(scope, 100, min_m2_seats: 41)
    assert Enum.map(window_41.countries, & &1["code"]) == ["PE"]
    assert Map.keys(window_41.snapshot["countries"]) == ["PE"]
  end
end
