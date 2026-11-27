defmodule BillingCore.TeamsAccessTest do
  use SystemsClock.Case, async: false

  alias BillingCore.TeamsAccess

  setup_all do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)

    Ecto.Migrator.run(BillingCore.Repo, :up, all: true)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    seed_teams_package!()
    :ok
  end

  test "check/1 admits 30, 48, and 100 paid seats and rejects refunded or missing accounts" do
    now = SystemsClock.utc_now()
    starts = DateTime.add(now, -3_600, :second)
    ends = DateTime.add(now, 86_400, :second)

    for {seats, source_type} <- [
          {30, "m2square_term"},
          {48, "m2square_term"},
          {100, "stripe_subscription"}
        ] do
      account_id = "bridge-ba-org_seats_#{seats}"
      insert_account!(account_id, true, "active")
      sub_id = insert_subscription!(account_id, source_type, "active")

      insert_cycle!(account_id, sub_id, starts, ends, %{
        "payment_sources" => %{
          "pay_#{seats}" => %{"state" => "paid", "teams_seats" => seats}
        }
      })

      assert {:ok, ^seats} = TeamsAccess.check(account_id)
    end

    insert_account!("bridge-ba-org_refunded", true, "active")
    refunded_sub = insert_subscription!("bridge-ba-org_refunded", "m2square_term", "active")

    insert_cycle!("bridge-ba-org_refunded", refunded_sub, starts, ends, %{
      "payment_sources" => %{
        "m2square:aaaaaaaaaaaaaaaaaaaaaaaa" => %{"state" => "refunded", "teams_seats" => 30}
      }
    })

    assert {:error, :teams_subscription_required} = TeamsAccess.check("bridge-ba-org_refunded")

    insert_account!("bridge-ba-org_unmanaged", false, "active")
    assert {:ok, :unmanaged} = TeamsAccess.check("bridge-ba-org_unmanaged")
    assert {:error, :billing_account_not_found} = TeamsAccess.check("bridge-ba-org_missing")
  end

  test "coverage/2 reports current cycle, contiguous future cycle, refunded cycle, and unmanaged accounts" do
    now = ~U[2026-11-20 12:00:00Z]
    q1_start = ~U[2026-10-01 00:00:00Z]
    q1_end = ~U[2027-01-01 00:00:00Z]
    q2_start = ~U[2027-01-01 00:00:00Z]
    q2_end = ~U[2027-04-01 00:00:00Z]

    # Current M2square cycle with contiguous next paid cycle
    insert_account!("bridge-ba-org_cov_contiguous", true, "active")
    sub_m2 = insert_subscription!("bridge-ba-org_cov_contiguous", "m2square_term", "active")

    insert_cycle!("bridge-ba-org_cov_contiguous", sub_m2, q1_start, q1_end, %{
      "payment_sources" => %{
        "m2square:mttaaaaaaaaaaaaaaaaaaaaa" => %{"state" => "paid", "teams_seats" => 30}
      }
    })

    insert_cycle!("bridge-ba-org_cov_contiguous", sub_m2, q2_start, q2_end, %{
      "payment_sources" => %{
        "m2square:mttbbbbbbbbbbbbbbbbbbbbb" => %{"state" => "paid", "teams_seats" => 48}
      }
    })

    assert {:ok, cov} = TeamsAccess.coverage("bridge-ba-org_cov_contiguous", now)
    assert cov.managed == true
    assert cov.account_active == true
    assert cov.active == true
    assert cov.licensed_seats == 30
    assert DateTime.compare(cov.current_period_end, q1_end) == :eq
    assert DateTime.compare(cov.next_period_end, q2_end) == :eq
    assert DateTime.compare(cov.expires_at, q2_end) == :eq
    assert cov.has_future_paid_cycle == true
    assert cov.provider == "m2square"
    assert cov.has_active_stripe_subscription == false

    # Active Stripe subscription with 100 seats and no future cycle
    insert_account!("bridge-ba-org_cov_stripe", true, "active")

    sub_stripe =
      insert_subscription!("bridge-ba-org_cov_stripe", "stripe_subscription", "active")

    insert_cycle!("bridge-ba-org_cov_stripe", sub_stripe, q1_start, q1_end, %{
      "payment_sources" => %{
        "in_stripe_100" => %{"state" => "paid", "teams_seats" => 100}
      }
    })

    assert {:ok, stripe_cov} = TeamsAccess.coverage("bridge-ba-org_cov_stripe", now)
    assert stripe_cov.active == true
    assert stripe_cov.licensed_seats == 100
    assert DateTime.compare(stripe_cov.expires_at, q1_end) == :eq
    assert stripe_cov.next_period_end == nil
    assert stripe_cov.has_future_paid_cycle == false
    assert stripe_cov.provider == "stripe"
    assert stripe_cov.has_active_stripe_subscription == true

    # Refunded cycle yields inactive coverage
    insert_account!("bridge-ba-org_cov_refunded", true, "active")
    sub_ref = insert_subscription!("bridge-ba-org_cov_refunded", "m2square_term", "active")

    insert_cycle!("bridge-ba-org_cov_refunded", sub_ref, q1_start, q1_end, %{
      "payment_sources" => %{
        "m2square:mttccccccccccccccccccccc" => %{"state" => "refunded", "teams_seats" => 36}
      }
    })

    assert {:ok, ref_cov} = TeamsAccess.coverage("bridge-ba-org_cov_refunded", now)
    assert ref_cov.managed == true
    assert ref_cov.account_active == true
    assert ref_cov.active == false
    assert ref_cov.licensed_seats == 0
    assert ref_cov.expires_at == nil
    assert ref_cov.current_period_end == nil
    assert ref_cov.next_period_end == nil
    assert ref_cov.has_future_paid_cycle == false
    assert ref_cov.provider == "m2square"
    assert ref_cov.has_active_stripe_subscription == false

    # Unmanaged account
    insert_account!("bridge-ba-org_cov_unmanaged", false, "active")
    assert {:ok, unm_cov} = TeamsAccess.coverage("bridge-ba-org_cov_unmanaged", now)
    assert unm_cov.managed == false
    assert unm_cov.account_active == true
    assert unm_cov.active == false
    assert unm_cov.licensed_seats == 0
    assert unm_cov.expires_at == nil
    assert unm_cov.provider == nil
    assert unm_cov.has_active_stripe_subscription == false

    assert {:error, :billing_account_not_found} =
             TeamsAccess.coverage("bridge-ba-org_cov_missing", now)
  end

  defp seed_teams_package! do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_packages (code, surface, name, status, inserted_at, updated_at)
      VALUES ('bridge_teams_seat_quarterly', 'bridge', 'Bridge Teams Quarterly', 'active', now(), now())
      ON CONFLICT (code) DO NOTHING
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_package_versions (
        id, package_code, version, surface, kind, billing_period, grant_credits,
        grant_period, currency, amount_minor, usage_policy, effective_at, status,
        inserted_at
      ) VALUES (
        'pkgv_bridge_teams_2026_11', 'bridge_teams_seat_quarterly', '2026-11', 'bridge',
        'subscription', 'quarter', 0, 'current_period', 'usd', 24000, '{}'::jsonb,
        '2026-01-01 00:00:00Z'::timestamptz, 'active', now()
      )
      ON CONFLICT (package_code, version) DO NOTHING
      """,
      []
    )
  end

  defp insert_account!(account_id, required?, status) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_accounts (
        id, surface, product_owner_type, product_owner_id, status,
        teams_subscription_required, inserted_at, updated_at
      ) VALUES ($1, 'bridge', 'organization', $2, $3, $4, now(), now())
      """,
      [account_id, "org_#{account_id}", status, required?]
    )
  end

  defp insert_subscription!(account_id, source_type, status) do
    sub_id = "sub_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_subscriptions (
        id, billing_account_id, surface, product_owner_type, product_owner_id,
        package_code, package_version, source_type, source_id, source_event_id,
        idempotency_key, source_metadata, status, inserted_at, updated_at
      ) VALUES (
        $1, $2, 'bridge', 'organization', $3,
        'bridge_teams_seat_quarterly', '2026-11', $4, $1, $1,
        $1, '{}'::jsonb, $5, now(), now()
      )
      """,
      [sub_id, account_id, "org_#{account_id}", source_type, status]
    )

    sub_id
  end

  defp insert_cycle!(account_id, sub_id, starts, ends, source_metadata) do
    cycle_id = "cycle_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_subscription_cycles (
        id, subscription_id, billing_account_id, package_code, package_version,
        cycle_key, period_start, period_end, grant_idempotency_key,
        source_event_id, grant_source_type, source_metadata, status, inserted_at, updated_at
      ) VALUES (
        $1, $2, $3, 'bridge_teams_seat_quarterly', '2026-11',
        $1, $4, $5, $1,
        $1, 'subscription_cycle', $6::jsonb, 'issued', now(), now()
      )
      """,
      [cycle_id, sub_id, account_id, starts, ends, source_metadata]
    )

    cycle_id
  end
end
