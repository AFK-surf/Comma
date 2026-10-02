defmodule BridgeForTeamsWeb.DashboardAPISwarmAgentsTest do
  @moduledoc """
  The Agents API behind the React Agents page: the paged list with its role
  badges, one agent's detail (model, binding, Triage use, Router session),
  new internal and external agents with their target pickers, model and prompt
  configuration, runtime rebind, archive with its Triage confirmation, and the
  Router session switch. Swarm admins write; a swarm member's write is refused
  with a denied audit; someone outside the swarm gets 404.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query, only: [from: 2]

  alias BridgeForTeams.{Agents, Environments, Memberships, Observability, Projects, Repo}
  alias BridgeForTeams.Salix.Reconciler
  alias BridgeForTeams.Schema.{Agent, ProjectDeviceProjection, ReconcileOutbox}
  alias SalixStore.RuntimeIds

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

  defmodule WorkloadClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    # Workloads live in application env; requests run in the test process.

    defdelegate get_group(group_id), to: BridgeForTeams.Salix.Erpc

    def page_external_worker_targets(_tenant_id, "project", project_id, _group_id, provider, opts) do
      send(self(), {:workload_page, project_id, provider, opts})

      case Application.get_env(:bridge_for_teams_core, :test_workload_page, :items) do
        :items ->
          query = opts |> Keyword.get(:query, "") |> String.downcase()
          limit = Keyword.fetch!(opts, :limit)
          page = if cursor = opts[:cursor], do: String.to_integer(cursor), else: 1

          matching =
            Enum.filter(
              workloads(),
              &(&1.provider == provider and
                  (query == "" or String.contains?(String.downcase(&1.label), query)))
            )

          items =
            matching
            |> Enum.drop((page - 1) * limit)
            |> Enum.take(limit)
            |> Enum.filter(&(opts[:include_unavailable] or &1.selectable))

          {:ok,
           %{
             items: items,
             next_cursor: if(length(matching) > page * limit, do: "#{page + 1}"),
             read_at: DateTime.utc_now()
           }}

        error ->
          error
      end
    end

    def validate_external_worker_target(_tenant, "project", _project, _group, provider, id, fence) do
      send(self(), {:workload_validate, provider, id})

      case Enum.find(workloads(), &(&1.provider == provider and &1.workload_id == id)) do
        nil ->
          {:error, :not_found}

        %{selection_fence: ^fence, selectable: false} = item ->
          {:error, {:target_unavailable, item.reason}}

        %{selection_fence: ^fence} = item ->
          Application.get_env(:bridge_for_teams_core, :test_validate, {:ok, item})

        _changed ->
          {:error, :selection_changed}
      end
    end

    defp workloads, do: Application.fetch_env!(:bridge_for_teams_core, :test_workloads)
  end

  defmodule ProjectionTimeoutClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    defdelegate get_group(group_id), to: BridgeForTeams.Salix.Erpc
    def get_agent_projection(_agent_id, _tenant_id), do: {:error, :timeout}
  end

  defmodule TemplateProbeClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    defdelegate get_group(group_id), to: BridgeForTeams.Salix.Erpc

    def get_template(template_id, _tenant_id) do
      send(self(), {:get_template, template_id})
      {:ok, %{"template_id" => template_id, "model" => "gpt-direct-read"}}
    end

    def list_sessions(agent_id), do: send(self(), {:list_sessions, agent_id})
  end

  defmodule SalixDownClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    def page_group_agents(_tenant, _group, _opts), do: {:error, :unavailable}
  end

  defmodule EmptyCatalogClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    def list_templates(_tenant_id), do: []
    def effective_agent_defaults(_tenant_id), do: {:ok, %{"router" => nil, "worker" => nil}}
    def get_template(_template_id, _tenant_id), do: {:error, :not_found}
  end

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    drain_all()
    %{conn: conn, user: user, org: org, project: project}
  end

  describe "list" do
    test "lists the Router first and the swarm's workers with their badges", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, router} = Agents.current_router(project)
      {:ok, worker} = create_agent(project, %{"name" => "triage", "role" => "worker"})

      data = conn |> get(agents_path(org, project)) |> json_response(200) |> data()

      assert data["status"] == "ok"
      assert data["project"] == %{"id" => project.id, "name" => "Acme", "role" => "admin"}
      assert data["next_cursor"] == nil

      assert data["triage_href"] ==
               "/orgs/#{org.slug}/triage?agent=#{router.id}#triage-worker-configuration"

      rows = Map.new(data["agents"], &{&1["id"], &1})

      assert %{"role" => "router", "group_router" => true, "rebindable" => false} =
               rows[router.id]

      assert %{
               "name" => "triage",
               "role" => "worker",
               "lifecycle" => "active",
               "runtime" => "internal",
               "group_router" => false,
               "triage" => false,
               "rebindable" => false
             } = rows[worker.id]
    end

    test "reads one bounded Salix page at a time from a large group, at a fixed query cost",
         %{conn: conn, org: org, project: project} do
      {:ok, router} = Agents.current_router(project)
      {:ok, base} = SalixAgent.Control.get(router.salix_agent_id)
      conn |> get(agents_path(org, project)) |> json_response(200)
      small = query_count(conn, agents_path(org, project))

      for index <- 1..150 do
        id = SalixStore.Ids.new_agent_id(project.salix_group_id)

        record =
          base
          |> Map.merge(%{
            "agent_id" => id,
            "role" => "worker",
            "name" => "live-worker-#{index}",
            "db_namespace" => "salix:" <> id,
            "heartbeat_schedule_id" => SalixStore.Ids.new_schedule_id()
          })
          |> Map.delete("router_session_id")

        assert {:ok, _} = SalixStore.S3.put(SalixStore.Keys.ctl_agent(id), Jason.encode!(record))
      end

      with_client(ProjectionOnlyClient)
      SalixStore.S3.Fake.reset_read_log()
      first = conn |> get(agents_path(org, project)) |> json_response(200) |> data()
      assert length(first["agents"]) == 100
      assert is_binary(first["next_cursor"])

      prefix = SalixStore.Keys.ctl_agents_prefix_for_group(project.salix_group_id)

      reads =
        Enum.filter(SalixStore.S3.Fake.read_log(), fn
          {:get, key} -> String.starts_with?(key, prefix)
          {:list, key, _opts} -> key == prefix
          _other -> false
        end)

      assert Enum.count(reads, &match?({:list, _, _}, &1)) == 1
      assert Enum.count(reads, &match?({:get, _}, &1)) <= 101

      second =
        conn
        |> get(agents_path(org, project), %{"cursor" => first["next_cursor"]})
        |> json_response(200)
        |> data()

      assert length(second["agents"]) == 51
      assert second["next_cursor"] == nil

      # A page of 100 costs the Postgres queries of a page of one.
      assert query_count(conn, agents_path(org, project)) == small
    end

    test "says so when Salix is down; a stale cursor or a later outage is an error",
         %{conn: conn, org: org, project: project} do
      assert %{"error" => %{"code" => "invalid_cursor"}} =
               conn
               |> get(agents_path(org, project), %{"cursor" => "not-a-cursor"})
               |> json_response(422)

      with_salix_down(fn ->
        assert %{"status" => "unavailable", "agents" => []} =
                 conn |> get(agents_path(org, project)) |> json_response(200) |> data()

        assert %{"error" => %{"code" => "runtime_unavailable"}} =
                 conn
                 |> get(agents_path(org, project), %{"cursor" => "later-page"})
                 |> json_response(503)
      end)
    end

    test "the React dashboard serves the Agents page and an agent's address", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} = create_agent(project, %{"name" => "deep", "role" => "worker"})
      base = "/orgs/#{org.slug}/projects/#{project.id}/agents"

      for path <- [base, "#{base}/#{agent.id}"] do
        assert html_response(get(conn, path), 200) =~ ~s(<div id="root">)
      end
    end
  end

  describe "detail" do
    test "shows the model, prompt and runtime id of a worker", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, template} =
        SalixAgent.Templates.create(%{
          "name" => "Test GPT",
          "model" => "gpt-test",
          "provider" => "mock"
        })

      {:ok, agent} =
        create_agent(project, %{
          "name" => "worker-detail",
          "role" => "worker",
          "template_id" => template["template_id"],
          "system_prompt" => "Summarize tickets."
        })

      data = conn |> get(agent_path(org, project, agent)) |> json_response(200) |> data()

      assert %{
               "id" => id,
               "name" => "worker-detail",
               "model" => "gpt-test",
               "system_prompt" => "Summarize tickets.",
               "runtime_id" => runtime_id,
               "binding" => nil
             } = data["agent"]

      assert id == agent.id
      assert runtime_id == agent.salix_agent_id
      assert data["router_session"] == nil
      assert data["triage"] == %{"status" => "ok", "used" => false, "revision" => nil}
    end

    test "reads the pinned template once and no runtime sessions", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, _} =
        SalixAgent.Templates.create(%{
          "template_id" => "tmpl-detail",
          "name" => "Direct",
          "model" => "gpt-direct-read",
          "provider" => "mock"
        })

      {:ok, agent} =
        create_agent(project, %{
          "name" => "lazy-detail",
          "role" => "worker",
          "template_id" => "tmpl-detail"
        })

      with_client(TemplateProbeClient)

      assert %{"model" => "gpt-direct-read"} =
               conn
               |> get(agent_path(org, project, agent))
               |> json_response(200)
               |> data()
               |> Map.fetch!("agent")

      assert_received {:get_template, "tmpl-detail"}
      refute_received {:list_sessions, _agent_id}
    end

    test "an agent of another swarm, or an unknown one, is not found", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, other} = Projects.create_project(org.id, %{"name" => "Other", "slug" => "other"})
      drain_all()
      {:ok, foreign} = create_agent(other, %{"name" => "foreign", "role" => "worker"})

      for agent_id <- [foreign.id, Ecto.UUID.generate(), "not-an-id"] do
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

    test "only a Router has a canonical session", %{conn: conn, org: org, project: project} do
      {:ok, worker} = create_agent(project, %{"name" => "w", "role" => "worker"})

      assert %{"error" => %{"code" => "not_router"}} =
               conn
               |> post(agent_path(org, project, worker, "/router-session"), %{
                 "expected_session_id" => "ses1_x"
               })
               |> json_response(422)
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
    test "creates an internal worker whatever role is asked for, with an audit", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      assert %{"notice" => "Agent creation accepted. Refresh the list after provisioning."} =
               conn
               |> post(agents_path(org, project), %{
                 "type" => "internal",
                 "name" => "worker-1",
                 "role" => "router"
               })
               |> json_response(201)
               |> data()

      drain_all()
      agents = Agents.list_agents(project.id)
      worker = Enum.find(agents, &(&1.salix["name"] == "worker-1"))
      assert worker.role == "worker"
      assert Enum.any?(agents, &(&1.salix["name"] == "Router" and &1.role == "router"))

      assert [audit] = Observability.list_audit_logs(org.id, action: "agent.created")
      assert audit.actor_user_id == admin.id
      assert audit.resource_id == worker.id
      assert audit.metadata["project_id"] == project.id
      assert audit.redacted_diff["role"] == %{"from" => nil, "to" => "worker"}
    end

    test "creates an external Codex worker on a connected device runtime", %{
      conn: conn,
      org: org,
      project: project
    } do
      device_id = "device-#{Ecto.UUID.generate()}"
      runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", "runtime-codex")
      checked_at = System.system_time(:millisecond)

      connect_device(org, project, device_id, [
        codex_runtime(runtime_id, %{
          "version" => "codex-cli 1.2.3",
          "readiness_checked_at" => checked_at,
          "readiness_valid_until" => checked_at + 600_000
        }),
        %{"id" => "internal-codex", "kind" => "internal", "provider" => "codex"},
        %{"id" => "other-runtime", "kind" => "external", "provider" => "other"}
      ])

      with_client(ProjectionOnlyClient)

      assert %{"devices" => [%{"id" => ^device_id, "label" => label, "runtimes" => [runtime]}]} =
               conn |> get(agents_path(org, project, "/targets")) |> json_response(200) |> data()

      assert label =~ "Mac Studio"

      assert %{
               "id" => ^runtime_id,
               "ready" => true,
               "status" => "ready",
               "version" => "codex-cli 1.2.3",
               "checked_at" => checked
             } = runtime

      assert {:ok, _, 0} = DateTime.from_iso8601(checked)
      refute inspect(runtime) =~ "/usr/local/bin/codex"

      assert conn
             |> post(agents_path(org, project), %{
               "type" => "external",
               "name" => "codex-worker",
               "target" => %{
                 "kind" => "connected_runtime",
                 "device_id" => device_id,
                 "device_runtime_id" => runtime_id
               }
             })
             |> json_response(201)

      drain_all()
      agent = Enum.find(Agents.list_agents(project.id), &(&1.salix["name"] == "codex-worker"))
      assert agent.role == "worker"
      assert agent.salix["runtime_config"]["device_runtime_id"] == runtime_id
    end

    test "names the missing or unready target", %{conn: conn, org: org, project: project} do
      device_id = "device-#{Ecto.UUID.generate()}"
      runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", "runtime-codex")

      connect_device(org, project, device_id, [
        codex_runtime(runtime_id, %{
          "version" => "unknown",
          "version_detected" => false,
          "status" => "unavailable",
          "ready" => false,
          "auth_ready" => false,
          "last_error" => "Codex CLI is not authenticated"
        })
      ])

      assert %{"devices" => [%{"runtimes" => [runtime]}]} =
               conn |> get(agents_path(org, project, "/targets")) |> json_response(200) |> data()

      assert %{"ready" => false, "status" => "unavailable", "issue" => issue} = runtime
      assert is_binary(issue)
      refute inspect(runtime) =~ "not authenticated"

      for {target, message} <- [
            {%{}, "Select a connected device."},
            {%{"device_id" => device_id}, "Select an external runtime."},
            {%{"device_id" => device_id, "device_runtime_id" => runtime_id},
             "Selected external runtime is not ready."},
            {%{"kind" => "compute_workload", "workload_id" => "w-1"},
             "Select a Compute Workload."}
          ] do
        assert %{"error" => %{"message" => ^message}} =
                 conn
                 |> post(agents_path(org, project), %{
                   "type" => "external",
                   "name" => "x",
                   "target" => target
                 })
                 |> json_response(422)
      end

      refute Enum.any?(Agents.list_agents(project.id), &(&1.salix["name"] == "x"))
    end

    test "a swarm without connected devices offers none", %{
      conn: conn,
      org: org,
      project: project
    } do
      assert %{"devices" => []} =
               conn |> get(agents_path(org, project, "/targets")) |> json_response(200) |> data()
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

      for path <- ["/targets", "/workloads"] do
        assert member_conn |> get(agents_path(org, project, path)) |> json_response(403)
      end

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

  describe "Compute Workloads" do
    setup do
      pi =
        for index <- 1..151 do
          %{
            workload_id: "pi-workload-#{index}",
            label: "Pi Workload #{index}",
            provider: "pi",
            node: %{id: "node-1", label: "Mac Studio"},
            selectable: index != 2,
            reason: if(index == 2, do: "runtime_not_ready"),
            reconcile_error:
              if(index == 2,
                do: %{
                  "code" => "resource_capacity_exhausted",
                  "stage" => "import_admission",
                  "resource" => "storage_headroom",
                  "message" => "Guest storage headroom is unavailable.",
                  "available_bytes" => 1_073_741_824,
                  "required_bytes" => 2_147_483_648
                }
              ),
            updated_at: DateTime.utc_now(),
            selection_fence: %{"workload_revision" => index, "runtime_connection_epoch" => 7}
          }
        end

      claude = %{
        workload_id: "claude-workload-1",
        label: "Claude Workload 1",
        provider: "claude",
        node: %{id: "node-1", label: "Mac Studio"},
        selectable: true,
        reason: nil,
        updated_at: DateTime.utc_now(),
        selection_fence: %{"workload_revision" => 1, "runtime_connection_epoch" => 7}
      }

      put_env(:test_workloads, [claude | pi])
      put_env(:test_workload_page, :items)
      with_client(WorkloadClient)
      :ok
    end

    test "pages 50 per provider, hides unavailable ones unless asked, and searches", %{
      conn: conn,
      org: org,
      project: project
    } do
      project_id = project.id
      page = workloads(conn, org, project, %{"provider" => "pi"})
      assert length(page["items"]) == 49
      assert page["next_cursor"] == "2"
      refute Enum.any?(page["items"], &(&1["id"] == "pi-workload-2"))
      assert_received {:workload_page, ^project_id, "pi", opts}
      assert opts[:include_unavailable] == false

      page = workloads(conn, org, project, %{"provider" => "pi", "include_unavailable" => "true"})
      assert length(page["items"]) == 50
      unavailable = Enum.find(page["items"], &(&1["id"] == "pi-workload-2"))

      assert %{"selectable" => false, "availability" => "Runtime not ready", "tone" => "warn"} =
               unavailable

      assert unavailable["issue"] ==
               "code=resource_capacity_exhausted / stage=import_admission / resource=storage_headroom / message=Guest storage headroom is unavailable. / available_bytes=1073741824 / required_bytes=2147483648"

      assert [%{"id" => "claude-workload-1", "node" => "Mac Studio"}] =
               workloads(conn, org, project, %{"provider" => "claude"})["items"]

      assert [%{"id" => "pi-workload-151"}] =
               workloads(conn, org, project, %{"provider" => "pi", "query" => "151"})["items"]

      assert workloads(conn, org, project, %{"provider" => "codex", "query" => "151"})["items"] ==
               []

      last = workloads(conn, org, project, %{"provider" => "pi", "cursor" => "4"})
      assert [%{"id" => "pi-workload-151"}] = last["items"]
      assert last["next_cursor"] == nil

      put_env(:test_workload_page, {:error, :unavailable})

      assert %{"status" => "unavailable", "items" => []} =
               workloads(conn, org, project, %{"provider" => "pi"})
    end

    test "creates a worker on the selected Workload with its selection fence", %{
      conn: conn,
      org: org,
      project: project
    } do
      [item] = workloads(conn, org, project, %{"provider" => "pi", "query" => "151"})["items"]
      target = %{"kind" => "compute_workload", "workload_id" => item["id"]}

      assert %{
               "error" => %{
                 "message" =>
                   "The selected Workload changed. Refresh the list and select it again."
               }
             } =
               conn
               |> post(agents_path(org, project), %{
                 "type" => "external",
                 "name" => "pi-compute",
                 "target" => Map.put(target, "selection_fence", %{"workload_revision" => 0})
               })
               |> json_response(409)

      assert conn
             |> post(agents_path(org, project), %{
               "type" => "external",
               "name" => "pi-compute",
               "target" => Map.put(target, "selection_fence", item["selection_fence"])
             })
             |> json_response(201)

      # Core tries each provider until one owns the Workload.
      assert_received {:workload_validate, "codex", "pi-workload-151"}
      assert_received {:workload_validate, "pi", "pi-workload-151"}

      row =
        Repo.one!(
          from(r in ReconcileOutbox,
            where:
              r.op == "create_owned_agent" and
                fragment("?->'attrs'->>'name' = ?", r.payload, "pi-compute"),
            limit: 1
          )
        )

      {:ok, agent} = Agents.get_agent(row.aggregate_id)
      assert Agent.lifecycle(agent) == "provisioning"
      refute Repo.get!(Agent, agent.id).salix["runtime_config"]
      assert agent.salix["runtime_config"]["kind"] == "compute_workload"
      assert agent.salix["runtime_config"]["runtime_spec"] == %{"provider" => "pi"}

      assert agent.salix["runtime_config"]["owner_scope"] == %{
               "type" => "project",
               "id" => project.id
             }

      assert agent.salix["runtime_config"]["binding_revision"] == 1
    end

    test "a Workload core refuses says why, in the reader's language", %{
      conn: conn,
      org: org,
      project: project,
      user: user
    } do
      [unready] =
        workloads(conn, org, project, %{"provider" => "pi", "include_unavailable" => "true"})[
          "items"
        ]
        |> Enum.filter(&(&1["id"] == "pi-workload-2"))

      [ready] = workloads(conn, org, project, %{"provider" => "pi", "query" => "151"})["items"]

      create = fn item ->
        conn
        |> post(agents_path(org, project), %{
          "type" => "external",
          "name" => "refused",
          "target" => %{
            "kind" => "compute_workload",
            "workload_id" => item["id"],
            "selection_fence" => item["selection_fence"]
          }
        })
      end

      assert %{
               "error" => %{
                 "code" => "target_unavailable",
                 "message" => "The selected Workload is not ready: Runtime not ready."
               }
             } = unready |> create.() |> json_response(409)

      for {result, status, code, message} <- [
            {{:ok, %{"provider" => "codex", "workload_id" => "pi-workload-151"}}, 422,
             "provider_mismatch",
             "The selected Workload runs a different provider. Refresh the list and select it again."},
            {{:error, :provider_unsupported}, 422, "provider_unsupported",
             "The selected Workload's provider is not supported."}
          ] do
        put_env(:test_validate, result)

        assert %{"error" => %{"code" => ^code, "message" => ^message}} =
                 ready |> create.() |> json_response(status)
      end

      Application.delete_env(:bridge_for_teams_core, :test_validate)
      {:ok, _} = BridgeForTeams.Accounts.update_user(user, %{"preferred_locale" => "zh_Hans"})

      assert %{"error" => %{"message" => "所选工作负载尚未就绪：运行时未就绪。"}} =
               unready |> create.() |> json_response(409)

      refute Enum.any?(Agents.list_agents(project.id), &(&1.salix["name"] == "refused"))
    end
  end

  describe "rebind" do
    test "moves an external worker's new sessions to another device runtime", %{
      conn: conn,
      org: org,
      project: project
    } do
      {agent, initial, next} = external_worker(org, project)

      detail = conn |> get(agent_path(org, project, agent)) |> json_response(200) |> data()

      assert %{
               "rebindable" => true,
               "runtime" => "connected",
               "binding" => %{
                 "location" => "connected",
                 "device_id" => initial_device,
                 "device_runtime_id" => initial_runtime,
                 "revision" => 0,
                 "summary" => "Codex · " <> _
               }
             } = detail["agent"]

      assert {initial_device, initial_runtime} == initial

      {next_device, next_runtime} = next

      assert %{"notice" => "Agent runtime rebound.", "agent" => %{"binding" => binding}} =
               conn
               |> put(agent_path(org, project, agent, "/runtime"), %{
                 "expected_binding_revision" => 0,
                 "target" => %{
                   "kind" => "connected_runtime",
                   "device_id" => next_device,
                   "device_runtime_id" => next_runtime
                 }
               })
               |> json_response(200)
               |> data()

      assert binding["revision"] == 1
      refute Repo.get!(Agent, agent.id).salix["runtime_config"]
      {:ok, record} = SalixAgent.Control.get(agent.salix_agent_id)

      assert record["runtime_config"] == %{
               "kind" => "connected_runtime",
               "provider" => "codex",
               "device_id" => next_device,
               "runtime_id" => "runtime-codex-next",
               "device_runtime_id" => next_runtime,
               "owner_scope" => %{"type" => "group", "id" => project.salix_group_id},
               "binding_revision" => 1
             }

      # The revision the form was opened with is now stale.
      assert %{"error" => %{"code" => "stale_binding"}} =
               conn
               |> put(agent_path(org, project, agent, "/runtime"), %{
                 "expected_binding_revision" => 0,
                 "target" => %{
                   "kind" => "connected_runtime",
                   "device_id" => next_device,
                   "device_runtime_id" => next_runtime
                 }
               })
               |> json_response(409)
    end

    test "works while the agent's runtime projection times out", %{
      conn: conn,
      org: org,
      project: project
    } do
      {agent, _initial, {next_device, next_runtime}} = external_worker(org, project)
      with_client(ProjectionTimeoutClient)

      assert conn
             |> put(agent_path(org, project, agent, "/runtime"), %{
               "expected_binding_revision" => 0,
               "target" => %{
                 "kind" => "connected_runtime",
                 "device_id" => next_device,
                 "device_runtime_id" => next_runtime
               }
             })
             |> json_response(200)

      {:ok, record} = SalixAgent.Control.get(agent.salix_agent_id)
      assert record["runtime_config"]["device_runtime_id"] == next_runtime
    end

    test "rebinding to a Workload that changed since it was listed is refused", %{
      conn: conn,
      org: org,
      project: project
    } do
      {agent, _initial, _next} = external_worker(org, project)
      {:ok, before} = SalixAgent.Control.get(agent.salix_agent_id)
      fence = %{"workload_revision" => 3, "runtime_connection_epoch" => 7}

      put_env(:test_workloads, [
        %{
          workload_id: "pi-1",
          label: "Pi 1",
          provider: "pi",
          selectable: true,
          selection_fence: fence
        }
      ])

      with_client(WorkloadClient)

      assert %{"error" => %{"code" => "selection_changed"}} =
               conn
               |> put(agent_path(org, project, agent, "/runtime"), %{
                 "expected_binding_revision" => 0,
                 "target" => %{
                   "kind" => "compute_workload",
                   "workload_id" => "pi-1",
                   "selection_fence" => %{"workload_revision" => 2}
                 }
               })
               |> json_response(409)

      {:ok, unchanged} = SalixAgent.Control.get(agent.salix_agent_id)
      assert unchanged["runtime_config"] == before["runtime_config"]
    end

    test "an internal worker cannot be rebound", %{conn: conn, org: org, project: project} do
      {:ok, worker} = create_agent(project, %{"name" => "internal", "role" => "worker"})

      assert %{"error" => %{"code" => "unsupported_runtime_binding"}} =
               conn
               |> put(agent_path(org, project, worker, "/runtime"), %{
                 "expected_binding_revision" => 0,
                 "target" => %{"device_id" => "d", "device_runtime_id" => "r"}
               })
               |> json_response(422)
    end
  end

  describe "configure" do
    test "saves a catalog model and prompt with an audit that keeps the prompt out", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      {:ok, tmpl} = SalixAgent.Templates.create(%{"name" => "Opus", "model" => "claude-opus-4-8"})
      {:ok, agent} = create_agent(project, %{"name" => "cfg", "role" => "worker"})

      config =
        conn |> get(agent_path(org, project, agent, "/config")) |> json_response(200) |> data()

      assert config["available"] == true
      assert %{"id" => "", "label" => "Default (" <> _} = hd(config["models"])
      assert Enum.any?(config["models"], &(&1["id"] == tmpl["template_id"]))

      assert %{"notice" => "Agent configuration saved."} =
               conn
               |> patch(agent_path(org, project, agent), %{
                 "template_id" => tmpl["template_id"],
                 "system_prompt" => "Be helpful."
               })
               |> json_response(200)
               |> data()

      {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.role == "worker"
      assert reloaded.salix["template_id"] == tmpl["template_id"]
      assert reloaded.salix["system_prompt"] == "Be helpful."

      assert %{"template_id" => template_id, "system_prompt" => "Be helpful."} =
               conn
               |> get(agent_path(org, project, agent, "/config"))
               |> json_response(200)
               |> data()

      assert template_id == tmpl["template_id"]

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

    test "a new model keeps an unset prompt unset; clearing a set prompt is refused", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, subscription} =
        SalixAgent.SubscriptionTemplates.save(org.salix_tenant_id, nil, %{
          "name" => "Codex",
          "model" => "gpt-5.6-sol",
          "subscription_provider" => "codex"
        })

      {:ok, router} = create_agent(project, %{"name" => "Router", "role" => "router"})
      assert router.salix["system_prompt"] in [nil, ""]

      # A private subscription model is in its own BYOK group.
      config =
        conn |> get(agent_path(org, project, router, "/config")) |> json_response(200) |> data()

      assert %{"group" => "BYOK"} =
               Enum.find(config["models"], &(&1["id"] == subscription["template_id"]))

      assert conn
             |> patch(agent_path(org, project, router), %{
               "template_id" => subscription["template_id"],
               "system_prompt" => ""
             })
             |> json_response(200)

      {:ok, saved} = Agents.get_agent(router.id)
      assert saved.salix["template_id"] == subscription["template_id"]
      assert saved.salix["system_prompt"] == router.salix["system_prompt"]

      {:ok, other} = SalixAgent.Templates.create(%{"name" => "Other model", "model" => "gpt-5"})

      {:ok, worker} =
        create_agent(project, %{
          "name" => "Configured",
          "role" => "worker",
          "system_prompt" => "Keep these instructions."
        })

      assert %{"error" => %{"details" => %{"fields" => %{"system_prompt" => [message]}}}} =
               conn
               |> patch(agent_path(org, project, worker), %{
                 "template_id" => other["template_id"],
                 "system_prompt" => ""
               })
               |> json_response(422)

      assert message == "An existing system prompt cannot be cleared."
      {:ok, unchanged} = Agents.get_agent(worker.id)
      assert unchanged.salix["system_prompt"] == "Keep these instructions."
      assert unchanged.salix["template_id"] == worker.salix["template_id"]
    end

    test "keeps a legacy default choice selectable and can follow the platform default", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_agent(project, %{
          "name" => "Legacy",
          "role" => "worker",
          "template_id" => "default"
        })

      config =
        conn |> get(agent_path(org, project, agent, "/config")) |> json_response(200) |> data()

      assert config["template_id"] == "default"

      assert %{"label" => label, "disabled" => false} =
               Enum.find(config["models"], &(&1["id"] == "default"))

      assert label =~ "(current choice)"

      assert conn
             |> patch(agent_path(org, project, agent), %{"template_id" => ""})
             |> json_response(200)

      {:ok, updated} = Agents.get_agent(agent.id)
      refute updated.salix["template_id"]
    end

    test "shows a pin the allowlist excludes without letting it be chosen again", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, current} =
        SalixAgent.Templates.create(%{"name" => "Current router", "model" => "deepseek-flash"})

      {:ok, allowed} =
        SalixAgent.Templates.create(%{"name" => "Allowed alternative", "model" => "gpt-5"})

      {:ok, agent} =
        create_agent(project, %{
          "name" => "Router",
          "role" => "router",
          "template_id" => current["template_id"]
        })

      {:ok, org} =
        BridgeForTeams.Orgs.update_org(org, %{"allowed_template_ids" => [allowed["template_id"]]})

      config =
        conn |> get(agent_path(org, project, agent, "/config")) |> json_response(200) |> data()

      ids = Enum.map(config["models"], & &1["id"])
      assert ids == ["", current["template_id"], allowed["template_id"]]

      assert %{
               "disabled" => true,
               "label" => "deepseek-flash (current; unavailable for selection)"
             } =
               Enum.at(config["models"], 1)

      # Saving the prompt alone keeps the model; the excluded pin is refused.
      assert conn
             |> patch(agent_path(org, project, agent), %{"system_prompt" => "Route politely."})
             |> json_response(200)

      assert %{"error" => %{"message" => "Choose a model from the list before saving."}} =
               conn
               |> patch(agent_path(org, project, agent), %{
                 "template_id" => current["template_id"]
               })
               |> json_response(422)

      {:ok, unchanged} = Agents.get_agent(agent.id)
      assert unchanged.salix["template_id"] == current["template_id"]

      assert conn
             |> patch(agent_path(org, project, agent), %{"template_id" => allowed["template_id"]})
             |> json_response(200)

      {:ok, changed} = Agents.get_agent(agent.id)
      assert changed.salix["template_id"] == allowed["template_id"]

      assert conn
             |> patch(agent_path(org, project, agent), %{"template_id" => ""})
             |> json_response(200)

      {:ok, following} = Agents.get_agent(agent.id)
      refute following.salix["template_id"]
    end

    test "says when no models are available and keeps the current pin visible", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, pinned} = SalixAgent.Templates.create(%{"name" => "Pinned model", "model" => "mock"})

      {:ok, agent} =
        create_agent(project, %{
          "name" => "cfg2",
          "role" => "worker",
          "template_id" => pinned["template_id"]
        })

      with_client(EmptyCatalogClient)

      config =
        conn |> get(agent_path(org, project, agent, "/config")) |> json_response(200) |> data()

      assert config["available"] == false

      assert [
               %{"id" => "", "label" => "Default (unavailable)"},
               %{"id" => id, "label" => label, "disabled" => true}
             ] = config["models"]

      assert id == pinned["template_id"]
      assert label =~ pinned["template_id"]
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

  describe "archive" do
    test "archives a worker with an audit", %{conn: conn, org: org, project: project, user: admin} do
      {:ok, agent} = create_agent(project, %{"name" => "gone", "role" => "worker"})

      assert %{"redirect" => redirect, "notice" => "Agent archived."} =
               conn
               |> post(agent_path(org, project, agent, "/archive"))
               |> json_response(200)
               |> data()

      assert redirect == "/orgs/#{org.slug}/projects/#{project.id}/agents"
      agents = Agents.list_agents(project.id)
      refute Enum.any?(agents, &(&1.id == agent.id))
      assert Enum.any?(agents, &(&1.salix["name"] == "Router" and &1.role == "router"))

      assert [audit] = Observability.list_audit_logs(org.id, action: "agent.archived")
      assert audit.actor_user_id == admin.id
      assert audit.resource_id == agent.id

      assert audit.redacted_diff["status"] == %{
               "from" => Agent.lifecycle(agent),
               "to" => "archived"
             }
    end

    @tag :triage_archive
    test "archiving the Triage Worker needs the confirmed Triage revision", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, worker} = create_agent(project, %{"name" => "Investigator", "role" => "worker"})
      {:ok, router} = Agents.current_router(project)

      assert {:ok, binding} =
               SalixAgent.TriageWorker.configure(
                 project.salix_group_id,
                 router.salix_agent_id,
                 worker.salix_agent_id,
                 0,
                 %{"actor_user_id" => "admin", "request_id" => "select"}
               )

      list = conn |> get(agents_path(org, project)) |> json_response(200) |> data()
      assert %{"triage" => true} = Enum.find(list["agents"], &(&1["id"] == worker.id))

      # Without the confirmation the archive is refused.
      assert %{"error" => %{"code" => "triage_confirmation_required"}} =
               conn |> post(agent_path(org, project, worker, "/archive")) |> json_response(409)

      assert Enum.any?(Agents.list_agents(project.id), &(&1.id == worker.id))

      detail = conn |> get(agent_path(org, project, worker)) |> json_response(200) |> data()
      assert %{"status" => "ok", "used" => true, "revision" => revision} = detail["triage"]

      assert detail["triage_href"] ==
               "/orgs/#{org.slug}/triage?agent=#{router.id}#triage-worker-configuration"

      assert conn
             |> post(agent_path(org, project, worker, "/archive"), %{
               "triage_revision" => revision
             })
             |> json_response(200)

      refute Enum.any?(Agents.list_agents(project.id), &(&1.id == worker.id))

      assert {:error, :triage_worker_unavailable} =
               SalixAgent.TriageWorker.ensure(project.salix_group_id, router.salix_agent_id)

      assert {:ok, ^binding} = SalixAgent.TriageWorker.get(project.salix_group_id)
    end

    @tag :triage_archive
    test "a Triage assignment made after the confirmation must be reviewed", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, worker} = create_agent(project, %{"name" => "Investigator", "role" => "worker"})
      {:ok, router} = Agents.current_router(project)

      assert %{"used" => false, "revision" => nil} =
               conn
               |> get(agent_path(org, project, worker))
               |> json_response(200)
               |> data()
               |> Map.fetch!("triage")

      assert {:ok, _} =
               SalixAgent.TriageWorker.configure(
                 project.salix_group_id,
                 router.salix_agent_id,
                 worker.salix_agent_id,
                 0,
                 %{"actor_user_id" => "other-admin", "request_id" => "late-select"}
               )

      assert conn |> post(agent_path(org, project, worker, "/archive")) |> json_response(409)
      assert Enum.any?(Agents.list_agents(project.id), &(&1.id == worker.id))

      # Choosing another Worker releases the original without pausing Triage.
      {:ok, replacement} = create_agent(project, %{"name" => "Replacement", "role" => "worker"})

      assert {:ok, _} =
               SalixAgent.TriageWorker.configure(
                 project.salix_group_id,
                 router.salix_agent_id,
                 replacement.salix_agent_id,
                 1,
                 %{"actor_user_id" => "admin", "request_id" => "replace"}
               )

      assert conn |> post(agent_path(org, project, worker, "/archive")) |> json_response(200)

      assert {:ok, selected} =
               SalixAgent.TriageWorker.ensure(project.salix_group_id, router.salix_agent_id)

      assert selected == replacement.salix_agent_id
    end

    test "a Router cannot be archived; the failure is audited", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      {:ok, router} = Agents.current_router(project)

      assert %{"error" => %{"message" => "Router agents cannot be archived."}} =
               conn |> post(agent_path(org, project, router, "/archive")) |> json_response(422)

      assert Enum.any?(Agents.list_agents(project.id), &(&1.id == router.id))

      assert [audit] =
               Observability.list_audit_logs(org.id, action: "agent.archived", result: "failed")

      assert audit.actor_user_id == admin.id
      assert audit.resource_id == router.id
      assert audit.reason_class == "router_agent"
    end

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
        {:patch, agent_path(org, project, foreign), %{"system_prompt" => "Hijacked."}},
        {:put, agent_path(org, project, foreign, "/runtime"),
         %{
           "expected_binding_revision" => 0,
           "target" => %{"device_id" => "d", "device_runtime_id" => "r"}
         }},
        {:post, agent_path(org, project, foreign, "/archive"), %{}},
        {:post, agent_path(org, project, router, "/router-session"),
         %{"expected_session_id" => before["router_session_id"]}}
      ]

      for {method, path, body} <- writes do
        assert %{"error" => %{"code" => "agent_not_found"}} =
                 conn
                 |> dispatch(@endpoint, method, path, body)
                 |> json_response(404)
      end

      {:ok, kept} = Agents.get_agent(foreign.id)
      assert kept.salix["system_prompt"] in [nil, ""]
      assert Enum.any?(Agents.list_agents(other.id), &(&1.id == foreign.id))
      {:ok, after_writes} = SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)
      assert after_writes["router_session_id"] == before["router_session_id"]

      for action <-
            ~w(agent.config_updated agent.runtime_rebound agent.archived agent.router_session_switched) do
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

  defp workloads(conn, org, project, params) do
    conn |> get(agents_path(org, project, "/workloads"), params) |> json_response(200) |> data()
  end

  defp data(%{"data" => data}), do: data

  defp member_conn(org, project) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")
    {log_in_user(build_conn(), member), member}
  end

  defp create_agent(project, attrs) do
    with {:ok, agent} <- Agents.create_agent(project.id, attrs) do
      drain_all()
      Agents.get_agent(agent.id)
    end
  end

  # A worker bound to one connected Codex runtime, with a second device ready
  # to take it over.
  defp external_worker(org, project) do
    initial_device = "device-#{Ecto.UUID.generate()}"
    initial = RuntimeIds.device_runtime_id(initial_device, "codex", "runtime-codex-initial")
    next_device = "device-#{Ecto.UUID.generate()}"
    next = RuntimeIds.device_runtime_id(next_device, "codex", "runtime-codex-next")

    connect_device(org, project, initial_device, [
      codex_runtime(initial, %{"runtime_id" => "runtime-codex-initial"})
    ])

    connect_device(org, project, next_device, [
      codex_runtime(next, %{
        "runtime_id" => "runtime-codex-next",
        "model" => "claude-sonnet-4",
        "model_provider" => "anthropic"
      })
    ])

    runtime_config = %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => initial_device,
      "runtime_id" => "runtime-codex-initial",
      "device_runtime_id" => initial
    }

    {:ok, agent} =
      create_agent(project, %{
        "name" => "codex-worker",
        "role" => "worker",
        "runtime_config" => runtime_config
      })

    {agent, {initial_device, initial}, {next_device, next}}
  end

  defp codex_runtime(device_runtime_id, attrs) do
    now = System.system_time(:millisecond)

    Map.merge(
      %{
        "kind" => "external",
        "provider" => "codex",
        "runtime_id" => "runtime-codex",
        "device_runtime_id" => device_runtime_id,
        "command" => "/usr/local/bin/codex",
        "version" => "codex-test",
        "status" => "available",
        "version_detected" => true,
        "ready" => true,
        "auth_ready" => true,
        "native_server_startable" => true,
        "readiness_checked_at" => now,
        "readiness_valid_until" => now + 600_000
      },
      attrs
    )
  end

  defp connect_device(org, project, device_id, runtimes) do
    {:ok, _transport_id, _record} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        %{
          "tenant_id" => org.salix_tenant_id,
          "group_id" => project.salix_group_id,
          "device_id" => device_id,
          "connector_id" => "connector-" <> device_id,
          "name" => "Mac Studio",
          "agent_runtimes" => runtimes
        },
        transport_id: "transport-" <> device_id
      )

    refresh_device_projection(project.id, device_id, 20)
  end

  defp refresh_device_projection(_project_id, _device_id, 0),
    do: flunk("device projection did not converge")

  defp refresh_device_projection(project_id, device_id, attempts) do
    assert {:ok, _result} = Environments.reconcile_device_projection(projection_page_limit: 100)

    unless Repo.get_by(ProjectDeviceProjection, project_id: project_id, device_id: device_id),
      do: refresh_device_projection(project_id, device_id, attempts - 1)
  end

  defp put_env(key, value) do
    previous = Application.get_env(:bridge_for_teams_core, key)
    Application.put_env(:bridge_for_teams_core, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:bridge_for_teams_core, key),
        else: Application.put_env(:bridge_for_teams_core, key, previous)
    end)
  end

  defp with_client(client), do: put_env(:salix_client, client)

  defp with_salix_down(fun) do
    with_client(SalixDownClient)
    fun.()
  end

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp query_count(conn, path) do
    test_pid = self()
    handler = "agents-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end
end
