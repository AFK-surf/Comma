defmodule BillingCommerce.ProviderCustomersTest do
  use ExUnit.Case, async: false

  alias BillingCommerce.ProviderCustomers

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    :ok
  end

  test "binds and reads provider customer by billing account provider context" do
    attrs = customer_attrs("example-ba-wsp-customer", "cus_customer_1")

    assert {:ok, customer} = ProviderCustomers.bind_customer(attrs)
    assert customer.billing_account_id == "example-ba-wsp-customer"
    assert customer.provider == "stripe"
    assert customer.provider_context == "default"
    assert customer.provider_customer_id == "cus_customer_1"
    assert customer.metadata["source"] == "test"

    assert {:ok, fetched} =
             ProviderCustomers.get_active_customer(%{
               billing_account_id: "example-ba-wsp-customer",
               provider: "stripe"
             })

    assert fetched.id == customer.id
  end

  test "does not allow one provider customer id to bind to a different billing account" do
    assert {:ok, _customer} =
             ProviderCustomers.bind_customer(customer_attrs("example-ba-wsp-first", "cus_shared"))

    assert {:error, :provider_customer_already_bound} =
             ProviderCustomers.bind_customer(customer_attrs("example-ba-wsp-second", "cus_shared"))
  end

  defp customer_attrs(account_id, customer_id) do
    %{
      billing_account_id: account_id,
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: String.replace_prefix(account_id, "example-ba-", ""),
      provider: "stripe",
      provider_customer_id: customer_id,
      billing_email: "billing@example.com",
      display_name: "Billing",
      source_type: "test",
      metadata: %{"source" => "test"}
    }
  end
end
