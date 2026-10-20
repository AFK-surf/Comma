defmodule BridgeForTeams.Migrations.DefaultTaskPlacesTest do
  @moduledoc """
  A live Agent Swarm whose live Workers all run on its Cloud VM gets the Cloud
  VM as its default place to run Tasks (`BridgeForTeams.Migrations.DefaultTaskPlaces`
  with `SalixAgent.Migrations.DefaultTaskPlaces.derive/2`); one whose Workers
  do not all agree, or that has none, keeps none. A second pass and a place
  set since are left as they are.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Orgs, Projects}
  alias BridgeForTeams.Migrations.DefaultTaskPlaces
  alias BridgeForTeams.TestSupport.CanonicalAgentClient
  alias SalixAgent.TaskPlace
  alias SalixStore.{CasRecord, Keys}

  @cloud_vm %{
    "runs_on" => %{"kind" => "cloud_vm"},
    "model" => %{"kind" => "runtime", "provider" => "codex"}
  }

  setup do
    SalixStore.S3.Fake.reset()
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-task-place"})
    %{org: org}
  end

  defp swarm!(org, slug) do
    {:ok, project} =
      CanonicalAgentClient.create_provisioned_project(org.id, %{"name" => slug, "slug" => slug})

    project
  end

  defp worker!(org, project, attrs \\ %{}) do
    SalixAgent.TestSupport.create_control_agent_in_group!(
      org.salix_tenant_id,
      project.salix_group_id,
      Map.merge(%{"role" => "worker", "name" => "Worker"}, attrs)
    )
  end

  defp archive!(agent),
    do:
      {:ok, _} =
        CasRecord.update(Keys.ctl_agent(agent["agent_id"]), &Map.put(&1, "archived_at", 1),
          create: false
        )

  defp run, do: DefaultTaskPlaces.run(Repo, &SalixAgent.Migrations.DefaultTaskPlaces.derive/2)

  test "a swarm gets the Cloud VM only when every live Worker runs there", %{org: org} do
    agree = swarm!(org, "agree")
    worker!(org, agree, %{"station_binding" => @cloud_vm})
    worker!(org, agree, %{"station_binding" => @cloud_vm})

    station =
      worker!(org, agree, %{
        "station_binding" => %{
          "runs_on" => %{"kind" => "station", "device_id" => "device-1"},
          "model" => %{"kind" => "runtime", "provider" => "codex"}
        }
      })

    # An archived Worker no longer runs anything.
    archive!(station)

    mixed = swarm!(org, "mixed")
    worker!(org, mixed, %{"station_binding" => @cloud_vm})
    worker!(org, mixed)

    empty = swarm!(org, "empty")

    chosen = swarm!(org, "chosen")
    worker!(org, chosen, %{"station_binding" => @cloud_vm})
    {:ok, _} = TaskPlace.put(org.salix_tenant_id, chosen.salix_group_id, TaskPlace.salix())

    archived = swarm!(org, "archived")
    worker!(org, archived, %{"station_binding" => @cloud_vm})
    {:ok, _} = Projects.archive_project(archived)

    assert {:ok, %{cloud_vm: 2}} = run()

    assert {:ok, %{"kind" => "cloud_vm"}} = TaskPlace.get(agree.salix_group_id)
    assert {:ok, nil} = TaskPlace.get(mixed.salix_group_id)
    assert {:ok, nil} = TaskPlace.get(empty.salix_group_id)
    assert {:ok, %{"kind" => "salix"}} = TaskPlace.get(chosen.salix_group_id)
    assert {:ok, nil} = TaskPlace.get(archived.salix_group_id)

    # Run again: the same result, and a place set since stays.
    {:ok, _} = TaskPlace.put(org.salix_tenant_id, agree.salix_group_id, TaskPlace.salix())
    assert {:ok, %{cloud_vm: 2}} = run()
    assert {:ok, %{"kind" => "salix"}} = TaskPlace.get(agree.salix_group_id)
    assert {:ok, nil} = TaskPlace.get(mixed.salix_group_id)
  end
end
