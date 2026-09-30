defmodule BillingCore.FeeControlTest do
  use ExUnit.Case, async: true

  alias BillingCore.{FeeControl, State}

  test "check/2 performs shadow query on cache miss and never blocks" do
    state = State.new()

    assert {:ok, check, state} =
             FeeControl.check(state, %{
               billing_account_id: "acct_1",
               provider: "openai",
               sku: "tokens",
               estimated_credits: 20,
               now: 100,
               query_fun: fn -> %{balance_snapshot: 5} end
             })

    assert check.allowed? == true
    assert check.would_block == true
    assert check.cache_hit == false
    assert check.query_performed == true
    assert is_integer(check.query_duration_ms)
    assert map_size(state.fee_control_cache) == 1
  end

  test "check/2 uses fresh shadow cache with hit/query metadata" do
    state =
      State.new(
        fee_control_cache: %{
          {"acct_1", "openai", "tokens"} => %{
            snapshot: %{balance_snapshot: 30},
            cached_at_ms: 100
          }
        }
      )

    assert {:ok, check, _state} =
             FeeControl.check(state, %{
               billing_account_id: "acct_1",
               provider: "openai",
               sku: "tokens",
               estimated_credits: 20,
               now: 125
             })

    assert check.allowed? == true
    assert check.would_block == false
    assert check.cache_hit == true
    assert check.query_performed == false
    assert check.query_duration_ms == 0
    assert check.cache_age_ms == 25
  end

  test "authorize/1 returns hard block in enforce mode for zero active credits" do
    state = State.new()

    assert {:ok, decision} =
             FeeControl.authorize(%{
               state: state,
               billing_account_id: "acct_1",
               resource_kind: :llm,
               action: :start,
               provider: "openai",
               sku: "gpt-x",
               mode: :enforce,
               estimated_credits: 1,
               checked_at: ~U[2026-06-17 00:00:00Z]
             })

    refute decision.allowed?
    assert decision.reason == "insufficient_credits"
    assert decision.entitlement_mode == :metered
    assert decision.entitlement_policy["vm_concurrency"]["mode"] == "unrestricted"
  end

  test "authorize/1 allows active unlimited entitlement with zero credits" do
    checked_at = ~U[2026-06-17 00:00:00Z]

    state =
      State.new(
        grants: [
          %{
            id: "grant_unlimited",
            billing_account_id: "acct_1",
            remaining_credits: 0,
            status: "active",
            valid_from: ~U[2026-06-01 00:00:00Z],
            expires_at: ~U[2026-07-01 00:00:00Z],
            policy_snapshot: %{"usage_credits" => %{"mode" => "unlimited_metered"}}
          }
        ]
      )

    assert {:ok, decision} =
             FeeControl.authorize(%{
               state: state,
               billing_account_id: "acct_1",
               resource_kind: :llm,
               action: :start,
               provider: "openai",
               sku: "gpt-x",
               mode: :enforce,
               estimated_credits: 1,
               checked_at: checked_at
             })

    assert decision.allowed?
    refute decision.would_block
    assert decision.reason == "allowed_unlimited"
    assert decision.entitlement_mode == :unlimited_metered
    assert decision.balance_snapshot == 0
  end

  test "authorize/1 blocks after unlimited entitlement expires" do
    checked_at = ~U[2026-07-02 00:00:00Z]

    state =
      State.new(
        grants: [
          %{
            id: "grant_unlimited",
            billing_account_id: "acct_1",
            remaining_credits: 0,
            status: "active",
            valid_from: ~U[2026-06-01 00:00:00Z],
            expires_at: ~U[2026-07-01 00:00:00Z],
            policy_snapshot: %{"usage_credits" => %{"mode" => "unlimited_metered"}}
          }
        ]
      )

    assert {:ok, decision} =
             FeeControl.authorize(%{
               state: state,
               billing_account_id: "acct_1",
               resource_kind: :llm,
               action: :start,
               mode: :enforce,
               estimated_credits: 1,
               checked_at: checked_at
             })

    refute decision.allowed?
    assert decision.reason == "insufficient_credits"
    assert decision.entitlement_mode == :metered
  end

  test "enforce mode refreshes even when an unlimited decision is cached" do
    state =
      State.new(
        fee_control_cache: %{
          {"acct_1", :llm, :start, "openai", "gpt-x", :enforce, 0} => %{
            snapshot: %{
              balance_snapshot: 0,
              account_status: "active",
              entitlement_policy: %{"usage_credits" => %{"mode" => "unlimited_metered"}},
              entitlement_mode: :unlimited_metered
            },
            cached_at_ms: 1_000
          }
        }
      )

    assert {:ok, decision, _state} =
             FeeControl.check(state, %{
               billing_account_id: "acct_1",
               resource_kind: :llm,
               action: :start,
               provider: "openai",
               sku: "gpt-x",
               mode: :enforce,
               estimated_credits: 1,
               now: 1_010,
               query_fun: fn -> %{balance_snapshot: 0, account_status: "active"} end
             })

    refute decision.cache_hit
    assert decision.query_performed
    refute decision.allowed?
    assert decision.reason == "insufficient_credits"
  end

  test "enforce mode blocks instead of trusting a snapshot when no query source exists" do
    assert {:ok, decision} =
             FeeControl.authorize(%{
               billing_account_id: "acct_no_repo",
               resource_kind: :llm,
               action: :start,
               provider: "runtime",
               sku: "llm",
               mode: :enforce,
               estimated_credits: 1,
               balance_snapshot: 100
             })

    refute decision.allowed?
    assert decision.reason == "missing_account"
    assert decision.balance_snapshot == 0
    refute decision.query_performed
  end

  test "typed request without cache_ttl_ms uses default TTL on cache hit" do
    state = State.new()

    request = %BillingCore.FeeControl.Request{
      billing_account_id: "acct_1",
      provider: "openai",
      sku: "gpt-x",
      resource_kind: :llm,
      action: :start,
      estimated_credits: 0,
      checked_at: ~U[2026-06-17 00:00:00Z]
    }

    assert {:ok, first, state} =
             FeeControl.check(state, Map.from_struct(request) |> Map.put(:now, 1_000))

    assert first.cache_ttl_ms == 60_000

    assert {:ok, second, _state} =
             FeeControl.check(state, Map.from_struct(request) |> Map.put(:now, 1_010))

    assert second.cache_hit == true
  end
end
