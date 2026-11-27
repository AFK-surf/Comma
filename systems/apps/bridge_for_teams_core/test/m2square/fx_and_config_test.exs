defmodule BridgeForTeams.M2square.FXAndConfigTest do
  use SystemsClock.Case, async: false

  alias BridgeForTeams.M2square.Config
  alias BridgeForTeams.M2square.FX
  alias BridgeForTeams.M2square.FX.StripeQuotes
  alias SalixStore.ConfigJson

  defmodule CountingFXProvider do
    @behaviour BridgeForTeams.M2square.FX.Provider

    @impl true
    def fetch_usd_base_rates(currencies, _opts) do
      agent = SystemsRuntime.get_env(:bridge_for_teams_core, :m2square_test_fx_agent)

      Agent.get_and_update(agent, fn state ->
        calls = state.calls + 1
        result = state.handler.(currencies, calls)
        {result, %{state | calls: calls}}
      end)
    end
  end

  defmodule FakeSalixClient do
    def get_m2square_settings do
      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :m2square_test_console_settings,
        {:ok, :unconfigured}
      )
    end
  end

  defmodule LegacySalixClientWithoutCallback do
  end

  setup tags do
    if epoch = tags[:clock] do
      :ok = SystemsClock.manual(epoch: epoch)
      on_exit(&SystemsClock.reset/0)
    end

    orig_salix_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, FakeSalixClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :m2square_test_console_settings,
      {:ok, :unconfigured}
    )

    FX.clear_cache()

    on_exit(fn ->
      FX.clear_cache()
      SystemsRuntime.delete_env(:bridge_for_teams_core, :m2square_test_console_settings)

      if orig_salix_client do
        SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, orig_salix_client)
      end
    end)

    :ok
  end

  defp start_fx_agent(handler) do
    {:ok, agent} = Agent.start_link(fn -> %{calls: 0, handler: handler} end)
    SystemsRuntime.put_env(:bridge_for_teams_core, :m2square_test_fx_agent, agent)
    agent
  end

  defp fx_calls(agent), do: Agent.get(agent, & &1.calls)

  defp all_enabled_console_settings(overrides \\ %{}) do
    base = %{
      "PE" => %{"enabled" => true, "payment_types" => ["NET_BANKING", "TD", "TC"]},
      "EC" => %{"enabled" => true, "payment_types" => ["NET_BANKING"]},
      "BR" => %{"enabled" => true, "payment_types" => ["PIX"]},
      "CL" => %{"enabled" => true, "payment_types" => ["NET_BANKING", "TD", "TC"]}
    }

    {:ok, {:configured, Map.merge(base, overrides)}}
  end

  defp put_console_settings(result) do
    SystemsRuntime.put_env(:bridge_for_teams_core, :m2square_test_console_settings, result)
  end

  defp put_m2square_config(overrides \\ %{}) do
    base = %{
      mch_id: "mch-test-1",
      secret_key: "secret-test-key",
      fx_provider: CountingFXProvider
    }

    SystemsRuntime.put_env(:bridge_for_teams_core, :m2square, Map.merge(base, overrides))
  end

  describe "Config defaults, Console authority, and fail-closed isolation" do
    test "defaults keep all four countries disabled and available_countries empty" do
      SystemsRuntime.put_env(:bridge_for_teams_core, :m2square, %{})

      cfg = Config.get()
      assert Config.credentials_configured?() == false
      assert Config.available_countries() == []

      for code <- ["PE", "EC", "BR", "CL"] do
        assert {:ok, c} = Config.country(code)
        assert c.enabled == false
      end

      assert {:ok, br} = Config.country(" br ")
      assert br.code == "BR"
      assert {:error, :unsupported_country} = Config.country("US")
      assert cfg.base_url == "https://latinapi.m2square.xyz/gateway/base/biz"
    end

    test "ConfigJson maps billing.m2square while stripping enabled and payment_types" do
      json = %{
        "billing" => %{
          "m2square" => %{
            "base_url" => "https://sandbox.m2square.test/gateway/base/biz",
            "mch_id" => "mch_123",
            "secret_key" => "sec_456",
            "markup_rate" => "0.01",
            "no_pay_page" => false,
            "fx_soft_ttl_ms" => 1_800_000,
            "countries" => %{
              "EC" => %{"enabled" => true, "payment_types" => ["CASH"]},
              "BR" => %{
                "enabled" => true,
                "payment_types" => ["PIX"],
                "brazil_doc_type" => "CPF",
                "extra_pay_fields" => %{"pixCheck" => "true"}
              }
            }
          }
        }
      }

      assert [{:bridge_for_teams_core, :m2square, mapped}] = ConfigJson.m2square_env(json)
      assert mapped.base_url == "https://sandbox.m2square.test/gateway/base/biz"
      assert mapped.mch_id == "mch_123"
      assert mapped.secret_key == "sec_456"
      assert mapped.markup_rate == "0.01"
      assert mapped.no_pay_page == "false"
      assert mapped.fx_soft_ttl_ms == 1_800_000
      refute Map.has_key?(mapped.countries, "EC")
      refute Map.has_key?(mapped.countries["BR"], :enabled)
      refute Map.has_key?(mapped.countries["BR"], :payment_types)
      assert mapped.countries["BR"].brazil_doc_type == "CPF"
      assert mapped.countries["BR"].extra_pay_fields == %{"pixCheck" => "true"}

      assert {:bridge_for_teams_core, :m2square, mapped} in ConfigJson.app_env(json)
      assert ConfigJson.m2square_env(%{}) == []
    end

    test "effective_config fails closed on :unconfigured, {:error, :unavailable}, and legacy client without callback" do
      put_m2square_config(%{
        countries: %{
          "PE" => %{enabled: true},
          "EC" => %{enabled: true},
          "BR" => %{enabled: true},
          "CL" => %{enabled: true}
        }
      })

      # 1. :unconfigured
      put_console_settings({:ok, :unconfigured})
      cfg_unconf = Config.effective_config()
      assert Enum.all?(Config.country_order(), &(cfg_unconf.countries[&1].enabled == false))
      assert Config.available_countries() == []

      # 2. {:error, :unavailable}
      put_console_settings({:error, :unavailable})
      cfg_err = Config.effective_config()
      assert Enum.all?(Config.country_order(), &(cfg_err.countries[&1].enabled == false))
      assert Config.available_countries() == []

      # 3. Legacy client without get_m2square_settings/0
      SystemsRuntime.put_env(
        :bridge_for_teams_core,
        :salix_client,
        LegacySalixClientWithoutCallback
      )

      cfg_legacy = Config.effective_config()
      assert Enum.all?(Config.country_order(), &(cfg_legacy.countries[&1].enabled == false))
      assert Config.available_countries() == []
    end

    test "EC with CASH-only removes PAS from effective id_types" do
      put_m2square_config()

      put_console_settings(
        all_enabled_console_settings(%{
          "PE" => %{"enabled" => false, "payment_types" => ["NET_BANKING"]},
          "EC" => %{"enabled" => true, "payment_types" => ["CASH"]},
          "BR" => %{"enabled" => false, "payment_types" => ["PIX"]},
          "CL" => %{"enabled" => false, "payment_types" => ["NET_BANKING"]}
        })
      )

      cfg = Config.effective_config()
      assert {:ok, ec_cfg} = Config.enabled_country(cfg, "EC")
      assert ec_cfg.payment_types == ["CASH"]
      assert ec_cfg.id_types == ["CI", "RUC"]

      [ec_view] = Config.available_countries()
      assert ec_view["code"] == "EC"
      assert ec_view["payment_types"] == ["CASH"]
      assert ec_view["id_types"] == ["CI", "RUC"]
    end
  end

  describe "FX.StripeQuotes" do
    test "posts form parameters with Stripe-Version and decodes base_rate as Decimal" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/fx_quotes"
        assert Plug.Conn.get_req_header(conn, "stripe-version") == ["2026-09-30.preview"]
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk_test_fx"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "to_currency=usd"
        assert body =~ "lock_duration=none"
        assert body =~ "from_currencies%5B%5D=brl"
        assert body =~ "from_currencies%5B%5D=clp"
        assert body =~ "from_currencies%5B%5D=pen"

        resp =
          ~s({"id":"fxq_1","rates":{"brl":{"rate_details":{"base_rate":0.20005}},"clp":{"rate_details":{"base_rate":0.00105}},"pen":{"rate_details":{"base_rate":0.275}}}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end

      assert {:ok, rates} =
               StripeQuotes.fetch_usd_base_rates(
                 ["BRL", "CLP", "PEN"],
                 secret_key: "sk_test_fx",
                 stripe_version: "2026-09-30.preview",
                 req_options: [plug: plug]
               )

      assert %Decimal{} = rates["BRL"]
      assert Decimal.equal?(rates["BRL"], Decimal.new("0.20005"))
      assert Decimal.equal?(rates["CLP"], Decimal.new("0.00105"))
      assert Decimal.equal?(rates["PEN"], Decimal.new("0.275"))
    end
  end

  describe "FX cache hit, 1h soft refresh, 24h hard expiry fail-closed, and 30s backoff" do
    @tag clock: ~U[2026-11-20 00:00:00.000000Z]
    test "serves cache hits, soft-refreshes after 1h, and fails closed after 24h while keeping EC available" do
      agent =
        start_fx_agent(fn _currencies, call ->
          case call do
            1 ->
              {:ok,
               %{
                 "BRL" => Decimal.new("0.20"),
                 "CLP" => Decimal.new("0.001"),
                 "PEN" => Decimal.new("0.28")
               }}

            2 ->
              {:ok,
               %{
                 "BRL" => Decimal.new("0.21"),
                 "CLP" => Decimal.new("0.0011"),
                 "PEN" => Decimal.new("0.29")
               }}

            _ ->
              {:error, :upstream_down}
          end
        end)

      put_m2square_config()
      put_console_settings(all_enabled_console_settings())

      # 1. Cold fetch populates cache for PE/BR/CL; EC uses usd_peg.
      countries = Config.available_countries()
      assert Enum.map(countries, & &1["code"]) == ["PE", "EC", "BR", "CL"]
      assert fx_calls(agent) == 1

      br_entry = Enum.find(countries, &(&1["code"] == "BR"))
      assert br_entry["fx_rate"] == "0.20"
      assert br_entry["sample_min_amount"] == "37500.00"
      assert br_entry["fx_source"] == "stripe_fx_quotes"

      ec_entry = Enum.find(countries, &(&1["code"] == "EC"))
      assert ec_entry["display_currency"] == "USD"
      assert ec_entry["currency"] == "ECS"
      assert ec_entry["max_seats"] == 39
      assert ec_entry["sample_min_amount"] == "7619.05"
      assert ec_entry["fx_source"] == "usd_peg"

      # 2. Cache hit within 1h does not call provider again.
      SystemsClock.advance(30 * 60 * 1_000)
      assert {:ok, br_cfg} = Config.country("BR")
      assert {:ok, %{rate: rate}} = FX.rate_for_country(br_cfg)
      assert Decimal.equal?(rate, Decimal.new("0.20"))
      assert fx_calls(agent) == 1

      # 3. Past 1h soft TTL: returns cached rate immediately and triggers async single-flight refresh.
      SystemsClock.advance(31 * 60 * 1_000)
      assert {:ok, %{rate: stale_rate}} = FX.rate_for_country(br_cfg)
      assert Decimal.equal?(stale_rate, Decimal.new("0.20"))
      SystemsClock.settle(until: fn -> fx_calls(agent) == 2 end)

      assert fx_calls(agent) == 2
      assert {:ok, %{rate: refreshed_rate}} = FX.rate_for_country(br_cfg)
      assert Decimal.equal?(refreshed_rate, Decimal.new("0.21"))

      # 4. Past 24h hard TTL when provider is failing: PE/BR/CL fail closed, EC stays available!
      SystemsClock.advance(25 * 60 * 60 * 1_000)
      assert {:error, :fx_rate_unavailable} = FX.rate_for_country(br_cfg)
      assert fx_calls(agent) == 3

      available_after_expiry = Config.available_countries()
      assert Enum.map(available_after_expiry, & &1["code"]) == ["EC"]

      # Still within 30s failure backoff: provider was NOT called again for PE/BR/CL.
      assert fx_calls(agent) == 3

      # After 30s failure backoff expires, a new lookup attempts the provider again.
      SystemsClock.advance(31_000)
      assert {:error, :fx_rate_unavailable} = FX.rate_for_country(br_cfg)
      assert fx_calls(agent) == 4
    end

    @tag clock: ~U[2026-11-20 00:00:00.000000Z]
    test "23h59m cached FX is rejected for 1-hour quote window on both primary and concurrent waiter paths" do
      test_pid = self()

      agent =
        start_fx_agent(fn _currencies, call ->
          case call do
            1 ->
              {:ok,
               %{
                 "BRL" => Decimal.new("0.20"),
                 "CLP" => Decimal.new("0.001"),
                 "PEN" => Decimal.new("0.28")
               }}

            2 ->
              send(test_pid, {:refresh_started, self()})

              receive do
                :fail_refresh -> {:error, :upstream_down}
              end

            _ ->
              {:error, :upstream_down}
          end
        end)

      put_m2square_config()
      put_console_settings(all_enabled_console_settings())

      # Populate cache at T=0
      assert {:ok, %{rate: r0}} = FX.rate_for_currency("PEN")
      assert Decimal.equal?(r0, Decimal.new("0.28"))
      assert fx_calls(agent) == 1

      # Advance to 23h59m: still valid for 0ms remaining, but NOT valid for 1h (3_600_000ms) remaining!
      SystemsClock.advance(23 * 3_600_000 + 59 * 60_000)

      # Two concurrent callers requesting 1h remaining must BOTH await refresh (waiter must NOT short-circuit on 23h59m cache!)
      t1 = Task.async(fn -> FX.rate_for_currency("PEN", min_remaining_ms: 3_600_000) end)
      t2 = Task.async(fn -> FX.rate_for_currency("PEN", min_remaining_ms: 3_600_000) end)

      leader_pid =
        receive do
          {:refresh_started, pid} -> pid
        end

      SystemsClock.settle(
        until: fn ->
          length(
            SystemsRuntime.ETS.match_object(
              BridgeForTeams.Cache,
              {{{:m2square_fx, :waiter}, :_, :_}, :_}
            )
          ) == 1
        end
      )

      send(leader_pid, :fail_refresh)

      assert {:error, :fx_rate_unavailable} = Task.await(t1, :infinity)
      assert {:error, :fx_rate_unavailable} = Task.await(t2, :infinity)
      assert fx_calls(agent) == 2

      # available_countries/0 rejects non-USD (23h59m < 1h remaining) while EC stays available!
      assert Enum.map(Config.available_countries(), & &1["code"]) == ["EC"]
    end

    @tag clock: ~U[2026-11-20 00:00:00.000000Z]
    test "fx_hard_ttl_ms configured above 24h (48h) is clamped to 24h hard cap while EC stays available" do
      agent =
        start_fx_agent(fn _currencies, call ->
          case call do
            1 ->
              {:ok,
               %{
                 "BRL" => Decimal.new("0.20"),
                 "CLP" => Decimal.new("0.001"),
                 "PEN" => Decimal.new("0.28")
               }}

            _ ->
              {:error, :upstream_down}
          end
        end)

      put_m2square_config(%{fx_hard_ttl_ms: 172_800_000})
      put_console_settings(all_enabled_console_settings())

      assert Config.get().fx_hard_ttl_ms == 86_400_000
      assert {:ok, _} = FX.rate_for_currency("PEN")
      assert fx_calls(agent) == 1

      # Advance 25h (90_000_000 ms): must reject stale cache despite 48h config, while EC stays available
      SystemsClock.advance(90_000_000)

      for ccy <- ["PEN", "BRL", "CLP"] do
        assert {:error, :fx_rate_unavailable} = FX.rate_for_currency(ccy)
      end

      assert Enum.map(Config.available_countries(), & &1["code"]) == ["EC"]
    end

    @tag clock: ~U[2026-11-20 12:00:00Z]
    test "concurrent cold-cache lookups coalesce to a single upstream fetch" do
      test_pid = self()

      agent =
        start_fx_agent(fn _currencies, _call_no ->
          send(test_pid, {:fx_fetch_started, self()})

          receive do
            :release_fx_fetch ->
              {:ok,
               %{
                 "BRL" => Decimal.new("0.20"),
                 "PEN" => Decimal.new("0.27"),
                 "CLP" => Decimal.new("0.00105")
               }}
          end
        end)

      put_m2square_config()

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> FX.rate_for_currency("BRL") end)
        end

      leader_pid =
        receive do
          {:fx_fetch_started, pid} -> pid
        end

      SystemsClock.settle(
        until: fn ->
          length(
            SystemsRuntime.ETS.match_object(
              BridgeForTeams.Cache,
              {{{:m2square_fx, :waiter}, :_, :_}, :_}
            )
          ) == 4
        end
      )

      send(leader_pid, :release_fx_fetch)

      results = Enum.map(tasks, &Task.await(&1, :infinity))
      assert fx_calls(agent) == 1

      for result <- results do
        assert {:ok, %{rate: rate, source: "stripe_fx_quotes"}} = result
        assert Decimal.equal?(rate, Decimal.new("0.20"))
      end
    end
  end
end
