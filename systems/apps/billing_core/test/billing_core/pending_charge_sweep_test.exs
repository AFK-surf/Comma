defmodule BillingCore.Metering.PendingChargeSweepTest do
  use ExUnit.Case, async: false

  alias BillingCore.Metering.PricingBackfill

  @repo BillingCore.Repo

  # SQL runner that tallies billing_accounts upserts so we can assert the sweep
  # ensures an account at most once per (sweep, account) instead of per charge.
  defmodule CountingSQL do
    def query!(repo, sql, params, opts \\ []) do
      if String.contains?(sql, "INSERT INTO billing_accounts") do
        :ets.update_counter(:sweep_account_upserts, :count, 1, {:count, 0})
      end

      Ecto.Adapters.SQL.query!(repo, sql, params, opts)
    end
  end

  setup_all do
    unless Process.whereis(@repo) do
      {:ok, _pid} = @repo.start_link()
    end

    Ecto.Migrator.run(@repo, :up, all: true)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, :manual)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
  end

  test "SQL catalog and pending replay charge retained usage once with the correct context tier" do
    account_id = ensure_account("example-ba-september-replay")

    e = %{
      billing_account_id: account_id,
      source_key: "september-replay",
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: account_id,
      resource_kind: "llm",
      provider: "openai",
      sku: "gpt-6-luna",
      metered_at: ~U[2026-09-28 12:00:00Z],
      typed_sink: false,
      meter_components: [
        %{component: "input", quantity: 272_001, meter_unit: "token"},
        %{component: "output", quantity: 100, meter_unit: "token"}
      ]
    }

    # Seed the saved pending fact as the pre-fix engine did when its price was absent.

    BillingCore.Repo.query!(
      "INSERT INTO pending_meter_charges (id,billing_account_id,source_key,resource_kind,provider,sku,meter_snapshot,status,metered_at,expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7,'pending',$8,$9)",
      [
        "september-replay",
        e.billing_account_id,
        e.source_key,
        e.resource_kind,
        e.provider,
        e.sku,
        Jason.encode!(e),
        e.metered_at,
        DateTime.add(e.metered_at, 86400)
      ]
    )

    assert %{charged_count: 1, failed_count: 0} =
             PricingBackfill.run(%{now: e.metered_at, limit: 1})

    assert [[54_475]] =
             BillingCore.Repo.query!(
               "SELECT calculated_credits FROM credit_ledger WHERE billing_account_id=$1 AND source_key=$2",
               [e.billing_account_id, e.source_key]
             ).rows

    assert %{charged_count: 0} = PricingBackfill.run(%{now: e.metered_at, limit: 1})
    assert {:ok, _} = BillingCore.RepoCharges.charge_meter_event(e)

    assert [[1]] =
             BillingCore.Repo.query!(
               "SELECT count(*) FROM credit_ledger WHERE billing_account_id=$1 AND source_key=$2",
               [e.billing_account_id, e.source_key]
             ).rows
  end

  test "a failed (unpriced) charge is backed off, not deleted" do
    account_id = ensure_account("example-ba-backoff")
    seed_pending(account_id, "usage_backoff")

    now = ~U[2026-07-09 12:00:00Z]
    summary = PricingBackfill.run(%{repo: @repo, now: now, limit: 100})

    assert summary.selected_count == 1
    assert summary.charged_count == 0
    assert summary.backed_off_count == 1
    assert summary.failed_count == 0

    row = pending_row(account_id, "usage_backoff")
    assert row.status == "pending"
    assert row.attempts == 1
    assert seconds_between(now, row.next_attempt_at) == 60
  end

  test "backoff grows exponentially across successive sweeps" do
    account_id = ensure_account("example-ba-progression")
    seed_pending(account_id, "usage_progression")

    now1 = ~U[2026-07-09 12:00:00Z]
    PricingBackfill.run(%{repo: @repo, now: now1, limit: 100})
    assert %{attempts: 1, next_attempt_at: t1} = pending_row(account_id, "usage_progression")
    assert seconds_between(now1, t1) == 60

    # Advance past the first backoff so the row is due again.
    now2 = DateTime.add(now1, 120, :second)
    PricingBackfill.run(%{repo: @repo, now: now2, limit: 100})
    assert %{attempts: 2, next_attempt_at: t2} = pending_row(account_id, "usage_progression")
    assert seconds_between(now2, t2) == 300

    now3 = DateTime.add(now2, 600, :second)
    PricingBackfill.run(%{repo: @repo, now: now3, limit: 100})
    assert %{attempts: 3, next_attempt_at: t3} = pending_row(account_id, "usage_progression")
    assert seconds_between(now3, t3) == 1800
  end

  test "a charge whose next_attempt_at is in the future is not selected" do
    account_id = ensure_account("example-ba-due-only")
    seed_pending(account_id, "usage_future", attempts: 1, next_attempt_after_seconds: 3600)

    now = ~U[2026-07-09 12:00:00Z]
    summary = PricingBackfill.run(%{repo: @repo, now: now, limit: 100})

    assert summary.selected_count == 0

    # Untouched by the sweep.
    assert %{attempts: 1} = pending_row(account_id, "usage_future")
  end

  test "a credit top-up requeues that account's backed-off charges" do
    account_id = ensure_account("example-ba-topup")
    other_id = ensure_account("example-ba-topup-other")
    now = database_now()
    seed_pending(account_id, "usage_topup", metered_at: now)
    seed_pending(other_id, "usage_other", metered_at: now)

    PricingBackfill.run(%{repo: @repo, now: now, limit: 100})

    assert %{attempts: 1, next_attempt_at: backed_off} = pending_row(account_id, "usage_topup")

    assert %{attempts: 1, next_attempt_at: other_backed_off} =
             pending_row(other_id, "usage_other")

    assert not is_nil(backed_off)

    before_top_up = database_now()

    {:ok, %{idempotent: false}} =
      BillingCore.Credits.issue_grant(%{
        repo: @repo,
        billing_account_id: account_id,
        idempotency_key: "topup-1",
        source_type: "manual_topup",
        credits: 5_000_000,
        valid_from: now,
        expires_at: DateTime.add(now, 30 * 24 * 3600, :second),
        policy_snapshot: %{}
      })

    requeued = pending_row(account_id, "usage_topup")
    after_top_up = database_now()

    assert requeued.attempts == 0
    assert not is_nil(requeued.next_attempt_at)
    assert DateTime.compare(requeued.next_attempt_at, before_top_up) in [:eq, :gt]
    assert DateTime.compare(requeued.next_attempt_at, after_top_up) in [:eq, :lt]
    assert DateTime.compare(requeued.next_attempt_at, backed_off) == :lt

    # Other accounts must be untouched.
    assert %{attempts: 1, next_attempt_at: ^other_backed_off} =
             pending_row(other_id, "usage_other")
  end

  test "ensure_account is hoisted: one upsert per account regardless of charge count" do
    account_id = ensure_account("example-ba-hoist")
    seed_pending(account_id, "usage_hoist_1")
    seed_pending(account_id, "usage_hoist_2")
    seed_pending(account_id, "usage_hoist_3")

    :ets.new(:sweep_account_upserts, [:named_table, :public, :set])

    now = ~U[2026-07-09 12:00:00Z]

    summary =
      PricingBackfill.run(%{repo: @repo, sql_runner: CountingSQL, now: now, limit: 100})

    assert summary.selected_count == 3

    [{:count, upserts}] = :ets.lookup(:sweep_account_upserts, :count)
    assert upserts == 1
  end

  defp ensure_account(account_id) do
    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: @repo,
        billing_account_id: account_id,
        surface: "comma",
        required_surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: account_id
      })

    account_id
  end

  # Inserts a pending charge with no matching pricing catalog row so the sweep
  # keeps it pending (missing_pricing) and applies backoff.
  defp seed_pending(account_id, source_key, opts \\ []) do
    id = "pending_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    metered_at = Keyword.get(opts, :metered_at, ~U[2026-07-01 00:00:00Z])
    expires_at = BillingCore.Time.add_one_month(metered_at)
    attempts = Keyword.get(opts, :attempts, 0)

    next_attempt_at =
      case opts[:next_attempt_after_seconds] do
        nil -> nil
        secs -> DateTime.add(~U[2026-07-09 12:00:00Z], secs, :second)
      end

    snapshot = %{
      "billing_account_id" => account_id,
      "source_key" => source_key,
      "resource_kind" => "llm",
      "provider" => "unpriced_provider",
      "sku" => "unpriced_sku",
      "component" => "runtime",
      "meter_unit" => "token",
      "quantity" => 10,
      "surface" => "comma",
      "product_owner_type" => "workspace",
      "product_owner_id" => account_id,
      "metered_at" => DateTime.to_iso8601(metered_at)
    }

    Ecto.Adapters.SQL.query!(
      @repo,
      """
      INSERT INTO pending_meter_charges (
        id, billing_account_id, source_key, resource_kind, provider, sku,
        meter_snapshot, status, metered_at, expires_at, inserted_at,
        attempts, next_attempt_at
      ) VALUES ($1, $2, $3, 'llm', 'unpriced_provider', 'unpriced_sku', $4,
                'pending', $5, $6, now(), $7, $8)
      """,
      [
        id,
        account_id,
        source_key,
        Jason.encode!(snapshot),
        metered_at,
        expires_at,
        attempts,
        next_attempt_at
      ]
    )

    id
  end

  defp pending_row(account_id, source_key) do
    %{rows: [[status, attempts, next_attempt_at]]} =
      Ecto.Adapters.SQL.query!(
        @repo,
        """
        SELECT status, attempts, next_attempt_at
        FROM pending_meter_charges
        WHERE billing_account_id = $1 AND source_key = $2
        """,
        [account_id, source_key]
      )

    %{status: status, attempts: attempts, next_attempt_at: next_attempt_at}
  end

  defp database_now do
    %{rows: [[now]]} = Ecto.Adapters.SQL.query!(@repo, "SELECT now()", [])
    now
  end

  defp seconds_between(from, to) do
    DateTime.diff(to, from, :second)
  end
end
