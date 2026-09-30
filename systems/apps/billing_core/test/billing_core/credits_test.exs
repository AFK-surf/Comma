defmodule BillingCore.CreditsTest do
  use ExUnit.Case, async: true

  alias BillingCore.{Credits, State}
  alias BillingCore.Entitlements.Policy

  @now ~U[2026-06-17 00:00:00Z]

  test "issue_grant/1 is idempotent by billing account and idempotency key" do
    state = State.new()

    attrs = %{
      state: state,
      billing_account_id: "acct_1",
      credits: 100,
      valid_from: @now,
      expires_at: ~U[2026-07-17 00:00:00Z],
      source_type: "manual_contract",
      source_id: "manual_1",
      source_event_id: "operator_1",
      idempotency_key: "manual:acct_1:2026-06",
      package_code: "bridge_contract",
      package_version: "2026-06"
    }

    assert {:ok, %{grant: grant, idempotent: false}, state} = Credits.issue_grant(attrs)
    assert grant.original_credits == 100
    assert grant.remaining_credits == 100
    assert grant.policy_snapshot == Policy.default()
    assert length(state.grant_events) == 1

    assert {:ok, %{grant: duplicate, idempotent: true}, same_state} =
             Credits.issue_grant(%{attrs | state: state, credits: 999})

    assert duplicate.id == grant.id
    assert same_state.grants == state.grants
    assert length(same_state.grant_events) == 1
  end

  test "policy normalizer rejects invalid persisted shapes" do
    assert {:ok,
            %{
              "usage_credits" => %{"mode" => "metered"},
              "llm_models" => %{"mode" => "unrestricted"}
            }} = Policy.normalize(nil)

    assert {:ok, %{"llm_models" => %{"mode" => "allowlist", "models" => ["gpt-x"]}}} =
             Policy.normalize(%{"llm_models" => %{"mode" => "allowlist", "models" => ["gpt-x"]}})

    assert {:error, {:invalid_llm_models, _}} =
             Policy.normalize(%{"llm_models" => %{"mode" => "allowlist", "models" => [nil]}})

    assert {:error, {:invalid_usage_credits, _}} =
             Policy.normalize(%{"usage_credits" => %{"mode" => "free_for_all"}})
  end

  test "active usage mode treats unlimited as an entitlement expansion" do
    metered = %{"usage_credits" => %{"mode" => "metered"}}
    unlimited = %{"usage_credits" => %{"mode" => "unlimited_metered"}}

    assert Policy.active_usage_mode([metered]) == :metered
    assert Policy.active_usage_mode([metered, unlimited]) == :unlimited_metered

    assert Policy.merge_active([metered, unlimited])["usage_credits"]["mode"] ==
             "unlimited_metered"
  end

  test "merge_active/1 preserves non-credit entitlement dimensions" do
    merged =
      Policy.merge_active([
        %{
          "usage_credits" => %{"mode" => "metered"},
          "llm_models" => %{"mode" => "allowlist", "models" => ["gpt-a"]},
          "vm_concurrency" => %{"mode" => "limit", "limit" => 2},
          "storage_hard_cap" => %{"mode" => "limit", "bytes" => 100}
        },
        %{
          "usage_credits" => %{"mode" => "unlimited_metered"},
          "llm_models" => %{"mode" => "allowlist", "models" => ["gpt-b"]},
          "vm_concurrency" => %{"mode" => "limit", "limit" => 4},
          "storage_hard_cap" => %{"mode" => "limit", "bytes" => 50}
        }
      ])

    assert merged["usage_credits"]["mode"] == "unlimited_metered"
    assert merged["llm_models"] == %{"mode" => "allowlist", "models" => ["gpt-a", "gpt-b"]}
    assert merged["vm_concurrency"] == %{"mode" => "limit", "limit" => 4}
    assert merged["storage_hard_cap"] == %{"mode" => "limit", "bytes" => 100}
  end

  test "grants without expiry remain available after a paid billing period" do
    assert {:ok, %{grant: grant}, state} =
             Credits.issue_grant(%{
               state: State.new(),
               billing_account_id: "acct_1",
               credits: 100,
               valid_from: @now,
               source_type: "comma_signup",
               source_id: "user_1",
               source_event_id: "user_1",
               idempotency_key: "comma_signup:user_1"
             })

    assert is_nil(grant.expires_at)
    assert grant.remaining_credits == 100

    assert Credits.active_policies(state.grants, "acct_1", ~U[2027-06-17 00:00:00Z]) ==
             [Policy.default()]
  end
end
