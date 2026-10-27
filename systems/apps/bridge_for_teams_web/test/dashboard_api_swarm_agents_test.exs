defmodule BridgeForTeamsWeb.DashboardAPISwarmAgentsTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The Agents API behind the React Agents page: the paged list with its role
  badges, one agent's detail (model, binding, Triage use, Router session),
  new internal agents and agents bound to a station with the station picker,
  model and prompt configuration, station rebind, archive with its Triage confirmation, and the
  Router session switch. Swarm admins write; a swarm member's write is refused
  with a denied audit; someone outside the swarm gets 404.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  import Ecto.Query, only: [from: 2]

  alias BridgeForTeams.{Agents, Environments, Memberships, Observability, Projects, Repo}
  alias BridgeForTeams.Salix.Reconciler
  alias BridgeForTeams.Schema.{Agent, ProjectDeviceProjection, ReconcileOutbox}

  # The list and the picker read projections, never the live device registry
  # or an agent's runtime state.
  defmodule ProjectionOnlyClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    defdelegate get_group(group_id), to: BridgeForTeams.Salix.Erpc

    def list_group_envs(_group_id, _tenant_id), do: raise("the Agents API must not list envs")

    def page_group_envs(_group_id, _tenant_id, _opts),
      do: raise("the Agents API must not page envs")

    def get_agent_projection(_agent_id, _tenant_id),
      do: raise("the agent list must not read agent projections")
  end

  defmodule ProjectionTimeoutClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    defdelegate get_group(group_id), to: BridgeForTeams.Salix.Erpc
    def get_agent_projection(_agent_id, _tenant_id), do: {:error, :timeout}
  end

  defmodule ModelProbeClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    defdelegate get_group(group_id), to: BridgeForTeams.Salix.Erpc

    def public_model(choice, _tenant_id) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:public_model, choice})
      {:ok, %{"model" => choice["model"], "model_display_name" => "Direct read"}}
    end

    def list_sessions(agent_id),
      do: SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:list_sessions, agent_id})
  end

  defmodule SalixDownClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    def page_group_agents(_tenant, _group, _opts), do: {:error, :unavailable}
  end

  defmodule EmptyCatalogClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    def model_catalog, do: {:ok, []}
    def platform_model(_role), do: {:error, :platform_model_unconfigured}
    def public_model(_choice, _tenant_id), do: {:error, :unavailable}
  end

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    SalixAgent.TestSupport.configure_platform_models!()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    drain_all()
    %{conn: conn, user: user, org: org, project: project}
  end

  describe "list" do
    test "lists the Router; a Worker made before is not listed", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, router} = Agents.current_router(project)
      {:ok, _worker} = create_agent(project, %{"name" => "triage", "role" => "worker"})

      data = conn |> get(agents_path(org, project)) |> json_response(200) |> data()

      assert data["status"] == "ok"
      assert data["project"] == %{"id" => project.id, "name" => "Acme", "role" => "admin"}
      assert data["next_cursor"] == nil
      assert data["triage_href"] == "/orgs/#{org.slug}/triage"

      assert [%{"id" => id, "role" => "router", "lifecycle" => "active"}] = data["agents"]
      assert id == router.id
    end

    test "a Router's Task without a Worker runs on the swarm's Task agent, which no list shows",
         %{conn: conn, org: org, project: project} do
      {:ok, router} = Agents.current_router(project)
      group_id = project.salix_group_id

      assert {:ok, %{"created" => true, "conversation_id" => conversation_id}} =
               SalixIM.Provider.call_api(
                 router.salix_agent_id,
                 "internal",
                 "internal.task.create",
                 %{
                   "connect_id" => "internal",
                   "params" => %{
                     "runs_on" => %{"kind" => "default"},
                     "content" => "Summarize this week's notes."
                   }
                 }
               )

      task_agent = SalixAgent.TaskAgent.id(group_id)
      assert {:ok, ^task_agent} = SalixAgent.TaskAgent.get(group_id)

      assert {:ok, %{"participants" => participants}} =
               SalixIM.Conversations.list_group_conversation_participants(
                 group_id,
                 conversation_id
               )

      assert Enum.any?(participants, &(&1["agent_id"] == task_agent))

      data = conn |> get(agents_path(org, project)) |> json_response(200) |> data()
      assert Enum.map(data["agents"], & &1["id"]) == [router.id]
      assert {:ok, %{items: items}} = Agents.page_agents(project)
      refute Enum.any?(items, &(&1.salix_agent_id == task_agent))
    end
  end

  describe "detail" do
    test "shows a Worker made before as read-only history", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_agent(project, %{
          "name" => "worker-detail",
          "role" => "worker",
          "model" => %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false},
          "system_prompt" => "Summarize tickets."
        })

      data = conn |> get(agent_path(org, project, agent)) |> json_response(200) |> data()

      assert %{
               "id" => id,
               "name" => "worker-detail",
               "model" => "GPT-5.5",
               "system_prompt" => "Summarize tickets.",
               "runtime_id" => runtime_id,
               "read_only" => true
             } = data["agent"]

      assert id == agent.id
      assert runtime_id == agent.salix_agent_id
      assert data["router_session"] == nil
      assert data["triage_href"] == nil
    end

    test "an agent of another swarm, or an unknown one, is not found", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, other} = Projects.create_project(org.id, %{"name" => "Other", "slug" => "other"})
      drain_all()
      {:ok, foreign} = create_agent(other, %{"name" => "foreign", "role" => "worker"})

      for agent_id <- [foreign.id, SystemsRuntime.Proc.uuid(), "not-an-id"] do
        assert %{"error" => %{"code" => "agent_not_found"}} =
                 conn
                 |> get(agents_path(org, project, "/#{agent_id}"))
                 |> json_response(404)
      end
    end
  end

  describe "Router session" do
    test "an admin starts a fresh canonical session; a stale one is refused", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, router} = create_agent(project, %{"name" => "router-detail", "role" => "router"})
      {:ok, before} = SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)
      old = before["router_session_id"]

      assert %{"router_session" => %{"status" => "ok", "id" => ^old}} =
               conn |> get(agent_path(org, project, router)) |> json_response(200) |> data()

      assert %{"router_session_id" => new, "notice" => "Started a new canonical Router session."} =
               conn
               |> post(agent_path(org, project, router, "/router-session"), %{
                 "expected_session_id" => old
               })
               |> json_response(200)
               |> data()

      assert new != old
      {:ok, after_switch} = SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)
      assert after_switch["router_session_id"] == new

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "agent.router_session_switched",
                 result: "ok"
               )

      assert audit.resource_id == router.id
      assert audit.redacted_diff["router_session_id"] == %{"from" => old, "to" => new}

      assert %{"error" => %{"code" => "stale_router_session", "details" => details}} =
               conn
               |> post(agent_path(org, project, router, "/router-session"), %{
                 "expected_session_id" => old
               })
               |> json_response(409)

      assert details["router_session_id"] == new
    end

    test "a swarm member cannot switch it; the attempt is audited", %{
      org: org,
      project: project
    } do
      {:ok, router} = create_agent(project, %{"name" => "router-read-only", "role" => "router"})
      {:ok, before} = SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)
      {member_conn, member} = member_conn(org, project)

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn
               |> post(agent_path(org, project, router, "/router-session"), %{
                 "expected_session_id" => before["router_session_id"]
               })
               |> json_response(403)

      {:ok, unchanged} = SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)
      assert unchanged["router_session_id"] == before["router_session_id"]

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "agent.router_session_switched",
                 result: "denied"
               )

      assert audit.actor_user_id == member.id
    end
  end

  describe "new agent" do
    test "creating, moving, changing or archiving a Worker answers 410 workers_retired", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, router} = Agents.current_router(project)
      {:ok, worker} = create_agent(project, %{"name" => "kept", "role" => "worker"})

      writes = [
        {:post, agents_path(org, project),
         %{"name" => "New", "target" => %{"kind" => "cloud_vm"}}},
        {:put, agent_path(org, project, worker, "/runtime"),
         %{"expected_binding_revision" => 0, "target" => %{"kind" => "cloud_vm"}}},
        {:patch, agent_path(org, project, worker), %{"system_prompt" => "Changed."}},
        {:post, agent_path(org, project, worker, "/archive"), %{}},
        {:post, agent_path(org, project, router, "/archive"), %{}}
      ]

      for {method, path, body} <- writes do
        assert %{"error" => %{"code" => "workers_retired"}} =
                 conn |> dispatch(@endpoint, method, path, body) |> json_response(410)
      end

      ids = Enum.map(Agents.list_agents(project.id), & &1.id)
      assert router.id in ids
      assert worker.id in ids
    end

    test "a swarm member reads the list but cannot create or open the pickers", %{
      org: org,
      project: project
    } do
      {member_conn, member} = member_conn(org, project)

      assert %{"project" => %{"role" => "user"}, "agents" => [_router]} =
               member_conn |> get(agents_path(org, project)) |> json_response(200) |> data()

      assert %{"error" => %{"message" => "Only Agent Swarm admins can manage agents."}} =
               member_conn
               |> post(agents_path(org, project), %{"type" => "internal", "name" => "forged"})
               |> json_response(403)

      assert member_conn |> get(agents_path(org, project, "/targets")) |> json_response(403)

      refute Enum.any?(Agents.list_agents(project.id), &(&1.salix["name"] == "forged"))

      assert [audit] = Observability.list_audit_logs(org.id, action: "agent.created")
      assert audit.actor_user_id == member.id
      assert audit.result == "denied"
      assert audit.reason_class == "forbidden"
      assert audit.resource_type == "agent"
      assert is_nil(audit.resource_id)
      assert audit.metadata["project_id"] == project.id
    end
  end

  describe "configure" do
    test "saves a catalog model and prompt with an audit that keeps the prompt out", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      opus = %{"kind" => "catalog", "model" => "claude-opus-4-8", "allow_paid" => false}
      {:ok, agent} = Agents.current_router(project)

      config =
        conn |> get(agent_path(org, project, agent, "/config")) |> json_response(200) |> data()

      assert config["available"] == true
      assert config["model_key"] == ""
      assert config["prompt_editable"] == true

      assert %{"key" => "", "choice" => nil, "label" => "Default (" <> _} =
               hd(config["models"])

      assert %{"key" => "catalog:claude-opus-4-8", "group" => "Anthropic"} =
               Enum.find(config["models"], &(&1["choice"] == opus))

      assert %{"notice" => "Agent configuration saved."} =
               conn
               |> patch(agent_path(org, project, agent), %{
                 "model" => opus,
                 "system_prompt" => "Be helpful."
               })
               |> json_response(200)
               |> data()

      {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.role == "router"
      assert reloaded.salix["model"] == opus
      assert reloaded.salix["router_system_prompt"] == "Be helpful."

      assert %{"model_key" => "catalog:claude-opus-4-8", "system_prompt" => "Be helpful."} =
               conn
               |> get(agent_path(org, project, agent, "/config"))
               |> json_response(200)
               |> data()

      refute Repo.exists?(
               from(o in ReconcileOutbox,
                 where:
                   o.aggregate == "agent" and o.aggregate_id == ^reloaded.id and
                     o.op == "update_agent"
               )
             )

      assert [audit] = Observability.list_audit_logs(org.id, action: "agent.config_updated")
      assert audit.actor_user_id == admin.id
      assert audit.resource_id == agent.id
      refute Map.has_key?(audit.redacted_diff, "role")
      refute Repo.get!(Agent, agent.id).salix["system_prompt"]

      assert audit.redacted_diff["instructions_configured"] == %{
               "from" => "false",
               "to" => "true"
             }

      refute inspect(audit) =~ "Be helpful."
    end

    test "shows a choice the allowed models exclude without letting it be chosen again", %{
      conn: conn,
      org: org,
      project: project
    } do
      current = %{"kind" => "catalog", "model" => "deepseek-chat-v3.1", "allow_paid" => false}
      allowed = %{"kind" => "catalog", "model" => "gpt-5", "allow_paid" => false}

      {:ok, agent} =
        create_agent(project, %{"name" => "Router", "role" => "router", "model" => current})

      {:ok, org} = BridgeForTeams.Orgs.update_org(org, %{"allowed_models" => [allowed]})

      config =
        conn |> get(agent_path(org, project, agent, "/config")) |> json_response(200) |> data()

      assert Enum.map(config["models"], & &1["choice"]) == [nil, current, allowed]

      assert %{
               "disabled" => true,
               "label" => "deepseek-chat-v3.1 (current; unavailable for selection)"
             } = Enum.at(config["models"], 1)

      # Saving the prompt alone keeps the model; the excluded choice is refused.
      assert conn
             |> patch(agent_path(org, project, agent), %{"system_prompt" => "Route politely."})
             |> json_response(200)

      assert %{"error" => %{"message" => "Choose a model from the list before saving."}} =
               conn
               |> patch(agent_path(org, project, agent), %{"model" => current})
               |> json_response(422)

      {:ok, unchanged} = Agents.get_agent(agent.id)
      assert unchanged.salix["model"] == current

      assert conn
             |> patch(agent_path(org, project, agent), %{"model" => allowed})
             |> json_response(200)

      {:ok, changed} = Agents.get_agent(agent.id)
      assert changed.salix["model"] == allowed

      # `null` follows the platform model of the role again.
      assert conn
             |> patch(agent_path(org, project, agent), %{"model" => nil})
             |> json_response(200)

      {:ok, following} = Agents.get_agent(agent.id)
      refute following.salix["model"]
    end

    test "a swarm member cannot read the catalog or configure; the attempt is audited", %{
      org: org,
      project: project
    } do
      {:ok, agent} = create_agent(project, %{"name" => "cfg3", "role" => "worker"})
      {member_conn, member} = member_conn(org, project)

      assert member_conn |> get(agent_path(org, project, agent, "/config")) |> json_response(403)

      assert member_conn
             |> patch(agent_path(org, project, agent), %{"system_prompt" => "forged"})
             |> json_response(403)

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "agent.config_updated",
                 result: "denied"
               )

      assert audit.actor_user_id == member.id
    end
  end

  describe "instructions" do
    test "the Router's own instructions win over the shared prompt and replace it when saved", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_agent(project, %{
          "name" => "Router",
          "role" => "router",
          "system_prompt" => "Shared rules."
        })

      {:ok, _record} =
        BridgeForTeams.Salix.Client.impl().configure_agent(
          agent.salix_agent_id,
          org.salix_tenant_id,
          %{"router_system_prompt" => "Imported rules."}
        )

      assert %{"system_prompt" => "Imported rules."} =
               conn
               |> get(agent_path(org, project, agent, "/config"))
               |> json_response(200)
               |> data()

      assert %{"agent" => %{"system_prompt" => "Edited rules."}} =
               conn
               |> patch(agent_path(org, project, agent), %{"system_prompt" => "Edited rules."})
               |> json_response(200)
               |> data()

      {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.salix["router_system_prompt"] == "Edited rules."
      assert reloaded.salix["system_prompt"] == "Shared rules."

      # Clearing them would only bring the shared prompt back.
      assert %{"error" => %{"details" => %{"fields" => %{"system_prompt" => [_message]}}}} =
               conn
               |> patch(agent_path(org, project, agent), %{"system_prompt" => ""})
               |> json_response(422)
    end

    test "an org admin who is not an owner changes the model but not the instructions", %{
      org: org,
      project: project
    } do
      gpt5 = %{"kind" => "catalog", "model" => "gpt-5", "allow_paid" => false}
      {:ok, agent} = Agents.current_router(project)
      admin = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, admin.id, "admin")
      admin_conn = log_in_user(build_conn(), admin)

      config =
        admin_conn
        |> get(agent_path(org, project, agent, "/config"))
        |> json_response(200)
        |> data()

      assert config["prompt_editable"] == false

      # The form sends the prompt it showed; unchanged, it is not a change.
      assert admin_conn
             |> patch(agent_path(org, project, agent), %{
               "model" => gpt5,
               "system_prompt" => config["system_prompt"]
             })
             |> json_response(200)

      assert admin_conn
             |> patch(agent_path(org, project, agent), %{"system_prompt" => "Forged."})
             |> json_response(403)

      {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.salix["model"] == gpt5
      refute reloaded.salix["router_system_prompt"] == "Forged."

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "agent.config_updated",
                 result: "denied"
               )

      assert audit.actor_user_id == admin.id
    end
  end

  describe "archive" do
    test "a swarm member cannot archive; the attempt is audited", %{org: org, project: project} do
      {:ok, agent} = create_agent(project, %{"name" => "kept", "role" => "worker"})
      {member_conn, member} = member_conn(org, project)

      assert member_conn
             |> post(agent_path(org, project, agent, "/archive"))
             |> json_response(403)

      assert Enum.any?(Agents.list_agents(project.id), &(&1.id == agent.id))

      assert [audit] =
               Observability.list_audit_logs(org.id, action: "agent.archived", result: "denied")

      assert audit.actor_user_id == member.id
    end
  end

  describe "visibility" do
    test "an admin cannot write to an agent of another swarm in the org", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, other} = Projects.create_project(org.id, %{"name" => "Other", "slug" => "other"})
      drain_all()
      {:ok, foreign} = create_agent(other, %{"name" => "foreign", "role" => "worker"})
      {:ok, router} = Agents.current_router(other)
      {:ok, before} = SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)

      writes = [
        {:patch, agent_path(org, project, router), %{"system_prompt" => "Hijacked."}},
        {:post, agent_path(org, project, router, "/router-session"),
         %{"expected_session_id" => before["router_session_id"]}}
      ]

      for {method, path, body} <- writes do
        assert %{"error" => %{"code" => "agent_not_found"}} =
                 conn
                 |> dispatch(@endpoint, method, path, body)
                 |> json_response(404)
      end

      {:ok, kept} = SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)
      refute kept["system_prompt"] == "Hijacked."
      assert Enum.any?(Agents.list_agents(other.id), &(&1.id == foreign.id))
      {:ok, after_writes} = SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)
      assert after_writes["router_session_id"] == before["router_session_id"]

      for action <-
            ~w(agent.config_updated agent.router_session_switched) do
        assert Observability.list_audit_logs(org.id, action: action) == []
      end
    end

    test "an org member without a grant, or an outsider, gets 404", %{org: org, project: project} do
      {:ok, agent} = create_agent(project, %{"name" => "private", "role" => "worker"})
      plain = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, plain.id, "member")

      for path <- [agents_path(org, project), agent_path(org, project, agent)] do
        assert %{"error" => %{"code" => "project_not_found"}} =
                 build_conn() |> log_in_user(plain) |> get(path) |> json_response(404)

        assert %{"error" => %{"code" => "org_not_found"}} =
                 build_conn() |> log_in_user(user_fixture()) |> get(path) |> json_response(404)
      end
    end
  end

  defp agents_path(org, project, rest \\ ""),
    do: "/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/agents#{rest}"

  defp agent_path(org, project, agent, rest \\ ""),
    do: agents_path(org, project, "/#{agent.id}#{rest}")

  defp data(%{"data" => data}), do: data

  defp member_conn(org, project) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")
    {log_in_user(build_conn(), member), member}
  end

  defp create_agent(project, attrs) do
    create =
      if attrs["role"] == "worker",
        do: &BridgeForTeams.TestSupport.LegacyWorker.create/2,
        else: &Agents.create_agent/2

    with {:ok, agent} <- create.(project.id, attrs) do
      drain_all()
      Agents.get_agent(agent.id)
    end
  end

  defp refresh_device_projection(_project_id, _device_id, 0),
    do: flunk("device projection did not converge")

  defp refresh_device_projection(project_id, device_id, attempts) do
    assert {:ok, _result} = Environments.reconcile_device_projection(projection_page_limit: 100)

    unless Repo.get_by(ProjectDeviceProjection, project_id: project_id, device_id: device_id),
      do: refresh_device_projection(project_id, device_id, attempts - 1)
  end

  defp put_env(key, value) do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, key)
    SystemsRuntime.put_env(:bridge_for_teams_core, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:bridge_for_teams_core, key),
        else: SystemsRuntime.put_env(:bridge_for_teams_core, key, previous)
    end)
  end

  defp with_client(client), do: put_env(:salix_client, client)

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "agents-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if SystemsRuntime.Proc.self() == test_pid,
            do: SystemsRuntime.Proc.send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      SystemsRuntime.Telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    SystemsRuntime.Proc.receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end
end
