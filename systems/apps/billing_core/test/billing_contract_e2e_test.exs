defmodule BillingContractE2ETest do
  use ExUnit.Case, async: false

  alias BillingCore.{Charges, FeeControl, LLMMetering, ResourceMetering, State}
  alias BillingCore.Metering.PricingBackfill
  alias SalixAnalytics.LLMCallEvent

  @now ~U[2026-06-17 12:00:00Z]

  defmodule TypedSinkFake do
    def enqueue(rows, _opts), do: insert(rows) |> then(fn _ -> :ok end)

    def insert(rows) do
      send(Application.fetch_env!(:billing_core, :contract_test_pid), {:typed_rows, rows})
      {:ok, length(rows)}
    end
  end

  setup do
    previous = Application.get_env(:billing_core, :contract_test_pid)
    Application.put_env(:billing_core, :contract_test_pid, self())

    on_exit(fn ->
      if previous do
        Application.put_env(:billing_core, :contract_test_pid, previous)
      else
        Application.delete_env(:billing_core, :contract_test_pid)
      end
    end)

    :ok
  end

  test "Cloudflare profile prices retain the old SKU and add the standard-1 rate" do
    start_supervised!(BillingCore.Repo)

    rows =
      BillingCore.Repo.query!(
        "SELECT sku, usd_micros_per_unit FROM meter_pricing_catalog " <>
          "WHERE resource_kind = 'vm' AND provider = 'cloudflare' " <>
          "AND sku IN ('runtime-minimum', 'runtime-standard-1')"
      ).rows

    prices = Map.new(rows, fn [sku, rate] -> {sku, rate} end)
    assert map_size(prices) == 2
    assert Decimal.eq?(prices["runtime-minimum"], Decimal.new("35.84"))
    assert Decimal.eq?(prices["runtime-standard-1"], Decimal.new("20.56"))
  end

  @tag :byok
  test "Comma tenant credentials preserve usage without model admission or ledger charges" do
    state =
      State.new(
        pricing_catalog: [price(:llm, :input, "openai", "gpt-x", 2)],
        grants: [grant("comma_ba", 100)]
      )

    fact = %{
      state: state,
      typed_sink: TypedSinkFake,
      billing_context: owner("comma", "comma_ba", "agent_round"),
      source_key: "byok:1",
      provider: "openai",
      model: "gpt-x",
      credential_scope: "tenant",
      metered_at: @now,
      usage: %{prompt_tokens: 10}
    }

    assert :ok = LLMMetering.before_llm_call(fact)
    assert :ok = deliver_llm(fact)

    assert_receive {:typed_rows,
                    [
                      %{
                        "charge_status" => "not_billable",
                        "prompt_tokens" => 10,
                        "billing_account_id" => "comma_ba"
                      }
                    ]}

    assert {:ok, charge, charged_state} =
             deliver_llm(%{
               fact
               | credential_scope: "platform",
                 source_key: "platform:1"
             })

    assert charge.charged_credits == 20
    assert remaining(charged_state.grants, "comma_ba") == 80

    assert {:ok, bridge_charge, _} =
             deliver_llm(%{
               fact
               | billing_context: owner("bridge", "comma_ba", "agent_round"),
                 source_key: "bridge-private:1"
             })

    assert bridge_charge.charged_credits == 20
  end

  test "Comma and Bridge LLM metering writes typed rows then decrements ledger" do
    state =
      State.new(
        pricing_catalog: [price(:llm, :input, "openai", "gpt-x", 2)],
        grants: [grant("comma_ba", 100), grant("bridge_ba", 100)]
      )

    {comma_charge, state} =
      meter_llm(state, owner("comma", "comma_ba", "conversation_send"), "comma:llm:1")

    {bridge_charge, state} =
      meter_llm(state, owner("bridge", "bridge_ba", "direct_deliver"), "bridge:llm:1")

    assert comma_charge.charged_credits == 20
    assert bridge_charge.charged_credits == 20
    assert remaining(state.grants, "comma_ba") == 80
    assert remaining(state.grants, "bridge_ba") == 80

    assert_receive {:typed_rows,
                    [
                      %{
                        "source" => "salix_agent.llm",
                        "source_key" => "comma:llm:1",
                        "entrypoint" => "conversation_send",
                        "billing_account_id" => "comma_ba",
                        "prompt_tokens" => 10
                      }
                    ]}

    assert_receive {:typed_rows,
                    [
                      %{
                        "source" => "salix_agent.llm",
                        "source_key" => "bridge:llm:1",
                        "entrypoint" => "direct_deliver",
                        "billing_account_id" => "bridge_ba",
                        "prompt_tokens" => 10
                      }
                    ]}
  end

  test "IM router and meeting actors keep entrypoint and actor attribution" do
    im = LLMCallEvent.build(llm_attrs(owner("bridge", "bridge_ba", "im_router"), "bridge:im:1"))

    meeting =
      LLMCallEvent.build(
        llm_attrs(owner("bridge", "bridge_ba", "meeting_runtime"), "meet:llm:1")
        |> Map.put(:actor_type, "system")
      )

    assert im["entrypoint"] == "im_router"
    assert im["product_owner_type"] == "organization"
    assert meeting["entrypoint"] == "meeting_runtime"
    assert meeting["actor_type"] == "system"
  end

  test "VM and storage contracts write typed rows and charge or pending" do
    state =
      State.new(
        pricing_catalog: [price(:vm, :runtime, "fly", "shared", 5)],
        grants: [grant("bridge_ba", 100)]
      )

    assert {:ok, vm_charge, state} =
             ResourceMetering.meter_vm_interval(%{
               state: state,
               typed_sink: TypedSinkFake,
               billing_account_id: "bridge_ba",
               source_key: "vm:1",
               provider: "fly",
               sku: "shared",
               quantity: 10,
               metered_at: @now,
               owner_snapshot: owner("bridge", "bridge_ba", "cloud_vm_sweeper")
             })

    assert vm_charge.charged_credits == 50
    assert_receive {:typed_rows, [%{"resource_kind" => "vm"}]}

    assert {:pending, pending, _state} =
             ResourceMetering.meter_storage_sample(%{
               state: state,
               typed_sink: TypedSinkFake,
               billing_account_id: "bridge_ba",
               source_key: "storage:1",
               provider: "aws",
               sku: "standard",
               quantity: 99,
               metered_at: @now,
               owner_snapshot: owner("bridge", "bridge_ba", "storage_snapshot")
             })

    assert pending.pricing_status == :missing_pricing
    assert_receive {:typed_rows, [%{"resource_kind" => "storage"}]}
  end

  test "pricing backfill and shadow fee-control contracts" do
    state = State.new(grants: [grant("ba_1", 3)])

    assert {:pending, _pending, state} =
             Charges.charge_meter_event(%{
               state: state,
               billing_account_id: "ba_1",
               source_key: "missing:1",
               provider: "aws",
               sku: "standard",
               quantity: 5,
               metered_at: @now
             })

    state = %{state | pricing_catalog: [price(:storage, :byte_second, "aws", "standard", 1)]}
    assert {:ok, %{charged_count: 1}, state} = PricingBackfill.run(%{state: state, now: @now})
    assert remaining(state.grants, "ba_1") == 0

    assert {:ok, check, _state} =
             FeeControl.check(state, %{
               billing_account_id: "ba_1",
               provider: "aws",
               sku: "standard",
               estimated_credits: 10,
               balance_snapshot: 0
             })

    assert check.allowed? == true
    assert check.would_block == true
    assert check.query_performed == false
  end

  defp meter_llm(state, owner, source_key) do
    assert {:ok, charge, state} =
             deliver_llm(%{
               state: state,
               typed_sink: TypedSinkFake,
               billing_context: owner,
               source_key: source_key,
               provider: "openai",
               model: "gpt-x",
               metered_at: @now,
               usage: %{prompt_tokens: 10}
             })

    {charge, state}
  end

  defp llm_attrs(owner, source_key) do
    %{
      source: "e2e",
      source_key: source_key,
      entrypoint: owner["entrypoint"],
      surface: owner["surface"],
      billing_account_id: owner["billing_account_id"],
      product_owner_type: owner["product_owner_type"],
      product_owner_id: owner["product_owner_id"],
      tenant_id: owner["salix_tenant_id"],
      group_id: owner["salix_group_id"],
      actor_type: "user",
      provider: "openai",
      sku: "gpt-x",
      usage: %{prompt_tokens: 10}
    }
  end

  defp owner(surface, billing_account_id, entrypoint) do
    %{
      "surface" => surface,
      "billing_account_id" => billing_account_id,
      "product_owner_type" => if(surface == "bridge", do: "organization", else: "workspace"),
      "product_owner_id" => "#{surface}_owner",
      "salix_tenant_id" => "#{surface}_tenant",
      "salix_group_id" => "#{surface}_group",
      "entrypoint" => entrypoint
    }
  end

  defp price(resource_kind, component, provider, sku, usd_micros_per_unit) do
    %{
      resource_kind: resource_kind,
      component: component,
      provider: provider,
      sku: sku,
      usd_micros_per_unit: usd_micros_per_unit,
      effective_at: @now
    }
  end

  defp grant(account_id, credits) do
    %{
      id: "grant_#{account_id}",
      billing_account_id: account_id,
      remaining_credits: credits,
      expires_at: ~U[2026-06-18 00:00:00Z]
    }
  end

  defp remaining(grants, account_id) do
    grants
    |> Enum.find(&(&1.billing_account_id == account_id))
    |> case do
      nil -> 0
      grant -> Map.get(grant, :remaining_credits, 0)
    end
  end

  # Pricing and row-projection assertions run at the delivery boundary.
  # LLMUsageSinkTest covers the production hook's asynchronous handoff.
  defp deliver_llm(fact), do: LLMMetering.deliver(LLMMetering.usage_row(fact), fact)
end
