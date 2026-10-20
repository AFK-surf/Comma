defmodule BridgeForTeams.Migrations.OrgModelChoicesTest do
  @moduledoc """
  Organizations' template-based model settings become model choices
  (`BridgeForTeams.Migrations.OrgModelChoices` with
  `SalixAgent.Migrations.OrgModelChoices.choice/3`): a subscription-pool
  template its catalog model, an own endpoint the Custom Profile Salix made
  for it, a global template the platform model of a default's role; the rest
  is dropped. A second pass and settings saved since are left as they are.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.Migrations.OrgModelChoices
  alias BridgeForTeams.Orgs
  alias BridgeForTeams.Schema.Organization
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixStore.{Ids, Keys, S3}

  setup do
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    {:ok, org} =
      Orgs.create_org(%{
        name: "Models",
        slug: "models-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      })

    tenant = org.salix_tenant_id

    on_exit(fn ->
      Store.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [tenant])
    end)

    {:ok, org: org, tenant: tenant}
  end

  test "template settings become model choices once", %{org: org, tenant: tenant} do
    pool =
      private_template!(tenant, "Pool", %{"account_pool" => "codex", "reasoning_effort" => "high"})

    own =
      private_template!(tenant, "Own endpoint", %{
        "base_url" => "https://llm.example.test/v1",
        "api_key" => "sk-own-0123456789",
        "protocol" => "chat_completions"
      })

    # The Custom Profile Salix migration 20261009210001 made for `own`.
    {:ok, %{"id" => profile}} =
      SalixAgent.AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "name" => "Own endpoint",
        "api_key" => "sk-own-0123456789",
        "base_url" => "https://llm.example.test/v1",
        "protocol" => "chat_completions",
        "models" => ["gpt-5.5"]
      })

    unpinned_own =
      private_template!(tenant, "No profile", %{
        "base_url" => "https://other.example.test/v1",
        "api_key" => "sk-other-0123456789"
      })

    global = global_template!()

    set_template_settings!(org, %{
      allowed: [pool, own, unpinned_own, global, "ptm1_gone"],
      router: global,
      worker: pool
    })

    convert = &SalixAgent.Migrations.OrgModelChoices.choice/3
    assert {:ok, %{converted: 1}} = OrgModelChoices.run(Repo, convert)

    pool_choice = %{
      "kind" => "catalog",
      "model" => "gpt-5.5",
      "reasoning_effort" => "high",
      "allow_paid" => false
    }

    converted = Repo.get!(Organization, org.id)

    assert converted.allowed_models == [
             pool_choice,
             %{
               "kind" => "catalog",
               "model" => "gpt-5.5",
               "profile_id" => profile,
               "allow_paid" => true
             }
           ]

    assert converted.default_router_model == %{"kind" => "platform", "tier" => "router"}
    assert converted.default_task_model == pool_choice

    # A second pass changes nothing, and a default an admin saved since stays.
    saved = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
    converted |> Ecto.Changeset.change(default_task_model: saved) |> Repo.update!()
    assert {:ok, %{converted: 0}} = OrgModelChoices.run(Repo, convert)
    assert Repo.get!(Organization, org.id).default_task_model == saved
  end

  defp set_template_settings!(org, %{allowed: allowed, router: router, worker: worker}) do
    Repo.query!(
      """
      UPDATE organizations
      SET allowed_template_ids=$2, default_router_template_id=$3, default_template_id=$4
      WHERE id=$1
      """,
      [Ecto.UUID.dump!(org.id), allowed, router, worker]
    )
  end

  # Template records as earlier releases stored them.
  defp private_template!(tenant, name, provider_config) do
    id = Ids.new_private_template_id()

    put_template!(Keys.ctl_private_template(tenant, id), %{
      "template_id" => id,
      "tenant_id" => tenant,
      "name" => name,
      "model" => "gpt-5.5",
      "provider_config" => provider_config
    })
  end

  defp global_template! do
    id = "global-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    put_template!(Keys.ctl_template(id), %{"template_id" => id, "name" => id, "model" => "mock"})
  end

  defp put_template!(key, template) do
    {:ok, _} = S3.put(key, Jason.encode!(template))
    template["template_id"]
  end
end
