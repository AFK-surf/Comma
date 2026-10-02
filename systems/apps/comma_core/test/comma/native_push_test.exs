defmodule Comma.NativePushTest.Salix do
  def resolve_workspace_scope(workspace), do: {:ok, workspace}

  def get_group_conversation(_workspace, id) do
    if callback = Process.get(:native_push_read_callback), do: callback.()

    case Process.get(:native_push_tasks, %{})[id] do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end
end

defmodule Comma.NativePushTest do
  use Comma.DataCase, async: false
  alias Comma.{Accounts, Notifications}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Notifications.{APNs, Target}
  alias SalixStore.Ids

  setup do
    prior_apns = Application.get_env(:comma_core, :apns)
    prior_client = Application.get_env(:comma_core, :salix_client)
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = JOSE.JWK.to_pem(key)

    Application.put_env(:comma_core, :apns,
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

    Application.put_env(:comma_core, :salix_client, Comma.NativePushTest.Salix)
    unless Process.whereis(APNs.ProviderToken), do: start_supervised!(APNs.ProviderToken)

    unless Oban.whereis(Comma.Oban) do
      start_supervised!(
        {Oban, name: Comma.Oban, repo: Repo, testing: :manual, queues: false, plugins: false}
      )
    end

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "push-#{System.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_native_#{System.unique_integer([:positive])}",
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
      "updated_at" => System.system_time(:millisecond),
      "created_at" => System.system_time(:millisecond) - 1_000,
      "metadata" => %{"origin" => %{"provider" => "comma", "client_platform" => "ios"}}
    }

    put_task(task)

    attrs = %{
      "token" => String.duplicate("a", 64),
      "environment" => "sandbox",
      "bundle_id" => "surf.comma.ios.dev",
      "workspace_id" => workspace.id,
      "group_id" => group,
      "task_id" => id,
      "activity_id" => "local-activity"
    }

    on_exit(fn ->
      restore(:apns, prior_apns)
      restore(:salix_client, prior_client)
    end)

    %{user: user, session: session, workspace: workspace, task: task, attrs: attrs, key: key}
  end

  test "missing Apple configuration reports unavailable and stores no fake address", ctx do
    Application.delete_env(:comma_core, :apns)

    assert {:error, :push_unavailable} =
             Notifications.register(ctx.user, ctx.session, "device", ctx.attrs)

    assert Repo.aggregate(Target, :count) == 0

    assert {:error, :push_unavailable} =
             APNs.send(
               %Target{kind: "device", environment: "sandbox", token: ctx.attrs["token"]},
               %{"aps" => %{}}
             )
  end

  test "registering requires the current Group owner and unrestricted Auth Session", ctx do
    {:ok, other} =
      Accounts.create_user(%{
        "email" => "other-push-#{System.unique_integer([:positive])}@example.test"
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

    assert {:error, :not_found} =
             Notifications.register(
               ctx.user,
               ctx.session,
               "live_activity",
               Map.put(ctx.attrs, "task_id", Ids.new_conversation_id())
             )

    assert Repo.aggregate(Target, :count) == 0
  end

  test "rotation replaces an address and an old asynchronous delete cannot remove it", ctx do
    {:ok, first} = Notifications.register(ctx.user, ctx.session, "live_activity", ctx.attrs)
    rotated = Map.put(ctx.attrs, "token", String.duplicate("b", 64))
    {:ok, next} = Notifications.register(ctx.user, ctx.session, "live_activity", rotated)
    refute first["id"] == next["id"]
    assert :ok = Notifications.unregister(ctx.session, first["id"])
    assert Repo.get!(Target, next["id"]).token == rotated["token"]
    assert Repo.aggregate(Target, :count) == 1
    {:ok, other_session} = Accounts.create_session(ctx.user["id"])
    assert :ok = Notifications.unregister(other_session, next["id"])
    assert Repo.get(Target, next["id"])
  end

  test "APNs request uses HTTP topic, token auth, server ordering time and public content state",
       ctx do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, conn, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    {:ok, registration} =
      Notifications.register(ctx.user, ctx.session, "live_activity", ctx.attrs)

    assert :delivered = Notifications.deliver(registration["id"], nil)
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

    assert issued <= System.system_time(:second)
    assert aps["event"] == "update"
    assert aps["content-state"]["title"] == ctx.task["title"]
    assert aps["content-state"]["updatedAtEpochSeconds"] == div(ctx.task["updated_at"], 1_000)
    assert aps["stale-date"] == aps["timestamp"] + 120
    refute inspect(aps) =~ ctx.session["token"]
    assert :current = Notifications.deliver(registration["id"], nil)
    refute_receive {:request, _, _}
  end

  test "revocation stops exact-Task delivery before touching APNs", ctx do
    Req.Test.stub(__MODULE__, fn _ -> flunk("revoked sessions must not send a push") end)

    {:ok, registration} =
      Notifications.register(ctx.user, ctx.session, "live_activity", ctx.attrs)

    assert :ok = Accounts.revoke_session_token(ctx.session["token"])
    assert :obsolete = Notifications.deliver(registration["id"], nil)
    assert Repo.get(Target, registration["id"]) == nil
  end

  test "revocation during an owner read cannot pass the APNs send boundary", ctx do
    {:ok, registration} =
      Notifications.register(ctx.user, ctx.session, "live_activity", ctx.attrs)

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :unexpected_apns_request)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Process.put(:native_push_read_callback, fn ->
      Accounts.revoke_session_token(ctx.session["token"])
    end)

    assert :obsolete = Notifications.deliver(registration["id"], nil)
    refute_receive :unexpected_apns_request
    assert Repo.get(Target, registration["id"]) == nil
  end

  test "terminal events end the Activity, and attention is canonical ready_for_review", ctx do
    review = %{ctx.task | "status" => "ready_for_review"}

    payload =
      Notifications.activity_payload(
        %{
          "title" => review["title"],
          "status" => review["status"],
          "updated_at" => review["updated_at"]
        },
        123
      )

    assert payload["aps"]["alert"]["body"] == "A task needs your attention"
    completed = %{ctx.task | "status" => "completed", "updated_at" => ctx.task["updated_at"] + 1}
    put_task(completed)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:ended, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    {:ok, registration} =
      Notifications.register(ctx.user, ctx.session, "live_activity", ctx.attrs)

    assert :obsolete = Notifications.deliver(registration["id"], nil)
    assert_receive {:ended, %{"aps" => aps}}
    assert aps["event"] == "end"
    assert aps["dismissal-date"] == aps["timestamp"] + 60
    assert Repo.get(Target, registration["id"]) == nil
  end

  test "automatic start uses canonical iPhone origin, creation time and one start receipt", ctx do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:started, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    {:ok, registration} =
      Notifications.register(ctx.user, ctx.session, "push_to_start", ctx.attrs)

    # Creation predates preference enrollment, so existing sidebar Tasks do not start.
    assert :current = Notifications.deliver(registration["id"], ctx.task["conversation_id"])

    recent = %{
      ctx.task
      | "created_at" => System.system_time(:millisecond) + 1,
        "updated_at" => System.system_time(:millisecond) + 1
    }

    put_task(put_in(recent, ["metadata", "origin", "client_platform"], "web"))
    assert :current = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
    put_task(recent)
    assert :delivered = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
    assert_receive {:started, %{"aps" => aps}}
    assert aps["event"] == "start"
    assert aps["input-push-token"] == 1
    assert aps["attributes-type"] == "TaskActivityAttributes"
    assert aps["attributes"]["accountID"] == ctx.user["id"]
    assert aps["attributes"]["taskID"] == ctx.task["conversation_id"]
    assert :current = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
    refute_receive {:started, _}
  end

  test "invalid APNs token is removed and retryable rejection retains the address", ctx do
    {:ok, registration} =
      Notifications.register(ctx.user, ctx.session, "live_activity", ctx.attrs)

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"reason" => "ServiceUnavailable"})
    end)

    assert {:error, :apns_retryable} = Notifications.deliver(registration["id"], nil)
    assert Repo.get(Target, registration["id"])

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(410) |> Req.Test.json(%{"reason" => "Unregistered"})
    end)

    assert :obsolete = Notifications.deliver(registration["id"], nil)
    assert Repo.get(Target, registration["id"]) == nil
  end

  test "profiles select signing identity and allow both app topics in either environment", ctx do
    production_key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, production_pem} = JOSE.JWK.to_pem(production_key)
    config = Application.get_env(:comma_core, :apns)

    production = [
      team_id: "PRODTEAM",
      key_id: "PRODKEY",
      private_key: production_pem,
      allowed_bundle_ids: ["surf.comma.ios", "surf.comma.ios.dev"]
    ]

    Application.put_env(
      :comma_core,
      :apns,
      Keyword.update!(config, :profiles, &Map.put(&1, "production", production))
    )

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:profile_request, conn})
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

  test "missing profile, invalid signer and unapproved bundle cannot create registrations", ctx do
    assert {:error, :push_unavailable} =
             Notifications.register(
               ctx.user,
               ctx.session,
               "device",
               Map.put(ctx.attrs, "environment", "production")
             )

    assert {:error, :invalid_push_registration} =
             Notifications.register(
               ctx.user,
               ctx.session,
               "device",
               Map.put(ctx.attrs, "bundle_id", "other.apple.app")
             )

    update_sandbox(fn profile ->
      Keyword.put(profile, :allowed_bundle_ids, ["surf.comma.ios"])
    end)

    assert {:error, :invalid_push_registration} =
             Notifications.register(ctx.user, ctx.session, "device", ctx.attrs)

    update_sandbox(fn profile -> Keyword.put(profile, :private_key, "invalid-test-key") end)

    assert {:error, :push_unavailable} =
             Notifications.register(
               ctx.user,
               ctx.session,
               "device",
               Map.put(ctx.attrs, "bundle_id", "surf.comma.ios")
             )

    assert Repo.aggregate(Target, :count) == 0
  end

  test "ordinary alerts are generic localized milestones, not cancellation, archive or progress",
       ctx do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:ordinary_alert, Jason.decode!(body)})
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
        refute_receive {:ordinary_alert, _}
      end

      for {status, body} <- Enum.zip(~w(ready_for_review escalated completed failed), bodies) do
        task = %{ctx.task | "status" => status}
        put_task(task)
        assert :delivered = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
        assert_receive {:ordinary_alert, payload}

        assert payload == %{
                 "aps" => %{
                   "alert" => %{"title" => "Comma", "body" => body},
                   "sound" => "default"
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
        refute_receive {:ordinary_alert, _}
      end
    end
  end

  test "a concurrent delivery cannot send while another holds the address lease", ctx do
    {:ok, registration} = Notifications.register(ctx.user, ctx.session, "device", ctx.attrs)
    task = %{ctx.task | "status" => "ready_for_review"}
    put_task(task)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:parallel_alert, self()})

      receive do
        :finish_send -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    first =
      Task.async(fn ->
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

    send(sender, :finish_send)
    assert :delivered = Task.await(first)
    assert Repo.get!(Target, registration["id"]).delivery_lease_until == nil

    assert :current = Notifications.deliver(registration["id"], task["conversation_id"])
    refute_receive {:parallel_alert, _}
    put_task(%{task | "status" => "active"})
    assert :current = Notifications.deliver(registration["id"], task["conversation_id"])
    put_task(%{task | "status" => "ready_for_review", "updated_at" => task["updated_at"] + 1})

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:parallel_alert, self()})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :delivered = Notifications.deliver(registration["id"], task["conversation_id"])
    assert_receive {:parallel_alert, _}
  end

  test "unknown locale defaults to English and successful rotation changes locale and identity",
       ctx do
    {:ok, registration} =
      Notifications.register(
        ctx.user,
        ctx.session,
        "device",
        Map.put(ctx.attrs, "locale", "fr-FR")
      )

    target = Repo.get!(Target, registration["id"])
    assert target.locale == "en-US"
    assert target.bundle_id == "surf.comma.ios.dev"

    {:ok, rotated} =
      Notifications.register(
        ctx.user,
        ctx.session,
        "device",
        Map.merge(ctx.attrs, %{"locale" => "zh-Hans", "bundle_id" => "surf.comma.ios"})
      )

    target = Repo.get!(Target, rotated["id"])
    assert target.locale == "zh-Hans"
    assert target.bundle_id == "surf.comma.ios"
  end

  test "legacy rows and old payloads require an explicit operator topic, not guessed identity",
       ctx do
    legacy_attrs = Map.delete(ctx.attrs, "bundle_id")

    assert {:error, :invalid_push_registration} =
             Notifications.register(ctx.user, ctx.session, "device", legacy_attrs)

    {:ok, registration} = Notifications.register(ctx.user, ctx.session, "device", ctx.attrs)
    target = Repo.get!(Target, registration["id"])
    Repo.update!(Ecto.Changeset.change(target, bundle_id: nil))
    put_task(%{ctx.task | "status" => "completed"})
    Req.Test.stub(__MODULE__, fn _ -> flunk("unknown legacy identity must not send") end)

    assert {:error, :push_unavailable} =
             Notifications.deliver(registration["id"], ctx.task["conversation_id"])

    assert %{bundle_id: nil, last_sent_version: 0} = Repo.get!(Target, registration["id"])

    update_sandbox(fn profile -> Keyword.put(profile, :legacy_bundle_id, "surf.comma.ios") end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "apns-topic") == ["surf.comma.ios"]
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :delivered = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
    # Authoritative configuration can send old rows without rewriting facts.
    assert Repo.get!(Target, registration["id"]).bundle_id == nil
    assert {:ok, enrolled} = Notifications.register(ctx.user, ctx.session, "device", legacy_attrs)
    assert Repo.get!(Target, enrolled["id"]).bundle_id == "surf.comma.ios"
    assert Repo.get!(Target, enrolled["id"]).locale == "en-US"
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
        | id: "wsp_next_#{System.unique_integer([:positive])}",
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

  test "provider topic/configuration and ambiguous environment errors retain undelivered targets",
       ctx do
    {:ok, registration} = Notifications.register(ctx.user, ctx.session, "device", ctx.attrs)
    put_task(%{ctx.task | "status" => "completed"})

    for {reason, error} <- [
          {"DeviceTokenNotForTopic", :apns_configuration_error},
          {"InvalidProviderToken", :apns_configuration_error},
          {"TopicDisallowed", :apns_configuration_error},
          {"BadDeviceToken", :apns_token_environment_mismatch}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"reason" => reason})
      end)

      assert {:error, ^error} =
               Notifications.deliver(registration["id"], ctx.task["conversation_id"])

      target = Repo.get!(Target, registration["id"])
      assert target.last_sent_version == 0
      assert target.last_sent_status == nil
      assert target.recent_states == %{}

      assert {:cancel, ^error} =
               Comma.Workers.NativePush.perform(%Oban.Job{
                 args: %{
                   "target_id" => registration["id"],
                   "conversation_id" => ctx.task["conversation_id"]
                 }
               })
    end

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
    assert :delivered = Notifications.deliver(registration["id"], ctx.task["conversation_id"])
  end

  defp update_sandbox(fun) do
    config = Application.get_env(:comma_core, :apns)

    Application.put_env(
      :comma_core,
      :apns,
      Keyword.update!(config, :profiles, &Map.update!(&1, "sandbox", fun))
    )
  end

  defp put_task(task),
    do:
      Process.put(
        :native_push_tasks,
        Map.put(Process.get(:native_push_tasks, %{}), task["conversation_id"], task)
      )

  defp restore(key, nil), do: Application.delete_env(:comma_core, key)
  defp restore(key, value), do: Application.put_env(:comma_core, key, value)
end
