defmodule Comma.FreeMonthlyCreditsTest do
  require SystemsRuntime.Proc
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma", "Elixir.BillingCore"]
  alias Comma.Billing.FreeMonthlyCredits
  alias Comma.Workers.FreeMonthlyCredits, as: Worker

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, {:shared, SystemsRuntime.Proc.self()})
    previous = SystemsRuntime.get_env(:comma_core, :selfhost)
    SystemsRuntime.put_env(:comma_core, :selfhost, false)
    on_exit(fn -> SystemsRuntime.put_env(:comma_core, :selfhost, previous) end)
    :ok
  end

  test "a free user gets one grant a month, in the default Workspace, until the UTC month ends" do
    {user, workspace} = free_user("free")
    now = SystemsClock.utc_now()

    assert [%{credits: 5_000_000, remaining: 5_000_000, expires_at: expires_at, account: account}] =
             grants(user["id"])

    assert account == workspace["billing_account_id"]
    assert expires_at.day == 1 and DateTime.compare(expires_at, now) == :gt
    assert DateTime.diff(expires_at, now) <= 31 * 86_400

    assert :ok = Worker.perform(%Oban.Job{})
    assert :ok = FreeMonthlyCredits.ensure(workspace)
    assert length(grants(user["id"])) == 1

    {:ok, other} = Comma.Workspaces.create_for_user(user["id"])
    :ok = BillingCore.Accounts.ensure_account(account(other))
    assert :ok = FreeMonthlyCredits.ensure(other)
    assert length(grants(user["id"])) == 1
  end

  test "the monthly pass reaches a free user after a subscription ends, and skips subscribers" do
    {user, workspace} = free_user("subscriber")
    delete_grants(user["id"])
    subscribe(workspace, "active")

    assert :ok = Worker.perform(%Oban.Job{})
    assert grants(user["id"]) == []

    subscribe(workspace, "canceled")
    assert :ok = Worker.perform(%Oban.Job{})
    assert [%{credits: 5_000_000}] = grants(user["id"])
  end

  test "excluded addresses, disabled users and self-hosted instances get no grant" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])

    for email <- ["alias+#{unique}@comma.test", "temporary#{unique}@mailinator.com"] do
      {:ok, user} = Comma.Accounts.get_or_create_user_by_email(email)
      create_ready_workspace!(user["id"])
      assert :ok = Worker.perform(%Oban.Job{})
      assert grants(user["id"]) == []
    end

    {disabled, _workspace} = free_user("disabled")
    delete_grants(disabled["id"])

    Repo.get!(Comma.Accounts.User, disabled["id"])
    |> Ecto.Changeset.change(status: "disabled")
    |> Repo.update!()

    assert :ok = Worker.perform(%Oban.Job{})
    assert grants(disabled["id"]) == []

    {selfhost, _workspace} = free_user("selfhost")
    delete_grants(selfhost["id"])
    SystemsRuntime.put_env(:comma_core, :selfhost, true)
    assert :ok = Worker.perform(%Oban.Job{})
    assert grants(selfhost["id"]) == []
  end

  test "the grant pays for Cloud VM and storage, and never for hosted models or voice" do
    {user, workspace} = free_user("spend")
    account = workspace["billing_account_id"]
    drop_other_grants(account)

    assert {:ok, %{allowed?: true}} = admit(account, :vm, "cloudflare", "runtime-minimum")
    assert {:ok, %{allowed?: true}} = admit(account, :storage, "salix_store", "storage_write")

    assert {:ok, %{allowed?: false, reason: "insufficient_credits", balance_snapshot: 0}} =
             admit(account, :llm, "runtime", "llm")

    assert {:ok, %{allowed?: false, reason: "insufficient_credits"}} =
             admit(account, :voice, "openai", "gpt-live-1")

    assert {:ok, %{status: "charged", charged_credits: vm_credits}} =
             charge(account, "vm", "cloudflare", "runtime-minimum", "vm:1", 10)

    assert vm_credits > 0
    assert [%{remaining: remaining}] = grants(user["id"])
    assert remaining == 5_000_000 - vm_credits

    price_test_model()

    assert {:ok, %{status: "grace", charged_credits: 7, grace_credits: 7, grant_debits: []}} =
             charge(account, "llm", "free-monthly-test", "model", "llm:1", 7)

    assert [%{remaining: ^remaining}] = grants(user["id"])
  end

  test "ordinary credits still pay for hosted models beside the grant" do
    {_user, workspace} = free_user("mixed")
    account = workspace["billing_account_id"]
    drop_other_grants(account)

    {:ok, _} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: account,
        idempotency_key: "test:ordinary",
        source_type: "manual_adjustment",
        source_id: "test",
        credits: 40,
        valid_from: DateTime.add(SystemsClock.utc_now(), -60)
      })

    assert {:ok, %{allowed?: true, balance_snapshot: 40}} =
             admit(account, :llm, "runtime", "llm")

    assert {:ok, %{balance_snapshot: 5_000_040}} =
             admit(account, :vm, "cloudflare", "runtime-minimum")
  end

  defp free_user(prefix) do
    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "#{prefix}-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      )

    {user, create_ready_workspace!(user["id"])}
  end

  defp admit(account, kind, provider, sku) do
    BillingCore.FeeControl.authorize(%{
      billing_account_id: account,
      resource_kind: kind,
      action: :start,
      mode: :enforce,
      estimated_credits: 1,
      provider: provider,
      sku: sku,
      repo: BillingCore.Repo,
      typed_sink: false,
      source: "test",
      source_key: "test:#{kind}",
      row_context: %{}
    })
  end

  defp charge(account, kind, provider, sku, key, quantity) do
    BillingCore.RepoCharges.charge_meter_event(%{
      repo: BillingCore.Repo,
      typed_sink: false,
      billing_account_id: account,
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: String.replace_prefix(account, "comma-ba-", ""),
      source_key: key,
      resource_kind: kind,
      provider: provider,
      sku: sku,
      quantity: quantity,
      metered_at: SystemsClock.utc_now()
    })
  end

  defp price_test_model do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO meter_pricing_catalog (
        id, resource_kind, provider, sku, component, meter_unit, usd_micros_per_unit,
        effective_at, version
      ) VALUES (
        'free-monthly-test', 'llm', 'free-monthly-test', 'model', 'runtime', 'token', 1,
        '2026-01-01', 'test'
      )
      """,
      []
    )
  end

  defp subscribe(workspace, status) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      DELETE FROM billing_subscriptions WHERE billing_account_id = $1
      """,
      [workspace["billing_account_id"]]
    )

    {:ok, _} =
      BillingCommerce.PackageCatalog.create_package(%{
        code: "free_monthly_test",
        surface: "comma",
        name: "Test",
        status: "active"
      })

    {:ok, _} =
      BillingCommerce.PackageCatalog.create_package_version(%{
        package_code: "free_monthly_test",
        version: "v1",
        surface: "comma",
        kind: "manual",
        billing_period: "month",
        grant_credits: 0,
        grant_period: "explicit",
        currency: "usd",
        amount_minor: 0,
        usage_policy: %{},
        effective_at: ~U[2026-01-01 00:00:00Z],
        expires_at: nil,
        status: "active"
      })

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_subscriptions (
        id, billing_account_id, surface, product_owner_type, product_owner_id,
        package_code, package_version, source_type, source_id, source_event_id,
        idempotency_key, status
      ) VALUES ($1, $2, 'comma', 'workspace', $3, 'free_monthly_test', 'v1', 'test', $1, $1, $1, $4)
      """,
      ["sub-" <> workspace["id"], workspace["billing_account_id"], workspace["id"], status]
    )
  end

  defp account(workspace),
    do: %{
      billing_account_id: workspace["billing_account_id"],
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: workspace["id"],
      enforce_product_owner_identity: true
    }

  defp drop_other_grants(account) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE credit_grants SET remaining_credits = 0 WHERE billing_account_id = $1 AND source_type <> 'comma_free_monthly'",
      [account]
    )
  end

  defp delete_grants(user) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "DELETE FROM credit_grant_events WHERE credit_grant_id IN (SELECT id FROM credit_grants WHERE source_type = 'comma_free_monthly' AND source_id = $1)",
      [user]
    )

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "DELETE FROM credit_grants WHERE source_type = 'comma_free_monthly' AND source_id = $1",
      [user]
    )
  end

  defp grants(user) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "SELECT original_credits, remaining_credits, expires_at, billing_account_id FROM credit_grants WHERE source_type = 'comma_free_monthly' AND source_id = $1",
      [user]
    ).rows
    |> Enum.map(fn [credits, remaining, expires_at, account] ->
      %{credits: credits, remaining: remaining, expires_at: expires_at, account: account}
    end)
  end
end
