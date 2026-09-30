defmodule BridgeForTeams.SitesTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Agents, Observability, Orgs, Sites}

  # Stub Salix client driven by a per-agent script stored in application env
  # (keyed by salix_agent_id). `list_agent_sites/1` reads the script;
  # `write_agent_file/3` records the write and reports it to the test pid.
  defmodule ScriptedClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    def list_agent_sites(agent_id) do
      Application.get_env(:bridge_for_teams_core, :test_agent_sites, %{})
      |> Map.get(agent_id, {:ok, []})
    end

    def write_agent_file(agent_id, path, body) do
      if pid = Application.get_env(:bridge_for_teams_core, :test_sites_pid) do
        send(pid, {:write_agent_file, agent_id, path, body})
      end

      Application.get_env(:bridge_for_teams_core, :test_write_result, {:ok, %{}})
    end
  end

  defmodule UnavailableAgentOwner do
    def page_group_agents(_tenant, _group, _opts), do: {:error, :unavailable}
  end

  test "Agent owner failure remains an actionable product read error", %{project: project} do
    Application.put_env(:bridge_for_teams_core, :salix_client, UnavailableAgentOwner)
    assert {:error, :unavailable} = Sites.list_project_sites(project)
  end

  setup do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ScriptedClient)

    Application.put_env(:bridge_for_teams_core, :test_sites_pid, self())

    on_exit(fn ->
      # Restore-or-delete: putting back a literal nil would poison every later
      # test that reads the Salix client config.
      case prev do
        nil -> Application.delete_env(:bridge_for_teams_core, :salix_client)
        value -> Application.put_env(:bridge_for_teams_core, :salix_client, value)
      end

      Application.delete_env(:bridge_for_teams_core, :test_agent_sites)
      Application.delete_env(:bridge_for_teams_core, :test_sites_pid)
      Application.delete_env(:bridge_for_teams_core, :test_write_result)
    end)

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "P",
        slug: "p"
      })

    %{org: org, project: project}
  end

  defp script(map), do: Application.put_env(:bridge_for_teams_core, :test_agent_sites, map)

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

  test "empty when the default router has no sites", %{project: project} do
    assert {:ok, []} = Sites.list_project_sites(project)
  end

  test "an agent with no sites contributes nothing", %{project: project} do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "solo",
        "role" => "worker"
      })

    script(%{agent.salix_agent_id => {:ok, []}})

    assert {:ok, []} = Sites.list_project_sites(project)
  end

  test "an unprovisioned agent (not_found) is skipped, others still listed", %{project: project} do
    {:ok, ready} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "ready",
        "role" => "router"
      })

    {:ok, pending} = Agents.create_agent(project.id, %{"name" => "pending", "role" => "worker"})

    script(%{
      ready.salix_agent_id => {:ok, [%{"name" => "site", "url" => "https://site.example.test"}]},
      pending.salix_agent_id => {:error, :not_found}
    })

    assert {:ok, [site]} = Sites.list_project_sites(project)
    assert site["agent_id"] == ready.id
  end

  test "surfaces :unavailable when Salix is unreachable", %{project: project} do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "a",
        "role" => "router"
      })

    script(%{agent.salix_agent_id => {:error, :unavailable}})

    assert {:error, :unavailable} = Sites.list_project_sites(project)
  end

  test "one transient failure fails the whole call even when other agents succeed", %{
    project: project
  } do
    {:ok, ok_agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "ok",
        "role" => "router"
      })

    {:ok, slow} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "slow",
        "role" => "worker"
      })

    script(%{
      ok_agent.salix_agent_id =>
        {:ok, [%{"name" => "site", "url" => "https://site.example.test"}]},
      slow.salix_agent_id => {:error, :timeout}
    })

    assert {:error, :timeout} = Sites.list_project_sites(project)
  end

  describe "list_project_sites/2 with cache: true" do
    setup %{project: project} do
      on_exit(fn -> Sites.invalidate_project_sites_cache(project.id) end)
      :ok
    end

    test "serves the cached result within the TTL", %{project: project} do
      {:ok, agent} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "a",
          "role" => "router"
        })

      script(%{
        agent.salix_agent_id => {:ok, [%{"name" => "one", "url" => "https://one.example.test"}]}
      })

      assert {:ok, [%{"name" => "one"}]} = Sites.list_project_sites(project, cache: true)

      # A changed Salix answer is not observed until the entry is invalidated.
      script(%{
        agent.salix_agent_id => {:ok, [%{"name" => "two", "url" => "https://two.example.test"}]}
      })

      assert {:ok, [%{"name" => "one"}]} = Sites.list_project_sites(project, cache: true)

      Sites.invalidate_project_sites_cache(project.id)
      assert {:ok, [%{"name" => "two"}]} = Sites.list_project_sites(project, cache: true)
    end

    test "does not cache transient errors", %{project: project} do
      {:ok, agent} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "a",
          "role" => "router"
        })

      script(%{agent.salix_agent_id => {:error, :unavailable}})

      assert {:error, :unavailable} = Sites.list_project_sites(project, cache: true)

      script(%{
        agent.salix_agent_id => {:ok, [%{"name" => "site", "url" => "https://site.example.test"}]}
      })

      assert {:ok, [%{"name" => "site"}]} = Sites.list_project_sites(project, cache: true)
    end

    test "uncached calls bypass and do not populate the cache", %{project: project} do
      {:ok, agent} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "a",
          "role" => "router"
        })

      script(%{
        agent.salix_agent_id => {:ok, [%{"name" => "one", "url" => "https://one.example.test"}]}
      })

      assert {:ok, [%{"name" => "one"}]} = Sites.list_project_sites(project)

      script(%{
        agent.salix_agent_id => {:ok, [%{"name" => "two", "url" => "https://two.example.test"}]}
      })

      assert {:ok, [%{"name" => "two"}]} = Sites.list_project_sites(project)
    end
  end

  test "records an Operations diagnostic when Salix is unreachable", %{
    org: org,
    project: project
  } do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "a",
        "role" => "router"
      })

    script(%{agent.salix_agent_id => {:error, :unavailable}})

    assert {:error, :unavailable} = Sites.list_project_sites(project)
    assert {:error, :unavailable} = Sites.list_project_sites(project)

    assert [event] =
             Observability.list_events(org.id,
               event_type: "project.websites.unavailable",
               limit: 10
             )

    assert event.domain == "project"
    assert event.project_id == project.id
    assert event.resource_type == "project_website_index"
    assert event.resource_id == project.id
    assert event.source == "salix.control"
    assert event.severity == "warning"
    assert event.status == "unavailable"
    assert event.reason_class == "unavailable"
    assert event.correlation_id == "project:#{project.id}:websites:index"
    assert event.evidence["surface"] == "project_websites"
    assert event.evidence["salix_agent_count"] == 2
    refute inspect(event.evidence) =~ "https://"
  end

  test "does not record an Operations diagnostic for successful website reads", %{
    org: org,
    project: project
  } do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "a",
        "role" => "router"
      })

    script(%{
      agent.salix_agent_id => {:ok, [%{"name" => "site", "url" => "https://site.example.test"}]}
    })

    assert {:ok, [_site]} = Sites.list_project_sites(project)

    assert [] =
             Observability.list_events(org.id,
               event_type: "project.websites.unavailable",
               limit: 10
             )
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

    test "returns :no_agent when the project has no provisioned agent", %{project: project} do
      Enum.each(Agents.list_agents(project.id), &archive_agent_fixture!/1)

      assert {:error, :no_agent} = Sites.publish_project_site(project, "x", "<html></html>")
    end

    test "returns :site_not_listed when the write lands but the site is absent", %{
      project: project
    } do
      assert {:error, :site_not_listed} =
               Sites.publish_project_site(project, "x", "<html></html>")
    end

    test "propagates the Salix write error", %{project: project} do
      Application.put_env(:bridge_for_teams_core, :test_write_result, {:error, :unavailable})

      assert {:error, :unavailable} = Sites.publish_project_site(project, "x", "<html></html>")
    end
  end

  test "excludes archived agents", %{project: project} do
    {:ok, kept} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "kept",
        "role" => "router"
      })

    {:ok, gone} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "gone",
        "role" => "worker"
      })

    {:ok, _} = Agents.archive_agent(gone)

    script(%{
      kept.salix_agent_id => {:ok, [%{"name" => "live", "url" => "https://live.example.test"}]},
      gone.salix_agent_id => {:ok, [%{"name" => "dead", "url" => "https://dead.example.test"}]}
    })

    assert {:ok, [site]} = Sites.list_project_sites(project)
    assert site["name"] == "live"
  end
end
