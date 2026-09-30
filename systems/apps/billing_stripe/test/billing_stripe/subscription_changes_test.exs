defmodule BillingStripe.SubscriptionChangesTest do
  use ExUnit.Case, async: false
  alias BillingStripe.SubscriptionChanges

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo, sandbox: tags[:sandbox] != false)
    old = Application.get_env(:billing_stripe, :stripe_api)
    Application.put_env(:billing_stripe, :stripe_api, BillingStripe.TestAPI)

    start_supervised!(%{
      id: BillingStripe.TestAPI.Recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: BillingStripe.TestAPI.Recorder]]}
    })

    {:ok, _} = BillingStripe.sync_prices(Comma.Billing.PricingV1.catalog())
    Application.put_env(:billing_stripe, :stripe_api, __MODULE__.API)

    start_supervised!(%{
      id: __MODULE__.State,
      start:
        {Agent, :start_link,
         [
           fn -> %{calls: [], results: %{}, payment: :paid, invoices: %{}} end,
           [name: __MODULE__.State]
         ]}
    })

    on_exit(fn -> Application.put_env(:billing_stripe, :stripe_api, old) end)
    :ok
  end

  test "one downgrade target is replaced, current selection clears it, and higher selection upgrades" do
    attrs = subscription("month", "comma_max_v1")
    assert {:ok, %{effect: "downgrade_scheduled"}} = change(attrs, "comma_value_v1")
    assert future_price() == plan("comma_value_v1").provider_price_id
    assert {:ok, _} = change(attrs, "comma_pro_v1")
    assert future_price() == plan("comma_pro_v1").provider_price_id
    assert current_price() == plan("comma_max_v1").provider_price_id
    assert {:ok, %{effect: "kept_current"}} = change(attrs, "comma_max_v1")
    assert current()["schedule"] == nil
    set_price(plan("comma_pro_v1").provider_price_id)
    assert {:ok, _} = change(attrs, "comma_value_v1")
    assert {:ok, %{effect: "upgraded"}} = change(attrs, "comma_max_v1")
    assert current()["schedule"] == nil
    assert current_price() == plan("comma_max_v1").provider_price_id
  end

  test "yearly downgrade starts at next yearly renewal and rejects monthly changes" do
    attrs = subscription("year", "comma_pro_annual_v1")
    assert {:ok, %{effective_at: ends}} = change(attrs, "comma_value_annual_v1")
    assert ends == attrs.period_end

    assert List.last(current()["schedule"]["phases"])["duration"] == %{
             "interval" => "year",
             "interval_count" => 1
           }

    assert current_price() == plan("comma_pro_annual_v1").provider_price_id

    assert {:error, :subscription_billing_period_change_unavailable} =
             change(attrs, "comma_value_v1")
  end

  test "failed upgrade cancels old downgrade and resumes only its original payment" do
    attrs = subscription("month", "comma_pro_v1")
    assert {:ok, _} = change(attrs, "comma_value_v1")
    Agent.update(__MODULE__.State, &Map.put(&1, :payment, :pending))
    command = command(attrs, "comma_max_v1", "failed_upgrade")
    assert {:ok, %{effect: "payment_required"}} = SubscriptionChanges.change(command)
    assert current_price() == plan("comma_pro_v1").provider_price_id
    assert current()["schedule"] == nil
    assert {:ok, %{effect: "payment_required"}} = SubscriptionChanges.change(command)
    assert Enum.count(state().calls, &(elem(&1, 0) == :update)) == 1
    assert {:error, :subscription_payment_pending} = change(attrs, "comma_value_v1")
  end

  test "payment succeeded but response lost recovers exact invoice without a second charge" do
    attrs = subscription("month", "comma_value_v1")
    Agent.update(__MODULE__.State, &Map.put(&1, :lose_response, true))
    command = command(attrs, "comma_pro_v1", "lost_response")
    assert {:error, :timeout} = SubscriptionChanges.change(command)
    assert {:ok, %{effect: "upgraded"}} = SubscriptionChanges.change(command)
    assert Enum.count(state().calls, &(elem(&1, 0) == :update)) == 1
  end

  test "same request resumes an attached schedule after its target update failed" do
    attrs = subscription("month", "comma_pro_v1")
    Agent.update(__MODULE__.State, &Map.put(&1, :fail_schedule_update, true))
    command = command(attrs, "comma_value_v1", "interrupted_downgrade")
    assert {:error, :timeout} = SubscriptionChanges.change(command)
    assert current()["schedule"]["metadata"] == %{}

    assert {:error, :subscription_quote_changed} =
             SubscriptionChanges.change(%{command | idempotency_key: "after_reload"})

    assert future_price() == plan("comma_value_v1").provider_price_id
    assert Enum.count(state().calls, &(elem(&1, 0) == :create_schedule)) == 1

    assert {:ok, %{effect: "downgrade_scheduled"}} =
             SubscriptionChanges.change(%{command | idempotency_key: "new_confirmation"})
  end

  @tag sandbox: false
  test "a stale downgrade recovery cannot overwrite a newer operation after waiting for its owner lock" do
    repo = BillingCore.Repo
    attrs = subscription("month", "comma_pro_v1")
    Agent.update(__MODULE__.State, &Map.put(&1, :fail_schedule_update, true))

    assert {:error, :timeout} =
             SubscriptionChanges.change(command(attrs, "comma_value_v1", "old_downgrade"))

    owner = self()

    try do
      {:ok, task} =
        repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(
            repo,
            "SELECT id FROM billing_accounts WHERE id='ba_change' FOR UPDATE"
          )

          task =
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, fn ->
                [[pid]] = Ecto.Adapters.SQL.query!(repo, "SELECT pg_backend_pid()").rows
                send(owner, {:backend, pid})
                SubscriptionChanges.reconcile("sub_change", current())
              end)
            end)

          assert_receive {:backend, pid}, 5_000
          assert wait_for_owner_lock(repo, pid, 100)

          Ecto.Adapters.SQL.query!(
            repo,
            "UPDATE billing_subscriptions SET source_metadata=jsonb_set(source_metadata, '{change_operation,key}', '\"new_downgrade\"') WHERE source_id='sub_change'"
          )

          task
        end)

      assert {:error, :subscription_quote_changed} = Task.await(task, 5_000)

      [[%{"change_operation" => %{"key" => "new_downgrade"}}]] =
        Ecto.Adapters.SQL.query!(
          repo,
          "SELECT source_metadata FROM billing_subscriptions WHERE source_id='sub_change'"
        ).rows

      refute Enum.any?(state().calls, &(elem(&1, 0) == :schedule))
    after
      for table <-
            ~w(credit_grant_events credit_grants billing_subscription_cycles billing_subscriptions credit_balances billing_accounts) do
        column = if table == "billing_accounts", do: "id", else: "billing_account_id"
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM #{table} WHERE #{column}='ba_change'")
      end
    end
  end

  defp wait_for_owner_lock(_repo, _pid, 0), do: false

  defp wait_for_owner_lock(repo, pid, attempts) do
    case Ecto.Adapters.SQL.query!(
           repo,
           "SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1",
           [pid]
         ).rows do
      [["Lock"]] ->
        true

      _ ->
        receive do
        after
          20 -> :ok
        end

        wait_for_owner_lock(repo, pid, attempts - 1)
    end
  end

  test "new charges require an active subscription and recorded paid tier, but pending recovery continues" do
    attrs = subscription("month", "comma_value_v1")

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscription_cycles SET source_metadata = '{}' WHERE billing_account_id = 'ba_change'"
    )

    assert {:error, :stripe_prior_payment_not_recorded} = change(attrs, "comma_pro_v1")
    refute Enum.any?(state().calls, &(elem(&1, 0) == :update))
    set_price(plan("comma_value_v1").provider_price_id)
    Agent.update(__MODULE__.State, &put_in(&1, [:subscription, "status"], "past_due"))
    assert {:error, :subscription_payment_pending} = change(attrs, "comma_pro_v1")

    Agent.update(
      __MODULE__.State,
      &(&1 |> put_in([:subscription, "status"], "active") |> Map.put(:payment, :pending))
    )

    command = command(attrs, "comma_pro_v1", "recover_due")
    assert {:ok, %{effect: "payment_required"}} = SubscriptionChanges.change(command)
    Agent.update(__MODULE__.State, &put_in(&1, [:subscription, "status"], "past_due"))
    assert {:ok, %{effect: "payment_required"}} = SubscriptionChanges.change(command)
    assert Enum.count(state().calls, &(elem(&1, 0) == :update)) == 1
  end

  test "changed billing period invalidates confirmation and keep current cannot restore cancelled renewal" do
    attrs = subscription("month", "comma_pro_v1")

    Agent.update(__MODULE__.State, fn s ->
      put_in(
        s,
        [:subscription, "items", "data", Access.at(0), "current_period_end"],
        attrs.period_end + 3600
      )
    end)

    assert {:error, :subscription_quote_changed} = change(attrs, "comma_value_v1")
    attrs = %{attrs | period_end: attrs.period_end + 3600}
    assert {:ok, _} = change(attrs, "comma_value_v1")

    assert {:ok, %{effect: "cancellation_scheduled"}} =
             SubscriptionChanges.cancel(Map.put(attrs, :idempotency_key, "cancel"))

    assert {:ok, %{effect: "kept_current"}} = change(attrs, "comma_pro_v1")
    assert current()["schedule"]["end_behavior"] == "cancel"
  end

  defp subscription(period, key) do
    plan = plan(key)
    now = DateTime.utc_now()
    starts = DateTime.new!(Date.new!(now.year, now.month, 1), ~T[00:00:00], "Etc/UTC")
    ends = DateTime.shift(starts, month: if(period == "month", do: 1, else: 12))

    {:ok, _} =
      BillingCommerce.Subscriptions.create_subscription(%{
        billing_account_id: "ba_change",
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: "wsp_change",
        package_code: plan.package_code,
        package_version: plan.package_version,
        source_type: "stripe_subscription",
        source_id: "sub_change",
        source_event_id: "in_initial",
        idempotency_key: "sub_change",
        periods: [%{cycle_key: "initial", valid_from: starts, expires_at: ends}]
      })

    sub = %{
      "id" => "sub_change",
      "customer" => "cus_change",
      "status" => "active",
      "metadata" => %{"surface" => "comma"},
      "schedule" => nil,
      "items" => %{
        "data" => [
          %{
            "id" => "si_change",
            "price" => plan.provider_price_id,
            "current_period_start" => DateTime.to_unix(starts),
            "current_period_end" => DateTime.to_unix(ends)
          }
        ]
      }
    }

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscription_cycles SET source_metadata = $1 WHERE billing_account_id = 'ba_change'",
      [
        %{
          "payment_sources" => %{
            "in_initial" => %{
              "target_tier" => plan.grant_credits,
              "payment_intent_id" => "pi_initial"
            }
          }
        }
      ]
    )

    Agent.update(__MODULE__.State, &Map.put(&1, :subscription, sub))

    %{
      billing_account_id: "ba_change",
      subscription_id: "sub_change",
      customer_id: "cus_change",
      period_end: DateTime.to_unix(ends)
    }
  end

  defp plan(key) do
    {:ok, plan} =
      BillingCommerce.get_provider_plan(%{
        surface: "comma",
        provider: "stripe",
        provider_lookup_key: key
      })

    plan
  end

  defp command(attrs, key, request),
    do:
      Map.merge(attrs, %{
        provider_price_id: plan(key).provider_price_id,
        current_price_id: current_price(),
        proration_date: System.system_time(:second),
        idempotency_key: request,
        success_url: "https://comma.test/return"
      })

  defp change(attrs, key),
    do:
      SubscriptionChanges.change(
        command(attrs, key, "change_#{System.unique_integer([:positive])}")
      )

  defp state, do: Agent.get(__MODULE__.State, & &1)
  defp current, do: state().subscription
  defp current_price, do: get_in(current(), ["items", "data", Access.at(0), "price"])

  defp set_price(price) do
    {:ok, tier} =
      BillingCommerce.get_provider_plan(%{
        surface: "comma",
        provider: "stripe",
        provider_price_id: price
      })

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscription_cycles SET source_metadata = $1 WHERE billing_account_id = 'ba_change'",
      [
        %{
          "payment_sources" => %{
            "in_current" => %{
              "target_tier" => tier.grant_credits,
              "payment_intent_id" => "pi_current"
            }
          }
        }
      ]
    )

    Agent.update(__MODULE__.State, fn s ->
      put_in(s, [:subscription, "items", "data", Access.at(0), "price"], price)
    end)
  end

  defp future_price,
    do:
      current()["schedule"]["phases"]
      |> List.last()
      |> Map.fetch!("items")
      |> hd()
      |> Map.fetch!("price")

  defmodule API do
    def retrieve_subscription(_, _, _),
      do: {:ok, Agent.get(BillingStripe.SubscriptionChangesTest.State, & &1.subscription)}

    def preview_invoice(_, _), do: {:ok, %{"amount_due" => 200, "currency" => "usd"}}

    def create_subscription_schedule(_, opts) do
      mutate(:create_schedule, "sched_change", %{}, opts, fn s ->
        item = hd(s.subscription["items"]["data"])

        phase = %{
          "start_date" => item["current_period_start"],
          "end_date" => item["current_period_end"],
          "items" => [%{"price" => item["price"], "quantity" => 1}]
        }

        schedule = %{
          "id" => "sched_change",
          "metadata" => %{},
          "current_phase" => Map.take(phase, ["start_date", "end_date"]),
          "phases" => [phase],
          "end_behavior" => "release"
        }

        {schedule, put_in(s, [:subscription, "schedule"], schedule)}
      end)
    end

    def update_subscription_schedule(id, params, opts) do
      fail =
        Agent.get_and_update(BillingStripe.SubscriptionChangesTest.State, fn s ->
          {s[:fail_schedule_update], Map.delete(s, :fail_schedule_update)}
        end)

      if fail do
        {:error, :timeout}
      else
        mutate(:schedule, id, params, opts, fn s ->
          schedule = Map.merge(s.subscription["schedule"], stringify(params))
          {schedule, put_in(s, [:subscription, "schedule"], schedule)}
        end)
      end
    end

    def release_subscription_schedule(id, params, opts),
      do:
        mutate(:release, id, params, opts, fn s ->
          {%{"id" => id, "status" => "released"}, put_in(s, [:subscription, "schedule"], nil)}
        end)

    def update_subscription(id, params, opts) do
      result =
        mutate(:update, id, params, opts, fn s ->
          invoice_id = "in_" <> opts[:idempotency_key]
          paid = s.payment == :paid

          current =
            s.subscription
            |> Map.put("latest_invoice", invoice_id)
            |> Map.put(
              "pending_update",
              if(paid, do: nil, else: %{"expires_at" => System.system_time(:second) + 3600})
            )

          current =
            if paid and params["items"],
              do:
                put_in(
                  current,
                  ["items", "data", Access.at(0), "price"],
                  hd(params["items"])["price"]
                ),
              else: current

          invoice = %{
            "id" => invoice_id,
            "status" => if(paid, do: "paid", else: "open"),
            "billing_reason" => "subscription_update",
            "metadata" => params["metadata"] || %{},
            "hosted_invoice_url" => "https://invoice.test/pay"
          }

          {current,
           s
           |> Map.put(:subscription, current)
           |> Map.update!(:invoices, &Map.put(&1, invoice_id, invoice))}
        end)

      Agent.get_and_update(BillingStripe.SubscriptionChangesTest.State, fn s ->
        if s[:lose_response],
          do: {{:error, :timeout}, Map.delete(s, :lose_response)},
          else: {result, s}
      end)
    end

    def retrieve_invoice(id, _, _),
      do: {:ok, Agent.get(BillingStripe.SubscriptionChangesTest.State, & &1.invoices[id])}

    defp mutate(name, id, params, opts, fun) do
      Agent.get_and_update(BillingStripe.SubscriptionChangesTest.State, fn s ->
        key = {name, opts[:idempotency_key]}

        case s.results[key] do
          nil ->
            {value, s} = fun.(s)

            {{:ok, value},
             %{
               s
               | results: Map.put(s.results, key, value),
                 calls: [{name, id, params, opts} | s.calls]
             }}

          value ->
            {{:ok, value}, s}
        end
      end)
    end

    defp stringify(value), do: value |> Jason.encode!() |> Jason.decode!()
  end
end
