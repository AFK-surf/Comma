defmodule BillingStripe.SubscriptionCheckoutTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)

    attrs = %{
      billing_account_id: "ba_checkout_test",
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: "workspace_checkout_test",
      provider_price_id: "price_one"
    }

    :ok = BillingCore.Accounts.ensure_account(attrs)
    %{attrs: attrs}
  end

  test "unknown creation retries the fixed request and holds other plans", %{attrs: attrs} do
    owner = self()

    timeout = fn request ->
      send(owner, {:request, request})
      {:error, :timeout}
    end

    unused = fn _ -> flunk("no session was created") end

    assert {:error, :timeout} =
             BillingCommerce.SubscriptionCheckout.create(attrs, timeout, unused)

    assert_receive {:request, first}

    assert {:error, :subscription_checkout_pending} =
             BillingCommerce.SubscriptionCheckout.create(
               %{attrs | provider_price_id: "price_two"},
               timeout,
               unused
             )

    assert {:error, :timeout} =
             BillingCommerce.SubscriptionCheckout.create(attrs, timeout, unused)

    assert_receive {:request, second}
    assert first == second
    assert first["expires_at"] > DateTime.to_unix(DateTime.utc_now())
  end

  test "completed session holds until subscription is recorded and confirmed expiry allows a new plan",
       %{attrs: attrs} do
    create = fn _ ->
      {:ok, %{"id" => "cs_one", "url" => "https://checkout.test/one", "status" => "open"}}
    end

    assert {:ok, %{"id" => "cs_one"}} =
             BillingCommerce.SubscriptionCheckout.create(attrs, create, fn _ ->
               flunk("unused")
             end)

    complete = fn _ -> {:ok, %{"id" => "cs_one", "status" => "complete"}} end

    assert {:error, :subscription_checkout_pending} =
             BillingCommerce.SubscriptionCheckout.create(
               %{attrs | provider_price_id: "price_two"},
               create,
               complete
             )

    assert {:ok, %{"status" => "complete"}} =
             BillingCommerce.SubscriptionCheckout.create(attrs, create, complete)

    expired = fn _ -> {:ok, %{"id" => "cs_one", "status" => "expired"}} end

    assert {:error, :subscription_checkout_expired} =
             BillingCommerce.SubscriptionCheckout.create(attrs, create, expired)

    assert {:ok, _} =
             BillingCommerce.SubscriptionCheckout.create(
               %{attrs | provider_price_id: "price_two"},
               create,
               expired
             )
  end

  test "two concurrent plans cannot reserve two subscription Sessions", %{attrs: attrs} do
    account = "ba_checkout_concurrent_#{System.unique_integer([:positive])}"
    attrs = %{attrs | billing_account_id: account, product_owner_id: account}
    repo = BillingCore.Repo

    Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, fn ->
      :ok = BillingCore.Accounts.ensure_account(attrs)
    end)

    owner = self()

    try do
      first =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, fn ->
            BillingCommerce.SubscriptionCheckout.create(
              attrs,
              fn request ->
                send(owner, {:creating, request})

                receive do
                  :continue -> {:ok, %{"id" => "cs_concurrent", "status" => "open"}}
                after
                  5_000 -> {:error, :timeout}
                end
              end,
              fn _ -> flunk("unused") end
            )
          end)
        end)

      assert_receive {:creating, request}, 5_000

      second =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, fn ->
            BillingCommerce.SubscriptionCheckout.create(
              %{attrs | provider_price_id: "price_two"},
              fn _ -> flunk("second plan reached Stripe") end,
              fn _ -> flunk("unused") end
            )
          end)
        end)

      assert {:error, :subscription_checkout_pending} = Task.await(second)
      send(first.pid, :continue)
      assert {:ok, %{"id" => "cs_concurrent"}} = Task.await(first)
      assert is_binary(request["idempotency_key"])
    after
      Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, fn ->
        Ecto.Adapters.SQL.query!(
          repo,
          "DELETE FROM credit_balances WHERE billing_account_id = $1",
          [account]
        )

        Ecto.Adapters.SQL.query!(repo, "DELETE FROM billing_accounts WHERE id = $1", [account])
      end)
    end
  end
end
