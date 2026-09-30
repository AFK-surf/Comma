defmodule BillingCore.VoiceMeteringTest do
  use ExUnit.Case, async: false

  alias BillingCore.VoiceMetering

  defmodule Repo do
    def transaction(fun) do
      try do
        {:ok, fun.()}
      catch
        {:rollback, reason} -> {:error, reason}
      end
    end

    def rollback(reason), do: throw({:rollback, reason})
  end

  # No voice pricing rows exist, so the engine stores the charge as pending.
  defmodule UnpricedSQL do
    def query!(_repo, query, params, _opts \\ []) do
      send(Application.fetch_env!(:billing_core, :voice_metering_test_pid), {:sql, query, params})

      cond do
        query =~ "INSERT INTO billing_accounts" -> %{rows: [[List.first(params)]], num_rows: 1}
        query =~ "SELECT surface" -> %{rows: [], num_rows: 0}
        query =~ "FROM billing_accounts" -> %{rows: [["active"]], num_rows: 1}
        true -> %{rows: [], num_rows: 0}
      end
    end
  end

  setup do
    Application.put_env(:billing_core, :voice_metering_test_pid, self())
    on_exit(fn -> Application.delete_env(:billing_core, :voice_metering_test_pid) end)
    :ok
  end

  defp call(overrides) do
    Map.merge(
      %{
        repo: Repo,
        sql_runner: UnpricedSQL,
        source_key: "voice:twilio:CA123",
        group_id: "grp_1",
        tenant_id: "ten_1",
        provider: "openai",
        sku: "gpt-live-1",
        carrier: "twilio",
        owner_snapshot: %{
          "billing_account_id" => "ba_1",
          "surface" => "comma",
          "product_owner_type" => "workspace",
          "product_owner_id" => "ws_1"
        },
        components: [
          %{component: :model_seconds, meter_unit: :second, quantity: 128},
          %{component: :carrier_seconds, meter_unit: :second, quantity: 131}
        ],
        metered_at: ~U[2026-09-25 10:00:00Z]
      },
      overrides
    )
  end

  test "an unpriced call is stored as a pending voice charge keyed by carrier call ID" do
    assert {:pending, %{source_key: "voice:twilio:CA123", status: "pending"}} =
             VoiceMetering.charge(call(%{}))

    queries = collect()

    assert {_, ["voice", "openai", "gpt-live-1", "model_seconds", _]} =
             Enum.find(queries, fn {query, _} -> query =~ "FROM meter_pricing_catalog" end)

    {_, [_id, "ba_1", "voice:twilio:CA123", "voice", "openai", "gpt-live-1", snapshot | _]} =
      Enum.find(queries, fn {query, _} -> query =~ "INSERT INTO pending_meter_charges" end)

    snapshot = Jason.decode!(snapshot)
    assert snapshot["resource_kind"] == "voice"

    assert snapshot["meter_components"] == [
             %{"component" => "model_seconds", "meter_unit" => "second", "quantity" => 128},
             %{"component" => "carrier_seconds", "meter_unit" => "second", "quantity" => 131}
           ]
  end

  test "a Group without a billing owner is not charged" do
    assert {:unattributed, %{source_key: "voice:twilio:CA123"}} =
             VoiceMetering.charge(call(%{owner_snapshot: nil}))

    assert collect() == []
  end

  test "a call with no billable seconds is not charged" do
    assert :ok =
             VoiceMetering.charge(
               call(%{
                 components: [%{component: :model_seconds, meter_unit: :second, quantity: 0}]
               })
             )

    assert collect() == []
  end

  defp collect(acc \\ []) do
    receive do
      {:sql, query, params} -> collect([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
