defmodule SalixIM.MiniAppTaskTest do
  @moduledoc """
  A Mini App build is a coding Task with `mini_app {app_id}`: placed only on a
  sandbox with the app's own repository (`SalixIM.TaskPlacement`), kept on the
  Task, and named in its station's start. The Router makes the app with
  `internal.apps.create`. A deploy's Message carries one `mini_app` block whose
  summary is its text. The app owner (`SalixIM.MiniApps`) and the product's
  place checks are fakes; the Task is real.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixIM.{ConversationMessage, ConversationServer, Conversations, TaskConversationInput}
  alias SalixIM.TaskPlacement
  alias SalixStore.{Ids, Keys}

  @app_id "6f1c2a0e-6c43-4a8e-9a55-2b8f0f1d3c11"

  defmodule Apps do
    @moduledoc "The Mini App owner: one app, `ann/comma-app-x7k2q9`; what it was asked to create."
    @behaviour SalixIM.MiniApps

    @impl true
    def create(scope, params) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :mini_app_test_pid),
        {:create, scope, params}
      )

      case params["name"] do
        "No GitHub" ->
          {:error, :github_not_connected}

        _ ->
          {:ok,
           %{
             "app_id" => "app-new",
             "repo" => %{"owner" => "ann", "name" => "comma-app-new"},
             "url" => "https://app.comma.test/#/apps/ws-1/app-new/run"
           }}
      end
    end

    @impl true
    def list(_group_id), do: {:ok, %{"apps" => [app()], "has_more" => false}}

    @impl true
    def get(_group_id, "6f1c2a0e-6c43-4a8e-9a55-2b8f0f1d3c11"), do: {:ok, app()}
    def get(_group_id, _app_id), do: {:error, :not_found}

    def app,
      do: %{
        "app_id" => "6f1c2a0e-6c43-4a8e-9a55-2b8f0f1d3c11",
        "name" => "Habits",
        "repo" => %{"owner" => "ann", "name" => "comma-app-x7k2q9"},
        "url" => "https://app.comma.test/#/apps/ws-1/6f1c2a0e-6c43-4a8e-9a55-2b8f0f1d3c11/run",
        "latest_version" => 1,
        "live_version" => nil
      }

    @impl true
    def manage(_scope, _action, _params), do: {:error, :unused}

    @impl true
    def repo(_group_id, "6f1c2a0e-6c43-4a8e-9a55-2b8f0f1d3c11"),
      do: {:ok, %{"owner" => "ann", "name" => "comma-app-x7k2q9"}}

    def repo(_group_id, _app_id), do: {:error, :not_found}
  end

  defmodule Stations do
    @moduledoc "The stations (`SalixIM.Ports.TaskStations`): the sandbox reservations they got."
    @behaviour SalixIM.Ports.TaskStations

    @impl true
    def invite(_invitation), do: {:ok, "ember:c-1"}
    @impl true
    def joined(_row), do: :ok
    @impl true
    def moved(_move), do: :ok
    @impl true
    def sessions(_group_id, _conversation_id), do: {:ok, %{}}

    @impl true
    def sandbox(reservation) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :mini_app_test_pid),
        {:sandbox, reservation}
      )

      :ok
    end

    @impl true
    def task_status(_group_id, _conversation_id, _status), do: :ok
    @impl true
    def appended(_group_id, _conversation_id), do: :ok
    @impl true
    def standing(_group_id, _conversation_id), do: :not_station
    @impl true
    def session_status(_group_id, _conversation_id), do: :unknown
  end

  defmodule Product do
    @moduledoc "The product's checks of a place and a model: each taken as asked."
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(_group_id, _delegator, _target, _attrs), do: {:error, :unused}
    @impl true
    def runs_on(_scope, request), do: {:ok, request}
    @impl true
    def session_model(_scope, choice), do: {:ok, choice}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    keys = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, SalixAgent.LLM.Mock},
      {:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery},
      {:salix_im, :session_activity_mod, SalixIM.TestSupport.SessionActivity},
      {:salix_im, :task_stations_mod, Stations},
      {:salix_im, :task_create_mod, Product},
      {:salix_im, :mini_apps, Apps},
      {:salix_im, :mini_app_test_pid, SystemsRuntime.Proc.self()}
    ]

    previous =
      Enum.map(keys, fn {app, key, _value} -> {app, key, SystemsRuntime.get_env(app, key)} end)

    Enum.each(keys, fn {app, key, value} -> SystemsRuntime.put_env(app, key, value) end)

    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)

    on_exit(fn ->
      try do
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        Enum.each(previous, fn
          {app, key, nil} -> SystemsRuntime.delete_env(app, key)
          {app, key, value} -> SystemsRuntime.put_env(app, key, value)
        end)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Apps"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    {:ok,
     tenant_id: tenant_id,
     group_id: group_id,
     router_id: router["agent_id"],
     worker_id: worker["agent_id"]}
  end

  defp resolve(ctx, params),
    do:
      TaskPlacement.resolve(
        %{tenant_id: ctx.tenant_id, group_id: ctx.group_id},
        ctx.worker_id,
        params,
        false
      )

  defp build(runs_on, repo, app_id \\ @app_id),
    do: %{"runs_on" => runs_on, "repo" => repo, "mini_app" => %{"app_id" => app_id}}

  describe "placement" do
    test "a build runs on a sandbox with the app's repository, named in any case", ctx do
      assert {:ok, placement} =
               resolve(
                 ctx,
                 build(%{"kind" => "sandbox"}, %{
                   "owner" => "Ann",
                   "name" => "Comma-App-X7K2Q9",
                   "base_ref" => "main"
                 })
               )

      assert placement.mini_app == %{"app_id" => @app_id}
      assert placement.repo["name"] == "Comma-App-X7K2Q9"

      attrs = TaskPlacement.placement_attrs(%{"content" => "Build it"}, placement)
      assert attrs["mini_app"] == %{"app_id" => @app_id}

      # A Task without mini_app has none.
      assert {:ok, %{mini_app: nil}} =
               resolve(ctx, %{
                 "runs_on" => %{"kind" => "sandbox"},
                 "repo" => %{"owner" => "acme", "name" => "api"}
               })
    end

    test "a build elsewhere than a sandbox, on another repository, or of an unknown app is refused",
         ctx do
      app_repo = %{"owner" => "ann", "name" => "comma-app-x7k2q9"}

      for {params, reason} <- [
            {Map.delete(build(nil, nil), "repo") |> Map.delete("runs_on"),
             :mini_app_requires_sandbox},
            {Map.delete(build(%{"kind" => "cloud_vm"}, nil), "repo"), :mini_app_requires_sandbox},
            {build(%{"kind" => "sandbox"}, %{"owner" => "ann", "name" => "other"}),
             :mini_app_repo_mismatch},
            {build(%{"kind" => "sandbox"}, nil), :mini_app_repo_mismatch},
            {build(%{"kind" => "sandbox"}, app_repo, "9d0b1e2f-0000-4000-8000-000000000000"),
             :mini_app_not_found},
            {%{build(%{"kind" => "sandbox"}, app_repo) | "mini_app" => %{"id" => @app_id}},
             :mini_app_not_found}
          ] do
        assert {:error, {:runs_on, ^reason, :requested} = refusal} = resolve(ctx, params),
               inspect(params)

        assert TaskPlacement.message(refusal) =~ "The Task was not made."
      end

      SystemsRuntime.delete_env(:salix_im, :mini_apps)

      assert {:error, {:runs_on, :mini_apps_unavailable, :requested}} =
               resolve(ctx, build(%{"kind" => "sandbox"}, app_repo))
    end
  end

  test "a build Task keeps its app next to its repository, and its sandbox's station start names it",
       ctx do
    command = "Build a habit tracker."
    repo = %{"owner" => "ann", "name" => "comma-app-x7k2q9", "base_ref" => "main"}

    attrs = %{
      "content" => command,
      "client_request_id" => "build",
      "schedule" => %{"schedule_id" => nil, "command" => command},
      "runs_on" => %{"kind" => "sandbox"},
      "repo" => repo,
      "mini_app" => %{"app_id" => @app_id},
      "initial_message_attrs" => %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => ctx.router_id,
        "content" => command,
        "metadata" => %{"message_type" => "task_command"},
        "client_request_id" => "delegate-build"
      }
    }

    assert {:ok, task} =
             ConversationServer.reserve_task_conversation_id(
               ctx.group_id,
               ctx.router_id,
               ctx.worker_id,
               attrs
             )

    assert {:ok, %{"conversation_id" => ^task}} =
             TaskConversationInput.create_with_id(
               ctx.group_id,
               task,
               ctx.router_id,
               ctx.worker_id,
               attrs
             )

    settle()

    assert {:ok, conversation} = Conversations.get_group_conversation(ctx.group_id, task)
    assert conversation["mini_app"] == %{"app_id" => @app_id}
    assert conversation["repo"]["name"] == "comma-app-x7k2q9"

    assert_received {:sandbox, %{start: start}}
    assert start["mini_app"] == %{"app_id" => @app_id}
    assert start["repo"]["name"] == "comma-app-x7k2q9"

    # A Message of the Worker that shows a deployed Version.
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(ctx.group_id, task)

    worker = Enum.find(participants, &(&1["agent_id"] == ctx.worker_id))
    summary = "Habit tracker — preview version 1"

    assert {:ok, %{"seq" => _seq}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group_id,
               task,
               ctx.worker_id,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => ctx.worker_id,
                 "participant_id" => worker["participant_id"],
                 "content" => [
                   %{"type" => "text", "text" => summary},
                   mini_app_block(summary)
                 ],
                 "client_request_id" => "deploy-1"
               }
             )
  end

  defp mini_app_block(summary),
    do: %{
      "type" => "mini_app",
      "version" => 1,
      "app_id" => @app_id,
      "app_version" => 1,
      "name" => "Habit tracker",
      "summary" => summary
    }

  test "a mini_app block is one per Message, well formed, with its summary as the Message's text" do
    summary = "Habit tracker — preview version 3"
    block = %{mini_app_block(summary) | "app_version" => 3}
    text = %{"type" => "text", "text" => summary}

    assert {:ok, _content} = ConversationMessage.validate_content("message", [text, block])

    for content <- [
          # The summary is not the Message's text.
          [block],
          [%{"type" => "text", "text" => "Look"}, block],
          # Two cards.
          [text, block, block],
          # A malformed card.
          [text, %{block | "version" => 2}],
          [text, %{block | "app_version" => 0}],
          [text, %{block | "name" => ""}],
          [text, Map.put(block, "url", "https://example.com")],
          [text, Map.delete(block, "app_id")]
        ] do
      assert {:error, {:bad_request, _}} =
               ConversationMessage.validate_content("message", content),
             inspect(content)
    end

    long = String.duplicate("x", 4001)

    assert {:error, {:bad_request, _}} =
             ConversationMessage.validate_content("message", [
               %{"type" => "text", "text" => long},
               mini_app_block(long)
             ])
  end

  describe "internal.apps.create" do
    defp call(ctx, role, params) do
      SalixIM.Provider.Internal.call(
        %{
          agent: %{"role" => role},
          tenant_id: ctx.tenant_id,
          group_id: ctx.group_id,
          agent_id: ctx.router_id
        },
        "internal.apps.create",
        params
      )
    end

    test "a Router makes an app through its owner, and gets its id, repository and URL", ctx do
      assert {:ok,
              %{
                "app_id" => "app-new",
                "repo" => %{"owner" => "ann", "name" => "comma-app-new"},
                "url" => "https://app.comma.test/#/apps/ws-1/app-new/run"
              }} =
               call(ctx, "router", %{
                 "name" => " Habit tracker ",
                 "description" => "Daily habits",
                 "repo" => %{"owner" => "ann", "name" => "habits"}
               })

      group_id = ctx.group_id

      assert_received {:create, %{group_id: ^group_id},
                       %{
                         "name" => "Habit tracker",
                         "description" => "Daily habits",
                         "repo" => %{"owner" => "ann", "name" => "habits"}
                       }}
    end

    test "without GitHub, the Router is told what the user does; a Worker may not make apps",
         ctx do
      assert {:error, message} = call(ctx, "router", %{"name" => "No GitHub"})

      # The Router asks for the same GitHub binding Settings > Plugins makes, and the user answers a card.
      assert message =~ "oauth.request_authorization"
      assert message =~ ~s("provider":"github","alias":"github")
      assert message =~ ~s("scopes":["repo","read:org","read:user","user:email"])
      assert_received {:create, _scope, %{"name" => "No GitHub"}}

      assert {:error, "operation is not authorized for this agent role"} =
               call(ctx, "worker", %{"name" => "Habit tracker"})

      for bad <- [%{}, %{"name" => "x", "icon" => "y"}, %{"name" => "x", "repo" => "ann/x"}],
          do: assert({:error, _} = call(ctx, "router", bad))

      refute_received {:create, _, _}
    end
  end

  describe "internal.apps.list and internal.apps.get" do
    defp read(ctx, role, api, params) do
      SalixIM.Provider.Internal.call(
        %{agent: %{"role" => role}, tenant_id: ctx.tenant_id, group_id: ctx.group_id},
        api,
        params
      )
    end

    test "a Router finds an app again with its URL; a Worker may not", ctx do
      app = Apps.app()

      assert {:ok, %{"apps" => [^app], "has_more" => false}} =
               read(ctx, "router", "internal.apps.list", %{})

      assert {:ok, ^app} = read(ctx, "router", "internal.apps.get", %{"app_id" => @app_id})

      assert {:error, message} = read(ctx, "router", "internal.apps.get", %{"app_id" => "other"})
      assert message =~ "internal.apps.list"
      assert {:error, _} = read(ctx, "router", "internal.apps.get", %{})
      assert {:error, _} = read(ctx, "router", "internal.apps.list", %{"limit" => 5})

      for api <- ["internal.apps.list", "internal.apps.get"],
          do:
            assert(
              {:error, "operation is not authorized for this agent role"} =
                read(ctx, "worker", api, %{"app_id" => @app_id})
            )
    end
  end
end
