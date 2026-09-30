defmodule BillingStripe.PortalTest do
  use ExUnit.Case, async: false

  setup do
    previous_secret = Application.get_env(:billing_stripe, :secret_key)
    previous_api = Application.get_env(:billing_stripe, :stripe_api)
    previous_configuration = Application.get_env(:billing_stripe, :portal_configuration_id)
    Application.put_env(:billing_stripe, :portal_configuration_id, "bpc_comma_staging")
    Application.put_env(:billing_stripe, :secret_key, "sk_test_secret")
    Application.put_env(:billing_stripe, :stripe_api, BillingStripe.TestAPI)

    start_supervised!(%{
      id: BillingStripe.TestAPI.Recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: BillingStripe.TestAPI.Recorder]]}
    })

    on_exit(fn ->
      restore_env(:secret_key, previous_secret)
      restore_env(:stripe_api, previous_api)
      restore_env(:portal_configuration_id, previous_configuration)
    end)

    :ok
  end

  test "creates a portal confirmation flow for an exact subscription price change" do
    assert {:ok, %{"provider" => "stripe", "url" => url}} =
             BillingStripe.create_subscription_change_portal(%{
               billing_account_id: "ba_1",
               customer_id: "cus_1",
               subscription_id: "sub_1",
               provider_price_id: "price_pro",
               return_url: "https://comma.test/billing?status=portal",
               success_url: "https://comma.test/billing?status=subscription",
               idempotency_key: "change_1"
             })

    assert String.starts_with?(url, "https://billing.stripe.test/session/")

    calls = Agent.get(BillingStripe.TestAPI.Recorder, &Enum.reverse/1)

    assert {:retrieve_subscription, "sub_1", %{expand: ["items.data.price"]}, retrieve_opts} =
             Enum.find(calls, &match?({:retrieve_subscription, _, _, _}, &1))

    assert retrieve_opts[:api_key] == "sk_test_secret"

    assert {:portal, params, opts} = Enum.find(calls, &match?({:portal, _, _}, &1))
    assert params.customer == "cus_1"
    assert params.configuration == "bpc_comma_staging"
    assert params.return_url == "https://comma.test/billing?status=portal"
    assert params.flow_data.type == "subscription_update_confirm"

    assert params.flow_data.after_completion.redirect.return_url ==
             "https://comma.test/billing?status=subscription"

    assert params.flow_data.subscription_update_confirm == %{
             subscription: "sub_1",
             items: [%{id: "si_test_current", price: "price_pro", quantity: 1}]
           }

    assert opts[:idempotency_key] == "change_1"
  end

  test "management portal uses the environment's dedicated configuration" do
    assert {:ok, _} =
             BillingStripe.create_customer_portal(%{
               billing_account_id: "ba_1",
               customer_id: "cus_1",
               return_url: "https://comma.test/billing",
               idempotency_key: "manage_1"
             })

    assert [{:portal, %{configuration: "bpc_comma_staging"}, _}] =
             Agent.get(BillingStripe.TestAPI.Recorder, & &1)
  end

  defp restore_env(key, nil), do: Application.delete_env(:billing_stripe, key)
  defp restore_env(key, value), do: Application.put_env(:billing_stripe, key, value)
end
