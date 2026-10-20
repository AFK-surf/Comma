defmodule BridgeForTeams.SitesTest do
  use BridgeForTeams.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Agents, Observability, Orgs, Sites}

  # Stub Salix client driven by a per-agent script stored in application env
  # (keyed by salix_agent_id). `list_agent_sites/1` reads the script;
  # `write_agent_file/3` records the write and reports it to the test pid.
  defmodule ScriptedClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    def list_agent_sites(agent_id) do
      SystemsRuntime.get_env(:bridge_for_teams_core, :test_agent_sites, %{})
      |> Map.get(agent_id, {:ok, []})
    end

    def write_agent_file(agent_id, path, body) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :test_sites_pid) do
        SystemsRuntime.Proc.send(pid, {:write_agent_file, agent_id, path, body})
      end

      SystemsRuntime.get_env(:bridge_for_teams_core, :test_write_result, {:ok, %{}})
    end
  end

  defmodule UnavailableAgentOwner do
    def page_group_agents(_tenant, _group, _opts), do: {:error, :unavailable}
  end

  setup do
    prev = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, ScriptedClient)

    SystemsRuntime.put_env(:bridge_for_teams_core, :test_sites_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      # Restore-or-delete: putting back a literal nil would poison every later
      # test that reads the Salix client config.
      case prev do
        nil -> SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
        value -> SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, value)
      end

      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_agent_sites)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_sites_pid)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_write_result)
    end)

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "P",
        slug: "p"
      })

    %{org: org, project: project}
  end

  defp script(map), do: SystemsRuntime.put_env(:bridge_for_teams_core, :test_agent_sites, map)

  test "aggregates sites across the project's agents, tagged with the owner", %{project: project} do
    {:ok, router} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    {:ok, worker} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "worker",
        "role" => "worker"
      })

    script(%{
      router.salix_agent_id =>
        {:ok, [%{"name" => "marketing", "url" => "https://marketing.example.test"}]},
      worker.salix_agent_id =>
        {:ok,
         [
           %{"name" => "docs", "url" => "https://docs.example.test"},
           %{"name" => "blog", "url" => "https://blog.example.test"}
         ]}
    })

    assert {:ok, sites} = Sites.list_project_sites(project)
    assert length(sites) == 3

    marketing = Enum.find(sites, &(&1["name"] == "marketing"))
    assert marketing["url"] == "https://marketing.example.test"
    assert marketing["agent_id"] == router.id
    assert marketing["salix_agent_id"] == router.salix_agent_id
    assert marketing["agent_name"] == "router"

    blog = Enum.find(sites, &(&1["name"] == "blog"))
    assert blog["agent_id"] == worker.id
  end

  describe "list_project_sites/2 with cache: true" do
    setup %{project: project} do
      on_exit(fn -> Sites.invalidate_project_sites_cache(project.id) end)
      :ok
    end
  end

  describe "publish_project_site/3" do
    # Projects get a default Router agent on creation — publishing targets it.
    defp first_agent(project) do
      project.id |> Agents.list_agents() |> Enum.find(&is_binary(&1.salix_agent_id))
    end

    test "writes index.html into the first agent's VFS and returns the site", %{
      project: project
    } do
      agent = first_agent(project)

      script(%{
        agent.salix_agent_id =>
          {:ok, [%{"name" => "daily-briefing", "url" => "https://daily-briefing-x.example.test"}]}
      })

      assert {:ok, site} =
               Sites.publish_project_site(project, "daily-briefing", "<html>hi</html>")

      assert site["name"] == "daily-briefing"
      assert site["url"] == "https://daily-briefing-x.example.test"
      assert site["agent_id"] == agent.id

      assert_received {:write_agent_file, agent_id, "/.salix/websites/daily-briefing/index.html",
                       "<html>hi</html>"}

      assert agent_id == agent.salix_agent_id
    end
  end
end
