defmodule BridgeForTeams.ProjectsTaskModelTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Models, Observability, Orgs, Projects}
  alias BridgeForTeams.Schema.Organization
  alias BridgeForTeams.TestSupport.CanonicalAgentClient

  @platform %{"kind" => "platform", "tier" => "worker"}
  @gpt %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
  @sol %{"kind" => "catalog", "model" => "gpt-6.1-sol", "allow_paid" => false}

  setup do
    SalixStore.S3.Fake.reset()
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-task-model"})

    {:ok, project} =
      CanonicalAgentClient.create_provisioned_project(org.id, %{"name" => "P", "slug" => "p"})

    %{org: org, project: project}
  end

  defp govern(org, attrs),
    do: Organization |> Repo.get!(org.id) |> Ecto.Changeset.change(attrs) |> Repo.update!()

  test "a swarm's default Task model is the platform model or one the org allows", %{
    org: org,
    project: project
  } do
    assert {:ok, nil} = Projects.default_task_model(project)

    govern(org, allowed_models: [@gpt])
    opts = [audit: true, actor_label: "admin@example.com"]

    # The platform model needs no allowance.
    assert {:ok, @platform} = Projects.set_default_task_model(project, @platform, opts)
    assert {:ok, @platform} = Projects.default_task_model(project)

    # A catalog model outside the allowed list is refused and changes nothing.
    assert {:error, :model_not_allowed} = Projects.set_default_task_model(project, @sol, opts)
    assert {:ok, @platform} = Projects.default_task_model(project)

    assert {:ok, @gpt} =
             Projects.set_default_task_model(project, Map.delete(@gpt, "allow_paid"), opts)

    assert {:ok, @gpt} = Projects.default_task_model(project)

    # An empty list allows every catalog model.
    govern(org, allowed_models: [])
    assert {:ok, @sol} = Projects.set_default_task_model(project, @sol, opts)

    for invalid <- [nil, %{"kind" => "runtime", "provider" => "codex", "model" => "gpt-5.5"}] do
      assert {:error, :invalid_model_configuration} =
               Projects.set_default_task_model(project, invalid, opts)
    end

    assert {:ok, @sol} = Projects.default_task_model(project)

    # Clearing leaves each Task its Worker's model again.
    assert {:ok, nil} = Projects.clear_default_task_model(project, opts)
    assert {:ok, nil} = Projects.default_task_model(project)

    diffs =
      for audit <-
            Observability.list_audit_logs(org.id, action: "project.default_task_model_changed") do
        assert audit.resource_id == project.id
        audit.redacted_diff["default_task_model"]
      end

    assert Enum.sort_by(diffs, &{&1["from"] || "", &1["to"] || ""}) == [
             %{"from" => nil, "to" => "platform:worker"},
             %{"from" => "catalog:gpt-5.5", "to" => Models.key(@sol)},
             %{"from" => Models.key(@sol), "to" => nil},
             %{"from" => "platform:worker", "to" => "catalog:gpt-5.5"}
           ]
  end
end
