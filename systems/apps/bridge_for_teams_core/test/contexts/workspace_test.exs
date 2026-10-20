defmodule BridgeForTeams.WorkspaceTest do
  use BridgeForTeams.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Agents, Orgs, Workspace}

  # Stub Salix client driven by application env: `:test_workspace_files` maps
  # `{salix_agent_id, path}` to the scripted read result and
  # `:test_workspace_listings` maps `{salix_agent_id, path}` to the scripted
  # list result; the test pid receives every call.
  defmodule ScriptedClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    def read_agent_file(agent_id, path) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :test_workspace_pid) do
        SystemsRuntime.Proc.send(pid, {:read_agent_file, agent_id, path})
      end

      SystemsRuntime.get_env(:bridge_for_teams_core, :test_workspace_files, %{})
      |> Map.get({agent_id, path}, {:error, :not_found})
    end

    def list_agent_files(agent_id, path) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :test_workspace_pid) do
        SystemsRuntime.Proc.send(pid, {:list_agent_files, agent_id, path})
      end

      SystemsRuntime.get_env(:bridge_for_teams_core, :test_workspace_listings, %{})
      |> Map.get({agent_id, path}, {:ok, []})
    end

    def write_agent_file(agent_id, path, body) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :test_workspace_pid) do
        SystemsRuntime.Proc.send(pid, {:write_agent_file, agent_id, path, body})
      end

      SystemsRuntime.get_env(:bridge_for_teams_core, :test_workspace_writes, %{})
      |> Map.get({agent_id, path}, {:ok, %{"path" => path}})
    end
  end

  defmodule UnavailableAgentOwner do
    def page_group_agents(_tenant, _group, _opts), do: {:error, :unavailable}
  end

  setup do
    prev = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, ScriptedClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :test_workspace_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      if prev do
        SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
      end

      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_workspace_files)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_workspace_listings)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_workspace_writes)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_workspace_pid)
    end)

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "P",
        slug: "p"
      })

    # Projects auto-provision a default router agent; archive it so each test
    # controls the roster it asserts against.
    Enum.each(Agents.list_agents(project.id), &archive_agent_fixture!/1)

    %{org: org, project: project}
  end

  defp script_files(map),
    do: SystemsRuntime.put_env(:bridge_for_teams_core, :test_workspace_files, map)

  defp script_listings(map),
    do: SystemsRuntime.put_env(:bridge_for_teams_core, :test_workspace_listings, map)

  describe "read_file/3" do
    test "reads from the project's first provisioned agent by default", %{project: project} do
      {:ok, agent} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "router",
          "role" => "router"
        })

      script_files(%{
        {agent.salix_agent_id, "/drafts/t1/draft.md"} => {:ok, "# Draft"}
      })

      assert {:ok, "# Draft"} = Workspace.read_file(project, "/drafts/t1/draft.md")
      settle_receive({:read_agent_file, agent_id, "/drafts/t1/draft.md"})
      assert agent_id == agent.salix_agent_id
    end

    test "targets a named project agent (bft uuid or salix id)", %{project: project} do
      {:ok, _router} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "router",
          "role" => "router"
        })

      {:ok, worker} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "worker",
          "role" => "worker"
        })

      script_files(%{{worker.salix_agent_id, "/notes.md"} => {:ok, "notes"}})

      assert {:ok, "notes"} = Workspace.read_file(project, "/notes.md", agent_id: worker.id)

      assert {:ok, "notes"} =
               Workspace.read_file(project, "/notes.md", salix_agent_id: worker.salix_agent_id)
    end

    test "refuses an agent that isn't the project's", %{org: org, project: project} do
      {:ok, _mine} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "mine",
          "role" => "router"
        })

      {:ok, other_project} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
          name: "Other",
          slug: "other"
        })

      {:ok, foreign} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
          other_project.id,
          %{"name" => "foreign", "role" => "router"}
        )

      assert {:error, :agent_not_found} =
               Workspace.read_file(project, "/notes.md", agent_id: foreign.id)

      refute_received {:read_agent_file, _agent_id, _path}
    end

    test "errors when the project has no provisioned agent", %{project: project} do
      assert {:error, :no_agent} = Workspace.read_file(project, "/notes.md")
    end
  end

  describe "list_files/3" do
    test "lists the workspace root by default", %{project: project} do
      {:ok, agent} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "router",
          "role" => "router"
        })

      entries = [
        %{"path" => "/uploads/", "kind" => "dir", "size" => 0, "modified_at" => 1},
        %{"path" => "/notes.md", "kind" => "file", "size" => 12, "modified_at" => 1}
      ]

      script_listings(%{{agent.salix_agent_id, "/"} => {:ok, entries}})

      assert {:ok, ^entries} = Workspace.list_files(project)
      settle_receive({:list_agent_files, _agent_id, "/"})
    end

    test "targets a named project agent and rejects foreign ones", %{
      org: org,
      project: project
    } do
      {:ok, _mine} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "mine",
          "role" => "router"
        })

      {:ok, other_project} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
          name: "Other",
          slug: "other"
        })

      {:ok, foreign} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
          other_project.id,
          %{"name" => "foreign", "role" => "router"}
        )

      assert {:error, :agent_not_found} =
               Workspace.list_files(project, "/", agent_id: foreign.salix_agent_id)

      refute_received {:list_agent_files, _agent_id, _path}
    end
  end

  describe "write_file/4" do
    test "writes to the project's first provisioned agent by default", %{project: project} do
      {:ok, agent} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "router",
          "role" => "router"
        })

      assert {:ok, %{"path" => "/drafts/t1/draft.md"}} =
               Workspace.write_file(project, "/drafts/t1/draft.md", "edited body")

      settle_receive({:write_agent_file, agent_id, "/drafts/t1/draft.md", "edited body"})
      assert agent_id == agent.salix_agent_id
    end

    test "targets a named project agent and rejects foreign ones", %{org: org, project: project} do
      {:ok, _mine} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "mine",
          "role" => "router"
        })

      {:ok, worker} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          "name" => "worker",
          "role" => "worker"
        })

      {:ok, other_project} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
          name: "Other",
          slug: "other"
        })

      {:ok, foreign} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
          other_project.id,
          %{"name" => "foreign", "role" => "router"}
        )

      assert {:ok, _result} =
               Workspace.write_file(project, "/notes.md", "body", agent_id: worker.id)

      settle_receive({:write_agent_file, agent_id, "/notes.md", "body"})
      assert agent_id == worker.salix_agent_id

      assert {:error, :agent_not_found} =
               Workspace.write_file(project, "/notes.md", "body", agent_id: foreign.id)

      refute_received {:write_agent_file, _agent_id, _path, _body}
    end

    test "errors when the project has no provisioned agent", %{project: project} do
      assert {:error, :no_agent} = Workspace.write_file(project, "/notes.md", "body")
    end
  end
end
