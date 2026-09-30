defmodule CommaCore.SalixAgentStorageAuthorizationTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(%{
      id: __MODULE__.ProjectionLog,
      start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__.ProjectionLog]]}
    })

    :ok
  end

  setup_all do
    {:ok, _, _} =
      Ecto.Migrator.with_repo(BillingCore.Repo, fn repo ->
        Ecto.Migrator.run(repo, :up, all: true)
      end)

    :ok
  end

  test "denied storage writes emit observable fee-control projection rows" do
    assert {:error, {:billing_unavailable, decision}} =
             SalixAgent.StorageAuthorization.BillingCore.authorize_write(%{
               typed_sink: __MODULE__.ProjectionSink,
               source_key: "storage-denied-1",
               balance_snapshot: 0,
               billing_context: %{
                 "billing_account_id" => "ba_storage_denied",
                 "surface" => "comma",
                 "product_owner_type" => "workspace",
                 "product_owner_id" => "wsp_storage_denied",
                 "salix_tenant_id" => "tenant_storage",
                 "salix_group_id" => "group_storage",
                 "entrypoint" => "workspace_write",
                 "actor_type" => "user"
               }
             })

    assert decision.allowed? == false

    assert [
             %{
               "resource_kind" => "fee_control",
               "target_resource_kind" => :storage,
               "allowed" => false,
               "surface" => "comma",
               "billing_account_id" => "ba_storage_denied"
             }
           ] = Agent.get(__MODULE__.ProjectionLog, & &1)
  end

  test "unlimited storage writes are allowed with zero credits" do
    account_id = unique_account_id("ba_storage_unlimited")
    issue_unlimited_grant(account_id)

    assert :ok =
             SalixAgent.StorageAuthorization.BillingCore.authorize_write(%{
               typed_sink: __MODULE__.ProjectionSink,
               source_key: "storage-unlimited-1",
               balance_snapshot: 0,
               billing_context: %{
                 "billing_account_id" => account_id,
                 "surface" => "bridge",
                 "product_owner_type" => "organization",
                 "product_owner_id" => "org_storage_unlimited",
                 "salix_tenant_id" => "tenant_storage",
                 "salix_group_id" => "group_storage",
                 "entrypoint" => "workspace_write",
                 "actor_type" => "user"
               }
             })

    assert [
             %{
               "resource_kind" => "fee_control",
               "target_resource_kind" => :storage,
               "allowed" => true,
               "reason" => "allowed_unlimited",
               "surface" => "bridge",
               "billing_account_id" => ^account_id,
               "entitlement_mode" => "unlimited_metered"
             }
           ] = Agent.get(__MODULE__.ProjectionLog, & &1)
  end

  test "revoked unlimited storage writes are blocked with zero credits" do
    account_id = unique_account_id("ba_storage_revoked")
    issue_unlimited_grant(account_id)

    assert :ok =
             SalixAgent.StorageAuthorization.BillingCore.authorize_write(%{
               typed_sink: __MODULE__.ProjectionSink,
               source_key: "storage-revoked-warm-1",
               balance_snapshot: 0,
               billing_context: storage_billing_context(account_id, "org_storage_revoked")
             })

    Agent.update(__MODULE__.ProjectionLog, fn _ -> [] end)
    revoke_default_entitlement(account_id)

    assert {:error, {:billing_unavailable, decision}} =
             SalixAgent.StorageAuthorization.BillingCore.authorize_write(%{
               typed_sink: __MODULE__.ProjectionSink,
               source_key: "storage-revoked-1",
               balance_snapshot: 0,
               billing_context: storage_billing_context(account_id, "org_storage_revoked")
             })

    assert decision.reason == "insufficient_credits"
    assert decision.entitlement_mode == :metered
  end

  defmodule ProjectionSink do
    # Fee-control checks reach the sink through the nonblocking enqueue path
    # (BillingCore.FeeControl.Server); its rescue would hide a missing clause.
    def enqueue(rows, _opts) do
      _ = insert(rows)
      :ok
    end

    def insert(rows) do
      Agent.update(CommaCore.SalixAgentStorageAuthorizationTest.ProjectionLog, &(rows ++ &1))
      {:ok, length(rows)}
    end
  end

  defp issue_unlimited_grant(account_id) do
    ensure_billing_repo_started()

    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        surface: "bridge",
        product_owner_type: "organization",
        product_owner_id: account_id
      })

    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        credits: 0,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at: future_expiry(),
        source_type: "default_entitlement",
        source_id: "bridge_platform_unlimited",
        source_event_id: "storage-test:#{account_id}",
        idempotency_key: "storage-test:#{account_id}:default",
        policy_snapshot: %{"usage_credits" => %{"mode" => "unlimited_metered"}}
      })

    :ok
  end

  defp storage_billing_context(account_id, owner_id) do
    %{
      "billing_account_id" => account_id,
      "surface" => "bridge",
      "product_owner_type" => "organization",
      "product_owner_id" => owner_id,
      "salix_tenant_id" => "tenant_storage",
      "salix_group_id" => "group_storage",
      "entrypoint" => "workspace_write",
      "actor_type" => "user"
    }
  end

  defp revoke_default_entitlement(account_id) do
    ensure_billing_repo_started()

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      UPDATE credit_grants
      SET status = 'revoked', updated_at = now()
      WHERE billing_account_id = $1 AND source_type = 'default_entitlement'
      """,
      [account_id]
    )

    :ok
  end

  defp ensure_billing_repo_started do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end
  end

  defp future_expiry do
    DateTime.utc_now()
    |> DateTime.add(30, :day)
    |> DateTime.truncate(:second)
  end

  defp unique_account_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
