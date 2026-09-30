defmodule BridgeForTeams.BillingTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Billing, Orgs}
  alias BillingCommerce.PackageCatalog

  setup do
    seed_package("bridge_contract_phase8")
    seed_package("bridge_license_phase8")
    {:ok, org} = Orgs.create_org(%{name: "Billing Org", slug: "billing-org-#{uniq()}"})
    %{org: org}
  end

  test "Bridge org receives manual contract grants without Stripe config", %{org: org} do
    {valid_from, expires_at} = current_period()
    previous_secret_key = Application.get_env(:billing_stripe, :secret_key)
    previous_webhook_secret = Application.get_env(:billing_stripe, :webhook_secret)

    Application.delete_env(:billing_stripe, :secret_key)
    Application.delete_env(:billing_stripe, :webhook_secret)

    try do
      assert {:ok, %{grant: grant, manual_grant: source, idempotent: false}} =
               Billing.issue_manual_contract_grant(org.id, %{
                 package_code: "bridge_contract_phase8",
                 package_version: "2026-06",
                 valid_from: valid_from,
                 expires_at: expires_at,
                 source_id: "contract_phase8",
                 source_event_id: "operator_contract_phase8",
                 idempotency_key: "manual:#{org.id}:2026-06",
                 operator: %{id: "ops_1", reason: "contract grant"}
               })

      assert grant.billing_account_id == org.billing_account_id
      assert grant.remaining_credits == 800
      assert source.source_type == "manual_contract"

      assert {:ok, %{idempotent: true, grant: nil}} =
               Billing.issue_manual_contract_grant(org.id, %{
                 package_code: "bridge_contract_phase8",
                 package_version: "2026-06",
                 valid_from: valid_from,
                 expires_at: expires_at,
                 source_id: "contract_phase8",
                 source_event_id: "ignored_retry_event",
                 idempotency_key: "manual:#{org.id}:2026-06",
                 operator: %{id: "ops_1", reason: "contract grant retry"}
               })
    after
      restore_env(:billing_stripe, :secret_key, previous_secret_key)
      restore_env(:billing_stripe, :webhook_secret, previous_webhook_secret)
    end
  end

  test "new Bridge org receives default unlimited entitlement", %{org: org} do
    assert grant_count(org.billing_account_id, "default_entitlement") == 1

    %{rows: [[package_code, remaining_credits, policy_snapshot]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT package_code, remaining_credits, policy_snapshot
        FROM credit_grants
        WHERE billing_account_id = $1 AND source_type = 'default_entitlement'
        """,
        [org.billing_account_id]
      )

    assert package_code == "bridge_platform_unlimited"
    assert remaining_credits == 0
    assert decode_json(policy_snapshot)["usage_credits"]["mode"] == "unlimited_metered"
  end

  test "license source grants are idempotent by license identity and period", %{org: org} do
    {valid_from, expires_at} = current_period()

    attrs = %{
      package_code: "bridge_license_phase8",
      package_version: "2026-06",
      valid_from: valid_from,
      expires_at: expires_at,
      license_id: "lic_bridge_phase8",
      license_event_id: "license_event_phase8",
      license_issuer: "private-deploy",
      operator: %{id: "license_verifier", reason: "verified license"}
    }

    assert {:ok, %{grant: grant, manual_grant: source, idempotent: false}} =
             Billing.issue_license_grant(org.id, attrs)

    assert grant.billing_account_id == org.billing_account_id
    assert grant.remaining_credits == 600
    assert source.source_type == "license_period"
    assert source.source_id == "lic_bridge_phase8"

    assert source.idempotency_key ==
             "license:lic_bridge_phase8:#{DateTime.to_iso8601(valid_from)}"

    assert {:ok, %{idempotent: true, grant: nil}} =
             Billing.issue_license_grant(org.id, %{attrs | license_event_id: "ignored_retry"})

    assert grant_count(org.billing_account_id, "license_period") == 1
  end

  test "Bridge billing summary is derived from active BillingCore grants", %{org: org} do
    {valid_from, expires_at} = current_period()

    {:ok, _manual} =
      Billing.issue_manual_contract_grant(org.id, %{
        package_code: "bridge_contract_phase8",
        package_version: "2026-06",
        valid_from: valid_from,
        expires_at: expires_at,
        source_id: "contract_summary_phase8",
        source_event_id: "operator_summary_phase8",
        idempotency_key: "manual:#{org.id}:summary:2026-06",
        operator: %{id: "ops_1", reason: "summary"}
      })

    assert {:ok, summary} = Billing.org_billing_summary(org.id, at: DateTime.utc_now())
    assert summary.billing_account_id == org.billing_account_id
    assert summary.entitlement_mode == "unlimited_metered"
    assert summary.current_credits >= 800
    assert Enum.any?(summary.active_grants, &(&1.source_type == "default_entitlement"))
    assert Enum.any?(summary.active_grants, &(&1.source_type == "manual_contract"))

    assert {:ok, expired_summary} =
             Billing.org_billing_summary(org.id, at: DateTime.add(expires_at, 1, :second))

    assert expired_summary.entitlement_mode == "unlimited_metered"
    assert Enum.any?(expired_summary.active_grants, &(&1.source_type == "default_entitlement"))
    refute Enum.any?(expired_summary.active_grants, &(&1.source_id == "contract_summary_phase8"))
  end

  defp current_period do
    valid_from =
      DateTime.utc_now()
      |> DateTime.add(-1, :day)
      |> DateTime.truncate(:second)

    expires_at = DateTime.add(valid_from, 30, :day)
    {valid_from, expires_at}
  end

  defp seed_package(code) do
    {:ok, _} =
      PackageCatalog.create_package(%{
        code: code,
        surface: "bridge",
        name: code
      })

    credits = if String.contains?(code, "license"), do: 600, else: 800

    {:ok, _} =
      PackageCatalog.create_package_version(%{
        package_code: code,
        version: "2026-06",
        surface: "bridge",
        kind: "manual",
        billing_period: "month",
        grant_credits: credits,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 0,
        usage_policy: %{},
        effective_at: ~U[2026-06-01 00:00:00Z],
        status: "active"
      })
  end

  defp grant_count(account_id, source_type) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT count(*)
        FROM credit_grants
        WHERE billing_account_id = $1 AND source_type = $2
        """,
        [account_id, source_type]
      )

    count
  end

  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value), do: value

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp uniq, do: System.unique_integer([:positive])
end
