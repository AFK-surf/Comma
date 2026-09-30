defmodule BillingCommerce.ManualGrantsTest do
  use ExUnit.Case, async: false

  alias BillingCommerce.{ManualGrants, PackageCatalog}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)

    start_supervised!(%{
      id: __MODULE__.WakeLog,
      start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__.WakeLog]]}
    })

    start_supervised!(%{
      id: __MODULE__.ProjectionLog,
      start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__.ProjectionLog]]}
    })

    Application.put_env(:billing_commerce, :vm_resume_waker, {__MODULE__, :record_wake})
    Application.put_env(:billing_commerce, :billing_source_typed_sink, __MODULE__.ProjectionSink)

    on_exit(fn ->
      Application.delete_env(:billing_commerce, :vm_resume_waker)
      Application.delete_env(:billing_commerce, :billing_source_typed_sink)
    end)

    seed_package("bridge_contract", "bridge")
    seed_package("comma_support", "comma")
    :ok
  end

  test "BFT org billing account can receive an idempotent manual current-period grant" do
    attrs =
      manual_attrs(%{
        billing_account_id: "bridge-ba-org_1",
        organization_id: "org_1",
        package_code: "bridge_contract",
        package_version: "2026-06",
        idempotency_key: "manual:org_1:2026-06"
      })

    assert {:ok, result} = ManualGrants.issue_bridge_org_grant(attrs)
    assert result.grant.remaining_credits == 500
    assert result.manual_grant.status == "issued"
    assert result.manual_grant.credit_grant_id == result.grant.id
    assert result.idempotent == false

    assert {:ok, duplicate} =
             ManualGrants.issue_bridge_org_grant(%{attrs | source_event_id: "ignored"})

    assert duplicate.idempotent == true
    assert duplicate.grant == nil

    assert grant_count("bridge-ba-org_1") == 1

    assert [
             %{
               billing_account_id: "bridge-ba-org_1",
               in_transaction?: false,
               grant_count_at_wake: 1
             }
           ] = Agent.get(__MODULE__.WakeLog, & &1)

    assert [%{"resource_kind" => "billing_source", "event_kind" => "grant_issued"}] =
             Agent.get(__MODULE__.ProjectionLog, & &1)
  end

  test "BFT default unlimited entitlement issues a zero-credit unlimited grant" do
    assert {:ok, result} =
             BillingCommerce.issue_bridge_platform_unlimited(%{
               billing_account_id: "bridge-ba-org_default",
               organization_id: "org_default",
               valid_from: ~U[2026-06-20 00:00:00Z],
               expires_at: ~U[2099-12-31 23:59:59Z]
             })

    assert result.grant.remaining_credits == 0
    assert result.manual_grant.source_type == "default_entitlement"
    assert result.manual_grant.source_id == "bridge_platform_unlimited"
    assert result.manual_grant.idempotency_key == "bridge:default_unlimited:org_default"

    assert {:ok, version} =
             BillingCommerce.get_package_version(%{
               package_code: "bridge_platform_unlimited",
               version: "2026-06"
             })

    assert version.expires_at == nil

    row =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT package_code, package_version, policy_snapshot
        FROM credit_grants
        WHERE billing_account_id = $1 AND source_type = 'default_entitlement'
        """,
        ["bridge-ba-org_default"]
      ).rows
      |> hd()

    assert ["bridge_platform_unlimited", "2026-06", policy_snapshot] = row
    assert decode_json(policy_snapshot)["usage_credits"]["mode"] == "unlimited_metered"

    assert {:ok, duplicate} =
             BillingCommerce.issue_bridge_platform_unlimited(%{
               billing_account_id: "bridge-ba-org_default",
               organization_id: "org_default",
               valid_from: ~U[2026-06-20 00:00:00Z],
               expires_at: ~U[2099-12-31 23:59:59Z]
             })

    assert duplicate.idempotent == true
    assert duplicate.grant == nil
    assert grant_count("bridge-ba-org_default") == 1
  end

  defmodule ProjectionSink do
    def insert(rows) do
      Agent.update(BillingCommerce.ManualGrantsTest.ProjectionLog, &(rows ++ &1))
      {:ok, length(rows)}
    end
  end

  test "BFT manual grants do not require Stripe configuration" do
    previous_secret_key = Application.get_env(:billing_stripe, :secret_key)
    previous_webhook_secret = Application.get_env(:billing_stripe, :webhook_secret)

    Application.delete_env(:billing_stripe, :secret_key)
    Application.delete_env(:billing_stripe, :webhook_secret)

    attrs =
      manual_attrs(%{
        billing_account_id: "bridge-ba-org_no_stripe",
        organization_id: "org_no_stripe",
        package_code: "bridge_contract",
        package_version: "2026-06",
        idempotency_key: "manual:org_no_stripe:2026-06",
        source_id: "contract_no_stripe",
        source_event_id: "operator_event_no_stripe"
      })

    try do
      assert {:ok, result} = ManualGrants.issue_bridge_org_grant(attrs)
      assert result.grant.remaining_credits == 500
      assert result.manual_grant.status == "issued"
      assert grant_count("bridge-ba-org_no_stripe") == 1
    after
      restore_env(:billing_stripe, :secret_key, previous_secret_key)
      restore_env(:billing_stripe, :webhook_secret, previous_webhook_secret)
    end
  end

  test "Comma support account can receive the same BillingCore grant lot shape" do
    attrs =
      manual_attrs(%{
        billing_account_id: "example-ba-wsp_1",
        workspace_id: "wsp_1",
        package_code: "comma_support",
        package_version: "2026-06",
        idempotency_key: "manual:wsp_1:2026-06"
      })

    assert {:ok, %{grant: grant, manual_grant: source}} =
             ManualGrants.issue_comma_support_grant(attrs)

    assert grant.billing_account_id == "example-ba-wsp_1"
    assert grant.remaining_credits == 500
    assert source.source_type == "manual_contract"

    row =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT package_code, package_version, package_snapshot, policy_snapshot
        FROM credit_grants
        WHERE billing_account_id = $1
        """,
        ["example-ba-wsp_1"]
      ).rows
      |> hd()

    assert ["comma_support", "2026-06", package_snapshot, policy_snapshot] = row
    package_snapshot = decode_json(package_snapshot)
    policy_snapshot = decode_json(policy_snapshot)

    assert package_snapshot["grant_credits"] == 500
    assert policy_snapshot["storage_hard_cap"]["mode"] == "unrestricted"
  end

  test "Comma support grants cannot issue Bridge unlimited package" do
    assert {:ok, _synced} = BillingCommerce.sync_bridge_default_entitlements()

    attrs =
      manual_attrs(%{
        billing_account_id: "example-ba-wsp_bridge_pkg",
        workspace_id: "wsp_bridge_pkg",
        package_code: "bridge_platform_unlimited",
        package_version: "2026-06",
        idempotency_key: "manual:wsp_bridge_pkg:bridge-unlimited"
      })

    assert {:error, :package_surface_mismatch} = BillingCommerce.issue_comma_support_grant(attrs)
    assert grant_count("example-ba-wsp_bridge_pkg") == 0
  end

  test "BFT default entitlement cannot mutate an existing Comma account" do
    insert_billing_account!("example-ba-wsp_existing", "comma", "workspace", "wsp_existing")

    assert {:error, :billing_account_surface_mismatch} =
             BillingCommerce.issue_bridge_platform_unlimited(%{
               billing_account_id: "example-ba-wsp_existing",
               organization_id: "org_existing"
             })

    assert account_surface("example-ba-wsp_existing") == "comma"
    assert grant_count("example-ba-wsp_existing") == 0
  end

  test "manual adjustment source issues the same bounded grant shape" do
    attrs =
      manual_attrs(%{
        billing_account_id: "example-ba-wsp_adjustment",
        workspace_id: "wsp_adjustment",
        package_code: "comma_support",
        package_version: "2026-06",
        idempotency_key: "manual:wsp_adjustment:adjustment",
        source_type: "manual_adjustment",
        source_id: "adjustment_1",
        source_event_id: "operator_adjustment_1"
      })

    assert {:ok, %{grant: grant, manual_grant: source}} =
             ManualGrants.issue_comma_support_grant(attrs)

    assert grant.remaining_credits == 500
    assert source.source_type == "manual_adjustment"
  end

  test "Comma Admin recovery validates the immutable owner command tuple" do
    billing_account_id = "example-ba-wsp_admin_recovery"
    workspace_id = "wsp_admin_recovery"
    source_event_id = "audit-admin-recovery"

    insert_billing_account!(
      billing_account_id,
      "comma",
      "workspace",
      workspace_id
    )

    attrs = %{
      billing_account_id: billing_account_id,
      workspace_id: workspace_id,
      package_code: "comma_support",
      package_version: "2026-06",
      idempotency_key:
        BillingCommerce.ManualGrantCommands.billing_idempotency_key(source_event_id),
      source_type: "manual_adjustment",
      source_id: "comma_admin:#{workspace_id}",
      source_event_id: source_event_id,
      operator: %{
        "id" => "usr_admin",
        "type" => "comma_admin_user",
        "reason" => "Approved support grant"
      },
      valid_from: ~U[2026-06-01 00:00:00Z],
      expires_at: ~U[2099-07-01 00:00:00Z],
      enforce_product_owner_identity: true,
      metadata: %{
        "admin_command_id" => source_event_id,
        "workspace_id" => workspace_id
      }
    }

    assert {:error, :invalid_manual_grant} =
             attrs
             |> Map.put(:expires_at, DateTime.add(DateTime.utc_now(), -1, :second))
             |> ManualGrants.issue_comma_admin_support_grant()

    assert {:ok, issued} = ManualGrants.issue_comma_admin_support_grant(attrs)
    assert issued.idempotent == false

    assert {:ok, recovered} =
             attrs
             |> Map.put(:valid_from, ~U[2026-08-01 00:00:00Z])
             |> ManualGrants.issue_comma_admin_support_grant()

    assert recovered.idempotent == true
    assert recovered.manual_grant.id == issued.manual_grant.id
    assert recovered.grant == nil

    for conflicting_attrs <- [
          Map.put(attrs, :expires_at, ~U[2099-07-02 00:00:00Z]),
          put_in(attrs, [:operator, "id"], "usr_other_admin"),
          Map.put(attrs, :package_version, "missing-version")
        ] do
      assert {:error, :admin_idempotency_key_conflict} =
               ManualGrants.issue_comma_admin_support_grant(conflicting_attrs)
    end

    assert grant_count(billing_account_id) == 1
  end

  test "owner-fenced manual adjustment cannot relink an existing Billing account" do
    insert_billing_account!(
      "example-ba-wsp_owner_fence",
      "comma",
      "workspace",
      "wsp_authoritative"
    )

    attrs =
      manual_attrs(%{
        billing_account_id: "example-ba-wsp_owner_fence",
        workspace_id: "wsp_spoofed",
        package_code: "comma_support",
        package_version: "2026-06",
        idempotency_key: "manual:wsp_owner_fence:adjustment",
        source_type: "manual_adjustment",
        source_id: "adjustment_owner_fence",
        source_event_id: "operator_owner_fence",
        enforce_product_owner_identity: true
      })

    assert {:error, :billing_account_owner_mismatch} =
             ManualGrants.issue_comma_support_grant(attrs)

    assert account_owner("example-ba-wsp_owner_fence") == {"workspace", "wsp_authoritative"}
    assert grant_count("example-ba-wsp_owner_fence") == 0
  end

  test "manual grant rejects inactive, future, and expired package versions" do
    seed_package("inactive_support", "comma", status: "inactive")
    seed_package("future_support", "comma", effective_at: ~U[2026-08-01 00:00:00Z])
    seed_package("expired_support", "comma", expires_at: ~U[2026-06-01 00:00:00Z])

    base = %{
      billing_account_id: "example-ba-wsp_pkg_guard",
      workspace_id: "wsp_pkg_guard",
      package_version: "2026-06",
      source_id: "contract_pkg_guard",
      source_event_id: "operator_pkg_guard"
    }

    assert {:error, :package_version_inactive} =
             issue_package_guard(Map.merge(base, %{package_code: "inactive_support"}))

    assert {:error, :package_version_not_yet_effective} =
             issue_package_guard(Map.merge(base, %{package_code: "future_support"}))

    assert {:error, :package_version_expired} =
             issue_package_guard(Map.merge(base, %{package_code: "expired_support"}))

    assert grant_count("example-ba-wsp_pkg_guard") == 0
  end

  test "manual grant command requires explicit period windows" do
    attrs =
      manual_attrs(%{
        billing_account_id: "example-ba-wsp_missing_period",
        workspace_id: "wsp_missing_period",
        package_code: "comma_support",
        package_version: "2026-06",
        idempotency_key: "manual:wsp_missing_period:2026-06"
      })

    attrs = Map.delete(attrs, :expires_at)

    assert {:error, :explicit_valid_from_and_expires_at_required} =
             ManualGrants.issue_comma_support_grant(attrs)
  end

  test "unsupported manual source types are rejected before grant issuance" do
    attrs =
      manual_attrs(%{
        billing_account_id: "example-ba-wsp_bad_source",
        workspace_id: "wsp_bad_source",
        package_code: "comma_support",
        package_version: "2026-06",
        idempotency_key: "manual:wsp_bad_source:2026-06",
        source_type: "stripe_invoice"
      })

    assert {:error, :invalid_manual_source_type} = ManualGrants.issue_comma_support_grant(attrs)
    assert grant_count("example-ba-wsp_bad_source") == 0
  end

  def record_wake(payload) do
    payload =
      Map.merge(payload, %{
        in_transaction?: BillingCore.Repo.in_transaction?(),
        grant_count_at_wake: grant_count(payload.billing_account_id)
      })

    Agent.update(__MODULE__.WakeLog, &[payload | &1])
  end

  defp seed_package(code, surface, opts \\ []) do
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
        kind: "manual",
        billing_period: "month",
        grant_credits: 500,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 0,
        usage_policy: %{},
        effective_at: Keyword.get(opts, :effective_at, ~U[2026-06-01 00:00:00Z]),
        expires_at: Keyword.get(opts, :expires_at),
        status: Keyword.get(opts, :status, "active")
      })
  end

  defp issue_package_guard(attrs) do
    attrs
    |> Map.put(:idempotency_key, "manual:#{attrs.package_code}:pkg_guard")
    |> manual_attrs()
    |> ManualGrants.issue_comma_support_grant()
  end

  defp manual_attrs(attrs) do
    Map.merge(
      %{
        valid_from: ~U[2026-06-01 00:00:00Z],
        expires_at: ~U[2026-07-01 00:00:00Z],
        source_type: "manual_contract",
        source_id: "contract_1",
        source_event_id: "operator_event_1",
        operator: %{id: "ops_1", reason: "test grant"}
      },
      attrs
    )
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

  defp account_owner(account_id) do
    %{rows: [[owner_type, owner_id]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT product_owner_type, product_owner_id
        FROM billing_accounts
        WHERE id = $1
        """,
        [account_id]
      )

    {owner_type, owner_id}
  end

  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value), do: value

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
