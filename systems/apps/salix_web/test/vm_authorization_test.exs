defmodule SalixWeb.VMAuthorizationTest do
  use ExUnit.Case, async: false

  setup do
    ensure_billing_repo_started()
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    start_supervised!(%{
      id: __MODULE__.ProjectionLog,
      start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__.ProjectionLog]]}
    })

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    :ok
  end

  test "paid LLM calls with omitted or zero estimates reject an exhausted account" do
    account = unique_account_id("ba_llm")

    assert :ok =
             BillingCore.Accounts.ensure_account(%{
               billing_account_id: account,
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: account
             })

    fact = %{
      billing_account_id: account,
      provider: "openai",
      model: "gpt-4.1",
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: account,
      fee_control_typed_sink: __MODULE__.ProjectionSink
    }

    for paid <- [fact, Map.put(fact, :estimated_credits, 0)] do
      assert {:error, {:billing_unavailable, %{reason: "insufficient_credits"}}} =
               BillingCore.LLMMetering.before_llm_call(paid)
    end

    assert :ok =
             BillingCore.LLMMetering.before_llm_call(Map.put(fact, :credential_scope, "tenant"))
  end

  test "voice admission uses account availability and keeps unattributed calls" do
    account = unique_account_id("ba_voice")

    assert :ok =
             BillingCore.Accounts.ensure_account(%{
               billing_account_id: account,
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: account
             })

    assert {:error, {:billing_unavailable, %{reason: "insufficient_credits"}}} =
             BillingCore.VoiceMetering.authorize(%{
               group_id: "group_voice",
               owner_snapshot: %{"billing_account_id" => account, "surface" => "comma"}
             })

    assert :ok = BillingCore.VoiceMetering.authorize(%{owner_snapshot: %{}})
  end

  test "denied VM authorization emits observable fee-control projection rows" do
    assert {:error, {:billing_unavailable, decision}} =
             SalixWeb.ComputeProviders.Cloudflare.VMAuthorization.BillingCore.authorize_vm(%{
               typed_sink: __MODULE__.ProjectionSink,
               source_key: "vm-denied-1",
               action: :resume,
               balance_snapshot: 0,
               billing_owner: %{
                 "billing_account_id" => "ba_vm_denied",
                 "surface" => "bridge",
                 "product_owner_type" => "organization",
                 "product_owner_id" => "org_vm_denied",
                 "salix_tenant_id" => "tenant_vm",
                 "salix_group_id" => "group_vm"
               }
             })

    assert decision.allowed? == false

    assert [
             %{
               "resource_kind" => "fee_control",
               "target_resource_kind" => :vm,
               "allowed" => false,
               "surface" => "bridge",
               "billing_account_id" => "ba_vm_denied"
             }
           ] = Agent.get(__MODULE__.ProjectionLog, & &1)
  end

  test "unlimited VM authorization is allowed with zero credits" do
    account_id = unique_account_id("ba_vm_unlimited")
    issue_unlimited_grant(account_id)

    assert :ok =
             SalixWeb.ComputeProviders.Cloudflare.VMAuthorization.BillingCore.authorize_vm(%{
               typed_sink: __MODULE__.ProjectionSink,
               source_key: "vm-unlimited-1",
               action: :resume,
               balance_snapshot: 0,
               billing_owner: %{
                 "billing_account_id" => account_id,
                 "surface" => "bridge",
                 "product_owner_type" => "organization",
                 "product_owner_id" => "org_vm_unlimited",
                 "salix_tenant_id" => "tenant_vm",
                 "salix_group_id" => "group_vm"
               }
             })

    assert [
             %{
               "resource_kind" => "fee_control",
               "target_resource_kind" => :vm,
               "allowed" => true,
               "reason" => "allowed_unlimited",
               "surface" => "bridge",
               "billing_account_id" => ^account_id,
               "entitlement_mode" => "unlimited_metered"
             }
           ] = Agent.get(__MODULE__.ProjectionLog, & &1)
  end

  test "revoked unlimited VM authorization is blocked with zero credits" do
    account_id = unique_account_id("ba_vm_revoked")
    issue_unlimited_grant(account_id)

    assert :ok =
             SalixWeb.ComputeProviders.Cloudflare.VMAuthorization.BillingCore.authorize_vm(%{
               typed_sink: __MODULE__.ProjectionSink,
               source_key: "vm-revoked-warm-1",
               action: :resume,
               balance_snapshot: 0,
               billing_owner: vm_billing_owner(account_id, "org_vm_revoked")
             })

    Agent.update(__MODULE__.ProjectionLog, fn _ -> [] end)
    revoke_default_entitlement(account_id)

    assert {:error, {:billing_unavailable, decision}} =
             SalixWeb.ComputeProviders.Cloudflare.VMAuthorization.BillingCore.authorize_vm(%{
               typed_sink: __MODULE__.ProjectionSink,
               source_key: "vm-revoked-1",
               action: :resume,
               balance_snapshot: 0,
               billing_owner: vm_billing_owner(account_id, "org_vm_revoked")
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
      Agent.update(SalixWeb.VMAuthorizationTest.ProjectionLog, &(rows ++ &1))
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
        source_event_id: "vm-test:#{account_id}",
        idempotency_key: "vm-test:#{account_id}:default",
        policy_snapshot: %{"usage_credits" => %{"mode" => "unlimited_metered"}}
      })

    :ok
  end

  defp vm_billing_owner(account_id, owner_id) do
    %{
      "billing_account_id" => account_id,
      "surface" => "bridge",
      "product_owner_type" => "organization",
      "product_owner_id" => owner_id,
      "salix_tenant_id" => "tenant_vm",
      "salix_group_id" => "group_vm"
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
