defmodule CommaWeb.StationsTest do
  @moduledoc """
  `CommaWeb.Stations` resolves the Group, requester and station from the tool
  ctx and calls the station gateway over HTTP (stubbed with `Req.Test`).
  """
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias CommaWeb.Stations
  alias SalixStore.Ids

  @station String.duplicate("cd", 32)
  @token "gateway-token-0123456789abcdef0123"

  defmodule Directory do
    @behaviour CommaWeb.Stations.Directory

    @impl true
    def list_group_stations(tenant_id, group_id) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:directory, tenant_id, group_id})
      {:ok, [%{"id" => String.upcase(String.duplicate("cd", 32)), "name" => "Build box"}]}
    end
  end

  defmodule TaskDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :station_task_test_pid),
        {:station_task_delivery, agent, payload}
      )

      {:ok, %{}}
    end
  end

  defmodule AppMembers do
    @moduledoc "A product that gives everyone its Group's chat app is available to the role `user`."
    @behaviour SalixStore.StationMembers

    @impl true
    def role(_tenant_id, _group_id, _user_id), do: :none
    @impl true
    def app_member_role(_tenant_id, _group_id), do: {:ok, "user"}
    @impl true
    def manager_role?(_role), do: false
    @impl true
    def read_only_role?(_role), do: false
    @impl true
    def workspace_name(_tenant_id, _group_id), do: :none
    @impl true
    def workspace_active?(_tenant_id, _group_id), do: :none
  end

  defmodule FakePlatform do
    @moduledoc "The Feishu and Lark open platforms: answers by path, and the requests it got."
    use Agent
    import Plug.Conn

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{routes: %{}, requests: []} end, name: __MODULE__)

    def route(path, status \\ 200, body),
      do: Agent.update(__MODULE__, &put_in(&1, [:routes, path], {status, body}))

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def init(opts), do: opts

    def call(conn, _opts) do
      Agent.update(__MODULE__, &%{&1 | requests: [conn.request_path | &1.requests]})

      {status, body} =
        Agent.get(__MODULE__, &Map.get(&1.routes, conn.request_path)) ||
          {404, %{"code" => 1_770_002, "msg" => "not found"}}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    previous =
      for key <- [:station_gateway, :station_directory],
          do: {key, SystemsRuntime.get_env(:comma_web, key)}

    # These tests exercise the gateway transport over a Req.Test stub.
    SystemsRuntime.put_env(:comma_web, :station_tools_transport, :gateway)
    on_exit(fn -> SystemsRuntime.delete_env(:comma_web, :station_tools_transport) end)

    SystemsRuntime.put_env(:comma_web, :station_gateway,
      url: "http://gateway.test",
      token: @token,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    SystemsRuntime.put_env(:comma_web, :station_directory, Directory)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:comma_web, key)
        {key, value} -> SystemsRuntime.put_env(:comma_web, key, value)
      end)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    owner = user!("owner")
    viewer = user!("viewer")

    workspace =
      Repo.insert!(
        Workspace.changeset(%Workspace{}, %{
          id: "wsp_station_#{SystemsRuntime.Proc.unique_integer([:positive])}",
          owner_user_id: owner["id"],
          salix_tenant_id: tenant,
          salix_group_id: group,
          group_generation: "test",
          salix_router_agent_id: Ids.new_agent_id(group),
          salix_worker_agent_id: Ids.new_agent_id(group),
          billing_owner_id: "station-test-#{tenant}",
          name: "Stations",
          status: "active"
        })
      )

    for {user, role} <- [{owner, "owner"}, {viewer, "viewer"}] do
      Repo.insert!(
        WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
          workspace_id: workspace.id,
          user_id: user["id"],
          role: role,
          status: "active"
        })
      )
    end

    agent = Ids.new_agent_id(group)

    {:ok,
     workspace: workspace,
     owner: owner,
     viewer: viewer,
     tenant: tenant,
     group: group,
     agent: agent}
  end

  defp user!(label) do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "#{label}-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    user
  end

  defp ctx(f, user) do
    %{
      agent_id: f.agent,
      session_id: "ses_station",
      tool_call_id: "call_station_1",
      tenant_id: f.tenant,
      group_id: f.group,
      trusted_origin: %{
        "provider" => "internal",
        "conversation_id" => "conv_station",
        "principal_ref" => %{"namespace" => "comma_user", "subject_id" => user["id"]}
      }
    }
  end

  defp stub_gateway(reply) do
    test = SystemsRuntime.Proc.self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      SystemsRuntime.Proc.send(
        test,
        {:gateway, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
         Jason.decode!(body)}
      )

      reply.(conn)
    end)
  end

  test "Workers discover Stations and execute through the member-authorized environment path",
       f do
    SystemsRuntime.put_env(:salix_agent, :stations, Stations)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :stations) end)

    stub_gateway(
      &Req.Test.json(&1, %{"ok" => true, "result" => %{"exit_code" => 0, "stdout" => "worker"}})
    )

    worker = Map.merge(ctx(f, f.owner), %{role: "worker", runtime_kind: :internal})
    disclosure = SalixAgent.ToolDisclosure.materialize_static("worker", :internal, worker)
    assert Enum.any?(disclosure["tools"], &(&1["name"] == "station.list" and &1["callable"]))

    assert %{"stations" => [%{"device_id" => device}]} =
             SalixAgent.Tools.Stations.list(%{}, worker) |> Jason.decode!()

    assert device == "station:" <> @station

    assert %{"stdout" => "worker"} =
             SalixAgent.Tools.Peers.exec(
               %{
                 "device_id" => device,
                 "environment" => "station",
                 "command" => "pwd",
                 "description" => "Check own directory"
               },
               worker
             )
             |> Jason.decode!()

    assert_received {:gateway, _, _, body}
    assert body["context"]["agent"] == f.agent
    assert body["context"]["conversation"] == "conv_station"
    assert body["context"]["user_id"] == f.owner["id"]
    refute Map.has_key?(body["args"], "cwd")
    anonymous = Map.delete(worker, :trusted_origin)

    assert {:error, :requester_required} =
             Stations.call(anonymous, @station, "exec", %{"command" => "id"})
  end

  test "a real Router-created Task reaches Stations only through its current human request", f do
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixAgent.TestSupport.stop_all_agents()
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    overrides = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_im, :conversation_placement, SalixIM.ConversationPlacement.LocalFleet},
      {:salix_im, :agent_delivery_mod, TaskDelivery},
      {:salix_im, :task_create_mod, Salix.Bindings.AgentConversations},
      {:comma_web, :station_task_test_pid, SystemsRuntime.Proc.self()}
    ]

    previous =
      for {app, key, _} <- overrides, do: {app, key, SystemsRuntime.get_env(app, key)}

    for {app, key, value} <- overrides, do: SystemsRuntime.put_env(app, key, value)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    router = f.workspace.salix_router_agent_id

    SalixAgent.TestSupport.create_control_agent!(router, %{
      "tenant_id" => f.tenant,
      "group_id" => f.group,
      "name" => "Router",
      "role" => "router"
    })

    {:ok, _} =
      SalixStore.CasRecord.update(
        SalixStore.Keys.ctl_group(f.group),
        &Map.put(&1, "router_agent_id", router)
      )

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(f.tenant, f.group, %{
        "name" => "Worker",
        "role" => "worker"
      })

    worker = worker["agent_id"]

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(f.group, %{
               "user_id" => f.owner["id"],
               "content" => "Use the Station to inspect my files",
               "client_request_id" => Ids.new_message_id()
             })

    settle_receive({:station_task_delivery, ^router, router_payload})
    router_ctx = task_context(f, router, router_payload)

    assert {:ok, task} =
             SalixIM.Provider.call_api(router, "internal", "internal.task.create", %{
               "connect_id" => "internal",
               "tool_context" => router_ctx,
               "params" => %{
                 "agent_id" => worker,
                 "content" => "Inspect files on the Station and report",
                 "runs_on" => %{"kind" => "default"}
               }
             })

    settle_receive({:station_task_delivery, ^worker, worker_payload})
    worker_ctx = task_context(f, worker, worker_payload)
    assert SalixAgent.IFC.principal(worker_ctx.trusted_origin) == nil

    stub_gateway(&Req.Test.json(&1, %{"ok" => true, "result" => %{"stdout" => "task"}}))

    assert {:ok, %{"stdout" => "task"}} =
             Stations.call(worker_ctx, @station, "exec", %{"command" => "pwd"})

    assert_received {:gateway, _, _, body}
    assert body["context"]["user_id"] == f.owner["id"]
    assert body["context"]["agent"] == worker
    assert body["context"]["conversation"] == task["conversation_id"]

    for invalid <- [
          %{worker_ctx | session_id: "another-session"},
          %{worker_ctx | source_message_ids: []},
          %{worker_ctx | agent_id: router}
        ] do
      assert {:error, :requester_required} =
               Stations.call(invalid, @station, "exec", %{"command" => "pwd"})
    end

    assert {:ok, _} =
             SalixIM.Provider.call_api(router, "internal", "internal.send_message", %{
               "connect_id" => "internal",
               "tool_context" => router_ctx,
               "params" => %{
                 "conversation_id" => task["conversation_id"],
                 "content" => [%{"type" => "text", "text" => "Continue"}]
               }
             })

    settle_receive({:station_task_delivery, ^worker, follow_up})

    assert {:error, :requester_required} =
             Stations.call(task_context(f, worker, follow_up), @station, "exec", %{
               "command" => "pwd"
             })

    assert {:ok, _} =
             SalixCluster.TaskSchedules.update_task_schedule(f.group, task["conversation_id"], %{
               "interval_minutes" => 5
             })

    assert {:error, :requester_required} =
             Stations.call(worker_ctx, @station, "exec", %{"command" => "pwd"})

    assert {:ok, _} =
             SalixCluster.TaskSchedules.update_task_schedule(
               f.group,
               task["conversation_id"],
               nil
             )

    Repo.delete_all(
      from(m in WorkspaceMembership,
        where: m.workspace_id == ^f.workspace.id and m.user_id == ^f.owner["id"]
      )
    )

    assert {:error, :requester_required} =
             Stations.call(worker_ctx, @station, "exec", %{"command" => "pwd"})

    refute_received {:gateway, _, _, _}
  end

  defp task_context(f, agent, payload) do
    origin = payload[:trusted_origin]

    %{
      agent_id: agent,
      tenant_id: f.tenant,
      group_id: f.group,
      session_id: payload[:session_id],
      trusted_origin: origin,
      source_message_id: origin["source_message_id"],
      source_message_ids: [origin["source_message_id"]]
    }
  end

  test "forwards an op with the requester context and the requester's email", f do
    stub_gateway(
      &Req.Test.json(&1, %{"ok" => true, "result" => %{"session" => "s1", "thread" => "t1"}})
    )

    args = %{"prompt" => "Ship it", "requester_email" => "spoofed@example.com"}

    assert Stations.call(ctx(f, f.owner), String.upcase(@station), "session.start", args) ==
             {:ok, %{"session" => "s1", "thread" => "t1"}}

    assert_received {:gateway, path, ["Bearer " <> @token], body}
    assert path == "/v1/stations/#{@station}/tools"
    assert body["op"] == "session.start"
    assert body["id"] == "call_station_1"
    assert body["args"] == %{"prompt" => "Ship it", "requester_email" => f.owner["email"]}

    assert body["context"] == %{
             # The Group id is the workspace the station holds.
             "workspace" => f.group,
             "user_id" => f.owner["id"],
             "user_email" => f.owner["email"],
             "agent" => f.agent,
             "conversation" => "conv_station"
           }
  end

  test "the Group's roster in Salix decides the offer, whichever product owns the Group", f do
    prior = SystemsRuntime.get_env(:salix_store, :stations)
    SystemsRuntime.put_env(:salix_store, :stations, kek: String.duplicate("k", 32))
    SalixStore.Repo.delete_all(SalixStore.Stations.SigningKeys.Key)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :stations, prior || []) end)
    SystemsRuntime.put_env(:comma_web, :station_directory, CommaWeb.Stations.GroupDirectory)

    # A Group that is no Comma Workspace.
    tenant = SalixAgent.TestSupport.new_tenant_id()
    ctx = %{tenant_id: tenant, group_id: Ids.new_group_id(tenant)}
    refute Stations.offered?(ctx)
    refute Stations.offered?(%{tenant_id: f.tenant, group_id: f.group})

    {public, _seed} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    station = Base.encode16(public, case: :lower)

    assert {:ok, %{"workspace" => workspace}} =
             Comma.Stations.admit_cloud_station(
               ctx.tenant_id,
               ctx.group_id,
               station,
               nil,
               nil,
               "https://salix.test"
             )

    assert workspace == ctx.group_id
    assert Stations.offered?(ctx)
    # The station is in that Group only.
    refute Stations.offered?(%{ctx | tenant_id: f.tenant})
    refute Stations.offered?(%{tenant_id: f.tenant, group_id: f.group})
  end

  test "refuses stations outside the Group and turns without a member", f do
    other = String.duplicate("ef", 32)

    assert Stations.call(ctx(f, f.owner), other, "exec", %{"command" => "id"}) ==
             {:error, :station_not_found}

    agent_turn = put_in(ctx(f, f.owner), [:trusted_origin, "principal_ref"], nil)

    assert Stations.call(agent_turn, @station, "exec", %{"command" => "id"}) ==
             {:error, :requester_required}

    stranger = user!("stranger")

    assert Stations.call(ctx(f, stranger), @station, "exec", %{"command" => "id"}) ==
             {:error, :requester_required}

    # The station tool tells the model to go on without a machine: nobody in
    # the chat can make a non-member's turn a member's.
    SystemsRuntime.put_env(:salix_agent, :stations, Stations)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :stations) end)

    unlinked_chat_user =
      put_in(ctx(f, f.owner), [:trusted_origin, "principal_ref"], %{
        "connect_id" => "con_feishu",
        "subject_id" => "ou_unlinked"
      })

    for turn <- [ctx(f, stranger), unlinked_chat_user] do
      error = assert_raise RuntimeError, fn -> SalixAgent.Tools.Stations.list(%{}, turn) end
      assert error.message =~ "unavailable for this turn"
      assert error.message =~ "without a Station"
    end

    refute_received {:gateway, _, _, _}
  end

  test "a Slack user is the member their Provider User Link names", f do
    stub_gateway(&Req.Test.json(&1, %{"ok" => true, "result" => %{"entries" => []}}))

    slack =
      put_in(ctx(f, f.owner), [:trusted_origin, "principal_ref"], %{
        "connect_id" => "con_slack",
        "subject_id" => "U123"
      })

    # Not linked yet.
    assert Stations.call(slack, @station, "fs.list", %{"path" => "/"}) ==
             {:error, :requester_required}

    {:ok, pending} = Comma.ProviderUserLinks.start("slack", "con_slack", "U123", "Sam")
    {:ok, _link} = Comma.ProviderUserLinks.accept(f.owner, %{}, pending["token"])

    assert {:ok, %{"entries" => []}} =
             Stations.call(slack, @station, "fs.list", %{"path" => "/"})

    assert_received {:gateway, _, _, %{"context" => %{"user_id" => owner_id}}}
    assert owner_id == f.owner["id"]

    # The linked member's role still holds: a viewer may only read.
    {:ok, pending} = Comma.ProviderUserLinks.start("slack", "con_slack", "U123", "Sam")
    {:ok, _link} = Comma.ProviderUserLinks.accept(f.viewer, %{}, pending["token"])

    assert Stations.call(slack, @station, "exec", %{"command" => "id"}) == {:error, :forbidden}
  end

  test "a viewer may only read", f do
    stub_gateway(&Req.Test.json(&1, %{"ok" => true, "result" => %{"entries" => []}}))

    assert Stations.call(ctx(f, f.viewer), @station, "exec", %{"command" => "id"}) ==
             {:error, :forbidden}

    assert {:ok, %{"entries" => []}} =
             Stations.call(ctx(f, f.viewer), @station, "fs.list", %{"path" => "/"})
  end

  # A Project's chat app, its stations' Group and the open platform that
  # answers for the app. The Group's products are Comma's alone until
  # `members!/1`.
  defp chat_app!(provider) do
    previous =
      for {app, key} <- [
            {:salix_store, :station_members},
            {:salix_store, :s3_backend},
            {:salix_im, :feishu_api_base_url},
            {:salix_im, :lark_api_base_url}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(FakePlatform)

    bandit =
      start_supervised!(
        {Bandit, plug: FakePlatform, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    reset_platform_caches()
    members!([Comma.Stations.Members])

    on_exit(fn ->
      reset_platform_caches()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    FakePlatform.route("/open-apis/auth/v3/tenant_access_token/internal", %{
      "code" => 0,
      "tenant_access_token" => "t-app",
      "expire" => 7200
    })

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    connect = Ids.new_connect_id()

    {:ok, _} =
      SalixStore.CasRecord.create(SalixStore.Keys.ctl_im_connect(group, connect), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "connect_id" => connect,
        "provider" => provider,
        "status" => "connected",
        "app_id" => "cli_project",
        "app_secret" => "secret"
      })

    %{tenant: tenant, group: group, connect: connect, provider: provider}
  end

  defp reset_platform_caches do
    SalixIM.Provider.Feishu.API.reset_token_cache()
    SalixIM.Provider.Lark.API.reset_token_cache()
    SalixIM.Provider.Feishu.AppAvailability.reset_cache()
    SalixIM.Provider.Lark.AppAvailability.reset_cache()
  end

  # `SalixStore.StationMembers.register/1` only adds; a test sets the whole list.
  defp members!(modules), do: SystemsRuntime.put_env(:salix_store, :station_members, modules)

  defp sender(f, app, open_id) do
    %{ctx(f, f.owner) | tenant_id: app.tenant, group_id: app.group}
    |> put_in([:trusted_origin, "principal_ref"], %{
      "connect_id" => app.connect,
      "subject_id" => open_id
    })
  end

  defp visible(items) do
    FakePlatform.route(
      "/open-apis/application/v6/applications/cli_project/visibility/check_white_black_list",
      %{"code" => 0, "data" => %{"user_visibility_list" => items}}
    )
  end

  defp person(open_id, user),
    do:
      FakePlatform.route("/open-apis/contact/v3/users/#{open_id}", %{
        "code" => 0,
        "data" => %{"user" => user}
      })

  test "a Feishu user the Project's app is available to uses its stations as their email", f do
    app = chat_app!("feishu")
    ann = sender(f, app, "ou_ann")

    # A product that needs an account gives a chat sender without one no role,
    # and the app is not asked.
    assert Stations.call(ann, @station, "exec", %{"command" => "id"}) ==
             {:error, :requester_required}

    assert FakePlatform.requests() == []

    members!([Comma.Stations.Members, AppMembers])
    visible([%{"user_id" => "ou_ann", "in_white_list" => true, "in_black_list" => false}])
    person("ou_ann", %{"name" => "Ann", "email" => "ann@acme.test"})
    stub_gateway(&Req.Test.json(&1, %{"ok" => true, "result" => %{"stdout" => "ann"}}))

    assert {:ok, [%{"id" => @station}]} = Stations.list(ann)
    assert {:ok, %{email: "ann@acme.test", role: "user"}} = Stations.member(ann)

    assert {:ok, %{"stdout" => "ann"}} =
             Stations.call(ann, @station, "exec", %{"command" => "id"})

    assert_received {:gateway, _, _, body}
    assert body["context"]["user_email"] == "ann@acme.test"
    assert body["context"]["user_id"] == "feishu:#{app.connect}:ou_ann"

    assert {:ok, _} =
             Stations.call(ann, @station, "session.start", %{
               "prompt" => "Ship it",
               "requester_email" => "spoofed@example.com"
             })

    assert_received {:gateway, _, _, %{"args" => %{"requester_email" => "ann@acme.test"}}}

    # An administrator takes Ann out of the availability range, or blocks her:
    # the next call is refused.
    for item <- [%{"in_white_list" => false}, %{"in_white_list" => true, "in_black_list" => true}] do
      visible([Map.put(item, "user_id", "ou_ann")])

      assert Stations.call(ann, @station, "exec", %{"command" => "id"}) ==
               {:error, {:requester_refused, :not_available}}
    end

    # Someone without an organization email cannot be matched to a person.
    visible([%{"user_id" => "ou_bo", "in_white_list" => true}])
    person("ou_bo", %{"name" => "Bo"})

    FakePlatform.route("/open-apis/application/v6/scopes", %{
      "code" => 0,
      "data" => %{
        "scopes" => [
          %{
            "scope_name" => "contact:user.email:readonly",
            "grant_status" => 1,
            "scope_type" => "tenant"
          }
        ]
      }
    })

    assert Stations.call(sender(f, app, "ou_bo"), @station, "exec", %{"command" => "id"}) ==
             {:error, {:requester_refused, :no_email}}

    # An app without the permission cannot say, so nobody passes.
    FakePlatform.route(
      "/open-apis/application/v6/applications/cli_project/visibility/check_white_black_list",
      400,
      %{
        "code" => 99_991_672,
        "msg" =>
          "Access denied. One of the following scopes is required: [application:application:self_manage]."
      }
    )

    assert Stations.list(ann) ==
             {:error,
              {:requester_refused, {:missing_scope, "application:application:self_manage"}}}

    refute_received {:gateway, _, _, _}
  end

  test "a Lark user the Project's app is available to uses its stations as their email", f do
    app = chat_app!("lark")
    members!([Comma.Stations.Members, AppMembers])
    visible([%{"user_id" => "ou_ann", "in_white_list" => true}])
    person("ou_ann", %{"name" => "Ann", "enterprise_email" => "ann@acme.test"})
    stub_gateway(&Req.Test.json(&1, %{"ok" => true, "result" => %{"entries" => []}}))

    assert {:ok, %{"entries" => []}} =
             Stations.call(sender(f, app, "ou_ann"), @station, "fs.list", %{"path" => "/"})

    assert_received {:gateway, _, _, body}
    assert body["context"]["user_email"] == "ann@acme.test"
    assert body["context"]["user_id"] == "lark:#{app.connect}:ou_ann"
  end
end
