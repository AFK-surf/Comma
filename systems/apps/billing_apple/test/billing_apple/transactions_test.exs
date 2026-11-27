defmodule BillingApple.TransactionsTest do
  use SystemsClock.Case, async: false

  alias BillingApple.TestAPI
  alias BillingCommerce.PackageCatalog

  @account "example-ba-wsp_apple"
  @bundle "surf.comma.test"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    seed("apple_test_plus", "apple_test_plus_v1", "subscription", 500)
    seed("apple_test_pro", "apple_test_pro_v1", "subscription", 1500)
    seed("apple_test_pack", "apple_test_pack_v1", "one_time", 300)

    for key <- [:test_transactions, :test_statuses, :test_calls],
        do: SystemsRuntime.delete_env(:billing_apple, key)

    {:ok, token} =
      BillingApple.account_token(%{
        billing_account_id: @account,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: "wsp_apple"
      })

    now = SystemsClock.utc_now() |> DateTime.truncate(:second)
    %{token: token, starts: DateTime.add(now, -10, :day)}
  end

  test "a purchase grants the plan's credits once and follows the subscription status", ctx do
    expires = DateTime.shift(ctx.starts, month: 1)
    put_tx("1001", sub_tx(ctx, "1001", "apple_test_plus_v1", expires))
    put_status("1001", "1001", 1, %{"autoRenewStatus" => 0})

    assert {:ok, %{recorded: :subscription, billing_account_id: @account}} =
             BillingApple.sync_transaction("1001", &team_email/1)

    assert {:ok, _} = BillingApple.sync_transaction("1001", &team_email/1)
    assert grants() == [{500, "apple:1001"}]

    assert %{"status" => "active", "cancel_at_period_end" => true, "source_id" => "1001"} =
             subscription()
  end

  test "an upgrade replaces the running payment and subtracts its unused credits", ctx do
    old_end = DateTime.shift(ctx.starts, month: 1)
    put_tx("2001", sub_tx(ctx, "2001", "apple_test_plus_v1", old_end))
    put_status("2001", "2001", 1)
    assert {:ok, _} = BillingApple.sync_transaction("2001", &team_email/1)

    # The App Store starts the upgraded period at the change time.
    upgraded_at = DateTime.add(ctx.starts, 9, :day)
    new_end = DateTime.shift(upgraded_at, month: 1)

    put_tx(
      "2002",
      sub_tx(ctx, "2002", "apple_test_pro_v1", new_end, %{
        "originalTransactionId" => "2001",
        "purchaseDate" => DateTime.to_unix(upgraded_at, :millisecond)
      })
    )

    put_tx("2001", sub_tx(ctx, "2001", "apple_test_plus_v1", old_end, %{"isUpgraded" => true}))
    put_status("2001", "2002", 1)

    assert {:ok, _} = BillingApple.sync_transaction("2002", &team_email/1)

    unused =
      div(
        500 * DateTime.diff(old_end, upgraded_at, :second),
        DateTime.diff(old_end, ctx.starts, :second)
      )

    # Both grants can share an insert time.
    assert Enum.sort(grants()) == [{500, "apple:2001"}, {1500 - unused, "apple:2002"}]

    # The upgraded transaction is not a refund and records nothing again.
    assert {:ok, %{reason: :upgraded}} = BillingApple.sync_transaction("2001", &team_email/1)
    assert length(grants()) == 2
    assert %{"package_code" => "apple_test_pro"} = subscription()
  end

  test "a renewal is recorded through the subscription without a token", ctx do
    first_end = DateTime.shift(ctx.starts, month: 1)
    put_tx("3001", sub_tx(ctx, "3001", "apple_test_plus_v1", first_end))
    put_status("3001", "3001", 1)
    assert {:ok, _} = BillingApple.sync_transaction("3001", &team_email/1)

    renewal =
      ctx
      |> sub_tx("3002", "apple_test_plus_v1", DateTime.shift(first_end, month: 1))
      |> Map.merge(%{
        "originalTransactionId" => "3001",
        "purchaseDate" => DateTime.to_unix(first_end, :millisecond),
        "transactionReason" => "RENEWAL"
      })
      |> Map.delete("appAccountToken")

    put_tx("3002", renewal)
    put_status("3001", "3002", 1)

    assert {:ok, %{billing_account_id: @account}} =
             BillingApple.sync_transaction("3002", &team_email/1)

    # The renewal period has not started, so its cycle issues later.
    assert grants() == [{500, "apple:3001"}]
    assert cycle_count() == 2
  end

  # Sandbox periods last minutes, not a calendar month. A renewal that starts
  # after a short lapse is a new paid period, not an upgrade.
  test "a renewal of a short sandbox period grants the plan's full credits", ctx do
    first_end = DateTime.add(ctx.starts, 5, :minute)
    put_tx("3101", sub_tx(ctx, "3101", "apple_test_plus_v1", first_end), :sandbox)
    put_status("3101", "3101", 1)
    assert {:ok, _} = BillingApple.sync_transaction("3101", &team_email/1)

    renewed_at = DateTime.add(first_end, 43, :second)

    renewal =
      sub_tx(ctx, "3102", "apple_test_plus_v1", DateTime.add(renewed_at, 5, :minute), %{
        "originalTransactionId" => "3101",
        "purchaseDate" => DateTime.to_unix(renewed_at, :millisecond),
        "transactionReason" => "RENEWAL"
      })

    put_tx("3102", renewal, :sandbox)
    put_status("3101", "3102", 1)

    assert {:ok, _} = BillingApple.sync_transaction("3102", &team_email/1)
    assert Enum.sort(grants()) == [{500, "apple:3101"}, {500, "apple:3102"}]
  end

  test "a revoked transaction removes that payment's unspent credits", ctx do
    expires = DateTime.shift(ctx.starts, month: 1)
    put_tx("4001", sub_tx(ctx, "4001", "apple_test_plus_v1", expires))
    put_status("4001", "4001", 1)
    assert {:ok, _} = BillingApple.sync_transaction("4001", &team_email/1)

    revoked_at = SystemsClock.system_time(:millisecond)

    put_tx(
      "4001",
      sub_tx(ctx, "4001", "apple_test_plus_v1", expires, %{"revocationDate" => revoked_at})
    )

    put_status("4001", "4001", 5)

    assert {:ok, %{status: "canceled"}} = BillingApple.sync_transaction("4001", &team_email/1)
    assert grants() == [{0, "apple:4001"}]
  end

  test "a credit pack is a one-time purchase", ctx do
    put_tx("5001", pack_tx(ctx, "5001"))

    assert {:ok, %{recorded: :purchase}} = BillingApple.sync_transaction("5001", &team_email/1)
    assert {:ok, _} = BillingApple.sync_transaction("5001", &team_email/1)
    assert grants() == [{300, "apple:5001"}]
  end

  test "transactions of another app, an unknown account, or a free offer record nothing", ctx do
    expires = DateTime.shift(ctx.starts, month: 1)

    put_tx(
      "6001",
      sub_tx(ctx, "6001", "apple_test_plus_v1", expires, %{"bundleId" => "other.app"})
    )

    put_tx(
      "6002",
      sub_tx(ctx, "6002", "apple_test_plus_v1", expires, %{
        "appAccountToken" => SystemsRuntime.Proc.uuid()
      })
    )

    put_tx("6003", sub_tx(ctx, "6003", "apple_test_plus_v1", expires, %{"price" => 0}))

    assert {:error, :apple_bundle_mismatch} = BillingApple.sync_transaction("6001", &team_email/1)
    assert {:error, :apple_account_unknown} = BillingApple.sync_transaction("6002", &team_email/1)

    assert {:error, :apple_unpaid_transaction} =
             BillingApple.sync_transaction("6003", &team_email/1)

    assert {:error, :apple_transaction_not_found} =
             BillingApple.sync_transaction("6999", &team_email/1)

    assert {:error, :invalid_transaction_id} =
             BillingApple.sync_transaction("../x", &team_email/1)

    assert grants() == []
  end

  # Sandbox purchases pay nothing. Only a team owner (App Review, TestFlight
  # testers of the team) gets credits from them.
  test "a sandbox transaction records only for an owner at a team email domain", ctx do
    expires = DateTime.shift(ctx.starts, month: 1)
    put_tx("8001", sub_tx(ctx, "8001", "apple_test_plus_v1", expires), :sandbox)
    put_tx("8002", pack_tx(ctx, "8002"), :sandbox)
    put_status("8001", "8001", 1)

    for email <- ["tester@example.com", "x@comma.surf.example.com", nil] do
      assert {:error, :apple_sandbox_not_allowed} =
               BillingApple.sync_transaction("8001", fn _owner -> email end)

      assert {:error, :apple_sandbox_not_allowed} =
               BillingApple.sync_transaction("8002", fn _owner -> email end)
    end

    assert grants() == []

    assert {:ok, _} =
             BillingApple.sync_transaction("8001", fn %{product_owner_id: "wsp_apple"} ->
               "Review@Cue.Surf"
             end)

    assert {:ok, %{recorded: :purchase}} = BillingApple.sync_transaction("8002", &team_email/1)
    assert Enum.sort(grants()) == [{300, "apple:8002"}, {500, "apple:8001"}]

    # A production transaction pays, so any owner gets its credits.
    put_tx("8003", pack_tx(ctx, "8003"))
    assert {:ok, _} = BillingApple.sync_transaction("8003", fn _owner -> nil end)
  end

  test "a notification only names the transaction, which is read from the App Store", ctx do
    expires = DateTime.shift(ctx.starts, month: 1)
    put_tx("7001", sub_tx(ctx, "7001", "apple_test_plus_v1", expires), :sandbox)
    put_status("7001", "7001", 1)

    # The notification claims a different product. The App Store read wins.
    claimed = sub_tx(ctx, "7001", "apple_test_pro_v1", expires)

    body = %{
      "signedPayload" =>
        TestAPI.jws(%{
          "notificationType" => "SUBSCRIBED",
          "data" => %{"bundleId" => @bundle, "signedTransactionInfo" => TestAPI.jws(claimed)}
        })
    }

    assert {:ok, _} = BillingApple.handle_notification(body, &team_email/1)
    assert grants() == [{500, "apple:7001"}]

    assert [{:transaction, :production, "7001"}, {:transaction, :sandbox, "7001"} | _] =
             SystemsRuntime.get_env(:billing_apple, :test_calls)
  end

  test "a sandbox annual subscription grants a full month of credits", ctx do
    seed("apple_test_annual", "apple_test_annual_v1", "subscription", 1000, "year")
    expires = DateTime.add(ctx.starts, 1, :hour)
    put_tx("9101", sub_tx(ctx, "9101", "apple_test_annual_v1", expires), :sandbox)
    put_status("9101", "9101", 1)

    assert {:ok, %{recorded: :subscription}} =
             BillingApple.sync_transaction("9101", &team_email/1)

    assert grants() == [{1000, "apple:9101"}]
  end

  test "resubscribing after a refund grants only the new tier's full credits", ctx do
    old_end = DateTime.shift(ctx.starts, month: 1)
    put_tx("9201", sub_tx(ctx, "9201", "apple_test_plus_v1", old_end))
    put_status("9201", "9201", 1)
    assert {:ok, _} = BillingApple.sync_transaction("9201", &team_email/1)

    revoked_at = SystemsClock.system_time(:millisecond)

    put_tx(
      "9201",
      sub_tx(ctx, "9201", "apple_test_plus_v1", old_end, %{"revocationDate" => revoked_at})
    )

    put_status("9201", "9201", 5)
    assert {:ok, %{status: "canceled"}} = BillingApple.sync_transaction("9201", &team_email/1)

    resub_at = DateTime.add(ctx.starts, 9, :day)
    new_end = DateTime.shift(resub_at, month: 1)

    put_tx(
      "9202",
      sub_tx(ctx, "9202", "apple_test_pro_v1", new_end, %{
        "originalTransactionId" => "9201",
        "purchaseDate" => DateTime.to_unix(resub_at, :millisecond)
      })
    )

    put_status("9201", "9202", 1)
    assert {:ok, %{status: "active"}} = BillingApple.sync_transaction("9202", &team_email/1)

    assert Enum.sort(grants()) == [{0, "apple:9201"}, {1500, "apple:9202"}]
  end

  test "first-seen revoked transactions grant nothing, and a recorded pack revokes cleanly",
       ctx do
    revoked_at = SystemsClock.system_time(:millisecond)
    expires = DateTime.shift(ctx.starts, month: 1)

    put_tx(
      "9301",
      sub_tx(ctx, "9301", "apple_test_plus_v1", expires, %{"revocationDate" => revoked_at})
    )

    put_status("9301", "9301", 5)
    assert {:ok, %{status: "canceled"}} = BillingApple.sync_transaction("9301", &team_email/1)

    put_tx("9302", pack_tx(ctx, "9302", %{"revocationDate" => revoked_at}))

    assert {:ok, %{ignored: true, reason: :revoked}} =
             BillingApple.sync_transaction("9302", &team_email/1)

    assert grants() == []

    # A previously recorded consumable revokes its unspent credits when revoked later.
    put_tx("9303", pack_tx(ctx, "9303"))
    assert {:ok, %{recorded: :purchase}} = BillingApple.sync_transaction("9303", &team_email/1)
    assert grants() == [{300, "apple:9303"}]

    put_tx("9303", pack_tx(ctx, "9303", %{"revocationDate" => revoked_at}))
    assert {:ok, %{recorded: :purchase}} = BillingApple.sync_transaction("9303", &team_email/1)
    assert grants() == [{0, "apple:9303"}]
  end

  test "a family-shared transaction is rejected and grants nothing", ctx do
    expires = DateTime.shift(ctx.starts, month: 1)

    put_tx(
      "9401",
      sub_tx(ctx, "9401", "apple_test_plus_v1", expires, %{
        "inAppOwnershipType" => "FAMILY_SHARED"
      })
    )

    assert {:error, :apple_family_shared_not_allowed} =
             BillingApple.sync_transaction("9401", &team_email/1)

    assert grants() == []
  end

  defp sub_tx(ctx, id, product, expires, extra \\ %{}) do
    Map.merge(
      %{
        "transactionId" => id,
        "originalTransactionId" => id,
        "bundleId" => @bundle,
        "productId" => product,
        "type" => "Auto-Renewable Subscription",
        "purchaseDate" => DateTime.to_unix(ctx.starts, :millisecond),
        "expiresDate" => DateTime.to_unix(expires, :millisecond),
        "price" => 9990,
        "appAccountToken" => ctx.token
      },
      extra
    )
  end

  defp pack_tx(ctx, id, extra \\ %{}) do
    Map.merge(
      %{
        "transactionId" => id,
        "originalTransactionId" => id,
        "bundleId" => @bundle,
        "productId" => "apple_test_pack_v1",
        "type" => "Consumable",
        "purchaseDate" => DateTime.to_unix(ctx.starts, :millisecond),
        "price" => 4990,
        "appAccountToken" => ctx.token
      },
      extra
    )
  end

  defp team_email(_owner), do: "review@comma.surf"

  defp put_tx(id, tx, environment \\ :production) do
    txs = SystemsRuntime.get_env(:billing_apple, :test_transactions, %{})

    SystemsRuntime.put_env(
      :billing_apple,
      :test_transactions,
      Map.put(txs, id, %{environment: environment, tx: tx})
    )
  end

  defp put_status(original, latest, status, renewal \\ %{"autoRenewStatus" => 1}) do
    %{tx: tx} = SystemsRuntime.get_env(:billing_apple, :test_transactions) |> Map.fetch!(latest)
    statuses = SystemsRuntime.get_env(:billing_apple, :test_statuses, %{})

    body = %{
      "data" => [
        %{
          "lastTransactions" => [
            %{
              "originalTransactionId" => original,
              "status" => status,
              "signedTransactionInfo" => TestAPI.jws(tx),
              "signedRenewalInfo" => TestAPI.jws(renewal)
            }
          ]
        }
      ]
    }

    SystemsRuntime.put_env(:billing_apple, :test_statuses, Map.put(statuses, original, body))
  end

  defp grants do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      SELECT remaining_credits, metadata->>'provider_payment_id' FROM credit_grants
      WHERE billing_account_id = $1 ORDER BY inserted_at, id
      """,
      [@account]
    ).rows
    |> Enum.map(&List.to_tuple/1)
  end

  defp cycle_count do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT count(*) FROM billing_subscription_cycles WHERE billing_account_id = $1",
        [@account]
      )

    count
  end

  defp subscription do
    %{rows: [[status, source_id, package_code, metadata]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT status, source_id, package_code, source_metadata FROM billing_subscriptions
        WHERE billing_account_id = $1
        """,
        [@account]
      )

    Map.merge(BillingCore.Metadata.object(metadata), %{
      "status" => status,
      "source_id" => source_id,
      "package_code" => package_code
    })
  end

  defp seed(code, plan_key, kind, credits, billing_period \\ "month") do
    {:ok, _} = PackageCatalog.create_package(%{code: code, surface: "comma", name: code})

    {:ok, _} =
      PackageCatalog.create_package_version(%{
        package_code: code,
        version: "2026-06",
        surface: "comma",
        kind: kind,
        billing_period: billing_period,
        grant_credits: credits,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 2_000,
        usage_policy: %{},
        effective_at: ~U[2026-01-01 00:00:00Z],
        status: "active"
      })

    {:ok, _} =
      BillingCommerce.put_provider_price(%{
        package_code: code,
        package_version: "2026-06",
        provider: "stripe",
        provider_lookup_key: plan_key,
        provider_price_id: "price_" <> plan_key,
        currency: "usd",
        amount_minor: 2_000
      })
  end
end
