defmodule BridgeForTeamsWeb.RouterTaskPlaceModelTest do
  @moduledoc """
  A BFT Router creates each Task by naming its model and, when needed, where it
  runs, never a Worker: its round offers no Worker management and its manual
  needs no agent_id. A Task without agent_id runs on the swarm's Task agent with
  the model the Router wrote on it, inside Salix or on a station. A catalog
  model the Organization does not allow is refused and makes no Task.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Agents, Projects, Repo}
  alias BridgeForTeams.Salix.Reconciler
  alias BridgeForTeams.Schema.Organization
  alias SalixIM.Conversations

  @worker_management ~w(agent.list agent.get agent.create_worker agent.update agent.rebind_runtime agent.archive)

  defmodule StationsFake do
    @moduledoc "The stations a Task runs on (`SalixIM.Ports.TaskStations`): what they are asked."
    @behaviour SalixIM.Ports.TaskStations

    @impl true
    def invite(invitation) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_web, :router_task_test_pid),
        do: SystemsRuntime.Proc.send(pid, {:station_invite, invitation})

      {:ok, "station-session-1"}
    end

    @impl true
    def joined(_row), do: :ok

    @impl true
    def standing(_group_id, _conversation_id), do: :not_station

    @impl true
    def appended(_group_id, _conversation_id), do: :ok
  end

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    SalixAgent.TestSupport.configure_platform_models!()
    %{org: org} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    drain_all()
    {:ok, router} = Agents.current_router(project)

    previous = SystemsRuntime.get_env(:salix_im, :task_stations_mod)
    SystemsRuntime.put_env(:salix_im, :task_stations_mod, StationsFake)

    SystemsRuntime.put_env(
      :bridge_for_teams_web,
      :router_task_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      SystemsRuntime.delete_env(:bridge_for_teams_web, :router_task_test_pid)

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_im, :task_stations_mod),
        else: SystemsRuntime.put_env(:salix_im, :task_stations_mod, previous)
    end)

    %{org: org, project: project, router: router}
  end

  test "a BFT Router is offered no Worker management, and nothing asks it to name a Worker",
       %{router: router} do
    assert {:ok, config} =
             SalixAgent.RoundConfig.build_round_config(router.salix_agent_id, "router", %{})

    tools = MapSet.new(config.session_config.tool_disclosure["tools"], & &1["name"])
    assert MapSet.member?(tools, "agent.models")
    for name <- @worker_management, do: refute(MapSet.member?(tools, name))

    prompt = config.session_config.system_prompt
    assert prompt =~ "Create every Task without agent_id"
    for name <- @worker_management, do: refute(prompt =~ name)

    assert {:ok, %{"apis" => apis}} =
             SalixIM.Provider.provider_manual("internal", router.salix_agent_id)

    create = Enum.find(apis, &(&1["name"] == "internal.task.create"))
    refute "agent_id" in create["required_params"]
  end

  test "a Task without agent_id takes the model the Router wrote on it, inside Salix or on a station",
       %{org: org, project: project, router: router} do
    task_agent = SalixAgent.TaskAgent.id(project.salix_group_id)
    sol = %{"kind" => "catalog", "model" => "gpt-6.1-sol", "reasoning_effort" => "high"}

    # Inside Salix: the Task agent's Session for this Task runs the chosen model.
    assert {:ok, %{"created" => true, "conversation_id" => inside}} =
             create_task(router, %{"content" => "Review the release notes.", "model" => sol})

    worker = task_worker(project, inside, task_agent)

    assert %{"model" => "gpt-6.1-sol", "reasoning_effort" => "high"} =
             worker["payload"]["session_model"]

    refute SalixIM.TaskConversationInput.station_worker?(worker)
    refute_received {:station_invite, _invitation}

    # On a station the Router names: that station runs the chosen runtime model.
    device_id = "device-router-station"

    connect_station(org, project, device_id, %{
      "tasks" => 2,
      "task_models" => %{"codex" => ["gpt-5.5"]}
    })

    runs_on = %{"kind" => "station", "device_id" => device_id}

    assert {:ok, %{"created" => true, "conversation_id" => on_station}} =
             create_task(router, %{
               "content" => "Run the benchmark.",
               "model" => %{"kind" => "runtime", "provider" => "codex", "model" => "gpt-5.5"},
               "runs_on" => runs_on
             })

    assert_received {:station_invite,
                     %{device_id: ^device_id, conversation_id: ^on_station, start: start}}

    assert start["runtime"] == "codex"
    assert start["model"] == "gpt-5.5"

    assert SalixIM.TaskConversationInput.station_worker?(
             task_worker(project, on_station, task_agent)
           )
  end

  test "a catalog model the Organization does not allow is refused and makes no Task",
       %{org: org, project: project, router: router} do
    allowed = %{"kind" => "catalog", "model" => "gpt-5.5"}

    Organization
    |> Repo.get!(org.id)
    |> Ecto.Changeset.change(allowed_models: [allowed])
    |> Repo.update!()

    assert {:error, refused} =
             create_task(router, %{
               "content" => "Draft the plan.",
               "model" => %{"kind" => "catalog", "model" => "gpt-6.1-sol"}
             })

    assert refused =~ "the organization does not allow this model choice"
    assert {:ok, %{"data" => []}} = list_tasks(project)

    assert {:ok, %{"created" => true, "conversation_id" => created}} =
             create_task(router, %{"content" => "Draft the plan.", "model" => allowed})

    worker = task_worker(project, created, SalixAgent.TaskAgent.id(project.salix_group_id))
    assert worker["payload"]["session_model"]["model"] == "gpt-5.5"
  end

  defp create_task(router, params) do
    SalixIM.Provider.call_api(router.salix_agent_id, "internal", "internal.task.create", %{
      "connect_id" => "internal",
      "params" => params
    })
  end

  defp list_tasks(project),
    do:
      Conversations.list_group_conversations(project.salix_group_id,
        kind: "agent_task",
        limit: 10
      )

  defp task_worker(project, conversation_id, task_agent) do
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               project.salix_group_id,
               conversation_id
             )

    assert %{} = worker = Enum.find(participants, &(&1["agent_id"] == task_agent))
    worker
  end

  defp connect_station(org, project, device_id, capabilities) do
    {:ok, _transport_id, record} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        %{
          "tenant_id" => org.salix_tenant_id,
          "group_id" => project.salix_group_id,
          "device_id" => device_id,
          "connector_id" => "connector-" <> device_id,
          "name" => "Mac Studio"
        },
        transport_id: "transport-" <> device_id
      )

    {:ok, _} =
      SalixEnv.Registry.update_meta(
        record["connector_run_id"],
        &Map.put(&1, "capabilities", capabilities)
      )

    :ok
  end

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end
end
