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

  test "missing configuration returns an actionable error" do
    Application.delete_env(:billing_stripe, :portal_configuration_id)

    assert {:error, :stripe_portal_not_configured} =
             BillingStripe.create_customer_portal(%{
               billing_account_id: "ba_1",
               customer_id: "cus_1",
               return_url: "https://comma.test/billing"
             })
  end

  defp restore_env(key, nil), do: Application.delete_env(:billing_stripe, key)
  defp restore_env(key, value), do: Application.put_env(:billing_stripe, key, value)
end
