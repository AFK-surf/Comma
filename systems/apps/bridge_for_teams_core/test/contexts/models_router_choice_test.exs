defmodule BridgeForTeams.ModelsRouterChoiceTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Models, Orgs, Projects}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Organization

  @sol %{"kind" => "catalog", "model" => "gpt-6.1-sol", "reasoning_effort" => "max"}

  setup do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, project} = Projects.create_project(org.id, %{name: "P", slug: "p"})
    %{org: org, project: project}
  end

  # Changes the stored org, whatever an earlier call left in it.
  defp govern(org, attrs),
    do: Organization |> Repo.get!(org.id) |> Ecto.Changeset.change(attrs) |> Repo.update!()

  test "a Router's model follows the org's allowed list and default", %{org: org, project: p} do
    # An empty list allows every catalog model; Salix checks the catalog.
    assert {:ok, nil} = Models.router_choice(p.id, nil)
    assert {:ok, %{"model" => "gpt-6.1-sol"}} = Models.router_choice(p.id, @sol)

    default = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
    govern(org, allowed_models: [default], default_task_model: default)

    assert {:ok, ^default} = Models.router_choice(p.id, nil)
    assert {:error, :model_not_allowed} = Models.router_choice(p.id, @sol)

    # An allowed choice without an effort allows the model at any effort; a
    # choice without an effort takes medium.
    medium = Map.put(default, "reasoning_effort", "medium")
    assert {:ok, ^medium} = Models.router_choice(p.id, Map.delete(default, "allow_paid"))
    high = Map.put(default, "reasoning_effort", "high")
    assert {:ok, ^high} = Models.router_choice(p.id, high)

    # An allowed choice with an effort allows only that effort.
    govern(org, allowed_models: [@sol |> Models.normalize()])
    assert {:ok, _} = Models.router_choice(p.id, @sol)

    assert {:error, :model_not_allowed} =
             Models.router_choice(p.id, Map.put(@sol, "reasoning_effort", "low"))

    assert {:error, :model_not_allowed} =
             Models.router_choice(p.id, Map.delete(@sol, "reasoning_effort"))

    govern(org, allowed_models: [Models.normalize(%{@sol | "reasoning_effort" => "medium"})])

    assert {:ok, %{"reasoning_effort" => "medium"}} =
             Models.router_choice(p.id, Map.delete(@sol, "reasoning_effort"))

    govern(org, allowed_models: [default])

    # A model without reasoning efforts keeps none, and Salix accepts both.
    govern(org, allowed_models: [])
    gpt4 = %{"kind" => "catalog", "model" => "gpt-4"}
    astra = %{"kind" => "catalog", "model" => "gpt-6-astra"}

    assert {:ok, gpt4_choice} = Models.router_choice(p.id, gpt4)
    refute Map.has_key?(gpt4_choice, "reasoning_effort")
    assert {:ok, _} = Client.impl().choose_model(gpt4_choice, org.salix_tenant_id)

    assert {:ok, %{"reasoning_effort" => "medium"} = astra_choice} =
             Models.router_choice(p.id, astra)

    assert {:ok, _} = Client.impl().choose_model(astra_choice, org.salix_tenant_id)
    govern(org, allowed_models: [default])

    platform = %{"kind" => "platform", "tier" => "worker"}
    assert {:ok, ^platform} = Models.router_choice(p.id, platform)
  end

  test "a Router lists only the models it may choose", %{org: org, project: p} do
    sub = %{"served_by" => "subscription", "requires_allow_paid" => false}
    key = %{"served_by" => "api_key", "requires_allow_paid" => true}
    efforts = ~w(low medium high max)

    models = [
      Map.merge(sub, %{"id" => "gpt-5.5", "efforts" => efforts}),
      Map.merge(sub, %{"id" => "gpt-6.1-sol", "efforts" => efforts}),
      Map.merge(sub, %{"id" => "gpt-5.6-luna", "efforts" => efforts}),
      Map.merge(key, %{"id" => "claude-opus-4-8", "efforts" => efforts}),
      Map.merge(key, %{"id" => "claude-haiku-4-5", "efforts" => efforts})
    ]

    # An empty list keeps every model.
    assert {:ok, filter} = Models.router_model_filter(p.id)
    assert filter.(models) == models

    plain = Models.normalize(%{"kind" => "catalog", "model" => "gpt-5.5"})

    paid_sol =
      Models.normalize(%{"kind" => "catalog", "model" => "gpt-6.1-sol", "allow_paid" => true})

    opus =
      Models.normalize(%{"kind" => "catalog", "model" => "claude-opus-4-8", "allow_paid" => true})

    # Only keys serve Haiku, and this choice does not allow pay-per-use.
    haiku = Models.normalize(%{"kind" => "catalog", "model" => "claude-haiku-4-5"})

    govern(org,
      allowed_models: [plain, Map.put(paid_sol, "reasoning_effort", "high"), opus, haiku]
    )

    assert {:ok, filter} = Models.router_model_filter(p.id)
    listed = filter.(models)
    by_id = Map.new(listed, &{&1["id"], &1})

    assert Enum.map(listed, & &1["id"]) == ~w(gpt-5.5 gpt-6.1-sol claude-opus-4-8)
    assert %{"efforts" => ^efforts, "requires_allow_paid" => false} = by_id["gpt-5.5"]

    assert %{"efforts" => ["high"], "requires_allow_paid" => true, "choices" => [sol]} =
             by_id["gpt-6.1-sol"]

    assert sol["allow_paid"] == true

    # Every listed choice, at every listed effort, is one the Router may use.
    for model <- listed, choice <- model["choices"], effort <- model["efforts"] do
      assert {:ok, _} =
               Models.router_choice(p.id, Map.put(choice, "reasoning_effort", effort))
    end

    assert {:error, :target_not_found} = Models.router_model_filter(SystemsRuntime.Proc.uuid())
  end
end
