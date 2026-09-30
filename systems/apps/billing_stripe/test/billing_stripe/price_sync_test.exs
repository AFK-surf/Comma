defmodule BillingStripe.PriceSyncTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    prev_secret = Application.get_env(:billing_stripe, :secret_key)
    prev_api = Application.get_env(:billing_stripe, :stripe_api)

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "DELETE FROM billing_provider_prices WHERE provider_lookup_key LIKE 'test_%'",
      []
    )

    Application.put_env(:billing_stripe, :secret_key, "sk_test_secret")
    Application.put_env(:billing_stripe, :stripe_api, BillingStripe.TestAPI)

    start_supervised!(%{
      id: BillingStripe.TestAPI.Recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: BillingStripe.TestAPI.Recorder]]}
    })

    on_exit(fn ->
      restore_env(:secret_key, prev_secret)
      restore_env(:stripe_api, prev_api)
    end)

    :ok
  end

  test "syncs a catalog to local package versions, creates missing Stripe prices, and stores mappings" do
    assert {:ok, summary} = BillingStripe.sync_prices(catalog())

    assert length(summary.local.versions) == 2
    assert length(summary.provider_prices) == 2

    calls = stripe_calls()

    assert Enum.count(calls, &match?({:list_prices, _, _}, &1)) == 2
    assert Enum.count(calls, &match?({:product, _, _}, &1)) == 2
    assert Enum.count(calls, &match?({:price, _, _}, &1)) == 2

    {:product, value_product, value_product_opts} =
      Enum.find(calls, fn
        {:product, %{metadata: %{provider_lookup_key: "test_value_v1"}}, _opts} -> true
        _ -> false
      end)

    assert value_product.name == "Test Value"
    assert value_product_opts[:idempotency_key] == "billing:stripe:product:test_value_v1"

    {:price, value_price, _opts} =
      Enum.find(calls, fn
        {:price, %{lookup_key: "test_value_v1"}, _opts} -> true
        _ -> false
      end)

    assert value_price.unit_amount == 2_000
    assert value_price.currency == "usd"
    assert value_price.nickname == "Test Value"
    assert value_price.recurring == %{interval: "month"}

    {:price, _value_price, value_price_opts} =
      Enum.find(calls, fn
        {:price, %{lookup_key: "test_value_v1"}, _opts} -> true
        _ -> false
      end)

    assert value_price_opts[:idempotency_key] == "billing:stripe:price:test_value_v1"

    assert {:ok, plan} =
             BillingCommerce.get_provider_plan(%{
               surface: "comma",
               provider: "stripe",
               provider_lookup_key: "test_value_v1"
             })

    assert plan.provider_price_id =~ "price_"
    assert plan.amount_minor == 2_000
  end

  test "fails fast when an existing Stripe lookup key points at incompatible terms" do
    Application.put_env(:billing_stripe, :stripe_api, __MODULE__.DriftAPI)

    assert {:error, {:provider_price_drift, "test_value_v1", :amount}} =
             BillingStripe.sync_prices(catalog())
  end

  test "release sync keeps local catalog when Stripe credentials are not configured" do
    Application.delete_env(:billing_stripe, :secret_key)

    assert [
             %{
               local: local,
               provider: "stripe",
               provider_prices: [],
               provider_sync: :skipped,
               reason: :stripe_not_configured
             }
           ] = BillingStripe.Release.sync_catalog(catalog())

    assert length(local.packages) == 2
    assert length(local.versions) == 2
    assert stripe_calls() == []
  end

  test "release provider sync fails closed when Stripe credentials are required" do
    Application.delete_env(:billing_stripe, :secret_key)

    assert_raise RuntimeError, ~r/:stripe_not_configured/, fn ->
      BillingStripe.Release.sync_catalog(catalog(), require_provider: true)
    end
  end

  test "release provider sync retries transient Stripe errors" do
    start_supervised!(%{
      id: __MODULE__.TransientAPI.Counter,
      start: {Agent, :start_link, [fn -> 0 end, [name: __MODULE__.TransientAPI.Counter]]}
    })

    Application.put_env(:billing_stripe, :stripe_api, __MODULE__.TransientAPI)

    assert [%{provider_prices: provider_prices}] =
             BillingStripe.Release.sync_catalog(catalog(),
               require_provider: true,
               max_attempts: 3
             )

    assert length(provider_prices) == 2
    assert Agent.get(__MODULE__.TransientAPI.Counter, & &1) >= 3
  end

  test "dry run plans first rollout without creating products or prices" do
    assert {:ok, summary} = BillingStripe.sync_prices(catalog(), dry_run: true)

    assert Enum.map(summary.provider_plan, & &1.action) == [:create, :create]
    assert summary.provider_prices == []

    calls = stripe_calls()
    assert Enum.any?(calls, &match?({:list_prices, _, _}, &1))
    refute Enum.any?(calls, &match?({:product, _, _}, &1))
    refute Enum.any?(calls, &match?({:price, _, _}, &1))
  end

  test "dry run validates provider state without creating products or prices" do
    Application.put_env(:billing_stripe, :stripe_api, __MODULE__.ExistingPriceAPI)

    assert {:ok, summary} = BillingStripe.sync_prices(catalog(), dry_run: true)

    assert Enum.map(summary.provider_plan, & &1.action) == [:reuse, :reuse]

    assert Enum.map(summary.provider_prices, & &1.provider_lookup_key) == [
             "test_value_v1",
             "test_addon_v1"
           ]

    calls = stripe_calls()
    assert Enum.any?(calls, &match?({:list_prices, _, _}, &1))
    refute Enum.any?(calls, &match?({:product, _, _}, &1))
    refute Enum.any?(calls, &match?({:price, _, _}, &1))
  end

  test "dry run can require persisted local mappings for post-mutation verification" do
    Application.put_env(:billing_stripe, :stripe_api, __MODULE__.ExistingPriceAPI)

    assert {:error, {:provider_price_mapping_missing, "test_value_v1"}} =
             BillingStripe.sync_prices(catalog(),
               dry_run: true,
               verify_local_mapping: true
             )
  end

  defmodule DriftAPI do
    @behaviour BillingStripe.API

    def list_prices(%{lookup_keys: ["test_value_v1"]}, _opts) do
      {:ok,
       %{
         data: [
           %{
             id: "price_drift",
             lookup_key: "test_value_v1",
             currency: "usd",
             unit_amount: 1,
             type: "recurring",
             recurring: %{interval: "month"},
             product: "prod_drift"
           }
         ]
       }}
    end

    def list_prices(_params, _opts), do: {:ok, %{data: []}}
    def create_product(_params, _opts), do: {:ok, %{id: "prod_unused"}}
    def create_price(_params, _opts), do: {:ok, %{id: "price_unused"}}
    def create_customer(_params, _opts), do: {:error, :unused}
    def create_checkout_session(_params, _opts), do: {:error, :unused}
    def create_customer_portal(_params, _opts), do: {:error, :unused}
    def retrieve_subscription(_subscription_id, _params, _opts), do: {:error, :unused}
    def retrieve_payment_intent(_payment_intent_id, _params, _opts), do: {:error, :unused}

    def construct_webhook_event(_payload, _signature, _secret, _tolerance, _opts),
      do: {:error, :unused}
  end

  defmodule ExistingPriceAPI do
    @behaviour BillingStripe.API

    def list_prices(%{lookup_keys: [lookup_key]}, _opts) do
      Agent.update(
        BillingStripe.TestAPI.Recorder,
        &[
          {:list_prices, %{lookup_keys: [lookup_key]}, []} | &1
        ]
      )

      amount = if lookup_key == "test_value_v1", do: 2_000, else: 499
      recurring = if lookup_key == "test_value_v1", do: %{interval: "month"}, else: nil

      {:ok,
       %{
         data: [
           %{
             id: "price_existing_" <> lookup_key,
             lookup_key: lookup_key,
             currency: "usd",
             unit_amount: amount,
             type: if(recurring, do: "recurring", else: "one_time"),
             recurring: recurring,
             product: "prod_existing_" <> lookup_key
           }
         ]
       }}
    end

    def create_product(_params, _opts), do: {:error, :unexpected_mutation}
    def create_price(_params, _opts), do: {:error, :unexpected_mutation}
    def create_customer(_params, _opts), do: {:error, :unused}
    def create_checkout_session(_params, _opts), do: {:error, :unused}
    def create_customer_portal(_params, _opts), do: {:error, :unused}
    def retrieve_subscription(_subscription_id, _params, _opts), do: {:error, :unused}
    def retrieve_payment_intent(_payment_intent_id, _params, _opts), do: {:error, :unused}

    def construct_webhook_event(_payload, _signature, _secret, _tolerance, _opts),
      do: {:error, :unused}
  end

  defmodule TransientAPI do
    @behaviour BillingStripe.API

    def list_prices(params, opts) do
      attempts =
        Agent.get_and_update(__MODULE__.Counter, fn count ->
          {count, count + 1}
        end)

      if attempts < 2 do
        {:error,
         %Stripe.Error{
           source: :stripe,
           code: :rate_limit_error,
           extra: %{http_status: 429},
           message: "rate limited"
         }}
      else
        BillingStripe.TestAPI.list_prices(params, opts)
      end
    end

    def create_product(params, opts), do: BillingStripe.TestAPI.create_product(params, opts)
    def create_price(params, opts), do: BillingStripe.TestAPI.create_price(params, opts)
    def create_customer(params, opts), do: BillingStripe.TestAPI.create_customer(params, opts)

    def create_checkout_session(params, opts),
      do: BillingStripe.TestAPI.create_checkout_session(params, opts)

    def create_customer_portal(params, opts),
      do: BillingStripe.TestAPI.create_customer_portal(params, opts)

    def retrieve_subscription(subscription_id, params, opts),
      do: BillingStripe.TestAPI.retrieve_subscription(subscription_id, params, opts)

    def retrieve_payment_intent(payment_intent_id, params, opts),
      do: BillingStripe.TestAPI.retrieve_payment_intent(payment_intent_id, params, opts)

    def construct_webhook_event(payload, signature, secret, tolerance, opts),
      do:
        BillingStripe.TestAPI.construct_webhook_event(payload, signature, secret, tolerance, opts)
  end

  defp stripe_calls do
    BillingStripe.TestAPI.Recorder
    |> Agent.get(&Enum.reverse/1)
  end

  defp catalog do
    %{
      name: "stripe_price_sync_test",
      provider: "stripe",
      packages: [
        package("test_value", "Test Value", "Test monthly plan."),
        package("test_addon", "Test Add-On", "Test one-time credit pack.")
      ],
      versions: [
        version(
          "test_value",
          "Test Value",
          "test_value_v1",
          "subscription",
          "month",
          20_000_000,
          2_000
        ),
        version("test_addon", "Test Add-On", "test_addon_v1", "one_time", "once", 4_000_000, 499)
      ]
    }
  end

  defp package(code, name, description) do
    %{
      code: code,
      surface: "comma",
      name: name,
      status: "active",
      metadata: %{"description" => description}
    }
  end

  defp version(package_code, name, lookup_key, kind, billing_period, credits, amount_minor) do
    %{
      package_code: package_code,
      name: name,
      version: "2026-06",
      surface: "comma",
      kind: kind,
      billing_period: billing_period,
      grant_credits: credits,
      grant_period: "current_period",
      currency: "usd",
      amount_minor: amount_minor,
      usage_policy: %{
        "llm_models" => %{"mode" => "unrestricted", "models" => []},
        "stripe_lookup_key" => lookup_key,
        "description" => "#{name} test catalog entry."
      },
      effective_at: ~U[2026-06-01 00:00:00Z],
      status: "active",
      provider_lookup_key: lookup_key
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:billing_stripe, key)
  defp restore_env(key, value), do: Application.put_env(:billing_stripe, key, value)
end
