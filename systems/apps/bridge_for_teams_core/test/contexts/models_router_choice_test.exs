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

    pinned = Map.put(haiku, "profile_id", "org-key")
    govern(org, allowed_models: [pinned])
    assert {:ok, filter} = Models.router_model_filter(p.id)
    assert [%{"choices" => [^pinned]}] = filter.(models)
    assert {:ok, _} = Models.router_choice(p.id, pinned)
    assert {:ok, other_profile} = Models.router_model_filter(p.id, profile_id: "other-key")
    assert other_profile.(models) == []

    assert {:error, :target_not_found} = Models.router_model_filter(SystemsRuntime.Proc.uuid())
  end

  test "the platform Router mark has its own key and no org choice can hold it", %{
    org: org,
    project: p
  } do
    plain = Models.normalize(%{"kind" => "catalog", "model" => "gpt-5.5"})
    marked = %{"kind" => "catalog", "model" => "gpt-5.5", "platform" => true}

    # A kept marked Router and one switched to the org's own account differ.
    assert Models.normalize(marked)["platform"] == true
    assert Models.key(Models.normalize(marked)) == "catalog:gpt-5.5+platform"
    assert Models.key(plain) == "catalog:gpt-5.5"

    # Not offered, allowed or chosen, whatever the allowed list says.
    catalog = {:ok, [Models.option(plain, [])]}
    assert Models.allowed?(org, plain, catalog)
    refute Models.allowed?(org, marked, catalog)
    assert {:error, :invalid_model_configuration} = Models.choose(org, marked, catalog)
    assert {:error, :model_not_allowed} = Models.router_choice(p.id, marked)

    for field <- ~w(default_router_model default_task_model) do
      assert {:error, %Ecto.Changeset{}} = Orgs.update_org(org, %{field => marked})
    end

    assert {:error, %Ecto.Changeset{}} = Orgs.update_org(org, %{"allowed_models" => [marked]})

    govern(org, allowed_models: [plain, Models.normalize(marked)])
    refute Models.allowed?(Repo.get!(Organization, org.id), marked, catalog)
    assert {:ok, filter} = Models.router_model_filter(p.id)

    assert [%{"choices" => [^plain]}] =
             filter.([%{"id" => "gpt-5.5", "served_by" => "subscription", "efforts" => []}])
  end
end
