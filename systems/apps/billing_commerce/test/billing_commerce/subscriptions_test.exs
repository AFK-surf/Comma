defmodule BillingCommerce.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias BillingCommerce.{PackageCatalog, Subscriptions}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)

    start_supervised!(%{
      id: __MODULE__.ProjectionLog,
      start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__.ProjectionLog]]}
    })

    Application.put_env(:billing_commerce, :billing_source_typed_sink, __MODULE__.ProjectionSink)

    on_exit(fn ->
      Application.delete_env(:billing_commerce, :billing_source_typed_sink)
    end)

    seed_package("comma_monthly", "comma")
    seed_package("bridge_internal", "bridge")
    :ok
  end

  test "due Stripe annual subscription issues one monthly grant once" do
    assert {:ok, %{subscription: subscription, cycles: cycles}} =
             Subscriptions.create_subscription(
               subscription_attrs(%{
                 billing_account_id: "example-ba-wsp_sub_annual",
                 product_owner_id: "wsp_sub_annual",
                 package_code: "comma_monthly",
                 source_type: "stripe_subscription",
                 source_id: "sub_stripe_annual",
                 source_event_id: "evt_stripe_annual",
                 idempotency_key: "stripe:sub_stripe_annual",
                 periods: [
                   period("2026-06", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z]),
                   period("2026-07", ~U[2026-07-01 00:00:00Z], ~U[2026-08-01 00:00:00Z])
                 ]
               })
             )

    assert subscription.source_metadata["source"] == "test"
    assert length(cycles) == 2

    assert {:ok, %{processed: 1, cycles: [result]}} =
             Subscriptions.run_due_cycles(%{at: ~U[2026-06-15 00:00:00Z], limit: 10})

    assert result.cycle.status == "issued"
    assert result.grant.remaining_credits == 500

    cycle_id = result.cycle.id

    assert %{
             source_type: "subscription_cycle",
             source_id: ^cycle_id,
             source_event_id: "2026-06",
             valid_from: valid_from,
             expires_at: expires_at
           } = grant_source(result.grant.id)

    assert DateTime.compare(valid_from, ~U[2026-06-01 00:00:00Z]) == :eq
    assert DateTime.compare(expires_at, ~U[2026-07-01 00:00:00Z]) == :eq

    assert grant_count("example-ba-wsp_sub_annual") == 1

    assert Enum.any?(
             Agent.get(__MODULE__.ProjectionLog, & &1),
             &(&1["event_kind"] == "subscription_cycle_issued")
           )

    assert {:ok, %{processed: 0, cycles: []}} =
             Subscriptions.run_due_cycles(%{at: ~U[2026-06-20 00:00:00Z], limit: 10})

    assert grant_count("example-ba-wsp_sub_annual") == 1
  end

  defmodule ProjectionSink do
    def insert(rows) do
      Agent.update(BillingCommerce.SubscriptionsTest.ProjectionLog, &(rows ++ &1))
      {:ok, length(rows)}
    end
  end

  test "internal subscription due cycle produces the same grant lot shape" do
    assert {:ok, _} =
             Subscriptions.create_subscription(
               subscription_attrs(%{
                 billing_account_id: "bridge-ba-org_sub_internal",
                 surface: "bridge",
                 product_owner_type: "organization",
                 product_owner_id: "org_sub_internal",
                 package_code: "bridge_internal",
                 source_type: "internal_subscription",
                 source_id: "internal_sub_1",
                 source_event_id: "ops_internal_sub_1",
                 idempotency_key: "internal:sub_1",
                 periods: [period("2026-06", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])]
               })
             )

    assert {:ok, %{cycles: [%{grant: grant, cycle: cycle}]}} =
             Subscriptions.run_due_cycles(%{at: ~U[2026-06-02 00:00:00Z], limit: 10})

    assert grant.billing_account_id == "bridge-ba-org_sub_internal"
    assert cycle.credit_grant_id == grant.id
    assert cycle.grant_idempotency_key =~ "subscription_cycle:"
  end

  test "failed due cycle is retried instead of skipped" do
    assert {:ok, %{cycles: [cycle]}} =
             Subscriptions.create_subscription(
               subscription_attrs(%{
                 billing_account_id: "example-ba-wsp_sub_retry",
                 product_owner_id: "wsp_sub_retry",
                 package_code: "comma_monthly",
                 source_type: "internal_subscription",
                 source_id: "internal_sub_retry",
                 source_event_id: "ops_internal_sub_retry",
                 idempotency_key: "internal:sub_retry",
                 periods: [period("2026-06", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])]
               })
             )

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscription_cycles SET status = 'failed', attempts = 1 WHERE id = $1",
      [cycle.id]
    )

    assert {:ok, %{processed: 1, cycles: [%{cycle: issued}]}} =
             Subscriptions.run_due_cycles(%{at: ~U[2026-06-02 00:00:00Z], limit: 10})

    assert issued.status == "issued"
    assert issued.attempts == 1
    assert grant_count("example-ba-wsp_sub_retry") == 1
  end

  test "one-time purchase issues one explicit current-period top-up grant" do
    attrs =
      purchase_attrs(%{
        billing_account_id: "example-ba-wsp_topup",
        product_owner_id: "wsp_topup",
        package_code: "comma_monthly",
        source_id: "checkout_topup_1",
        source_event_id: "evt_checkout_topup_1",
        idempotency_key: "checkout:topup_1"
      })

    assert {:ok, %{purchase: purchase, grant: grant, idempotent: false}} =
             Subscriptions.issue_one_time_purchase(attrs)

    assert purchase.status == "issued"
    assert purchase.credit_grant_id == grant.id
    assert grant.remaining_credits == 500

    assert {:ok, %{idempotent: true, grant: nil}} =
             Subscriptions.issue_one_time_purchase(attrs)

    assert grant_count("example-ba-wsp_topup") == 1
  end

  test "package-backed subscription and purchase reject surface mismatches" do
    subscription =
      subscription_attrs(%{
        billing_account_id: "example-ba-wsp_bridge_sub",
        product_owner_id: "wsp_bridge_sub",
        package_code: "bridge_internal",
        source_type: "internal_subscription",
        source_id: "internal_bridge_sub",
        source_event_id: "ops_bridge_sub",
        idempotency_key: "internal:bridge-sub",
        periods: [period("2026-06", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])]
      })

    assert {:error, :package_surface_mismatch} =
             Subscriptions.create_subscription(subscription)

    purchase =
      purchase_attrs(%{
        billing_account_id: "example-ba-wsp_bridge_purchase",
        product_owner_id: "wsp_bridge_purchase",
        package_code: "bridge_internal",
        source_id: "checkout_bridge_purchase",
        source_event_id: "evt_bridge_purchase",
        idempotency_key: "checkout:bridge-purchase"
      })

    assert {:error, :package_surface_mismatch} =
             Subscriptions.issue_one_time_purchase(purchase)

    assert grant_count("example-ba-wsp_bridge_sub") == 0
    assert grant_count("example-ba-wsp_bridge_purchase") == 0
  end

  test "one-time purchase cannot mutate an existing account to another surface" do
    insert_billing_account!("example-ba-wsp_existing_purchase", "comma", "workspace", "wsp_existing")

    attrs =
      purchase_attrs(%{
        billing_account_id: "example-ba-wsp_existing_purchase",
        surface: "bridge",
        product_owner_type: "organization",
        product_owner_id: "org_existing",
        package_code: "bridge_internal",
        source_id: "checkout_existing_purchase",
        source_event_id: "evt_existing_purchase",
        idempotency_key: "checkout:existing-purchase"
      })

    assert {:error, :billing_account_surface_mismatch} =
             Subscriptions.issue_one_time_purchase(attrs)

    assert account_surface("example-ba-wsp_existing_purchase") == "comma"
    assert grant_count("example-ba-wsp_existing_purchase") == 0
  end

  defp seed_package(code, surface) do
    {:ok, _} =
      PackageCatalog.create_package(%{
        code: code,
        surface: surface,
        name: code
      })

    {:ok, _} =
      PackageCatalog.create_package_version(%{
        package_code: code,
        version: "2026-06",
        surface: surface,
        kind: "subscription",
        billing_period: "month",
        grant_credits: 500,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 2_000,
        usage_policy: %{},
        effective_at: ~U[2026-06-01 00:00:00Z],
        status: "active"
      })
  end

  defp subscription_attrs(attrs) do
    Map.merge(
      %{
        surface: "comma",
        product_owner_type: "workspace",
        package_version: "2026-06",
        source_metadata: %{"source" => "test"}
      },
      attrs
    )
  end

  defp purchase_attrs(attrs) do
    Map.merge(
      %{
        surface: "comma",
        product_owner_type: "workspace",
        package_version: "2026-06",
        source_type: "top_up",
        valid_from: ~U[2026-06-01 00:00:00Z],
        expires_at: ~U[2026-07-01 00:00:00Z],
        source_metadata: %{"source" => "test"}
      },
      attrs
    )
  end

  defp period(cycle_key, valid_from, expires_at) do
    %{cycle_key: cycle_key, valid_from: valid_from, expires_at: expires_at}
  end

  defp grant_count(account_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT count(*) FROM credit_grants WHERE billing_account_id = $1",
        [account_id]
      )

    count
  end

  defp insert_billing_account!(account_id, surface, product_owner_type, product_owner_id) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_accounts (
        id, surface, product_owner_type, product_owner_id, status, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'active', now(), now())
      """,
      [account_id, surface, product_owner_type, product_owner_id]
    )
  end

  defp account_surface(account_id) do
    %{rows: [[surface]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT surface FROM billing_accounts WHERE id = $1",
        [account_id]
      )

    surface
  end

  defp grant_source(grant_id) do
    %{rows: [[source_type, source_id, source_event_id, valid_from, expires_at]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT source_type, source_id, source_event_id, valid_from, expires_at
        FROM credit_grants
        WHERE id = $1
        """,
        [grant_id]
      )

    %{
      source_type: source_type,
      source_id: source_id,
      source_event_id: source_event_id,
      valid_from: valid_from,
      expires_at: expires_at
    }
  end
end
