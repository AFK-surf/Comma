defmodule BridgeForTeams.M2square.PricingTest do
  use SystemsClock.Case, async: true

  alias BridgeForTeams.M2square.Config
  alias BridgeForTeams.M2square.Pricing

  defp country!(code) do
    {:ok, cfg} = Config.country(code)
    cfg
  end

  describe "quote_order/4 exact Decimal vectors" do
    test "BRL r=0.20, 30 seats, 4% fee -> 37500.00" do
      br = country!("BR")

      assert {:ok, quote} = Pricing.quote_order(br, 30, "0.20", "0")
      assert quote.seats == 30
      assert quote.usd_net_minor == 720_000
      assert quote.usd_net == "7200.00"
      assert quote.formatted_amount == "37500.00"
      assert Decimal.equal?(quote.local_amount, Decimal.new("37500.00"))
      assert quote.fee_rate == "0.04"
      assert quote.fx_rate == "0.20"
      assert quote.markup_rate == "0"
    end

    test "BRL r=0.25005, 30 seats, 4% fee -> 29994.02 (auto-steps past 29994.01 1-cent shortfall)" do
      br = country!("BR")

      assert {:ok, quote} = Pricing.quote_order(br, 30, "0.25005", "0")
      assert quote.formatted_amount == "29994.02"

      # Verify why 29994.01 is insufficient under 2-decimal ceiling fee rule:
      # fee(29994.01) = ceil(29994.01 * 0.04, 2) = ceil(1199.7604, 2) = 1199.77
      # net(29994.01) = 28794.24 -> 28794.24 * 0.25005 = 7199.999712 < 7200
      short_g = Decimal.new("29994.01")
      short_fee = Decimal.mult(short_g, Decimal.new("0.04")) |> Decimal.round(2, :ceiling)
      assert Decimal.equal?(short_fee, Decimal.new("1199.77"))

      assert Decimal.lt?(
               Decimal.mult(Decimal.sub(short_g, short_fee), Decimal.new("0.25005")),
               Decimal.new("7200")
             )

      # At 29994.02, net * 0.25005 = 28794.25 * 0.25005 = 7200.0022125 >= 7200.
      ok_g = quote.local_amount
      ok_fee = Decimal.mult(ok_g, Decimal.new("0.04")) |> Decimal.round(2, :ceiling)

      assert Decimal.compare(
               Decimal.mult(Decimal.sub(ok_g, ok_fee), Decimal.new("0.25005")),
               Decimal.new("7200")
             ) != :lt
    end

    test "CLP 4% fee, local_target=7200000.50 -> 7500001 (scale 0 gross, scale 2 ceiling fee)" do
      assert {:ok, gross, formatted} = Pricing.gross_for_local_target("7200000.50", "0.04", 0)
      assert formatted == "7500001"
      assert Decimal.equal?(gross, Decimal.new("7500001"))

      # Verify 7500000 fails while 7500001 satisfies G - ceil(G * 0.04, 2) >= 7200000.50.
      fee_7500000 =
        Decimal.mult(Decimal.new(7_500_000), Decimal.new("0.04")) |> Decimal.round(2, :ceiling)

      assert Decimal.lt?(
               Decimal.sub(Decimal.new(7_500_000), fee_7500000),
               Decimal.new("7200000.50")
             )

      fee_7500001 = Decimal.mult(gross, Decimal.new("0.04")) |> Decimal.round(2, :ceiling)
      assert Decimal.equal?(fee_7500001, Decimal.new("300000.04"))
      assert Decimal.compare(Decimal.sub(gross, fee_7500001), Decimal.new("7200000.50")) != :lt

      # Also verify CLP quote_order formats with zero decimal places.
      cl = country!("CL")
      assert {:ok, cl_quote} = Pricing.quote_order(cl, 30, "0.001", "0")
      assert cl_quote.formatted_amount == "7500000"
      refute String.contains?(cl_quote.formatted_amount, ".")
    end

    test "EC 5.5% fee: 39 seats -> 9904.77 (valid), 40 seats -> out of bounds, max_seats -> 39" do
      ec = country!("EC")

      # EC forces rate=1 and markup=0 regardless of passed base_rate/markup_rate.
      assert {:ok, q39} = Pricing.quote_order(ec, 39, "0.50", "0.05")
      assert q39.formatted_amount == "9904.77"
      assert q39.fx_rate == "1"
      assert q39.markup_rate == "0"
      assert q39.usd_net == "9360.00"
      assert q39.usd_net_minor == 936_000

      assert {:error, :amount_out_of_bounds} = Pricing.quote_order(ec, 40, "1", "0")
      assert {:ok, 39} = Pricing.max_seats(ec, "1", "0")
    end

    test "rejects seats outside 30..48 and invalid rates" do
      br = country!("BR")

      assert {:error, :invalid_seats} = Pricing.quote_order(br, 29, "0.20", "0")
      assert {:error, :invalid_seats} = Pricing.quote_order(br, 49, "0.20", "0")
      assert {:error, :invalid_seats} = Pricing.quote_order(br, 100, "0.20", "0")
      assert {:error, :invalid_seats} = Pricing.quote_order(br, 0, "0.20", "0")

      assert {:error, :invalid_rate} = Pricing.quote_order(br, 30, "0", "0")
      assert {:error, :invalid_rate} = Pricing.quote_order(br, 30, "-0.20", "0")
      assert {:error, :invalid_rate} = Pricing.quote_order(br, 30, "not-a-number", "0")
      assert {:error, :invalid_rate} = Pricing.quote_order(br, 30, "0.20", "-0.01")
    end

    test "max_seats returns error when even 30 seats exceeds country max_amount" do
      br = country!("BR")
      # At r = 0.10, 30 seats = 7200 / 0.10 / 0.96 = 75000 BRL > 50000 BRL max_amount.
      assert {:error, :country_limit_below_minimum_seats} = Pricing.max_seats(br, "0.10", "0")
    end
  end
end
