defmodule BridgeForTeams.TestSupport.LegacyWorker do
  @moduledoc """
  A Worker as BridgeForTeams made one before Workers were retired: a product
  association and its queued `create_owned_agent` row. Workers made then stay
  as history, and a row queued before the release still drains, so tests of
  that history make one here (`BridgeForTeams.Agents.create_agent/3` refuses
  new Workers).
  """

  alias BridgeForTeams.{Agents, Outbox, Repo}
  alias BridgeForTeams.Schema.{Agent, Organization, Project}

  @spec create(Ecto.UUID.t() | Project.t(), map()) :: {:ok, Agent.t()}
  def create(project, attrs \\ %{})

  def create(project_id, attrs) when is_binary(project_id),
    do: create(Repo.get!(Project, project_id), attrs)

  def create(%Project{} = project, attrs) do
    org = Repo.get!(Organization, project.org_id)
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    salix_agent_id = SalixStore.Ids.new_agent_id(project.salix_group_id)

    changeset =
      Agent.changeset(
        %Agent{},
        Map.merge(attrs, %{
          "project_id" => project.id,
          "salix_agent_id" => salix_agent_id,
          "role" => "worker"
        })
      )

    {:ok, agent} = Agents.insert_association(changeset)

    payload =
      %{
        "agent_id" => salix_agent_id,
        "group_id" => project.salix_group_id,
        "tenant_id" => org.salix_tenant_id,
        "role" => "worker",
        "name" => agent.salix["name"]
      }
      |> put_present("system_prompt", agent.salix["system_prompt"])
      |> put_present("purpose", agent.salix["management_purpose"])
      |> put_present("model", agent.salix["model"])
      |> put_present("station_binding", agent.salix["station_binding"])

    {:ok, _row} =
      Outbox.enqueue("agent", agent.id, "create_owned_agent", %{"attrs" => payload})

    {:ok, agent}
  end

  @doc """
  A Worker bound to a station as `create_station_agent/3` made one: `target`
  names a device's station (`device_id`) or the Cloud VM (`kind: cloud_vm`)
  and the runtime its Tasks run (`runtime`).
  """
  @spec create_station(Project.t(), map(), map()) :: {:ok, Agent.t()}
  def create_station(%Project{} = project, attrs, target) do
    target = Map.new(target, fn {key, value} -> {to_string(key), value} end)

    runs_on =
      case target["kind"] do
        "cloud_vm" -> %{"kind" => "cloud_vm"}
        _station -> %{"kind" => "station", "device_id" => target["device_id"]}
      end

    binding = %{
      "runs_on" => runs_on,
      "model" => %{"kind" => "runtime", "provider" => target["runtime"] || "codex"}
    }

    create(project, Map.put(attrs, "station_binding", binding))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
