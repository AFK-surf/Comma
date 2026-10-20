defmodule Comma.NativePushTest.Salix do
  require SystemsRuntime.Proc

  def resolve_workspace_scope(workspace) do
    if router = Process.get(:native_push_router) do
      {:ok, Map.put(workspace, "router_conversation_id", router["conversation_id"])}
    else
      {:ok, workspace}
    end
  end

  def list_group_conversation_message_page(workspace, id, opts) do
    case Process.get(:native_push_router_error) do
      nil -> router_page(workspace, id, opts)
      error -> {:error, error}
    end
  end

  defp router_page(_workspace, _id, opts) do
    messages = Process.get(:native_push_router)["messages"]
    head = Enum.reduce(messages, nil, &min(&1["seq"], &2 || &1["seq"])) || 1
    tail = Enum.reduce(messages, 0, &max(&1["seq"], &2))
    limit = Keyword.fetch!(opts, :limit)

    page =
      cond do
        after_seq = opts[:after] ->
          Enum.filter(messages, &(&1["seq"] > after_seq)) |> Enum.take(limit)

        around = opts[:around] ->
          Enum.filter(messages, &(&1["seq"] >= around)) |> Enum.take(limit)

        true ->
          Enum.take(messages, -limit)
      end

    {:ok,
     %{
       "messages" => page,
       "bounds" => %{"head_seq" => head, "tail_seq" => tail},
       "covered" => %{"last_seq" => if(page == [], do: tail, else: List.last(page)["seq"])},
       "has_newer" => page != [] and List.last(page)["seq"] < tail
     }}
  end

  def get_group_conversation_with_messages(_workspace, _id, opts) do
    messages = Process.get(:native_push_router)["messages"]
    through = Enum.find(messages, &(&1["message_id"] == opts[:through_id]))

    {:ok,
     %{
       "messages" =>
         Enum.filter(messages, &(&1["seq"] <= through["seq"])) |> Enum.take(-opts[:limit])
     }}
  end

  def list_group_activity_tasks(_workspace) do
    if callback = Process.get(:native_push_read_callback), do: callback.()

    if error = Process.get(:native_push_projection_error) do
      {:error, error}
    else
      tasks =
        Process.get(:native_push_tasks, %{})
        |> Map.values()
        |> Enum.filter(&(&1["status"] in ["active", "in_progress", "ready_for_review"]))
        |> Enum.sort_by(&{-&1["updated_at"], &1["conversation_id"]})
        |> Enum.take(2)

      {:ok, %{"data" => tasks}}
    end
  end

  def get_group_conversation(_workspace, id) do
    if callback = Process.get(:native_push_read_callback), do: callback.()

    router = Process.get(:native_push_router)

    task =
      if router && router["conversation_id"] == id,
        do: %{
          "conversation_id" => id,
          "kind" => "user_chat",
          "status" => "active",
          "metadata" => %{}
        },
        else: Process.get(:native_push_tasks, %{})[id]

    case task do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end
end

defmodule Comma.NativePushTest do
  require SystemsRuntime.Proc

  use Comma.DataCase, async: false
  # Activity updates are ordered by epoch second, and an Activity lives for
  # hours: the tests run on a clock they drive, so a wait for the next second
  # or the end of a lifetime moves the clock instead of taking real time.
  use SystemsClock.Test, scope: ["Elixir.Comma"]
  alias Comma.{Accounts, Notifications}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Notifications.{APNs, Target}
  alias SalixStore.Ids

  setup do
    prior_apns = SystemsRuntime.get_env(:comma_core, :apns)
    prior_client = SystemsRuntime.get_env(:comma_core, :salix_client)
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = JOSE.JWK.to_pem(key)

    SystemsRuntime.put_env(:comma_core, :apns,
      profiles: %{
        "sandbox" => [
          team_id: "TESTTEAM",
          key_id: "TESTKEY",
          private_key: pem,
          allowed_bundle_ids: ["surf.comma.ios", "surf.comma.ios.dev"]
        ]
      },
      plug: {Req.Test, __MODULE__}
    )

    SystemsRuntime.put_env(:comma_core, :salix_client, Comma.NativePushTest.Salix)

    unless SystemsRuntime.Proc.whereis(APNs.ProviderToken),
      do: start_supervised!(APNs.ProviderToken)

    unless Oban.whereis(Comma.Oban) do
      start_supervised!(
        {Oban, name: Comma.Oban, repo: Repo, testing: :manual, queues: false, plugins: false}
      )
    end

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "push-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_native_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "native-push-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "native-push-test",
        name: "Native push",
        status: "active"
      })

    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    id = Ids.new_conversation_id()

    task = %{
      "conversation_id" => id,
      "kind" => "agent_task",
      "title" => "A private task title",
      "status" => "active",
      "updated_at" => SystemsClock.system_time(:millisecond),
      "created_at" => SystemsClock.system_time(:millisecond) - 1_000,
      "metadata" => %{"origin" => %{"provider" => "comma", "client_platform" => "ios"}}
    }

    put_task(task)

    attrs = %{
      "token" => String.duplicate("a", 64),
      "environment" => "sandbox",
      "bundle_id" => "surf.comma.ios.dev",
      "workspace_id" => workspace.id,
      "group_id" => group,
      "activity_schema" => "tasks_v1",
      "activity_id" => "local-activity"
    }

    on_exit(fn ->
      restore(:apns, prior_apns)
      restore(:salix_client, prior_client)
    end)

    %{user: user, session: session, workspace: workspace, task: task, attrs: attrs, key: key}
  end

  test "registering requires the current Group owner and unrestricted Auth Session", ctx do
    {:ok, other} =
      Accounts.create_user(%{
        "email" => "other-push-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, other_session} = Accounts.create_session(other["id"])

    assert {:error, :not_found} =
             Notifications.register(other, other_session, "live_activity", ctx.attrs)

    assert {:error, :forbidden} =
             Notifications.register(
               ctx.user,
               Map.put(ctx.session, "restricted", true),
               "device",
               ctx.attrs
             )

    assert {:error, :invalid_push_registration} =
             Notifications.register(
               ctx.user,
               ctx.session,
               "live_activity",
               Map.put(ctx.attrs, "task_id", Ids.new_conversation_id())
             )

    assert Repo.aggregate(Target, :count) == 0
  end

  test "registration ID collisions cannot insert or replace another Session's address", ctx do
    id = SystemsRuntime.Proc.uuid()
    attrs = Map.put(ctx.attrs, "registration_id", id)

    assert {:ok, %{"id" => ^id}} =
             Notifications.register(ctx.user, ctx.session, "live_activity", attrs)

    {:ok, other} = Accounts.create_session(ctx.user["id"])

    assert {:error, :invalid_push_registration} =
             Notifications.register(ctx.user, other, "live_activity", attrs)

    assert Repo.get!(Target, id).auth_session_id == ctx.session["id"]
    {:ok, second} = Notifications.register(ctx.user, other, "live_activity", ctx.attrs)

    assert {:error, :invalid_push_registration} =
             Notifications.register(ctx.user, other, "live_activity", attrs)

    assert Repo.get!(Target, id).token == ctx.attrs["token"]
    assert Repo.get!(Target, second["id"]).auth_session_id == other["id"]
    assert Repo.aggregate(Target, :count) == 2

    assert {:error, :invalid_push_registration} =
             Notifications.register(
               ctx.user,
               ctx.session,
               "live_activity",
               Map.put(ctx.attrs, "registration_id", "not-a-uuid")
             )

    assert Repo.get!(Target, id)
  end

  test "APNs request uses HTTP topic, token auth, server ordering time and public content state",
       ctx do
    owner = SystemsRuntime.Proc.self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      SystemsRuntime.Proc.send(owner, {:request, conn, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    {:ok, registration} =
      Notifications.register(ctx.user, ctx.session, "live_activity", ctx.attrs)

    registered_at = Repo.get!(Target, registration["id"]).activity_started_at
    assert :delivered = deliver_activity(registration["id"])
    assert_receive {:request, conn, %{"aps" => aps}}
    assert conn.host == "api.sandbox.push.apple.com"
    assert conn.request_path == "/3/device/" <> ctx.attrs["token"]

    assert Plug.Conn.get_req_header(conn, "apns-topic") == [
             "surf.comma.ios.dev.push-type.liveactivity"
           ]

    assert Plug.Conn.get_req_header(conn, "apns-push-type") == ["liveactivity"]
    assert Plug.Conn.get_req_header(conn, "apns-priority") == ["5"]
    ["bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")

    assert {true, %JOSE.JWT{fields: %{"iss" => "TESTTEAM", "iat" => issued}}, _} =
             JOSE.JWT.verify_strict(JOSE.JWK.to_public(ctx.key), ["ES256"], jwt)

    assert issued <= SystemsClock.system_time(:second)
    assert aps["event"] == "update"
    assert aps["timestamp"] > DateTime.to_unix(registered_at)
    assert [%{"id" => id, "title" => title}] = aps["content-state"]["tasks"]
    assert id == ctx.task["conversation_id"]
    assert title == ctx.task["title"]
    assert aps["content-state"]["updatedAtEpochSeconds"] == div(ctx.task["updated_at"], 1_000)
    assert aps["stale-date"] == aps["timestamp"] + 120
    refute inspect(aps) =~ ctx.session["token"]
    assert :current = deliver_activity(registration["id"])
    refute_received {:request, _, _}
  end

  test "revocation stops exact-Task delivery before touching APNs", ctx do
    Req.Test.stub(__MODULE__, fn _ -> flunk("revoked sessions must not send a push") end)

    {:ok, registration} =
      Notifications.register(ctx.user, ctx.session, "live_activity", ctx.attrs)

    assert :ok = Accounts.revoke_session_token(ctx.session["token"])
    assert :obsolete = deliver_activity(registration["id"])
    assert Repo.get(Target, registration["id"]) == nil
  end

  test "one completed item promotes the next candidate; only an empty Group ends", ctx do
    owner = SystemsRuntime.Proc.self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      SystemsRuntime.Proc.send(owner, {:activity, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    second =
      Map.merge(ctx.task, %{
        "conversation_id" => Ids.new_conversation_id(),
        "status" => "ready_for_review",
        "updated_at" => ctx.task["updated_at"] - 1000
      })

    third =
      Map.merge(ctx.task, %{
        "conversation_id" => Ids.new_conversation_id(),
        "updated_at" => ctx.task["updated_at"] - 2000
      })

    put_task(second)
    put_task(third)

    {:ok, registration} =
      Notifications.register(ctx.user, ctx.session, "live_activity", ctx.attrs)

    assert :delivered = deliver_activity(registration["id"])
    assert_receive {:activity, %{"aps" => %{"event" => "update", "content-state" => first}}}

    assert Enum.map(first["tasks"], & &1["id"]) == [
             ctx.task["conversation_id"],
             second["conversation_id"]
           ]

    put_task(%{ctx.task | "status" => "completed"})
    assert :delivered = deliver_activity(registration["id"])
    assert_receive {:activity, %{"aps" => %{"event" => "update", "content-state" => next}}}

    assert Enum.map(next["tasks"], & &1["id"]) == [
             second["conversation_id"],
             third["conversation_id"]
           ]

    # The aggregate timestamp may decrease when its newest item leaves.
    assert next["updatedAtEpochSeconds"] < first["updatedAtEpochSeconds"]
    put_task(%{second | "status" => "completed"})
    put_task(%{third | "status" => "cancelled"})
    assert :obsolete = deliver_activity(registration["id"])
    assert_receive {:activity, %{"aps" => aps}}
    assert aps["event"] == "end"
    assert aps["content-state"]["tasks"] == []
    assert aps["dismissal-date"] == aps["timestamp"]
    assert Repo.get(Target, registration["id"]) == nil
  end

  test "automatic start includes existing desktop and provider tasks with legacy Session metadata",
       ctx do
    owner = SystemsRuntime.Proc.self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      SystemsRuntime.Proc.send(owner, {:started, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    put_task(put_in(ctx.task, ["metadata", "origin"], %{"provider" => "wechat"}))

    older =
      Map.merge(ctx.task, %{
        "conversation_id" => Ids.new_conversation_id(),
        "status" => "ready_for_review",
        "updated_at" => ctx.task["updated_at"] - 1000
      })

    put_task(
      put_in(older, ["metadata", "origin"], %{"provider" => "comma", "client_platform" => "macos"})
    )

    {:ok, legacy} = Accounts.create_session(ctx.user["id"])
    {:ok, registration} = Notifications.register(ctx.user, legacy, "push_to_start", ctx.attrs)
    assert :delivered = deliver_activity(registration["id"])
    assert_receive {:started, %{"aps" => aps}}
    assert aps["event"] == "start"
    assert aps["input-push-token"] == 1
    assert aps["attributes-type"] == "TaskActivityAttributes"

    assert aps["attributes"] == %{
             "accountID" => ctx.user["id"],
             "workspaceID" => ctx.workspace.id,
             "groupID" => ctx.attrs["group_id"]
           }

    assert Enum.map(aps["content-state"]["tasks"], & &1["id"]) == [
             ctx.task["conversation_id"],
             older["conversation_id"]
           ]

    assert :current = deliver_activity(registration["id"])
    refute_received {:started, _}
  end

  test "profiles select signing identity and allow both app topics in either environment", ctx do
    production_key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, production_pem} = JOSE.JWK.to_pem(production_key)
    config = SystemsRuntime.get_env(:comma_core, :apns)

    production = [
      team_id: "PRODTEAM",
      key_id: "PRODKEY",
      private_key: production_pem,
      allowed_bundle_ids: ["surf.comma.ios", "surf.comma.ios.dev"]
    ]

    SystemsRuntime.put_env(
      :comma_core,
      :apns,
      Keyword.update!(config, :profiles, &Map.put(&1, "production", production))
    )

    owner = SystemsRuntime.Proc.self()

    Req.Test.stub(__MODULE__, fn conn ->
      SystemsRuntime.Proc.send(owner, {:profile_request, conn})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    tokens =
      for {environment, bundle, kind} <- [
            {"sandbox", "surf.comma.ios", "device"},
            {"production", "surf.comma.ios.dev", "live_activity"},
            {"sandbox", "surf.comma.ios.dev", "push_to_start"},
            {"production", "surf.comma.ios", "device"}
          ] do
        attrs = Map.merge(ctx.attrs, %{"environment" => environment, "bundle_id" => bundle})
        assert {:ok, registration} = Notifications.register(ctx.user, ctx.session, kind, attrs)
        target = Repo.get!(Target, registration["id"])
        assert :ok = APNs.send(target, %{"aps" => %{}})
        assert_receive {:profile_request, conn}

        assert conn.host ==
                 if(environment == "sandbox",
                   do: "api.sandbox.push.apple.com",
                   else: "api.push.apple.com"
                 )

        assert Plug.Conn.get_req_header(conn, "apns-topic") ==
                 [bundle <> if(kind == "device", do: "", else: ".push-type.liveactivity")]

        ["bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        key = if environment == "sandbox", do: ctx.key, else: production_key
        issuer = if environment == "sandbox", do: "TESTTEAM", else: "PRODTEAM"
        key_id = if environment == "sandbox", do: "TESTKEY", else: "PRODKEY"

        assert {true, %JOSE.JWT{fields: %{"iss" => ^issuer}},
                %JOSE.JWS{fields: %{"kid" => ^key_id}}} =
                 JOSE.JWT.verify_strict(JOSE.JWK.to_public(key), ["ES256"], jwt)

        jwt
      end

    assert Enum.at(tokens, 0) == Enum.at(tokens, 2)
    assert Enum.at(tokens, 1) == Enum.at(tokens, 3)
  end

  test "ordinary alerts are generic localized milestones, not cancellation, archive or progress",
       ctx do
    owner = SystemsRuntime.Proc.self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      SystemsRuntime.Proc.send(owner, {:ordinary_alert, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    for {locale, bodies} <- [
          {"en-US",
           [
             "A task needs your attention.",
             "A task needs your attention.",
             "A task is complete.",
             "A task couldn’t finish."
           ]},
          {"zh-Hans", ["有任务需要你处理。", "有任务需要你处理。", "有任务已完成。", "有任务未能完成。"]}
        ] do
      {:ok, registration} =
        Notifications.register(
          ctx.user,
          ctx.session,
          "device",
          Map.put(ctx.attrs, "locale", locale)
        )

      for status <- ~w(active pending paused cancelled archived) do
        put_task(%{ctx.task | "status" => status})
        assert :current = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
        refute_received {:ordinary_alert, _}
      end

      for {status, body} <- Enum.zip(~w(ready_for_review escalated completed failed), bodies) do
        task = %{ctx.task | "status" => status}
        put_task(task)
        assert :delivered = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
        assert_receive {:ordinary_alert, payload}

        assert payload == %{
                 "aps" => %{
                   "alert" => %{"title" => "Comma", "body" => body},
                   "sound" => "default",
                   "badge" => 0
                 },
                 "session_id" => ctx.session["id"],
                 "workspace_id" => ctx.workspace.id,
                 "group_id" => ctx.attrs["group_id"],
                 "task_id" => ctx.task["conversation_id"]
               }

        assert :current = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
        # A message/title/progress timestamp change is not another milestone.
        put_task(%{
          task
          | "updated_at" => task["updated_at"] + 1,
            "title" => "Different private title"
        })

        assert :current = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
        refute_received {:ordinary_alert, _}
      end
    end
  end

  test "Router banners and read acknowledgements carry absolute badges without historical alerts",
       ctx do
    owner = SystemsRuntime.Proc.self()
    id = Ids.new_conversation_id()

    historical = %{
      "message_id" => Ids.new_message_id(),
      "seq" => 1,
      "actor_type" => "agent",
      "agent_id" => ctx.workspace.salix_router_agent_id,
      "content" => [%{"type" => "text", "text" => "Old private reply"}]
    }

    Process.put(:native_push_router, %{"conversation_id" => id, "messages" => [historical]})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      SystemsRuntime.Proc.send(owner, {:router_push, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    {:ok, registration} =
      Notifications.register(
        ctx.user,
        ctx.session,
        "device",
        Map.put(ctx.attrs, "locale", "zh-Hans")
      )

    assert :delivered = Notifications.deliver_router(registration["id"])
    assert_receive {:router_push, %{"type" => "router_counter", "aps" => %{"badge" => 0}}}
    reply = %{historical | "message_id" => Ids.new_message_id(), "seq" => 2}

    mirror = %{
      "message_id" => Ids.new_message_id(),
      "seq" => 3,
      "actor_type" => "system",
      "kind" => "app_event",
      "metadata" => %{"event_type" => "provider.message"},
      "platform_message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Private WeChat reply"}]
      }
    }

    Process.put(:native_push_router, %{
      "conversation_id" => id,
      "messages" => [historical, reply, mirror]
    })

    assert :delivered = Notifications.deliver_router(registration["id"])
    assert_receive {:router_push, payload}

    assert payload == %{
             "type" => "router_message",
             "aps" => %{
               "badge" => 2,
               "alert" => %{"title" => "Comma", "body" => "Router 有新消息。"},
               "sound" => "default"
             },
             "session_id" => ctx.session["id"],
             "workspace_id" => ctx.workspace.id,
             "group_id" => ctx.attrs["group_id"],
             "conversation_id" => id,
             "message_id" => mirror["message_id"]
           }

    assert :current = Notifications.deliver_router(registration["id"])
    refute_received {:router_push, _}

    # Enrollment on another phone synchronizes the existing unread count only.
    {:ok, other} = Accounts.create_session(ctx.user["id"])
    {:ok, next} = Notifications.register(ctx.user, other, "device", ctx.attrs)
    assert :delivered = Notifications.deliver_router(next["id"])
    assert_receive {:router_push, %{"type" => "router_counter", "aps" => %{"badge" => 2}}}

    put_task(%{ctx.task | "status" => "completed"})
    assert :delivered = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
    assert_receive {:router_push, %{"task_id" => _, "aps" => %{"badge" => 2}}}

    assert {:ok, %{"unread_count" => 0}} =
             Comma.RouterNotifications.read(
               ctx.user,
               ctx.session,
               ctx.attrs["group_id"],
               mirror["message_id"]
             )

    assert :delivered = Notifications.deliver_router(registration["id"])
    assert_receive {:router_push, %{"type" => "router_counter", "aps" => %{"badge" => 0}}}
    assert :delivered = Notifications.deliver_router(next["id"])
    assert_receive {:router_push, %{"type" => "router_counter", "aps" => %{"badge" => 0}}}
  end

  test "a concurrent delivery cannot send while another holds the address lease", ctx do
    {:ok, registration} = Notifications.register(ctx.user, ctx.session, "device", ctx.attrs)
    task = %{ctx.task | "status" => "ready_for_review"}
    put_task(task)
    owner = SystemsRuntime.Proc.self()

    Req.Test.stub(__MODULE__, fn conn ->
      SystemsRuntime.Proc.send(owner, {:parallel_alert, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        :finish_send -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    first =
      SystemsRuntime.Task.async(fn ->
        put_task(task)
        Notifications.deliver(registration["id"], task["conversation_id"])
      end)

    :ok = Req.Test.allow(__MODULE__, owner, first.pid)
    assert_receive {:parallel_alert, sender}

    # The first send is in APNs without holding a transaction or row lock.
    assert {:error, :delivery_busy} =
             Notifications.deliver(registration["id"], task["conversation_id"])

    assert {:snooze, 30} =
             Comma.Workers.NativePush.perform(%Oban.Job{
               args: %{
                 "target_id" => registration["id"],
                 "conversation_id" => task["conversation_id"]
               }
             })

    SystemsRuntime.Proc.send(sender, :finish_send)
    assert :delivered = SystemsRuntime.Task.await(first, :infinity)
    assert Repo.get!(Target, registration["id"]).delivery_lease_until == nil

    assert :current = Notifications.deliver(registration["id"], task["conversation_id"])
    refute_received {:parallel_alert, _}
    put_task(%{task | "status" => "active"})
    assert :current = Notifications.deliver(registration["id"], task["conversation_id"])
    put_task(%{task | "status" => "ready_for_review", "updated_at" => task["updated_at"] + 1})

    Req.Test.stub(__MODULE__, fn conn ->
      SystemsRuntime.Proc.send(owner, {:parallel_alert, SystemsRuntime.Proc.self()})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :delivered = Notifications.deliver(registration["id"], task["conversation_id"])
    assert_receive {:parallel_alert, _}
  end

  test "ordinary scope is the supported default Group; failed replacement retains old scope",
       ctx do
    {:ok, registration} = Notifications.register(ctx.user, ctx.session, "device", ctx.attrs)
    assert Repo.get!(Target, registration["id"]).group_id == ctx.workspace.salix_group_id
    other_group = Ids.new_group_id(ctx.workspace.salix_tenant_id)

    assert {:error, :not_found} =
             Notifications.register(
               ctx.user,
               ctx.session,
               "device",
               Map.put(ctx.attrs, "group_id", other_group)
             )

    assert {:error, :forbidden} =
             Notifications.register(
               ctx.user,
               ctx.session,
               "device",
               Map.put(ctx.attrs, "workspace_id", "another-workspace")
             )

    assert Repo.get!(Target, registration["id"]).group_id == ctx.workspace.salix_group_id
    assert Notifications.targets_for_task(other_group, ctx.task["conversation_id"], nil) == []

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    next_workspace =
      Repo.insert!(%Workspace{
        ctx.workspace
        | id: "wsp_next_#{SystemsRuntime.Proc.unique_integer([:positive])}",
          salix_tenant_id: tenant,
          salix_group_id: group,
          salix_router_agent_id: Ids.new_agent_id(group),
          salix_worker_agent_id: Ids.new_agent_id(group),
          inserted_at: nil,
          updated_at: nil
      })

    Repo.insert!(%WorkspaceMembership{
      workspace_id: next_workspace.id,
      user_id: ctx.user["id"],
      role: "owner",
      status: "active"
    })

    {:ok, replaced} =
      Notifications.register(
        ctx.user,
        ctx.session,
        "device",
        Map.merge(ctx.attrs, %{"workspace_id" => next_workspace.id, "group_id" => group})
      )

    assert Repo.get(Target, registration["id"]) == nil
    assert Repo.get!(Target, replaced["id"]).group_id == group

    assert Notifications.targets_for_task(
             ctx.workspace.salix_group_id,
             ctx.task["conversation_id"],
             nil
           ) == []
  end

  test "revoked ordinary session cannot deliver even a generic alert", ctx do
    {:ok, registration} = Notifications.register(ctx.user, ctx.session, "device", ctx.attrs)
    put_task(%{ctx.task | "status" => "ready_for_review"})
    Req.Test.stub(__MODULE__, fn _ -> flunk("revoked ordinary targets must not send") end)
    assert :ok = Accounts.revoke_session_token(ctx.session["token"])
    assert :obsolete = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
  end

  defp put_task(task),
    do:
      Process.put(
        :native_push_tasks,
        Map.put(Process.get(:native_push_tasks, %{}), task["conversation_id"], task)
      )

  defp deliver_activity(id) do
    case Notifications.deliver(id, nil) do
      {:error, :activity_update_busy} ->
        SystemsClock.sleep(1_001)
        Notifications.deliver(id, nil)

      result ->
        result
    end
  end

  defp restore(key, nil), do: SystemsRuntime.delete_env(:comma_core, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:comma_core, key, value)
end
