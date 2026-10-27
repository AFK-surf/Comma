defmodule CommaWeb.RouterTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test
  import Comma.WorkspaceTestSupport

  alias Comma.Accounts.AuthSession
  alias Comma.Repo

  @opts CommaWeb.Router.init([])
  @admin_token "test-token"
  @web_origin "http://127.0.0.1:5174"
  @admin_origin "http://127.0.0.1:4175"

  setup context do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    comma_owner =
      if context[:database_isolation] do
        CommaWeb.TestRepoSandbox.start_owner!(:multi_connection)
      else
        CommaWeb.TestRepoSandbox.start_owner!(:transaction)
      end

    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_api_token = SystemsRuntime.get_env(:comma_web, :api_token)
    prev_auth = SystemsRuntime.get_env(:comma_core, :auth)
    prev_salix_client = SystemsRuntime.get_env(:comma_core, :salix_client)
    prev_salix_vm = SystemsRuntime.get_env(:comma_core, :salix_vm)
    prev_salix_client_test_pid = SystemsRuntime.get_env(:comma_core, :salix_client_test_pid)

    prev_google_credentials =
      SystemsRuntime.get_env(:comma_core, :google_adapter_fake_credentials)

    prev_google_exchange_pid =
      SystemsRuntime.get_env(:comma_core, :google_adapter_fake_exchange_pid)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    Comma.PodLifecycle.reset_for_test()

    SystemsRuntime.put_env(:comma_core, :auth,
      challenge_store: Comma.AuthChallengeStore.Memory,
      email_delivery: Comma.EmailDelivery.Logger,
      secret: "comma-web-test-secret",
      rate_limit_secret: "comma-web-test-rate-limit-secret",
      challenge_ttl_seconds: 900,
      max_attempts: 5,
      session_ttl_seconds: 3600,
      auto_create_users: true,
      resend_cooldown_seconds: 0,
      email_request_limit: 1_000_000,
      ip_request_limit: 1_000_000,
      verification_failure_limit: 1_000_000,
      provider_failure_threshold: 1_000_000,
      expose_codes: true
    )

    ensure_fake_s3!()
    SalixAgent.TestSupport.configure_platform_models!()
    Comma.AuthChallengeStore.Memory.reset!()

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
      restore_env(:comma_web, :api_token, prev_api_token)
      restore_env(:comma_core, :auth, prev_auth)
      restore_env(:comma_core, :salix_client, prev_salix_client)
      restore_env(:comma_core, :salix_vm, prev_salix_vm)
      restore_env(:comma_core, :salix_client_test_pid, prev_salix_client_test_pid)
      restore_env(:comma_core, :google_adapter_fake_credentials, prev_google_credentials)
      restore_env(:comma_core, :google_adapter_fake_exchange_pid, prev_google_exchange_pid)
      Comma.Migrations.LegacyS3Fixture.reset!()
      Comma.PodLifecycle.reset_for_test()
      Comma.AuthChallengeStore.Memory.reset!()
      CommaWeb.TestRepoSandbox.stop_owner(comma_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    :ok
  end

  @tag :browser_run
  test "browser endpoints enforce workspace ownership and redact provider credentials" do
    session = email_login!("browser-owner@example.com")
    outsider = email_login!("browser-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Browser")

    owner =
      SalixAgent.Browser.owner(%{
        agent_id: workspace["router_agent_id"],
        session_id: "browser-test"
      })

    settings = %SalixStore.BrowserSettings.Row{
      scope: owner.tenant_id,
      account_id: String.duplicate("a", 32),
      token_ciphertext: "private-ciphertext"
    }

    {:ok, row} = SalixStore.BrowserBindings.reserve(owner, settings)

    {:ok, ready} =
      SalixStore.BrowserBindings.finish(row, %{status: "ready", provider_id: "private-provider"})

    assert {:ok, :saved} =
             SalixStore.BrowserStorage.save(
               ready,
               %{
                 "cookies" => [%{"name" => "login", "value" => "private-login"}],
                 "origins" => %{}
               },
               nil
             )

    on_exit(fn -> SalixStore.Repo.delete_all(SalixStore.BrowserBindings.query(owner)) end)
    path = "/v1/comma/workspaces/#{workspace["id"]}/browsers"

    response =
      :get
      |> conn(path)
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> call()

    assert response.status == 200
    assert [%{"agent_id" => _}] = Jason.decode!(response.resp_body)["browsers"]
    refute response.resp_body =~ "private-"

    chat =
      :post
      |> json_conn("/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat", %{})
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> call()
      |> expect_json(200)

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(
        workspace["default_group_id"],
        chat["id"]
      )

    participant = Enum.find(participants, &(&1["actor_type"] == "agent"))

    scoped_path =
      path <>
        "?" <>
        URI.encode_query(%{
          "conversation_id" => chat["id"],
          "participant_id" => participant["participant_id"]
        })

    read = fn ->
      :get
      |> conn(scoped_path)
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> call()
      |> expect_json(200)
    end

    # The ready browser above belongs to a different Runtime Session.
    assert read.()["browsers"] == []
    current_owner = %{owner | session_id: get_in(participant, ["payload", "session_id"])}

    assert {:error, :browser_shared_profile_in_use} =
             SalixStore.BrowserBindings.reserve(current_owner, settings)

    {:ok, closing} = SalixStore.BrowserBindings.claim(owner, :agent, "close")
    {:ok, _} = SalixStore.BrowserBindings.finish(closing, %{status: "closed"})
    {:ok, current_row} = SalixStore.BrowserBindings.reserve(current_owner, settings)
    on_exit(fn -> SalixStore.Repo.delete_all(SalixStore.BrowserBindings.query(current_owner)) end)
    assert read.()["browsers"] == []
    {:ok, _} = SalixStore.BrowserBindings.finish(current_row, %{status: "ready"})
    assert [%{"session_id" => current_session}] = read.()["browsers"]
    assert current_session == current_owner.session_id

    SalixStore.Repo.update_all(SalixStore.BrowserBindings.query(current_owner),
      set: [status: "closed"]
    )

    assert read.()["browsers"] == []

    denied =
      :get
      |> conn(path)
      |> put_req_header("authorization", "Bearer " <> outsider["token"])
      |> call()

    assert denied.status == 403
    unauthenticated = :get |> conn(path) |> call()
    assert unauthenticated.status == 401

    foreign =
      SalixStore.Ids.new_tenant_id()
      |> SalixStore.Ids.new_group_id()
      |> SalixStore.Ids.new_agent_id()

    denied_command =
      :post
      |> json_conn(path <> "/#{foreign}/browser-test", %{
        "operation" => "take_control",
        "viewer_id" => SystemsRuntime.Proc.uuid()
      })
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> call()

    assert denied_command.status in [403, 409]
    assert SalixStore.BrowserBindings.get(owner).controller == nil

    denied_clear =
      :post
      |> json_conn(path <> "/#{owner.agent_id}/#{owner.session_id}", %{
        "operation" => "clear_storage",
        "viewer_id" => SystemsRuntime.Proc.uuid()
      })
      |> put_req_header("authorization", "Bearer " <> outsider["token"])
      |> call()

    assert denied_clear.status == 409
    assert Jason.decode!(denied_clear.resp_body)["error"] == "browser_forbidden"

    clear_idle = fn token ->
      :post
      |> json_conn(path <> "/clear-storage", %{})
      |> put_req_header("authorization", "Bearer " <> token)
      |> call()
    end

    assert clear_idle.(outsider["token"]).status == 403
    assert clear_idle.(session["token"]).status == 200
    assert {:ok, %{"cookies" => [], "origins" => %{}}} = SalixStore.BrowserStorage.load(owner)
    {:ok, _} = SalixStore.BrowserBindings.reserve(owner, settings)
    assert clear_idle.(session["token"]).status == 409
  end

  @tag :task_panel
  test "workspace owners list and delete saved device secrets without their values" do
    session = email_login!("device-secrets-owner@example.com")
    outsider = email_login!("device-secrets-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Lamps")
    value = "00112233445566778899aabbccddeeff"

    assert {:ok, _, :created} =
             SalixAgent.DeviceSecrets.save(workspace["default_group_id"], %{
               "kind" => "miio_token",
               "name" => "床头灯",
               "value" => value,
               "host" => "192.168.5.19"
             })

    path = "/v1/comma/workspaces/#{workspace["id"]}/device-secrets"
    response = :get |> conn(path) |> user_auth(session["token"]) |> call()
    assert response.status == 200
    refute response.resp_body =~ value

    assert %{"secrets" => [%{"name" => "床头灯", "kind" => "miio_token", "host" => "192.168.5.19"}]} =
             Jason.decode!(response.resp_body)

    :get |> conn(path) |> user_auth(outsider["token"]) |> call() |> expect_json(403)
    item = path <> "/" <> URI.encode("床头灯", &URI.char_unreserved?/1)
    :delete |> conn(item) |> user_auth(outsider["token"]) |> call() |> expect_json(403)

    deleted = :delete |> conn(item) |> user_auth(session["token"]) |> call() |> expect_json(200)
    assert %{"deleted" => true, "secret" => %{"name" => "床头灯"}} = deleted
    refute Jason.encode!(deleted) =~ value

    :delete |> conn(item) |> user_auth(session["token"]) |> call() |> expect_json(404)

    assert %{"secrets" => []} =
             :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)
  end

  # Pause a publisher after its database read, while other requests can finish.
  def pause_setup_offer_read(_event, _measurements, metadata, {publisher, parent, handler}) do
    if SystemsRuntime.Proc.self() == publisher and
         metadata[:source] == "comma_device_setup_offers" do
      SystemsRuntime.Telemetry.detach(handler)
      SystemsRuntime.Proc.send(parent, {:setup_offer_read, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        :continue_publish -> :ok
      end
    end
  end

  test "a nearby device report posts one setup offer that members resolve" do
    session = email_login!("nearby-owner@example.com")
    outsider = email_login!("nearby-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Nearby")
    {:ok, scope} = CommaWeb.SalixClient.resolve_workspace_scope(workspace)
    path = "/v1/comma/workspaces/#{workspace["id"]}/nearby-devices"

    report = fn request_id, devices ->
      %{"request_id" => request_id, "reporter_device_id" => "phone-1", "devices" => devices}
    end

    device = fn short_id, state ->
      %{
        "name" => "Comma-" <> String.upcase(short_id),
        "model" => "t-circle-s3",
        "state" => state,
        "short_id" => short_id,
        "rssi" => -58
      }
    end

    post = fn token, body -> :post |> json_conn(path, body) |> user_auth(token) |> call() end

    assert %{"devices" => [%{"outcome" => "offered", "offer_id" => offer_id}, ignored]} =
             session["token"]
             |> post.(report.("r1", [device.("5d28", "unprovisioned"), device.("AAAA", "ready")]))
             |> expect_json(202)

    assert ignored == %{"short_id" => "AAAA", "outcome" => "ignored"}

    # A second phone, or the app reopened, within 30 minutes.
    assert %{"devices" => [%{"outcome" => "duplicate", "offer_id" => ^offer_id}]} =
             session["token"]
             |> post.(report.("r2", [device.("5D28", "unprovisioned")]))
             |> expect_json(202)

    session["token"] |> post.(report.("r3", [%{"short_id" => "5D28"}])) |> expect_json(400)

    outsider["token"]
    |> post.(report.("r4", [device.("5D28", "unprovisioned")]))
    |> expect_json(403)

    run = fn args -> CommaWeb.DeviceSetupOffers.perform(%Oban.Job{args: args}) end
    assert :ok = run.(%{"op" => "post", "offer_id" => offer_id})
    assert :ok = run.(%{"op" => "post", "offer_id" => offer_id})

    home = fn ->
      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(
          scope["default_group_id"],
          scope["router_conversation_id"]
        )

      messages
    end

    assert [offer_message] =
             Enum.filter(home.(), &(get_in(&1, ["metadata", "offer_id"]) == offer_id))

    assert offer_message["actor_type"] == "agent"
    assert offer_message["agent_id"] == scope["router_agent_id"]

    assert [
             %{"type" => "text", "text" => text},
             %{"type" => "device_setup_offer", "status" => "open", "short_id" => "5D28"}
           ] = offer_message["content"]

    assert text == "Found a new Comma nearby. Want to set it up?"

    # The Router gets the offer as context that does not wake it.
    assert [context] =
             Enum.filter(home.(), &(&1["source_message_id"] == "device-setup-offer:" <> offer_id))

    assert context["agent_input"]["no_wake"] == true

    offer_path = path <> "/offers/" <> offer_id

    resolve = fn token, body ->
      :post |> json_conn(offer_path, body) |> user_auth(token) |> call()
    end

    outsider["token"] |> resolve.(%{"action" => "dismiss"}) |> expect_json(403)

    assert %{"offer" => %{"status" => "dismissed"}} =
             session["token"] |> resolve.(%{"action" => "dismiss"}) |> expect_json(200)

    session["token"] |> resolve.(%{"action" => "started"}) |> expect_json(409)

    dismissed = CommaWeb.DeviceSetupOffers.card(Repo.get!(Comma.Data.DeviceSetupOffer, offer_id))
    assert :ok = run.(%{"op" => "publish", "offer_id" => offer_id, "card" => dismissed})

    assert [%{"kind" => "app_event", "content" => [], "metadata" => metadata}] =
             Enum.filter(home.(), &(get_in(&1, ["metadata", "offer", "offer_id"]) == offer_id))

    assert metadata["event_type"] == "device_setup_offer.updated"
    assert metadata["offer"]["status"] == "dismissed"

    # Dismissal still suppresses repeated reports within the window.
    assert %{"devices" => [%{"outcome" => "duplicate", "offer_id" => ^offer_id}]} =
             session["token"]
             |> post.(report.("dismissed-again", [device.("5D28", "unprovisioned")]))
             |> expect_json(202)

    # A repeated started action publishes its new revision and deadline.
    assert %{"devices" => [%{"offer_id" => extended_id}]} =
             session["token"]
             |> post.(report.("extend", [device.("CA11", "unprovisioned")]))
             |> expect_json(202)

    extension_path = path <> "/offers/" <> extended_id

    for revision <- [2, 3] do
      assert %{"offer" => %{"revision" => ^revision} = expected} =
               :post
               |> json_conn(extension_path, %{"action" => "started"})
               |> user_auth(session["token"])
               |> call()
               |> expect_json(200)

      job =
        Repo.one!(
          from(j in Oban.Job,
            where:
              j.worker == "CommaWeb.DeviceSetupOffers" and
                fragment("?->>'offer_id'", j.args) == ^extended_id and
                fragment("?->>'op'", j.args) == "publish" and
                fragment("(?->'card'->>'revision')::int", j.args) == ^revision
          )
        )

      assert :ok = CommaWeb.DeviceSetupOffers.perform(job)

      latest =
        home.()
        |> Enum.filter(&(get_in(&1, ["metadata", "offer", "offer_id"]) == extended_id))
        |> Enum.max_by(& &1["seq"])

      assert latest["metadata"]["offer"] == expected
    end

    assert %{"devices" => [%{"outcome" => "duplicate", "offer_id" => ^extended_id}]} =
             session["token"]
             |> post.(report.("started-again", [device.("CA11", "unprovisioned")]))
             |> expect_json(202)

    # Setup started from another offer finishes when that device connects.
    assert %{"devices" => [%{"outcome" => "offered", "offer_id" => other_id}]} =
             session["token"]
             |> post.(report.("r5", [device.("BEEF", "unprovisioned")]))
             |> expect_json(202)

    assert %{"offer" => %{"status" => "started"}} =
             :post
             |> json_conn(path <> "/offers/" <> other_id, %{
               "action" => "started",
               "device_id" => "dev-new"
             })
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    CommaWeb.DeviceSetupOffers.device_connected(%{
      "group_id" => scope["default_group_id"],
      "device_id" => "dev-other",
      "name" => "Kitchen"
    })

    assert %{"offer" => %{"status" => "started"}} =
             :get
             |> conn(path <> "/offers/" <> other_id)
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    CommaWeb.DeviceSetupOffers.device_connected(%{
      "group_id" => scope["default_group_id"],
      "device_id" => "dev-new",
      "name" => "Bedroom"
    })

    assert %{"offer" => %{"status" => "done"}} =
             :get
             |> conn(path <> "/offers/" <> other_id)
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    # The device coming online gets one Router Message in Home, in the app
    # language.
    Repo.update_all(
      from(u in Comma.Accounts.User, where: u.id == ^session["user"]["id"]),
      set: [locale: "zh-CN"]
    )

    connected_job =
      Repo.one!(
        from(j in Oban.Job,
          where:
            j.worker == "CommaWeb.DeviceSetupOffers" and
              fragment("?->>'offer_id'", j.args) == ^other_id and
              fragment("?->>'op'", j.args) == "connected"
        )
      )

    assert :ok = CommaWeb.DeviceSetupOffers.perform(connected_job)
    assert :ok = CommaWeb.DeviceSetupOffers.perform(connected_job)

    assert [connected] =
             Enum.filter(
               home.(),
               &(get_in(&1, ["metadata", "message_type"]) == "device_setup_connected" and
                   get_in(&1, ["metadata", "offer_id"]) == other_id)
             )

    assert connected["agent_id"] == scope["router_agent_id"]

    assert [%{"type" => "text", "text" => connected_text}] = connected["content"]

    assert connected_text ==
             "Comma-BEEF 已连接。点一下它就能打电话。要让我通过它控制家里的设备，请在 设置 › 设备 里把它的「访问权限」设为「完全」。"

    # A device that connects through the Registry, named for the short id,
    # closes an open offer without a device id.
    assert %{"devices" => [%{"outcome" => "offered", "offer_id" => named_id}]} =
             session["token"]
             |> post.(report.("r7", [device.("D00D", "unprovisioned")]))
             |> expect_json(202)

    assert {:ok, _transport, _device} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => scope["default_group_id"],
                 "device_id" => SalixStore.Ids.new_device_id(),
                 "connector_id" => "connector-nearby-test",
                 "name" => "Comma-D00D"
               },
               connection_generation: 1,
               transport_id: "transport-nearby-test"
             )

    assert nearby_eventually(fn ->
             match?(
               %{"offer" => %{"status" => "done"}},
               :get
               |> conn(path <> "/offers/" <> named_id)
               |> user_auth(session["token"])
               |> call()
               |> expect_json(200)
             )
           end)

    # A connected device still suppresses an offer after its prior offer is done.
    assert %{"devices" => [%{"outcome" => "already_connected"}]} =
             session["token"]
             |> post.(report.("online-again", [device.("D00D", "unprovisioned")]))
             |> expect_json(202)

    # A late or retried publication cannot bring back an older card: each
    # card carries its revision and a stale job stops before appending.
    done = Repo.get!(Comma.Data.DeviceSetupOffer, other_id)

    started = %{
      CommaWeb.DeviceSetupOffers.card(done)
      | "status" => "started",
        "revision" => done.revision - 1
    }

    assert :ok =
             run.(%{
               "op" => "publish",
               "offer_id" => other_id,
               "card" => CommaWeb.DeviceSetupOffers.card(done)
             })

    assert :ok = run.(%{"op" => "publish", "offer_id" => other_id, "card" => started})

    cards =
      for %{"metadata" => %{"event_type" => "device_setup_offer.updated", "offer" => card}} <-
            home.(),
          card["offer_id"] == other_id,
          do: card

    assert %{"status" => "done"} = Enum.max_by(cards, & &1["revision"])
    refute Enum.any?(cards, &(&1["status"] == "started" and &1["revision"] >= done.revision))

    # Without a device id, the device's name or hostname carries the short id.
    assert CommaWeb.DeviceSetupOffers.matches?(
             %{"system_info" => %{"hostname" => "comma-5d28"}},
             "5D28",
             "Comma-5D28",
             nil
           )

    refute CommaWeb.DeviceSetupOffers.matches?(
             %{"name" => "Comma-5D29"},
             "5D28",
             "Comma-5D28",
             nil
           )

    # An open offer expires after 30 minutes.
    assert %{"devices" => [%{"outcome" => "offered", "offer_id" => late_id}]} =
             session["token"]
             |> post.(report.("r6", [device.("CAFE", "unprovisioned")]))
             |> expect_json(202)

    Repo.update_all(
      from(o in Comma.Data.DeviceSetupOffer, where: o.id == ^late_id),
      set: [expires_at: DateTime.add(SystemsClock.utc_now(), -1, :second)]
    )

    assert :ok = run.(%{"op" => "expire", "offer_id" => late_id, "at" => 0})

    assert %{"offer" => %{"status" => "expired"}} =
             :get
             |> conn(path <> "/offers/" <> late_id)
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    # A completed or expired offer does not suppress a reset device's new report.
    for {short_id, previous_id} <- [{"BEEF", other_id}, {"CAFE", late_id}] do
      assert %{"devices" => [%{"outcome" => "offered", "offer_id" => new_id}]} =
               session["token"]
               |> post.(report.("reset-" <> short_id, [device.(short_id, "unprovisioned")]))
               |> expect_json(202)

      refute new_id == previous_id
      assert :ok = run.(%{"op" => "post", "offer_id" => new_id})

      assert [%{"content" => [_, %{"status" => "open"}]}] =
               Enum.filter(home.(), &(get_in(&1, ["metadata", "offer_id"]) == new_id))

      assert %{"devices" => [%{"outcome" => "duplicate", "offer_id" => ^new_id}]} =
               session["token"]
               |> post.(report.("reset-retry-" <> short_id, [device.(short_id, "unprovisioned")]))
               |> expect_json(202)
    end
  end

  test "the Task panel reads its bound Worker only after ordinary Task authorization" do
    session = email_login!("task-panel-owner@example.com")
    other_session = email_login!("task-panel-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Task panel")
    workspace = CommaWeb.TestWorkers.with_default_worker!(workspace)
    group = workspace["default_group_id"]

    {:ok, task} =
      SalixCluster.TaskSchedules.create_task_conversation(
        group,
        workspace["router_agent_id"],
        workspace["default_worker_agent_id"],
        %{"title" => "Read task properties", "content" => "A read-only panel"}
      )

    task_id = task["conversation_id"]
    path = "/v1/comma/groups/#{group}/conversations/#{task_id}/preview"

    plain = :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)
    refute Map.has_key?(plain, "bound_worker")

    panel =
      :get
      |> conn(path <> "?include_worker=true")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert panel["id"] == task_id
    assert panel["status"] == plain["status"]
    assert %{"participant_id" => participant_id, "name" => name} = panel["bound_worker"]
    assert is_binary(participant_id) and participant_id != ""
    assert is_binary(name) and name != ""
    refute Map.has_key?(panel, "messages")
    # New apps show where the Task runs and its model instead of its Worker.
    assert panel["run"]["place"] == %{"kind" => "salix"}

    # A Task that a station's Session runs names that station; the Cloud VM
    # runs Comma's model when the Task names none.
    :ok =
      SalixStore.StationTaskSessions.join(%{
        tenant_id: workspace["salix_tenant_id"],
        group_id: group,
        conversation_id: task_id,
        device_id: SalixStore.RuntimeIds.cloud_vm_device_id(group),
        session: "station-session-1",
        agent_id: workspace["default_worker_agent_id"],
        start: %{"requester" => "panel-test"}
      })

    assert %{"run" => %{"place" => %{"kind" => "cloud_vm"}, "model" => %{"kind" => "platform"}}} =
             :get
             |> conn(path <> "?include_worker=true")
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    # Another station runs its runtime's model; the run names that model's maker.
    for {start, model} <- [
          {%{"runtime" => "claude"},
           %{"kind" => "runtime", "provider" => "claude", "name" => nil, "vendor" => "anthropic"}},
          {%{"runtime" => "codex", "model" => "gpt-5.5"},
           %{"kind" => "runtime", "provider" => "codex", "vendor" => "openai"}}
        ] do
      {:ok, station_task} =
        SalixCluster.TaskSchedules.create_task_conversation(
          group,
          workspace["router_agent_id"],
          workspace["default_worker_agent_id"],
          %{"title" => "Run on a station", "content" => "A station's runtime"}
        )

      :ok =
        SalixStore.StationTaskSessions.join(%{
          tenant_id: workspace["salix_tenant_id"],
          group_id: group,
          conversation_id: station_task["conversation_id"],
          device_id: "device-panel-station",
          session: "station-session-" <> start["runtime"],
          agent_id: workspace["default_worker_agent_id"],
          start: Map.put(start, "requester", "panel-test")
        })

      assert %{"run" => %{"place" => %{"kind" => "station"}, "model" => shown}} =
               :get
               |> conn(
                 "/v1/comma/groups/#{group}/conversations/#{station_task["conversation_id"]}/preview?include_worker=true"
               )
               |> user_auth(session["token"])
               |> call()
               |> expect_json(200)

      assert Map.take(shown, Map.keys(model)) == model
    end

    :get |> conn(path <> "?include_worker=true") |> call() |> expect_json(401)

    :get
    |> conn(path <> "?include_worker=true")
    |> user_auth(other_session["token"])
    |> call()
    |> expect_json(404)
  end

  test "a Task's run switch is checked as a new Task's place is; a place that cannot take it is refused with why" do
    session = email_login!("task-run-owner@example.com")
    other_session = email_login!("task-run-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Task run")
    workspace = CommaWeb.TestWorkers.with_default_worker!(workspace)
    group = workspace["default_group_id"]

    {:ok, task} =
      SalixCluster.TaskSchedules.create_task_conversation(
        group,
        workspace["router_agent_id"],
        workspace["default_worker_agent_id"],
        %{"title" => "Switch me", "content" => "Run on another model"}
      )

    task_id = task["conversation_id"]
    path = "/v1/comma/groups/#{group}/conversations/#{task_id}/run"
    put = fn body, token -> :put |> json_conn(path, body) |> user_auth(token) |> call() end

    assert %{"error" => "runs_on is required"} =
             put.(%{"model" => nil}, session["token"]) |> expect_json(400)

    # A computer this workspace does not have takes nothing; the Task is as it was.
    assert %{"code" => "task_run_refused", "reason" => "device_not_found", "message" => why} =
             put.(
               %{"runs_on" => %{"kind" => "station", "device_id" => "dev-unknown"}},
               session["token"]
             )
             |> expect_json(422)

    assert why =~ "not known"

    put.(%{"runs_on" => %{"kind" => "salix"}}, other_session["token"]) |> expect_json(404)

    # Nothing was switched: the Worker was told nothing.
    assert {:ok, messages} =
             SalixIM.Conversations.list_group_conversation_messages(group, task_id)

    assert [] =
             Enum.filter(
               messages,
               &(get_in(&1, ["metadata", "message_type"]) == SalixIM.TaskRun.message_type())
             )
  end

  test "the workspace owner turns the Condensed Workspace on and edits its statements" do
    session = email_login!("condensed-owner@example.com")
    other_session = email_login!("condensed-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Condensed")
    path = "/v1/comma/groups/#{workspace["default_group_id"]}/condensed-workspace"

    assert %{"enabled" => false, "revision" => 0, "statements" => []} =
             :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)

    :get |> conn(path) |> user_auth(other_session["token"]) |> call() |> expect_json(404)

    :put
    |> json_conn(path <> "/settings", %{"enabled" => true})
    |> user_auth(other_session["token"])
    |> call()
    |> expect_json(404)

    assert %{"enabled" => true} =
             :put
             |> json_conn(path <> "/settings", %{"enabled" => true})
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    assert %{"revision" => 1, "statements" => [%{"id" => "s1", "text" => "Launch is Friday."}]} =
             :post
             |> json_conn(path <> "/operations", %{
               "operations" => [%{"op" => "add", "text" => "Launch is Friday."}]
             })
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    assert %{"condensed_workspace" => %{"revision" => 1}} =
             :post
             |> json_conn(path <> "/operations", %{
               "operations" => [%{"op" => "remove", "id" => "s9"}]
             })
             |> user_auth(session["token"])
             |> call()
             |> expect_json(409)
  end

  @tag :task_labels_policy
  test "only the workspace owner can grant label automation and approve a batch through HTTP" do
    session = email_login!("labels-owner@example.com")
    other_session = email_login!("labels-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Task Labels")
    group_id = workspace["default_group_id"]
    path = "/v1/comma/groups/#{group_id}/task-labels"

    assert %{"approval_policy" => "ask", "labels" => labels} =
             :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)

    assert length(labels) == 4

    :patch
    |> json_conn(path <> "/policy", %{"approval_policy" => "auto"})
    |> call()
    |> expect_json(401)

    :patch
    |> json_conn(path <> "/policy", %{"approval_policy" => "auto"})
    |> user_auth(other_session["token"])
    |> call()
    |> expect_json(404)

    :patch
    |> json_conn(path <> "/policy", %{"approval_policy" => "always"})
    |> user_auth(session["token"])
    |> call()
    |> expect_json(400)

    assert %{"approval_policy" => "ask"} =
             :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)

    {:ok, proposal} =
      SalixIM.TaskLabels.propose(
        group_id,
        %{
          "op" => "create",
          "payload" => %{
            "labels" => [
              %{
                "name" => "Invoices",
                "description" => "Add when processing invoices; skip other documents."
              },
              %{
                "name" => "Budgets",
                "description" => "Add when planning budgets; skip unrelated work."
              }
            ]
          }
        },
        %{"agent_id" => workspace["router_agent_id"], "session_id" => "session-labels"}
      )

    resolve_path = path <> "/proposals/#{proposal["id"]}/resolve"

    :post
    |> json_conn(resolve_path, %{"decision" => "approve", "auto_approve" => true})
    |> user_auth(other_session["token"])
    |> call()
    |> expect_json(404)

    :post
    |> json_conn(resolve_path, %{"decision" => "reject", "auto_approve" => true})
    |> user_auth(session["token"])
    |> call()
    |> expect_json(400)

    assert %{
             "approval_policy" => "auto",
             "labels" => approved_labels,
             "proposal" => %{"status" => "approved", "payload" => %{"labels" => created}}
           } =
             :post
             |> json_conn(resolve_path, %{"decision" => "approve", "auto_approve" => true})
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    assert length(approved_labels) == 6
    assert Enum.all?(created, &SalixStore.Ids.valid_task_label_id?(&1["id"]))

    assert %{"approval_policy" => "ask"} =
             :patch
             |> json_conn(path <> "/policy", %{"approval_policy" => "ask"})
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    # Replaying the already approved request cannot restore a revoked grant.
    assert %{"approval_policy" => "ask", "labels" => ^approved_labels} =
             :post
             |> json_conn(resolve_path, %{"decision" => "approve", "auto_approve" => true})
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)
  end

  test "liveness stays healthy while drain rejects readiness and product requests" do
    assert :get |> conn("/live") |> call() |> Map.fetch!(:status) == 200

    Comma.PodLifecycle.begin_drain()

    assert :get |> conn("/live") |> call() |> Map.fetch!(:status) == 200
    assert :get |> conn("/ready") |> call() |> Map.fetch!(:status) == 503
    assert :get |> conn("/v1/comma/admin/users") |> call() |> Map.fetch!(:status) == 503
  end

  test "v1 CORS preflight succeeds before auth" do
    conn =
      :options
      |> conn("/v1/comma/admin/users")
      |> put_req_header("origin", "http://localhost:5173")
      |> put_req_header("access-control-request-method", "GET")
      |> put_req_header("access-control-request-headers", "authorization")
      |> call()

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:5173"]

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "authorization,content-type,if-none-match,range,x-comma-session-transport,x-comma-session-lifecycle-version,x-comma-expected-auth-session-id,x-comma-client,x-comma-client-capabilities,x-comma-app-via,x-comma-app-method,x-comma-app-version"
           ]

    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]

    assert get_resp_header(conn, "access-control-expose-headers") == [
             "accept-ranges,content-range,etag,retry-after,x-comma-bundle-digest,x-comma-app-version"
           ]
  end

  test "v1 CORS rejects every unapproved browser and Electron renderer origin before auth" do
    for origin <- ["https://untrusted.example", "assets://."] do
      conn =
        :options
        |> conn("/v1/comma/auth/email/verify")
        |> put_req_header("origin", origin)
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "x-comma-session-transport")
        |> call()

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "origin_not_allowed"
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      conn =
        :post
        |> json_conn("/v1/comma/auth/email/login", %{"email" => "origin-spam@example.com"})
        |> put_req_header("origin", origin)
        |> call()

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "origin_not_allowed"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "an allowed secondary origin cannot become a second Web Cookie authority" do
    canonical_origin = "http://127.0.0.1:5174"
    secondary_origin = "http://localhost:5173"

    preflight =
      :options
      |> conn("/v1/comma/auth/email/verify")
      |> put_req_header("origin", secondary_origin)
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "x-comma-session-transport")
      |> call()

    assert expect_json(preflight, 403) == %{"error" => "web_cookie_origin_not_allowed"}

    pending =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "secondary-origin@example.com"})
      |> call()
      |> expect_json(200)

    secondary_verify =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => pending["challenge_id"],
        "code" => pending["code"]
      })
      |> web_cookie_request(secondary_origin, :none)
      |> call()

    assert expect_json(secondary_verify, 403) == %{
             "error" => "web_cookie_origin_not_allowed"
           }

    assert secondary_verify.resp_cookies == %{}
    assert {:error, :not_found} = Comma.Accounts.get_user_by_email("secondary-origin@example.com")

    assert %{"user" => %{"email" => "secondary-origin@example.com"}} =
             :post
             |> json_conn("/v1/comma/auth/email/verify", %{
               "challenge_id" => pending["challenge_id"],
               "code" => pending["code"]
             })
             |> web_cookie_request(canonical_origin, :none)
             |> call()
             |> expect_json(200)
  end

  test "Web Session mismatch fences auth consumption, last-seen, product work, and logout" do
    origin = "http://127.0.0.1:5174"
    active = email_login!("web-fence-active@example.com")
    old_last_seen = DateTime.add(SystemsClock.utc_now(), -600) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(session in AuthSession, where: session.id == ^active["session_id"]),
      set: [last_seen_at: old_last_seen, updated_at: old_last_seen]
    )

    pending =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "web-fence-pending@example.com"})
      |> call()
      |> expect_json(200)

    verify_mismatch =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => pending["challenge_id"],
        "code" => pending["code"]
      })
      |> put_req_header(
        "cookie",
        "#{CommaWeb.SessionCookie.cookie_name()}=#{active["token"]}"
      )
      |> web_cookie_request(origin, :none)
      |> call()

    assert expect_json(verify_mismatch, 409) == %{"error" => "session_changed"}
    assert verify_mismatch.resp_cookies == %{}

    assert {:error, :not_found} =
             Comma.Accounts.get_user_by_email("web-fence-pending@example.com")

    assert DateTime.compare(
             Repo.get!(AuthSession, active["session_id"]).last_seen_at,
             old_last_seen
           ) == :eq

    assert %{"token" => _, "session_id" => _} =
             :post
             |> json_conn("/v1/comma/auth/email/verify", %{
               "challenge_id" => pending["challenge_id"],
               "code" => pending["code"]
             })
             |> call()
             |> expect_json(200)

    wrong_session_id = SystemsRuntime.Proc.uuid()

    product_mismatch =
      :post
      |> json_conn("/v1/comma/me/bootstrap", %{})
      |> cookie_auth(active["token"], origin, wrong_session_id)
      |> call()

    assert expect_json(product_mismatch, 409) == %{"error" => "session_changed"}
    assert product_mismatch.resp_cookies == %{}
    assert get_resp_header(product_mismatch, "cache-control") == ["no-store"]

    assert Repo.aggregate(
             from(workspace in Comma.Data.Workspace,
               where: workspace.owner_user_id == ^active["user"]["id"]
             ),
             :count
           ) == 0

    assert DateTime.compare(
             Repo.get!(AuthSession, active["session_id"]).last_seen_at,
             old_last_seen
           ) == :eq

    logout_mismatch =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> cookie_auth(active["token"], origin, wrong_session_id)
      |> call()

    assert expect_json(logout_mismatch, 409) == %{"error" => "session_changed"}
    assert logout_mismatch.resp_cookies == %{}
    assert {:ok, _user, _session} = Comma.Accounts.resolve_session(active["token"])
  end

  test "bearer Session paths do not require or emit the Web cookie protocol" do
    session = email_login!("bearer-hard-cut@example.com")

    assert %{
             "expires_at" => _expires_at,
             "session_id" => session_id,
             "token" => token,
             "user" => %{"email" => "bearer-hard-cut@example.com"}
           } = session

    current_conn =
      :get
      |> conn("/v1/comma/auth/session")
      |> user_auth(token)
      |> call()

    assert %{"session_id" => ^session_id} = expect_json(current_conn, 200)
    assert current_conn.resp_cookies == %{}

    logout_conn =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> user_auth(token)
      |> call()

    assert expect_json(logout_conn, 200) == %{"signed_out" => true}
    assert logout_conn.resp_cookies == %{}

    assert 401 ==
             (:get
              |> conn("/v1/comma/workspaces")
              |> user_auth(token)
              |> call()).status
  end

  test "ops admin auth rejects different-length deployment tokens without raising" do
    for invalid_token <- ["x", @admin_token <> "-longer"] do
      response =
        :get
        |> conn("/v1/comma/admin/users")
        |> put_req_header("authorization", "Bearer #{invalid_token}")
        |> call()

      assert response.halted
      assert response.status == 401
      assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
    end

    assert :get
           |> conn("/v1/comma/admin/users")
           |> admin_auth()
           |> call()
           |> expect_json(200)

    response =
      :get
      |> conn("/v1/admin/vm/worker-release")
      |> admin_auth()
      |> call()

    assert response.halted
    assert response.status == 401
    assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
  end

  test "Comma product endpoint creates a user session and exposes workspace API" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "web@example.com", "name" => "Web"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    body =
      :get
      |> conn("/v1/comma/workspaces")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert [%{"id" => id, "name" => "Workspace"}] = body["data"]
    assert id == workspace["id"]
  end

  test "Comma Main authorizes one exact workspace Agent VMM install target" do
    previous =
      SystemsRuntime.get_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled)

    SystemsRuntime.put_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, true)

    on_exit(fn ->
      restore_env(
        :salix_store,
        :agent_vmm_environment_scoped_bindings_enabled,
        previous
      )
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "compute-#{suffix}@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Compute Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    path =
      "/v1/comma/workspaces/#{workspace["id"]}/compute-nodes/agent-vmm/install-operations"

    created =
      :post
      |> json_conn(path, %{})
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> put_req_header("idempotency-key", "comma-install-#{suffix}")
      |> call()

    body = expect_json(created, 200)
    assert get_resp_header(created, "cache-control") == ["no-store"]
    assert body["operation"]["status"] == "processing"
    assert body["descriptor"]["operation_id"] == body["operation"]["id"]
    assert is_binary(body["descriptor"]["one_time_secret"])

    assert {:error, :no_pending_operation} =
             SalixStore.AgentVMMInstallations.deliver_next(
               "comma_main_device",
               "another-device"
             )

    assert {:ok, delivered} =
             SalixStore.AgentVMMInstallations.deliver_next(
               "comma_main_device",
               session["id"]
             )

    assert delivered.operation.id == body["operation"]["id"]

    fetched =
      :get
      |> conn(path <> "/#{body["operation"]["id"]}")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()

    fetched_body = expect_json(fetched, 200)
    assert get_resp_header(fetched, "cache-control") == ["no-store"]
    refute fetched.resp_body =~ "one_time_secret"
    assert fetched_body["operation"]["delivery_target_id"] == session["id"]
    assert fetched_body["operation"]["work_activity"] == "unknown"

    # A Comma session is valid on the product surface, but never a tenant API key.
    tenant_response =
      :get
      |> conn("/v1/compute-node/work-activity/#{body["operation"]["registration_id"]}")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))

    assert tenant_response.status == 401

    environment =
      SalixStore.Repo.get!(SalixStore.Compute.Environment, body["operation"]["environment_id"])

    assert {:ok, _registration} =
             SalixStore.AgentVMM.create_registration(%{
               id: body["operation"]["registration_id"],
               tenant_id: environment.tenant_id,
               group_id: body["operation"]["group_id"],
               device_id: "activity-device-#{suffix}",
               enrollment_token: SystemsRuntime.Proc.random_bytes(32)
             })

    assert {:ok, _binding} =
             SalixStore.Compute.create_provider_binding(%{
               id: "activity-binding-#{suffix}",
               environment_id: environment.id,
               pool_id: environment.pool_id,
               provider: "agent_vmm",
               provider_ref: body["operation"]["registration_id"]
             })

    activity_response =
      :get
      |> conn(path <> "/#{body["operation"]["id"]}")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert activity_response["operation"]["work_activity"] == "idle"

    other_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    foreign_retry =
      :post
      |> json_conn(path <> "/#{body["operation"]["id"]}/retry", %{})
      |> put_req_header("authorization", "Bearer #{other_session["token"]}")
      |> call()

    assert foreign_retry.status == 404

    foreign_read =
      :get
      |> conn(path <> "/#{body["operation"]["id"]}")
      |> put_req_header("authorization", "Bearer #{other_session["token"]}")
      |> call()

    assert foreign_read.status == 404
    refute foreign_read.resp_body =~ "work_activity"
  end

  test "restricted sessions cannot list or revoke the user's real sessions" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "restricted-session-management@example.com"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    ordinary =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => "wsp_restricted_session_management"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert %{"error" => "forbidden"} =
             :get
             |> conn("/v1/comma/auth/sessions")
             |> user_auth(restricted["token"])
             |> call()
             |> expect_json(403)

    assert %{"error" => "forbidden"} =
             :delete
             |> conn("/v1/comma/auth/sessions/#{ordinary["id"]}")
             |> user_auth(restricted["token"])
             |> call()
             |> expect_json(403)

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn("/v1/comma/auth/sessions/revoke-all", %{})
             |> user_auth(restricted["token"])
             |> call()
             |> expect_json(403)

    assert %{"signed_out" => true} =
             :post
             |> json_conn("/v1/comma/auth/logout", %{})
             |> user_auth(restricted["token"])
             |> call()
             |> expect_json(200)

    assert %{"user" => %{"id" => user_id}} =
             :get
             |> conn("/v1/comma/auth/session")
             |> user_auth(ordinary["token"])
             |> call()
             |> expect_json(200)

    assert user_id == user["id"]
  end

  test "restricted sessions cannot read or mutate global profile state" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "restricted-profile@example.com",
        "name" => "Original"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => "wsp_restricted_profile"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for {method, path, body} <- [
          {:get, "/v1/comma/me/profile", nil},
          {:patch, "/v1/comma/me/profile", %{"name" => "Mutated"}},
          {:put, "/v1/comma/me/avatar", %{}},
          {:get, "/v1/comma/me/avatar/avt_restricted", nil},
          {:delete, "/v1/comma/me/avatar", nil}
        ] do
      request = if body, do: json_conn(method, path, body), else: conn(method, path)

      assert %{"error" => "forbidden"} =
               request
               |> user_auth(restricted["token"])
               |> call()
               |> expect_json(403)
    end

    assert {:ok, profile} = Comma.ProfileAvatar.get(user["id"])
    assert profile["name"] == "Original"
    assert profile["avatar_id"] == nil
  end

  test "Admin user projections expose bounded login-method metadata without provider subjects" do
    assert {:ok, user} =
             Comma.Accounts.create_user(%{
               "email" => "admin-identity@example.com",
               "name" => "Identity Example"
             })

    assert {:ok, _identity} =
             Comma.Accounts.Repository.ensure_identity(user["id"], %{
               provider: "google",
               issuer: "https://accounts.google.com",
               subject: "admin-route-google-subject",
               email_snapshot: "admin-identity@gmail.com",
               email_verified: true,
               last_authenticated_at: ~U[2026-07-25 08:30:00.000000Z]
             })

    detail =
      :get
      |> conn("/v1/comma/admin/users/#{user["id"]}")
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert [
             %{"method" => "email_otp", "email" => "admin-identity@example.com"},
             %{
               "method" => "google",
               "email_snapshot" => "admin-identity@gmail.com",
               "email_verified" => true,
               "linked_at" => linked_at,
               "last_authenticated_at" => last_authenticated_at
             }
           ] = detail["login_methods"]

    assert is_integer(linked_at)
    assert last_authenticated_at == DateTime.to_unix(~U[2026-07-25 08:30:00.000000Z])
    refute inspect(detail) =~ "admin-route-google-subject"
    refute inspect(detail) =~ "accounts.google.com"

    list =
      :get
      |> conn("/v1/comma/admin/users?email=admin-identity%40example.com")
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert [%{"login_methods" => login_methods}] = list["data"]
    assert login_methods == detail["login_methods"]
  end

  test "device checks refresh public readiness through the scoped live connector" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "device-probe@example.com"})
    workspace = create_ready_workspace!(user["id"], "Device checks")
    other = create_additional_ready_workspace!(user["id"], "Other devices")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    outsider = email_login!("device-probe-outsider@example.com")
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    :ok = CommaWeb.TestConvergence.workspace!(other["id"])

    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        %{}
      )

    transport = "device-probe-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    now = SystemsClock.system_time(:millisecond)

    runtime = %{
      "kind" => "external",
      "provider" => "codex",
      "runtime_id" => "runtime",
      "device_runtime_id" => "device-runtime",
      "version" => "1.0.0",
      "version_detected" => true,
      "auth_ready" => true,
      "native_server_startable" => true,
      "ready" => true,
      "readiness_checked_at" => now - 700_000,
      "readiness_valid_until" => now - 1,
      "identity_material" => "/private/codex"
    }

    {:ok, ^transport, record} =
      SalixEnv.Registry.connect(
        to_string(node()),
        %{
          "tenant_id" => workspace["salix_tenant_id"],
          "group_id" => workspace["default_group_id"],
          "device_id" => token["device_id"],
          "connector_id" => token["connector_id"],
          "capabilities" => %{"runtime_probe" => true},
          "agent_runtimes" => [runtime]
        },
        connection_generation: 0,
        credential_generation: token["credential_generation"],
        transport_id: transport
      )

    run_id = record["connector_run_id"]
    test_pid = SystemsRuntime.Proc.self()

    owner =
      SystemsRuntime.Proc.spawn_link(fn ->
        SalixEnv.Bridge.register_owner(transport)
        SystemsRuntime.Proc.send(test_pid, :probe_owner_ready)

        loop = fn loop ->
          SystemsRuntime.Proc.receive do
            {:env_rpc, ref, from, message} ->
              SystemsRuntime.Proc.send(test_pid, {:probe_request, message})

              fresh =
                Map.merge(runtime, %{
                  "readiness_checked_at" => now,
                  "readiness_valid_until" => now + 600_000
                })

              {:ok, _} =
                SalixEnv.Registry.update_meta(run_id, &Map.put(&1, "agent_runtimes", [fresh]))

              SystemsRuntime.Proc.send(
                from,
                {:env_rpc_reply, ref, {:ok, %{"runtimes" => [fresh]}}}
              )

              loop.(loop)

            :stop ->
              :ok
          end
        end

        loop.(loop)
      end)

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(owner), do: SystemsRuntime.Proc.send(owner, :stop)
    end)

    assert_receive :probe_owner_ready
    path = "/v1/comma/workspaces/#{workspace["id"]}/devices/#{token["device_id"]}"
    before = :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)
    assert Enum.find(before["device_runtimes"], &(&1["provider"] == "codex"))["status"] == "stale"

    checked =
      :post
      |> json_conn(path <> "/probe", %{})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert_receive {:probe_request, %{"method" => "runtime_probe", "params" => %{}}}
    codex = Enum.find(checked["device_runtimes"], &(&1["provider"] == "codex"))
    assert codex["status"] == "ready"
    assert codex["readiness_checked_at"] == div(now, 1000)
    refute Map.has_key?(codex, "identity_material")
    refute Map.has_key?(checked, "connector_run_id")

    :post
    |> json_conn(path <> "/probe", %{})
    |> user_auth(outsider["token"])
    |> call()
    |> expect_json(403)

    :post
    |> json_conn("/v1/comma/workspaces/#{other["id"]}/devices/#{token["device_id"]}/probe", %{})
    |> user_auth(session["token"])
    |> call()
    |> expect_json(404)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :post
    |> json_conn(path <> "/probe", %{})
    |> user_auth(restricted["token"])
    |> call()
    |> expect_json(403)

    {:ok, _} = SalixEnv.Registry.update_meta(run_id, &Map.put(&1, "scope", "local_file_read"))

    :post
    |> json_conn(path <> "/probe", %{})
    |> user_auth(session["token"])
    |> call()
    |> expect_json(403)

    {:ok, _} = SalixEnv.Registry.update_meta(run_id, &Map.delete(&1, "scope"))
    {:ok, _} = SalixEnv.Registry.mark_disconnected(run_id)

    :post
    |> json_conn(path <> "/probe", %{})
    |> user_auth(session["token"])
    |> call()
    |> expect_json(503)

    refute_receive {:probe_request, _}
  end

  test "a computer's one access value is set by its owner, the old boolean mapped and Off refused to a connector from before" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "device-access@example.com"})
    workspace = create_ready_workspace!(user["id"], "Device access")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]
    tenant_id = workspace["salix_tenant_id"]
    test_pid = SystemsRuntime.Proc.self()

    # A device whose connector answers `device_access` with `reply`, and tells the test what it was asked.
    device = fn name, owner, capabilities, reply ->
      {:ok, token} =
        SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "meta" => %{"owner_user_id" => owner, "surface" => "comma"}
        })

      transport = "device-access-#{name}-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      {:ok, ^transport, _record} =
        SalixEnv.Registry.connect(
          to_string(node()),
          %{
            "tenant_id" => tenant_id,
            "group_id" => group_id,
            "device_id" => token["device_id"],
            "connector_id" => token["connector_id"],
            "capabilities" => capabilities
          },
          connection_generation: 0,
          credential_generation: token["credential_generation"],
          transport_id: transport
        )

      connector =
        SystemsRuntime.Proc.spawn_link(fn ->
          SalixEnv.Bridge.register_owner(transport)
          SystemsRuntime.Proc.send(test_pid, {:access_owner_ready, name})

          loop = fn loop ->
            SystemsRuntime.Proc.receive do
              {:env_rpc, ref, from, %{"method" => "device_access", "params" => params}} ->
                SystemsRuntime.Proc.send(test_pid, {:access_request, name, params})
                SystemsRuntime.Proc.send(from, {:env_rpc_reply, ref, {:ok, reply.(params)}})
                loop.(loop)

              :stop ->
                :ok
            end
          end

          loop.(loop)
        end)

      on_exit(fn ->
        if SystemsRuntime.Proc.alive?(connector), do: SystemsRuntime.Proc.send(connector, :stop)
      end)

      # Waits for the connector's owner, however long it takes: no real-time bound.
      SystemsRuntime.Proc.receive do
        {:access_owner_ready, ^name} -> :ok
      end

      "/v1/comma/workspaces/#{workspace["id"]}/devices/#{token["device_id"]}"
    end

    # A station that reports its access maps the old boolean itself: false keeps it Off.
    station =
      device.("station", user["id"], %{"tasks" => 2, "access" => "read"}, fn
        %{"access" => access} -> %{"access" => access, "allows_operations" => access == "full"}
        %{"allow_operations" => true} -> %{"access" => "full", "allows_operations" => true}
        %{"allow_operations" => false} -> %{"access" => "off", "allows_operations" => false}
      end)

    go_connector =
      device.("go", user["id"], %{}, fn %{"allow_operations" => allow} ->
        %{"allows_operations" => allow}
      end)

    others = device.("others", "usr_other_member", %{"tasks" => 2, "access" => "full"}, & &1)

    # A PUT returns once the connector replied, and it tells the test before it replies: what it
    # was asked is already in the mailbox.
    put = fn path, body, status ->
      :put
      |> json_conn(path <> "/access", body)
      |> user_auth(session["token"])
      |> call()
      |> expect_json(status)
    end

    shown = :get |> conn(station) |> user_auth(session["token"]) |> call() |> expect_json(200)
    assert shown["access"] == "read"

    assert put.(station, %{"access" => "off"}, 200) == %{
             "access" => "off",
             "allows_operations" => false
           }

    assert_received {:access_request, "station", %{"access" => "off"}}

    assert put.(station, %{"allow_operations" => false}, 200) == %{
             "access" => "off",
             "allows_operations" => false
           }

    assert_received {:access_request, "station", %{"allow_operations" => false}}

    assert put.(station, %{"access" => "all"}, 400) == %{
             "error" => "access must be off, read or full"
           }

    # A connector from before has two levels: Read and Full go as the boolean, Off changes nothing.
    assert put.(go_connector, %{"access" => "read"}, 200) == %{
             "access" => "read",
             "allows_operations" => false
           }

    assert_received {:access_request, "go", %{"allow_operations" => false}}

    assert put.(go_connector, %{"allow_operations" => true}, 200) == %{
             "access" => "full",
             "allows_operations" => true
           }

    assert_received {:access_request, "go", %{"allow_operations" => true}}
    assert put.(go_connector, %{"access" => "off"}, 400) == %{"error" => "device_needs_station"}

    # Only the computer's owner sets it, the Workspace's owner included.
    put.(others, %{"access" => "off"}, 403)
    refute_received {:access_request, _, _}
  end

  test "device names survive reconnect and deletion removes only the selected workspace device" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "device-manage@example.com"})
    workspace = create_ready_workspace!(user["id"], "Device management")
    {:ok, other_user} = Comma.Accounts.create_user(%{"email" => "other-devices@example.com"})
    other = create_ready_workspace!(other_user["id"], "Other devices")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    :ok = CommaWeb.TestConvergence.workspace!(other["id"])

    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        %{}
      )

    {:ok, retained} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        %{}
      )

    path = "/v1/comma/workspaces/#{workspace["id"]}/devices/#{token["device_id"]}"

    assert {:ok, _, _} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => token["device_id"],
                 "connector_id" => token["connector_id"],
                 "name" => "Default workspace Connector",
                 "system_info" => %{"hostname" => "office-mini"}
               },
               connection_generation: 0,
               credential_generation: token["credential_generation"],
               transport_id: "device-name-test"
             )

    discovered = :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)
    assert discovered["name"] == "office-mini"

    for method <- [:put, :delete] do
      method
      |> json_conn("/v1/comma/workspaces/#{other["id"]}/devices/#{token["device_id"]}", %{
        "name" => "Wrong workspace"
      })
      |> user_auth(session["token"])
      |> call()
      |> expect_json(403)
    end

    :put
    |> json_conn(path, %{"name" => "  "})
    |> user_auth(session["token"])
    |> call()
    |> expect_json(400)

    renamed =
      :put
      |> json_conn(path, %{"name" => "  Office Mac  "})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert renamed["name"] == "Office Mac"

    assert {:ok, _, connected} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => token["device_id"],
                 "connector_id" => token["connector_id"],
                 "name" => "Old hostname",
                 "system_info" => %{"hostname" => "new-hostname"}
               },
               connection_generation: 1,
               credential_generation: token["credential_generation"],
               transport_id: "device-manage-test"
             )

    {:ok, _} = SalixEnv.Registry.mark_disconnected(connected["connector_run_id"])
    detail = :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)
    assert detail["name"] == "Office Mac"

    assert {:ok, _, reconnected} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => token["device_id"],
                 "connector_id" => token["connector_id"],
                 "name" => "Old hostname",
                 "system_info" => %{"hostname" => "new-hostname"}
               },
               connection_generation: 2,
               credential_generation: token["credential_generation"],
               transport_id: "device-manage-reconnect"
             )

    assert SalixEnv.Control.environment_json(reconnected)["name"] == "Office Mac"

    assert %{"removed" => true} =
             :delete |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)

    :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(404)
    {:ok, _, credential} = SalixEnv.ConnectorTokens.validate_connector_token(token["token"])
    refute SalixEnv.ConnectorTokens.credential_active?(credential["token_hash"])

    assert {:error, :not_found} =
             SalixEnv.Registry.get_by_connector_run_id(reconnected["connector_run_id"])

    assert {:ok, _} =
             SalixEnv.Registry.get_device(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               retained["device_id"]
             )
  end

  test "Settings devices list the user's own computers and the Cloud VM apart" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "own-devices@example.com"})
    workspace = create_ready_workspace!(user["id"], "Own devices")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]
    tenant_id = workspace["salix_tenant_id"]

    mint = fn meta ->
      {:ok, token} =
        SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "meta" => meta
        })

      token
    end

    connect = fn token, capabilities ->
      {:ok, _transport, device} =
        SalixEnv.Registry.connect(
          to_string(node()),
          %{
            "tenant_id" => tenant_id,
            "group_id" => group_id,
            "device_id" => token["device_id"],
            "connector_id" => token["connector_id"],
            "capabilities" => capabilities
          },
          connection_generation: 1,
          credential_generation: token["credential_generation"],
          transport_id: "own-devices-" <> token["device_id"]
        )

      device
    end

    own = %{"owner_user_id" => user["id"], "surface" => "comma"}
    station = %{"tasks" => 2, "task_models" => %{"codex" => ["gpt-5.5", "gpt-5.4-mini"]}}
    ready = mint.(own) |> connect.(station)
    # The station its Connector proved it runs (`relay_register`).
    station_id = String.duplicate("ab", 32)

    {:ok, _} =
      SalixEnv.Registry.update_meta(
        ready["connector_run_id"],
        &Map.put(&1, "station_id", station_id)
      )

    outdated = mint.(own) |> connect.(%{"tasks" => 1})
    old_connector = mint.(own) |> connect.(%{})
    offline = mint.(own) |> connect.(station)
    {:ok, _} = SalixEnv.Registry.mark_disconnected(offline["connector_run_id"])
    mine = Enum.map([ready, outdated, old_connector, offline], & &1["device_id"])
    _install_command_never_used = mint.(own)["device_id"]

    _other_member =
      mint.(%{"owner_user_id" => "usr_other_member", "surface" => "comma"}) |> connect.(%{})

    cloud =
      mint.(%{})
      |> connect.(%{"tasks" => 2, "task_models" => %{"claude" => ["opus"]}})
      |> Map.fetch!("device_id")

    {:ok, _, :created} =
      SalixStore.Compute.ensure_group_workload(%{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => cloud,
        "connector_id" => "connector-" <> group_id,
        "env_id" => "env-" <> group_id,
        "provider" => "cloudflare",
        "provider_resource_name" => "own-devices-vm",
        "status" => "ready"
      })

    read = fn query ->
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices?" <> URI.encode_query(query))
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)
    end

    first = read.(%{"limit" => 3})
    assert first["cloud_vm"]["device_id"] == cloud
    assert first["cloud_vm"]["tasks_readiness"] == "ready"
    assert first["cloud_vm"]["task_models"] == %{"claude" => ["opus"]}
    assert length(first["devices"]) == 3
    assert is_binary(first["next_cursor"])

    rest = read.(%{"limit" => 3, "cursor" => first["next_cursor"]})
    assert rest["cloud_vm"] == nil
    assert rest["next_cursor"] == nil

    listed = Map.new(first["devices"] ++ rest["devices"], &{&1["device_id"], &1})
    assert Enum.sort(Map.keys(listed)) == Enum.sort(mine)

    # Each row says whether the computer takes Tasks and which models its
    # station runs, from the same page read.
    assert %{
             "tasks_readiness" => "ready",
             "task_models" => %{"codex" => ["gpt-5.5", _]},
             "station_id" => ^station_id
           } = listed[ready["device_id"]]

    refute Map.has_key?(listed[old_connector["device_id"]], "station_id")

    assert Map.take(listed[outdated["device_id"]], ~w(tasks_readiness task_models)) ==
             %{"tasks_readiness" => "station_outdated", "task_models" => %{}}

    assert Map.take(listed[old_connector["device_id"]], ~w(tasks_readiness task_models)) ==
             %{"tasks_readiness" => "device_needs_station", "task_models" => %{}}

    assert listed[offline["device_id"]]["tasks_readiness"] == "offline"

    get = fn device ->
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices/#{device["device_id"]}")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)
    end

    assert %{"tasks_readiness" => "ready", "task_models" => %{"codex" => ["gpt-5.5", _]}} =
             get.(ready)

    assert get.(outdated)["tasks_readiness"] == "station_outdated"
    assert get.(offline)["tasks_readiness"] == "offline"

    :get
    |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices?cursor=not%2Fa%2Fcursor")
    |> user_auth(session["token"])
    |> call()
    |> expect_json(400)
  end

  test "the duplicate device cleanup keeps each machine's online and most recently seen devices" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "duplicate-devices@example.com"})
    workspace = create_ready_workspace!(user["id"], "Duplicate devices")
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]
    tenant_id = workspace["salix_tenant_id"]
    day = 24 * 60 * 60 * 1000
    now = SystemsClock.system_time(:millisecond)

    device = fn owner, hostname, seen_days_ago, online? ->
      {:ok, token} =
        SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "meta" => %{"owner_user_id" => owner}
        })

      {:ok, _transport, record} =
        SalixEnv.Registry.connect(
          to_string(node()),
          %{
            "tenant_id" => tenant_id,
            "group_id" => group_id,
            "device_id" => token["device_id"],
            "connector_id" => token["connector_id"],
            "os" => "darwin",
            "arch" => "arm64",
            "system_info" => %{"hostname" => hostname, "client_source" => "comma"}
          },
          connection_generation: 1,
          credential_generation: token["credential_generation"],
          transport_id: "duplicate-" <> token["device_id"],
          now: now - seen_days_ago * day
        )

      unless online? do
        {:ok, _} =
          SalixEnv.Registry.mark_disconnected(record["connector_run_id"],
            now: now - seen_days_ago * day
          )
      end

      token
    end

    # Studio: an online device and three offline ones, one of them newer than
    # it was seen. The laptop: two offline devices.
    online = device.(user["id"], "studio.local", 20, true)

    studio_offline = [
      device.(user["id"], "studio.local", 2, false),
      device.(user["id"], "Studio.local", 11, false),
      device.(user["id"], "studio.local", 10, false)
    ]

    laptop_old = device.(user["id"], "laptop.local", 9, false)
    laptop_new = device.(user["id"], "laptop.local", 3, false)
    # Another owner on the same hostname, and devices that reported no hostname.
    other_owner = device.(user["id"] <> "-other", "studio.local", 30, false)
    unnamed = [device.(user["id"], "", 40, false), device.(user["id"], "", 1, false)]

    assert {:ok, %{removed: 4, failed: 0}} = Comma.Devices.DuplicateCleanup.run(Repo)

    present? = fn token ->
      match?({:ok, _}, SalixEnv.Registry.get_device(tenant_id, group_id, token["device_id"]))
    end

    old = [laptop_old | studio_offline]
    refute Enum.any?(old, present?)

    for kept <- [online, laptop_new, other_owner | unnamed] do
      assert present?.(kept)
    end

    # A removed device's credential is revoked as by Settings removal.
    for token <- old do
      assert {:error, _} =
               SalixEnv.Registry.connect(
                 to_string(node()),
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => token["device_id"],
                   "connector_id" => token["connector_id"]
                 },
                 credential_generation: token["credential_generation"],
                 transport_id: "duplicate-again-" <> token["device_id"]
               )
    end

    assert {:ok, %{removed: 0}} = Comma.Devices.DuplicateCleanup.run(Repo)
  end

  test "Comma user session mints a scoped attachment connector token and revokes it" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "scoped-connector@example.com",
        "name" => "Scoped"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Scoped Connector Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    token =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
        "expires_in_seconds" => 7_200,
        "scope" => "local_file_read"
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert token["scope"] == "local_file_read"
    assert "salix_conn_" <> _ = token["token"]
    assert "dev_" <> _ = token["device_id"]
    assert is_integer(token["credential_generation"])
    now = SystemsClock.system_time(:second)
    assert_in_delta token["expires_at"], now + 7_200, 60

    # The stored device identity re-attaches only after the registry proves
    # continuity for this owner. The run carries the credential's own
    # connector identity so a later revocation is fenced to exactly this run.
    assert {:ok, _transport_id, _device} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => token["device_id"],
                 "connector_id" => token["connector_id"],
                 "owner_user_id" => user["id"],
                 "scope" => "local_file_read",
                 "credential_generation" => token["credential_generation"]
               },
               connection_generation: 1,
               credential_generation: token["credential_generation"],
               token_expires_at: token["expires_at"],
               transport_id: "comma-scoped-endpoint-test"
             )

    page =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices?limit=20")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert [visible] = page["devices"]
    assert visible["device_id"] == token["device_id"]
    assert visible["allows_operations"] == false
    refute Map.has_key?(visible, "connector_run_id")
    refute Map.has_key?(visible, "token")

    detail =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices/#{token["device_id"]}")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert detail["device_id"] == visible["device_id"]

    {:ok, full_token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        %{}
      )

    assert {:ok, _, _} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => full_token["device_id"],
                 "connector_id" => full_token["connector_id"],
                 "owner_user_id" => user["id"],
                 "capabilities" => %{"scope" => ""}
               },
               connection_generation: 1,
               credential_generation: full_token["credential_generation"],
               transport_id: "comma-full-device-read-test"
             )

    full_device =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices/#{full_token["device_id"]}")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert full_device["allows_operations"] == true

    :get
    |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices?limit=51")
    |> put_req_header("authorization", "Bearer #{session["token"]}")
    |> call()
    |> expect_json(400)

    reissued =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
        "scope" => "local_file_read",
        "stable_device_id" => token["device_id"]
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert reissued["device_id"] == token["device_id"]

    assert %{"revoked" => true} =
             :delete
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
               "token" => token["token"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(200)

    assert {:error, :unauthorized} =
             SalixEnv.ConnectorTokens.validate_connector_token(token["token"])

    assert {:ok, device} =
             SalixEnv.Registry.get_device(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               token["device_id"]
             )

    assert device["status"] == "disconnected"

    # The second credential still validates: revocation is per token.
    assert {:ok, _tenant, _rec} =
             SalixEnv.ConnectorTokens.validate_connector_token(reissued["token"])
  end

  test "direct installation uses workspace authorization without Drive setup" do
    root =
      Path.join(
        System.tmp_dir!(),
        "comma-api-install-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    for platform <- SalixStore.ConnectorInstall.platforms() do
      File.mkdir_p!(Path.join(root, platform))
      File.write!(Path.join([root, platform, "salix-connect"]), "fixture")
    end

    old = SystemsRuntime.get_env(:salix_env, :device_install_local_artifact_root)
    SystemsRuntime.put_env(:salix_env, :device_install_local_artifact_root, root)

    on_exit(fn ->
      if old,
        do: SystemsRuntime.put_env(:salix_env, :device_install_local_artifact_root, old),
        else: SystemsRuntime.delete_env(:salix_env, :device_install_local_artifact_root)

      File.rm_rf!(root)
    end)

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "direct-install@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Direct installation")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    token =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
        "installation" => true,
        "name" => "My computer"
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert is_binary(token["install_command"])
    refute token["install_command"] =~ "\n"
    assert token["install_command"] =~ "/v1/device-connection/install.sh' | sh"
    assert is_nil(token["expires_at"])
    assert token["registration_expires_at"] > SystemsClock.system_time(:second)
    {:ok, _, record} = SalixEnv.ConnectorTokens.validate_connector_token(token["token"])
    assert record["meta"]["owner_user_id"] == user["id"]
    assert record["group_id"] == workspace["default_group_id"]

    :post
    |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
      "installation" => true
    })
    |> call()
    |> expect_json(401)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_ids" => [workspace["id"]]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :post
    |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
      "installation" => true
    })
    |> put_req_header("authorization", "Bearer #{restricted["token"]}")
    |> call()
    |> expect_json(403)
  end

  test "Comma user session mints a workspace connector token and bootstraps Salix scope" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "connector@example.com",
        "name" => "Conn"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Connector Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    tenant_id = workspace["salix_tenant_id"]

    token =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{"alias" => "mac"})
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert "salix_conn_" <> _ = token["token"]
    assert token["server"] =~ "ws://"
    assert token["alias"] == "mac"
    refute Map.has_key?(token, "tenant_id")
    refute Map.has_key?(token, "group_id")
    refute Map.has_key?(token, "token_hash")
    assert is_nil(token["registration_expires_at"])

    enrolling =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
        "name" => "T-Circle",
        "registration_expires_in_seconds" => 600
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert is_nil(enrolling["expires_at"])
    # Without an alias of its own the device's tool-facing alias is its name.
    assert enrolling["alias"] == "T-Circle"

    assert_in_delta enrolling["registration_expires_at"],
                    SystemsClock.system_time(:second) + 600,
                    60

    # Removing the device in settings fences its credential: a device paired
    # from another phone cannot reconnect with the token it still holds.
    {:ok, _tenant, enrolling_record} =
      SalixEnv.ConnectorTokens.validate_connector_token(enrolling["token"])

    connect_enrolling = fn transport_id ->
      SalixEnv.Registry.connect(
        to_string(node()),
        %{
          "tenant_id" => tenant_id,
          "group_id" => workspace["default_group_id"],
          "device_id" => enrolling["device_id"],
          "connector_id" => enrolling["connector_id"],
          "owner_user_id" => user["id"],
          "credential_generation" => enrolling["credential_generation"]
        },
        credential_generation: enrolling["credential_generation"],
        registration_token_hash: enrolling_record["token_hash"],
        transport_id: transport_id
      )
    end

    assert {:ok, _transport_id, _device} = connect_enrolling.("comma-enrolling-1")

    assert %{"removed" => true} =
             :delete
             |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices/#{enrolling["device_id"]}")
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(200)

    assert {:error, :connector_credential_revoked} = connect_enrolling.("comma-enrolling-2")

    assert {:error, :not_found} =
             SalixEnv.Registry.get_device(
               tenant_id,
               workspace["default_group_id"],
               enrolling["device_id"]
             )

    assert {:ok, _} = Salix.Control.Tenants.get(workspace["salix_tenant_id"])

    assert {:ok, group} =
             Salix.Control.Groups.get(
               workspace["default_group_id"],
               workspace["salix_tenant_id"]
             )

    assert group["router_agent_id"] == workspace["router_agent_id"]

    assert {:ok, %{"role" => "router", "group_id" => group_id}} =
             SalixAgent.Control.get(
               group["router_agent_id"],
               workspace["salix_tenant_id"]
             )

    assert group_id == workspace["default_group_id"]

    assert {:ok, legacy_token} =
             SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
               "name" => "Legacy ownerless Connector"
             })

    assert {:ok, _legacy_tenant_id, legacy_rec} =
             SalixEnv.ConnectorTokens.validate_connector_token(legacy_token["token"])

    assert {:ok, _transport_id, _legacy_device} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "device_id" => legacy_rec["device_id"],
                 "connector_id" => legacy_rec["connector_id"],
                 "capabilities" => %{"local_file_import_v1" => true}
               },
               connection_generation: 1,
               transport_id: "comma-ownerless-upgrade-test"
             )

    legacy_ref =
      "lfi1_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

    assert %{
             "action" => "reissue_connector_token",
             "connector_token_endpoint" => connector_token_endpoint,
             "error" => "connector_reconfiguration_required",
             "reason" => "connector_owner_missing"
           } =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "local_file_ref" => legacy_ref,
               "stable_device_id" => legacy_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(409)

    assert connector_token_endpoint ==
             "/v1/comma/workspaces/#{workspace["id"]}/connector-token"

    # A new Workspace has only its Router; the Router creates Workers.
    assert workspace["default_worker_agent_id"] == nil

    assert :ok = CommaWeb.SalixClient.provision_workspace_scope(workspace)
    assert :ok = CommaWeb.SalixClient.verify_workspace_scope(workspace)

    assert [%{"role" => "router", "group_id" => ^group_id}] =
             SalixAgent.Control.list(workspace["salix_tenant_id"],
               group_id: workspace["default_group_id"]
             )

    assert {:ok, ^tenant_id, connector_rec} =
             SalixEnv.ConnectorTokens.validate_connector_token(token["token"])

    assert connector_rec["meta"]["owner_user_id"] == user["id"]

    assert {:ok, _transport_id, legacy_reader_device} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => tenant_id,
                 "group_id" => workspace["default_group_id"],
                 "device_id" => connector_rec["device_id"],
                 "connector_id" => connector_rec["connector_id"],
                 "owner_user_id" => user["id"],
                 "capabilities" => %{"local_file_import_v1" => true}
               },
               connection_generation: 9,
               transport_id: "comma-local-file-registration-test"
             )

    legacy_registration_ref =
      "lfi1_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

    assert %{"error" => "invalid_local_file_ref"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "local_file_ref" => legacy_registration_ref,
               "path" => "/Users/owner/secret.txt",
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(400)

    assert %{"error" => "invalid_local_file_ref"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => legacy_reader_device["connector_run_id"],
               "local_file_ref" => legacy_registration_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(400)

    assert %{"error" => "invalid_local_file_ref"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => legacy_reader_device["connector_run_id"],
               "local_file_index_version" => 3,
               "local_file_ref" => legacy_registration_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(400)

    assert %{"error" => "invalid_local_file_ref"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => legacy_reader_device["connector_run_id"],
               "extra" => true,
               "local_file_index_version" => 2,
               "local_file_ref" => legacy_registration_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(400)

    legacy_registration =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
        "local_file_ref" => legacy_registration_ref,
        "stable_device_id" => connector_rec["device_id"]
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert legacy_registration == %{
             "local_file_ref" => legacy_registration_ref,
             "state" => "registered"
           }

    old_run_id = legacy_reader_device["connector_run_id"]

    assert {:ok, _old_v2_reader} =
             SalixEnv.Registry.update_meta(old_run_id, fn meta ->
               Map.put(meta, "capabilities", %{
                 "local_file_import_v1" => true,
                 "local_file_index_version" => 2
               })
             end)

    assert {:ok, _transport_id, replacement_reader_device} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => tenant_id,
                 "group_id" => workspace["default_group_id"],
                 "device_id" => connector_rec["device_id"],
                 "connector_id" => connector_rec["connector_id"],
                 "owner_user_id" => user["id"]
               },
               connection_generation: 10,
               transport_id: "comma-local-file-replacement-registration-test"
             )

    replacement_run_id = replacement_reader_device["connector_run_id"]
    refute replacement_run_id == old_run_id

    # The Registry merge can temporarily preserve the old run's V2 metadata.
    # A private status file for that old run must still fail the exact-run gate.
    assert get_in(replacement_reader_device, [
             "meta",
             "capabilities",
             "local_file_index_version"
           ]) == 2

    stale_status_ref =
      "lfi1_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

    assert %{"error" => "local_file_ref_unavailable"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => old_run_id,
               "local_file_index_version" => 2,
               "local_file_ref" => stale_status_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(503)

    assert {:error, :not_found} = SalixStore.LocalFileRefs.get(stale_status_ref)

    assert {:ok, _current_legacy_reader} =
             SalixEnv.Registry.update_meta(replacement_run_id, fn meta ->
               Map.put(meta, "capabilities", %{"local_file_import_v1" => true})
             end)

    current_status_ref =
      "lfi1_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

    assert %{"error" => "local_file_ref_unavailable"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => replacement_run_id,
               "local_file_index_version" => 2,
               "local_file_ref" => current_status_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(503)

    assert {:error, :not_found} = SalixStore.LocalFileRefs.get(current_status_ref)

    assert {:ok, _current_v2_reader} =
             SalixEnv.Registry.update_meta(replacement_run_id, fn meta ->
               Map.put(meta, "capabilities", %{
                 "local_file_import_v1" => true,
                 "local_file_index_version" => 2
               })
             end)

    registration =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
        "connector_run_id" => replacement_run_id,
        "local_file_index_version" => 2,
        "local_file_ref" => current_status_ref,
        "stable_device_id" => connector_rec["device_id"]
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert registration == %{
             "local_file_ref" => current_status_ref,
             "state" => "registered"
           }

    refute Map.has_key?(registration, "owner_user_id")
    refute Map.has_key?(registration, "stable_device_id")

    # A recording attachment belongs to the authenticated person, not the
    # Router's historical shared participant named "current".
    chat =
      :post
      |> json_conn("/v1/comma/groups/#{group_id}/assistant-chat", %{})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert {:ok, _grant} =
             BillingCore.Credits.issue_grant(%{
               repo: BillingCore.Repo,
               billing_account_id: "comma-ba-#{workspace["id"]}",
               credits: 100,
               valid_from: DateTime.add(SystemsClock.utc_now(), -60, :second),
               expires_at: DateTime.add(SystemsClock.utc_now(), 3600, :second),
               source_type: "manual_contract",
               source_id: current_status_ref,
               source_event_id: current_status_ref,
               idempotency_key: current_status_ref
             })

    summary_request = %{
      "client_request_id" => "recording-summary-#{current_status_ref}",
      "message" => %{
        "content" => [
          %{"type" => "text", "text" => "Summarize this meeting in a Task."},
          %{
            "type" => "local_file",
            "local_file_ref" => current_status_ref,
            "display_name" => "meeting.m4a",
            "media_type" => "audio/mp4",
            "size" => 334_562
          }
        ]
      }
    }

    :post
    |> json_conn(
      "/v1/comma/groups/#{group_id}/conversations/#{chat["id"]}/messages",
      summary_request
    )
    |> user_auth(session["token"])
    |> call()
    |> expect_json(202)

    assert {:ok, route} = SalixStore.LocalFileRefs.get(current_status_ref)
    assert route["state"] == "bound"
    assert route["owner_user_id"] == user["id"]
  end

  test "Chat ensure follows a rotated Salix Group Router without rolling it back" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "router-rotation@example.com",
        "name" => "Router Rotation"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Rotated Router Workspace")

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    original_router_id = workspace["router_agent_id"]
    rotated_router_id = SalixStore.Ids.new_agent_id(group_id)

    assert {:ok, _router} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "name" => "Rotated Router",
                 "role" => "router",
                 "purpose" => "router_rotation_regression"
               },
               tenant_id,
               rotated_router_id
             )

    assert {:ok, _group} =
             Salix.Control.Groups.update(
               group_id,
               %{"router_agent_id" => rotated_router_id},
               tenant_id
             )

    assert {:ok, resolved_workspace} = CommaWeb.SalixClient.resolve_workspace_scope(workspace)
    assert resolved_workspace["router_agent_id"] == rotated_router_id
    assert workspace["router_agent_id"] == original_router_id

    assert :ok = CommaWeb.SalixClient.provision_workspace_scope(workspace)

    assert {:error, :workspace_scope_conflict} =
             CommaWeb.SalixClient.verify_workspace_scope(workspace)

    assert {:ok, group_after_provision_retry} =
             Salix.Control.Groups.get(group_id, tenant_id)

    assert group_after_provision_retry["router_agent_id"] == rotated_router_id

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    chat =
      :post
      |> json_conn("/v1/comma/groups/#{group_id}/assistant-chat", %{})
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert chat["group_id"] == group_id
    assert chat["status"] == "active"

    assert {:ok, group} = Salix.Control.Groups.get(group_id, tenant_id)
    assert group["router_agent_id"] == rotated_router_id
    refute group["router_agent_id"] == original_router_id

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               chat["id"],
               limit: 50
             )

    assert Enum.any?(participants, fn participant ->
             participant["actor_type"] == "agent" and
               participant["agent_id"] == rotated_router_id and
               participant["state"] == "active"
           end)

    refute Enum.any?(participants, fn participant ->
             participant["actor_type"] == "agent" and
               participant["agent_id"] == original_router_id
           end)
  end

  test "Comma workspace VM mutation is durable and never performs provider I/O inline" do
    SystemsRuntime.put_env(:comma_core, :salix_client, __MODULE__.RecordingSalixClient)
    SystemsRuntime.put_env(:comma_core, :salix_client_test_pid, SystemsRuntime.Proc.self())

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "vm@example.com", "name" => "VM"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "VM Workspace")

    assert_receive {:provision_workspace_scope, %{"id" => workspace_id}}
    assert workspace_id == workspace["id"]

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    other_user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "vm-other@example.com",
        "name" => "Other"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    other_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{other_user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace_s3_keys =
      MapSet.new([
        "comma/workspaces/#{workspace["id"]}",
        "comma/user_workspaces/#{user["id"]}",
        SalixStore.Keys.ctl_group(workspace["default_group_id"])
      ])

    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = SalixStore.S3.Fake.reset_read_log()

    # The fake log is process-global. Keep unrelated traffic in the observation
    # window so this guard cannot regress to asserting global log emptiness.
    assert {:error, :not_found} =
             SalixStore.S3.Fake.get("ctl/groups/unrelated-vm-guard.json", [])

    forbidden =
      :patch
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}", %{
        "vm" => %{"enabled" => true, "provider" => "cloudflare"}
      })
      |> put_req_header("authorization", "Bearer #{other_session["token"]}")
      |> call()
      |> expect_json(403)

    assert forbidden == %{"error" => "forbidden"}

    updated =
      :patch
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}", %{
        "vm" => %{"enabled" => true, "provider" => "cloudflare", "recreate" => true}
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert updated["vm"] == %{"enabled" => true, "provider" => "cloudflare"}
    refute_receive {:update_workspace_vm, _, _}

    operation =
      Repo.get_by!(Comma.Data.ExternalOperation,
        operation_type: "workspace_convergence",
        owner_id: workspace["id"],
        generation: 2
      )

    assert operation.status == "pending"
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    assert_receive {:update_workspace_vm, %{"id" => ^workspace_id},
                    %{"enabled" => true, "provider" => "cloudflare", "recreate" => true}}

    renamed =
      :patch
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}", %{"name" => "Renamed Workspace"})
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert renamed["name"] == "Renamed Workspace"
    assert Repo.get!(Comma.Data.Workspace, workspace["id"]).name == "Renamed Workspace"

    refute Enum.any?(
             SalixStore.S3.Fake.put_log(),
             &MapSet.member?(workspace_s3_keys, &1)
           )

    refute Enum.any?(SalixStore.S3.Fake.read_log(), fn
             {_operation, key} -> MapSet.member?(workspace_s3_keys, key)
             _other -> false
           end)
  end

  test "Comma user session manages the workspace's inbound API keys" do
    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")
    prev_public_base_url = SystemsRuntime.get_env(:salix_web, :public_base_url)
    SystemsRuntime.put_env(:salix_web, :public_base_url, "https://api.comma.example/")

    on_exit(fn ->
      if prev_public_base_url == nil,
        do: SystemsRuntime.delete_env(:salix_web, :public_base_url),
        else: SystemsRuntime.put_env(:salix_web, :public_base_url, prev_public_base_url)
    end)

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "inbound-api@example.com",
        "name" => "Inbound"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Inbound API Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    path = "/v1/comma/workspaces/#{workspace["id"]}/router-api-keys"
    auth = &put_req_header(&1, "authorization", "Bearer #{session["token"]}")

    assert [] = conn(:get, path) |> auth.() |> call() |> expect_json(200)

    created =
      :post
      |> json_conn(path, %{"name" => "Zendesk"})
      |> auth.()
      |> call()
      |> expect_json(201)

    assert "salix_gk_" <> _ = created["key"]
    assert created["name"] == "Zendesk"
    assert created["status"] == "active"
    # The key acts as this user under information-flow checking, and the
    # Salix ids never reach the client.
    assert created["created_by"] == "comma_user:" <> user["id"]
    refute Map.has_key?(created, "key_hash")
    refute Map.has_key?(created, "tenant_id")
    refute Map.has_key?(created, "group_id")

    assert {:ok, %{"group_id" => group_id}} =
             Salix.Control.GroupApiKeys.validate(created["key"])

    assert group_id == workspace["default_group_id"]

    # What the client shows is a ready-to-use posting URL on the externally
    # reachable Salix base, since the group id itself never leaves the server.
    assert created["post_message_url"] ==
             "https://api.comma.example/v1/agent-groups/#{group_id}/router/post-message"

    assert [listed] = conn(:get, path) |> auth.() |> call() |> expect_json(200)
    assert listed["key_id"] == created["key_id"]
    assert listed["post_message_url"] == created["post_message_url"]
    refute Map.has_key?(listed, "key")

    updated =
      :patch
      |> json_conn(path <> "/" <> created["key_id"], %{"name" => "Jira", "status" => "disabled"})
      |> auth.()
      |> call()
      |> expect_json(200)

    assert updated["name"] == "Jira"
    assert updated["status"] == "disabled"
    assert {:error, :unauthorized} = Salix.Control.GroupApiKeys.validate(created["key"])

    assert %{"error" => _} =
             :patch
             |> json_conn(path <> "/" <> created["key_id"], %{"status" => "weird"})
             |> auth.()
             |> call()
             |> expect_json(400)

    assert %{"error" => "not_found"} =
             :patch
             |> json_conn(path <> "/gak_missing", %{"name" => "x"})
             |> auth.()
             |> call()
             |> expect_json(404)

    # Another user's session cannot see or touch this workspace's keys.
    stranger =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "stranger-inbound@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    stranger_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{stranger["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    stranger_status =
      conn(:get, path)
      |> put_req_header("authorization", "Bearer #{stranger_session["token"]}")
      |> call()
      |> Map.fetch!(:status)

    assert stranger_status in [403, 404]

    assert %{"deleted" => true} =
             conn(:delete, path <> "/" <> created["key_id"])
             |> auth.()
             |> call()
             |> expect_json(200)

    assert [] = conn(:get, path) |> auth.() |> call() |> expect_json(200)

    # A restricted session is refused, as it is for connector tokens.
    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn(path, %{"name" => "Nope"})
             |> put_req_header("authorization", "Bearer #{restricted["token"]}")
             |> call()
             |> expect_json(403)
  end

  # A local stand-in for the Twilio Verify API: `246810` is the only code it
  # approves. Every request is reported to the test process.
  defmodule TwilioVerifyStub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      form = URI.decode_query(body)

      if pid = SystemsRuntime.PersistentTerm.get({__MODULE__, :test_pid}, nil),
        do: SystemsRuntime.Proc.send(pid, {:twilio_verify, conn.request_path, form})

      reply =
        if String.ends_with?(conn.request_path, "/VerificationCheck") do
          %{"status" => if(form["Code"] == "246810", do: "approved", else: "pending")}
        else
          %{"status" => "pending"}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(reply))
    end
  end

  test "Comma user session verifies voice caller numbers and manages voice agent keys" do
    prev_public_base_url = SystemsRuntime.get_env(:salix_web, :public_base_url)
    prev_verify_base_url = SystemsRuntime.get_env(:salix_web, :twilio_verify_base_url)
    SystemsRuntime.put_env(:salix_web, :public_base_url, "https://api.comma.example/")

    twilio =
      start_supervised!(
        {Bandit, plug: TwilioVerifyStub, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, twilio_port}} = ThousandIsland.listener_info(twilio)
    SystemsRuntime.put_env(:salix_web, :twilio_verify_base_url, "http://127.0.0.1:#{twilio_port}")
    SystemsRuntime.PersistentTerm.put({TwilioVerifyStub, :test_pid}, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.PersistentTerm.erase({TwilioVerifyStub, :test_pid})
      _ = SalixStore.S3.delete(SalixStore.Keys.ctl_system_voice())

      for {key, prev} <- [
            public_base_url: prev_public_base_url,
            twilio_verify_base_url: prev_verify_base_url
          ] do
        if prev == nil,
          do: SystemsRuntime.delete_env(:salix_web, key),
          else: SystemsRuntime.put_env(:salix_web, key, prev)
      end
    end)

    line = "+15550001111"

    assert {:ok, _settings} =
             SalixVoice.Settings.update(%{
               "enabled" => true,
               "twilio_account_sid" => "AC_test",
               "twilio_auth_token" => "twilio-auth-secret",
               "twilio_verify_service_sid" => "VA_test",
               "twilio_numbers" => [line]
             })

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "voice@example.com", "name" => "Voice"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Voice Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]
    auth = &put_req_header(&1, "authorization", "Bearer #{session["token"]}")
    voice = "/v1/comma/workspaces/#{workspace["id"]}/integrations/voice"
    keys = "/v1/comma/workspaces/#{workspace["id"]}/voice-api-keys"
    # A fresh caller number per run: Verify rate limits are per number.
    caller = "+1555" <> Integer.to_string(1_000_000 + SystemsRuntime.Proc.uniform(8_999_999))

    # ---- caller numbers ----

    status_conn = conn(:get, voice) |> auth.() |> call()
    status = expect_json(status_conn, 200)
    assert get_resp_header(status_conn, "cache-control") == ["no-store"]
    assert status["lines"] == [line]
    assert status["numbers"] == []
    assert is_boolean(status["readiness"]["ready"])

    assert status["sessions_url"] ==
             "wss://api.comma.example/v1/agent-groups/#{group_id}/voice/sessions"

    refute Map.has_key?(status, "group_id")
    refute Map.has_key?(status, "connect")

    assert %{"e164" => ^caller, "status" => "pending"} =
             :post
             |> json_conn(voice <> "/numbers/verify-start", %{"e164" => caller})
             |> auth.()
             |> call()
             |> expect_json(200)

    assert_receive {:twilio_verify, "/v2/Services/VA_test/Verifications",
                    %{"To" => ^caller, "Channel" => "sms"}}

    # A wrong code binds nothing.
    assert %{"error" => "invalid_code"} =
             :post
             |> json_conn(voice <> "/numbers/verify-check", %{
               "e164" => caller,
               "code" => "111111"
             })
             |> auth.()
             |> call()
             |> expect_json(422)

    assert %{"numbers" => []} = conn(:get, voice) |> auth.() |> call() |> expect_json(200)

    verified =
      :post
      |> json_conn(voice <> "/numbers/verify-check", %{"e164" => caller, "code" => "246810"})
      |> auth.()
      |> call()
      |> expect_json(200)

    assert [%{"e164" => ^caller, "line" => ^line, "pin_set" => false, "status" => "verified"}] =
             verified["numbers"]

    with_pin =
      :put
      |> json_conn(voice <> "/pin", %{"e164" => caller, "pin" => "2468"})
      |> auth.()
      |> call()

    assert [%{"pin_set" => true}] = expect_json(with_pin, 200)["numbers"]
    # The PIN and its hash never leave Salix.
    refute with_pin.resp_body =~ "pbkdf2"
    refute with_pin.resp_body =~ "pin_hash"
    # Not as a substring of the body: a timestamp or the random caller
    # number may contain the PIN's digits.
    refute "2468" in json_strings(Jason.decode!(with_pin.resp_body))

    assert %{"error" => _} =
             :put
             |> json_conn(voice <> "/pin", %{"e164" => caller, "pin" => "12"})
             |> auth.()
             |> call()
             |> expect_json(400)

    # A number bound to another Group is a conflict before any SMS is sent.
    {:ok, other_tenant} = Salix.Control.Tenants.create(%{"name" => "Other voice tenant"})

    {:ok, other_group} =
      Salix.Control.Groups.create(%{"name" => "Other voice group"}, other_tenant["tenant_id"])

    taken = "+1556" <> Integer.to_string(1_000_000 + SystemsRuntime.Proc.uniform(8_999_999))

    assert {:ok, _connect} =
             SalixIM.ProviderConnects.confirm_voice_number(
               other_tenant["tenant_id"],
               other_group["group_id"],
               "twilio",
               line,
               taken
             )

    assert %{"error" => "voice_number_in_use"} =
             :post
             |> json_conn(voice <> "/numbers/verify-start", %{"e164" => taken})
             |> auth.()
             |> call()
             |> expect_json(409)

    refute_received {:twilio_verify, _path, %{"To" => ^taken}}

    # Removing a number unbinds it; the "+" survives the path segment.
    assert %{"numbers" => []} =
             conn(:delete, voice <> "/numbers/" <> URI.encode_www_form(caller))
             |> auth.()
             |> call()
             |> expect_json(200)

    # Repeated codes to one number hit the Verify rate limit.
    busy = "+1557" <> Integer.to_string(1_000_000 + SystemsRuntime.Proc.uniform(8_999_999))

    statuses =
      for _attempt <- 1..6 do
        :post
        |> json_conn(voice <> "/numbers/verify-start", %{"e164" => busy})
        |> auth.()
        |> call()
        |> Map.fetch!(:status)
      end

    assert List.last(statuses) == 429

    # ---- voice agent API keys ----

    created =
      :post
      |> json_conn(keys, %{"name" => "Front desk"})
      |> auth.()
      |> call()
      |> expect_json(201)

    assert "salix_vk_" <> _ = created["key"]
    assert created["created_by"] == "comma_user:" <> user["id"]
    assert created["sessions_url"] == status["sessions_url"]

    assert created["readiness_url"] ==
             "https://api.comma.example/v1/agent-groups/#{group_id}/voice"

    refute Map.has_key?(created, "key_hash")
    refute Map.has_key?(created, "tenant_id")
    refute Map.has_key?(created, "group_id")

    assert {:ok, %{"group_id" => ^group_id, "kind" => "voice"}} =
             Salix.Control.GroupApiKeys.validate(created["key"])

    assert [listed] = conn(:get, keys) |> auth.() |> call() |> expect_json(200)
    assert listed["key_id"] == created["key_id"]
    refute Map.has_key?(listed, "key")

    # The two kinds stay apart: a voice key is not an inbound key, and an
    # inbound key cannot be managed through the voice routes.
    router_keys = "/v1/comma/workspaces/#{workspace["id"]}/router-api-keys"
    assert [] = conn(:get, router_keys) |> auth.() |> call() |> expect_json(200)

    inbound =
      :post
      |> json_conn(router_keys, %{"name" => "Zendesk"})
      |> auth.()
      |> call()
      |> expect_json(201)

    assert %{"error" => "not_found"} =
             :patch
             |> json_conn(keys <> "/" <> inbound["key_id"], %{"status" => "disabled"})
             |> auth.()
             |> call()
             |> expect_json(404)

    assert {:ok, _} = Salix.Control.GroupApiKeys.validate(inbound["key"])

    disabled =
      :patch
      |> json_conn(keys <> "/" <> created["key_id"], %{"name" => "Lobby", "status" => "disabled"})
      |> auth.()
      |> call()
      |> expect_json(200)

    assert %{"name" => "Lobby", "status" => "disabled"} = disabled
    assert {:error, :unauthorized} = Salix.Control.GroupApiKeys.validate(created["key"])

    assert %{"deleted" => true} =
             conn(:delete, keys <> "/" <> created["key_id"])
             |> auth.()
             |> call()
             |> expect_json(200)

    assert [] = conn(:get, keys) |> auth.() |> call() |> expect_json(200)

    # Another user's session cannot reach this workspace's voice setup.
    stranger =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "stranger-voice@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    stranger_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{stranger["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for path <- [voice, keys] do
      stranger_status =
        conn(:get, path)
        |> put_req_header("authorization", "Bearer #{stranger_session["token"]}")
        |> call()
        |> Map.fetch!(:status)

      assert stranger_status in [403, 404]
    end

    # A restricted session is refused, as it is for inbound keys.
    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for {method, path, body} <- [
          {:post, keys, %{"name" => "Nope"}},
          {:post, voice <> "/numbers/verify-start", %{"e164" => caller}}
        ] do
      assert %{"error" => "forbidden"} =
               method
               |> json_conn(path, body)
               |> put_req_header("authorization", "Bearer #{restricted["token"]}")
               |> call()
               |> expect_json(403)
    end
  end

  # A local stand-in for the OpenAI Voices API: every request is reported to
  # the test process. A created voice's id is `voice_` and its prompt.
  defmodule OpenAIVoicesStub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      body = if body == "", do: nil, else: Jason.decode!(body)

      if pid = SystemsRuntime.PersistentTerm.get({__MODULE__, :test_pid}, nil),
        do:
          SystemsRuntime.Proc.send(
            pid,
            {:openai_voice, conn.method, conn.request_path, get_req_header(conn, "authorization"),
             body}
          )

      prompt = (body || %{})["prompt"] || ""
      id = "voice_" <> String.replace(prompt, ~r/\W/, "")

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"object" => "audio.voice", "id" => id}))
    end
  end

  test "Comma user session sets the call voice, a custom voice and Router calls" do
    prev_base_url = SystemsRuntime.get_env(:salix_web, :openai_api_base_url)

    openai =
      start_supervised!(
        {Bandit, plug: OpenAIVoicesStub, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, openai_port}} = ThousandIsland.listener_info(openai)
    SystemsRuntime.put_env(:salix_web, :openai_api_base_url, "http://127.0.0.1:#{openai_port}")
    SystemsRuntime.PersistentTerm.put({OpenAIVoicesStub, :test_pid}, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.PersistentTerm.erase({OpenAIVoicesStub, :test_pid})
      _ = SalixStore.S3.delete(SalixStore.Keys.ctl_system_voice())

      if prev_base_url == nil,
        do: SystemsRuntime.delete_env(:salix_web, :openai_api_base_url),
        else: SystemsRuntime.put_env(:salix_web, :openai_api_base_url, prev_base_url)
    end)

    assert {:ok, _settings} =
             SalixVoice.Settings.update(%{"enabled" => true, "openai_api_key" => "sk-voice"})

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "voice-prefs@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Voice Preferences")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    auth = &put_req_header(&1, "authorization", "Bearer #{session["token"]}")
    voice = "/v1/comma/workspaces/#{workspace["id"]}/integrations/voice"

    put_prefs = fn body ->
      :put |> json_conn(voice <> "/preferences", body) |> auth.() |> call()
    end

    status = conn(:get, voice) |> auth.() |> call() |> expect_json(200)

    assert status["preferences"] == %{
             "voice" => nil,
             "custom_voice" => nil,
             "router_calls" => false
           }

    assert "quartz" in status["voices"]

    # A preset voice and Router calls are kept separately.
    assert %{"voice" => %{"kind" => "preset", "name" => "quartz"}, "router_calls" => false} =
             put_prefs.(%{"voice" => %{"kind" => "preset", "name" => "quartz"}})
             |> expect_json(200)
             |> Map.fetch!("preferences")

    assert %{"voice" => %{"name" => "quartz"}, "router_calls" => true} =
             put_prefs.(%{"router_calls" => true})
             |> expect_json(200)
             |> Map.fetch!("preferences")

    # Unknown presets, the custom voice before it exists and bad types are refused.
    assert %{"error" => _} =
             put_prefs.(%{"voice" => %{"kind" => "preset", "name" => "nobody"}})
             |> expect_json(400)

    assert %{"error" => _} = put_prefs.(%{"voice" => %{"kind" => "custom"}}) |> expect_json(400)
    assert %{"error" => _} = put_prefs.(%{"router_calls" => "yes"}) |> expect_json(400)

    # A custom voice is made from the description with the platform key and
    # selected; its provider id stays in Salix.
    created =
      :post
      |> json_conn(voice <> "/custom-voice", %{
        "name" => "Warm",
        "description" => "A warm, calm voice speaking Mandarin Chinese."
      })
      |> auth.()
      |> call()

    assert %{
             "voice" => %{"kind" => "custom"},
             "custom_voice" => %{
               "name" => "Warm",
               "description" => "A warm, calm voice speaking Mandarin Chinese."
             },
             "router_calls" => true
           } = expect_json(created, 200)["preferences"]

    warm_id = "voice_AwarmcalmvoicespeakingMandarinChinese"
    refute created.resp_body =~ warm_id

    # The stub reports before it answers, so the report is already here.
    assert_received {:openai_voice, "POST", "/v1/audio/voices", ["Bearer sk-voice"],
                     %{
                       "type" => "prompt",
                       "name" => "Warm",
                       "prompt" => "A warm, calm voice speaking Mandarin Chinese.",
                       "model" => "auto"
                     }}

    # Calls of the Group speak with it.
    {:ok, connect} =
      SalixIM.ProviderConnects.get_voice_im_connect(
        workspace["salix_tenant_id"],
        workspace["default_group_id"]
      )

    assert %{"id" => ^warm_id} =
             workspace["default_group_id"]
             |> SalixIM.VoiceConnects.voice_preferences(connect["connect_id"])
             |> SalixVoice.Voices.session_voice()

    # Back to the platform default; the custom voice stays for later.
    assert %{"voice" => nil, "custom_voice" => %{"name" => "Warm"}} =
             put_prefs.(%{"voice" => nil}) |> expect_json(200) |> Map.fetch!("preferences")

    # A voice made again without a name keeps an empty one (the clients show
    # their own label) and sends no Group id to OpenAI; the replaced voice is
    # deleted there.
    assert %{"voice" => %{"kind" => "custom"}, "custom_voice" => %{"name" => ""}} =
             :post
             |> json_conn(voice <> "/custom-voice", %{"description" => "Bright and quick."})
             |> auth.()
             |> call()
             |> expect_json(200)
             |> Map.fetch!("preferences")

    assert_received {:openai_voice, "POST", "/v1/audio/voices", _,
                     %{"name" => "Comma custom voice", "prompt" => "Bright and quick."}}

    delete_path = "/v1/audio/voices/" <> warm_id
    assert_received {:openai_voice, "DELETE", ^delete_path, ["Bearer sk-voice"], nil}

    assert %{"error" => _} =
             :post
             |> json_conn(voice <> "/custom-voice", %{"description" => " "})
             |> auth.()
             |> call()
             |> expect_json(400)
  end

  # A registered Signal account with Comma-chosen identifiers, removed after the test.
  defp signal_account!(scope) do
    n = SystemsRuntime.Proc.uniform(9_999_999)
    identity = SalixSignalProto.Keys.ec_keypair()

    {:ok, id} =
      SalixSignal.Accounts.create(%{
        aci: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0"),
        pni: nil,
        e164: "+1555" <> String.pad_leading(Integer.to_string(n), 7, "0"),
        device_id: 1,
        password: "device-password",
        identities: %{aci: identity, pni: nil},
        registration_ids: %{aci: 1, pni: 0},
        profile_key: :binary.copy(<<7>>, 32),
        pre_keys: %{},
        scope: scope,
        environment: :staging
      })

    on_exit(fn ->
      SalixStore.Repo.query("DELETE FROM signal_accounts WHERE id = $1", [Ecto.UUID.dump!(id)])
    end)

    {:ok, summary} = SalixSignal.Accounts.get(id)
    summary
  end

  test "Comma user session connects Signal chats and sets the workspace Signal number" do
    on_exit(fn -> SalixSignal.Settings.set_platform_number(nil) end)

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "signal@example.com", "name" => "Signal"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Signal Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    auth = &put_req_header(&1, "authorization", "Bearer #{session["token"]}")
    signal = "/v1/comma/workspaces/#{workspace["id"]}/integrations/signal"
    platform = signal_account!(:platform)
    {:ok, _} = SalixSignal.Settings.set_platform_number(platform.e164)

    status_conn = conn(:get, signal) |> auth.() |> call()
    status = expect_json(status_conn, 200)
    assert get_resp_header(status_conn, "cache-control") == ["no-store"]
    assert status["account"]["e164"] == platform.e164
    assert status["bindings"] == []

    # The code is shown once; the status lists only the pending claim.
    started =
      :post |> json_conn(signal <> "/claims", %{}) |> auth.() |> call() |> expect_json(200)

    assert started["claim"]["number"] == platform.e164
    assert "comma connect " <> _ = started["claim"]["command"]

    listed = conn(:get, signal) |> auth.() |> call()
    assert [%{"claim_id" => claim_id}] = expect_json(listed, 200)["pending_claims"]
    refute listed.resp_body =~ started["claim"]["code"]

    assert %{"pending_claims" => []} =
             conn(:delete, signal <> "/claims/" <> claim_id)
             |> auth.()
             |> call()
             |> expect_json(200)

    # The workspace sets its own number; another tenant's account is refused.
    tenant_id = workspace["salix_tenant_id"]
    own = signal_account!({:organization, tenant_id})
    foreign = signal_account!({:organization, "ten_other_signal"})

    assert %{"error" => "signal_account_scope"} =
             :put
             |> json_conn(signal <> "/number", %{"number" => foreign.e164})
             |> auth.()
             |> call()
             |> expect_json(422)

    number = :put |> json_conn(signal <> "/number", %{"number" => own.e164}) |> auth.() |> call()
    assert %{"effective" => %{"e164" => own_number}} = expect_json(number, 200)
    assert own_number == own.e164
    refute Map.has_key?(expect_json(number, 200), "tenant_id")

    started =
      :post |> json_conn(signal <> "/claims", %{}) |> auth.() |> call() |> expect_json(200)

    assert started["claim"]["number"] == own.e164

    # Comma admin sees and clears the same override.
    admin_path = "/v1/comma/admin/users/#{user["id"]}/workspaces/signal-number"

    assert %{"override" => %{"e164" => ^own_number}, "workspace_id" => workspace_id} =
             conn(:get, admin_path) |> admin_auth() |> call() |> expect_json(200)

    assert workspace_id == workspace["id"]

    assert %{"override" => nil, "effective" => %{"e164" => platform_number}} =
             :put
             |> json_conn(admin_path, %{"number" => ""})
             |> admin_auth()
             |> call()
             |> expect_json(200)

    assert platform_number == platform.e164

    # An admin's cookie session runs the same audited command.
    {operator, operator_token} =
      browser_cookie_login!("signal-operator@comma.surf", @admin_origin)

    assert %{"override" => %{"e164" => ^own_number}} =
             :put
             |> json_conn(admin_path, %{
               "number" => own.e164,
               "reason" => "Workspace uses its own number",
               "confirmation" => "workspace-signal-number:#{user["id"]}:#{own.e164}",
               "idempotency_key" => SystemsRuntime.Proc.uuid()
             })
             |> cookie_auth(operator_token, @admin_origin, operator["session_id"])
             |> call()
             |> expect_json(200)

    # Another user's session cannot reach this workspace's Signal setup.
    stranger =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "stranger-signal@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    stranger_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{stranger["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for {method, path} <- [{:get, signal}, {:post, signal <> "/claims"}] do
      status =
        method
        |> json_conn(path, %{})
        |> put_req_header("authorization", "Bearer #{stranger_session["token"]}")
        |> call()
        |> Map.fetch!(:status)

      assert status in [403, 404]
    end
  end

  test "restricted Comma sessions cannot mint workspace connector tokens" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "restricted-connector@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    user_id = user["id"]

    workspace = create_ready_workspace!(user["id"], "Restricted")

    open_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    conversation =
      :post
      |> json_conn("/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat", %{})
      |> put_req_header("authorization", "Bearer #{open_session["token"]}")
      |> call()
      |> expect_json(200)

    workspace_restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    conversation_restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"],
        "group_id" => workspace["default_group_id"],
        "conversation_id" => conversation["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for session <- [workspace_restricted, conversation_restricted] do
      response =
        :post
        |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
          "alias" => "mac"
        })
        |> put_req_header("authorization", "Bearer #{session["token"]}")
        |> call()

      assert response.status == 403

      bootstrap =
        :post
        |> json_conn("/v1/comma/me/bootstrap", %{})
        |> put_req_header("authorization", "Bearer #{session["token"]}")
        |> call()

      assert bootstrap.status == 403
    end

    assert Repo.aggregate(
             from(row in Comma.Data.Workspace,
               where: row.owner_user_id == ^user_id
             ),
             :count
           ) == 1

    assert Repo.get!(Comma.Data.Workspace, workspace["id"]).owner_user_id == user_id
  end

  test "public passwordless email login returns a Comma session that can access product API" do
    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "public@example.com"})
      |> call()
      |> expect_json(200)

    assert %{"challenge_id" => challenge_id, "code" => code} = login

    session =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => challenge_id,
        "code" => code
      })
      |> call()
      |> expect_json(200)

    assert "comma_sess_" <> _ = session["token"]
    assert %{"email" => "public@example.com"} = session["user"]

    body =
      :get
      |> conn("/v1/comma/workspaces")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert %{"data" => []} = body
  end

  test "ordinary sessions bootstrap one default Workspace without provisioning inline" do
    previous_vm = SystemsRuntime.get_env(:salix_agent, :cloud_vm_mod)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_mod, __MODULE__.WorkspaceVM)
    on_exit(fn -> restore_env(:salix_agent, :cloud_vm_mod, previous_vm) end)
    SystemsRuntime.put_env(:comma_core, :salix_client, __MODULE__.RecordingSalixClient)
    SystemsRuntime.put_env(:comma_core, :salix_client_test_pid, SystemsRuntime.Proc.self())

    session = email_login!("workspace-bootstrap-route@example.com")
    user_id = session["user"]["id"]

    managed_creation =
      :post
      |> json_conn("/v1/comma/workspaces", %{"name" => "Client-created workspace"})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(409)

    assert managed_creation == %{"error" => "workspace_creation_managed"}

    assert Repo.aggregate(
             from(row in Comma.Data.Workspace,
               where: row.owner_user_id == ^user_id
             ),
             :count
           ) == 0

    first_conn =
      :post
      |> json_conn("/v1/comma/me/bootstrap", %{})
      |> user_auth(session["token"])
      |> call()

    first = expect_json(first_conn, 202)
    assert get_resp_header(first_conn, "retry-after") == ["2"]
    assert first["status"] == "provisioning"
    assert first["workspace"]["owner_user_id"] == user_id
    assert first["workspace"]["status"] == "provisioning"

    second =
      :post
      |> json_conn("/v1/comma/me/bootstrap", %{})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(202)

    workspace_id = first["workspace"]["id"]
    group_id = first["workspace"]["group_id"]
    assert second["workspace"]["id"] == workspace_id

    assert Repo.aggregate(
             from(row in Comma.Data.Workspace,
               where: row.owner_user_id == ^user_id
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(row in Comma.Data.WorkspaceMembership, where: row.user_id == ^user_id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(row in Comma.Data.ExternalOperation,
               where:
                 row.owner_id == ^workspace_id and row.operation_type == "workspace_convergence"
             ),
             :count
           ) == 1

    pending_workspace =
      :get
      |> conn("/v1/comma/workspaces/#{workspace_id}")
      |> user_auth(session["token"])
      |> call()

    assert expect_json(pending_workspace, 202) == %{
             "error" => "workspace_provisioning",
             "retry_after_seconds" => 2
           }

    assert get_resp_header(pending_workspace, "retry-after") == ["2"]

    pending_calls = [
      {:post, "/v1/comma/groups/#{group_id}/assistant-chat"},
      {:post, "/v1/comma/groups/#{group_id}/files"},
      {:get, "/v1/comma/workspaces/#{workspace_id}/billing/summary"}
    ]

    for {method, path} <- pending_calls do
      conn =
        method
        |> json_conn(path, %{})
        |> user_auth(session["token"])
        |> call()

      assert expect_json(conn, 202) == %{
               "error" => "workspace_provisioning",
               "retry_after_seconds" => 2
             }

      assert get_resp_header(conn, "retry-after") == ["2"]
    end

    refute_received {:provision_workspace_scope, _workspace}

    operation =
      Repo.get_by!(Comma.Data.ExternalOperation,
        owner_id: workspace_id,
        operation_type: "workspace_convergence",
        generation: 1
      )

    job =
      Repo.one!(
        from(job in Oban.Job,
          where:
            job.worker == "Comma.Workers.WorkspaceConvergence" and
              fragment("?->>'operation_id'", job.args) == ^operation.operation_id
        )
      )

    timeout = SystemsRuntime.fetch_env!(:comma_core, :operation_claim_timeout_ms)
    stale_at = DateTime.add(SystemsClock.utc_now(), -(timeout + 1_000), :millisecond)

    Repo.update_all(
      from(row in Comma.Data.ExternalOperation,
        where: row.operation_id == ^operation.operation_id
      ),
      set: [status: "executing", attempt: job.max_attempts, updated_at: stale_at]
    )

    Repo.update_all(
      from(row in Oban.Job, where: row.id == ^job.id),
      set: [
        state: "executing",
        attempt: job.max_attempts,
        attempted_at: stale_at,
        attempted_by: ["salix@terminated-pod", "terminated-producer"]
      ]
    )

    assert {1, [%{id: rescued_id, max_attempts: rescued_max_attempts}]} =
             Comma.ObanPlugins.OperationLifeline.rescue_jobs(Oban.config(Comma.Oban), timeout)

    assert rescued_id == job.id
    assert rescued_max_attempts == job.max_attempts + 1

    Repo.update_all(
      from(candidate in Oban.Job,
        where:
          candidate.queue == "comma_external" and candidate.state == "available" and
            candidate.id != ^job.id
      ),
      set: [state: "scheduled", scheduled_at: DateTime.add(SystemsClock.utc_now(), 1, :hour)]
    )

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(Comma.Oban, queue: :comma_external, with_limit: 1)

    assert Repo.get!(Oban.Job, job.id).state == "completed"
    assert Repo.get!(Comma.Data.ExternalOperation, operation.operation_id).status == "succeeded"

    assert Repo.get!(Comma.Data.ExternalOperation, operation.operation_id).attempt ==
             job.max_attempts + 1

    assert_receive {:provision_workspace_scope, %{"id" => ^workspace_id}}
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)

    ready =
      :post
      |> json_conn("/v1/comma/me/bootstrap", %{})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert ready["status"] == "ready"
    assert ready["workspace"]["id"] == workspace_id

    assert %{"data" => [%{"id" => ^workspace_id}]} =
             :get
             |> conn("/v1/comma/workspaces")
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    assert %{"id" => ^workspace_id} =
             :get
             |> conn("/v1/comma/workspaces/#{workspace_id}")
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    assert %{"group_id" => ^group_id} =
             :post
             |> json_conn("/v1/comma/groups/#{group_id}/assistant-chat", %{})
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    billing_summary =
      :get
      |> conn("/v1/comma/workspaces/#{workspace_id}/billing/summary")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert billing_summary["billing_account_id"] == "comma-ba-" <> workspace_id
    assert billing_summary["current_credits"] == 20_000_000
    assert billing_summary["active_subscription"] == nil
  end

  test "v1 workspace HTTP authorization and projection remain owner-only" do
    owner_session = email_login!("workspace-owner-only@example.com")
    attacker_session = email_login!("workspace-future-member@example.com")
    owner_id = owner_session["user"]["id"]
    attacker_id = attacker_session["user"]["id"]
    workspace = create_ready_workspace!(owner_id, "Owner-only Workspace")

    Repo.insert!(
      Comma.Data.WorkspaceMembership.changeset(%Comma.Data.WorkspaceMembership{}, %{
        workspace_id: workspace["id"],
        user_id: attacker_id,
        role: "member",
        status: "active"
      })
    )

    assert %{"data" => []} =
             :get
             |> conn("/v1/comma/workspaces")
             |> user_auth(attacker_session["token"])
             |> call()
             |> expect_json(200)

    assert %{"error" => "forbidden"} =
             :get
             |> conn("/v1/comma/workspaces/#{workspace["id"]}")
             |> user_auth(attacker_session["token"])
             |> call()
             |> expect_json(403)

    assert %{"error" => "forbidden"} =
             :patch
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}", %{"name" => "Stolen"})
             |> user_auth(attacker_session["token"])
             |> call()
             |> expect_json(403)

    owner_workspace =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}")
      |> user_auth(owner_session["token"])
      |> call()
      |> expect_json(200)

    assert owner_workspace["name"] == "Owner-only Workspace"

    assert owner_workspace["members"] == [
             %{"role" => "owner", "user_id" => owner_id}
           ]

    workspace["id"]
    |> then(&Repo.get!(Comma.Data.Workspace, &1))
    |> Ecto.Changeset.change(status: "provisioning")
    |> Repo.update!()

    provisioning_response =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}")
      |> user_auth(attacker_session["token"])
      |> call()

    assert expect_json(provisioning_response, 403) == %{"error" => "forbidden"}
    assert get_resp_header(provisioning_response, "retry-after") == []
  end

  test "browser login keeps the session token in an HttpOnly revocable cookie" do
    origin = "http://127.0.0.1:5174"

    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "browser-cookie@example.com"})
      |> web_cookie_request(origin, :none)
      |> call()
      |> expect_json(200)

    verify_conn =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => login["challenge_id"],
        "code" => login["code"]
      })
      |> web_cookie_request(origin, :none)
      |> call()

    session = expect_json(verify_conn, 200)
    assert Map.keys(session) |> Enum.sort() == ["expires_at", "session_id", "user"]
    assert {:ok, _session_id} = Ecto.UUID.cast(session["session_id"])
    refute Map.has_key?(session, "token")
    assert session["user"]["email"] == "browser-cookie@example.com"
    refute Map.has_key?(session["user"], "admin")

    cookie = verify_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()]
    assert cookie.http_only == true
    assert cookie.secure == false
    assert cookie.same_site == "Lax"
    assert is_binary(cookie.value)
    assert String.starts_with?(cookie.value, "comma_sess_")

    startup_view =
      :get
      |> conn("/v1/comma/auth/session")
      |> cookie_auth(cookie.value, origin, :unknown)
      |> call()
      |> expect_json(200)

    assert Map.keys(startup_view) |> Enum.sort() == ["expires_at", "session_id", "user"]
    refute Map.has_key?(startup_view, "token")
    assert startup_view["session_id"] == session["session_id"]
    assert startup_view["user"]["email"] == "browser-cookie@example.com"

    assert %{"session_id" => session_id} =
             :get
             |> conn("/v1/comma/auth/session")
             |> cookie_auth(cookie.value, origin)
             |> call()
             |> expect_json(200)

    assert session_id == session["session_id"]

    active_none =
      :get
      |> conn("/v1/comma/auth/session")
      |> cookie_auth(cookie.value, origin, :none)
      |> call()

    assert expect_json(active_none, 409) == %{"error" => "session_changed"}
    assert active_none.resp_cookies == %{}

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(cookie.value, origin)
             |> call()
             |> expect_json(403)

    assert 401 ==
             (:get
              |> conn("/v1/comma/auth/session")
              |> cookie_auth(cookie.value, origin)
              |> user_auth(cookie.value)
              |> call()).status

    logout_conn =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> cookie_auth(cookie.value, origin)
      |> call()

    assert %{"signed_out" => true} = expect_json(logout_conn, 200)
    assert logout_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()].max_age == 0

    assert 401 ==
             (:get
              |> conn("/v1/comma/auth/session")
              |> cookie_auth(cookie.value, origin)
              |> call()).status
  end

  test "canonical browser origins reject cross-surface paths regardless of bearer" do
    product_session = email_login!("cross-surface-product@example.com")

    assert :options
           |> conn("/v1/comma/admin/users")
           |> put_req_header("origin", @admin_origin)
           |> put_req_header("access-control-request-method", "GET")
           |> put_req_header(
             "access-control-request-headers",
             "x-comma-session-transport"
           )
           |> call()
           |> Map.fetch!(:status) == 204

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> put_req_header("origin", @web_origin)
             |> admin_auth()
             |> call()
             |> expect_json(403)

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(
               product_session["token"],
               @web_origin,
               product_session["session_id"]
             )
             |> call()
             |> expect_json(403)

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/workspaces")
             |> put_req_header("origin", @admin_origin)
             |> user_auth(product_session["token"])
             |> call()
             |> expect_json(403)

    for {origin, path} <- [
          {@web_origin, "/v1/comma/admin/users"},
          {@admin_origin, "/v1/comma/workspaces"},
          {@admin_origin, "/v1/admin/vm/worker-release"}
        ] do
      assert %{"error" => "origin_path_not_allowed"} =
               :options
               |> conn(path)
               |> put_req_header("origin", origin)
               |> put_req_header("access-control-request-method", "GET")
               |> put_req_header("access-control-request-headers", "authorization")
               |> call()
               |> expect_json(403)
    end
  end

  test "Agent VMM Admin command replays a succeeded HTTP response from its receipt" do
    {browser_session, token} =
      browser_cookie_login!("compute-operator@comma.surf", @admin_origin)

    registration_id = "registration-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    tenant_id = "tenant-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    assert {:ok, registration} =
             SalixStore.AgentVMM.create_registration(%{
               id: registration_id,
               tenant_id: tenant_id,
               group_id: "group-a",
               device_id: "node-a",
               enrollment_token: String.duplicate("a", 32)
             })

    action = "disable_agent_vmm_registration"
    idempotency_key = "agent-vmm-http-#{SystemsRuntime.Proc.uuid()}"

    body = %{
      "tenant_id" => tenant_id,
      "expected_revision" => registration.revision,
      "reason" => "Drain this registration for maintenance",
      "idempotency_key" => idempotency_key,
      "confirmation" => "#{action}:#{registration_id}:#{registration.revision}"
    }

    path = "/v1/comma/admin/compute/agent-vmm/commands/#{action}/#{registration_id}"

    first =
      :post
      |> json_conn(path, body)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(202)

    second =
      :post
      |> json_conn(path, body)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(202)

    assert second == first
    assert first["accepted"]
    assert first["result_revision"] == registration.revision + 1

    assert SalixStore.Repo.get!(SalixStore.AgentVMM.Registration, registration_id).revision ==
             registration.revision + 1

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn(path, Map.put(body, "idempotency_key", SystemsRuntime.Proc.uuid()))
             |> admin_auth()
             |> call()
             |> expect_json(403)
  end

  test "exact comma.surf Admin Cookie Sessions can read and run named audited commands" do
    {browser_session, token} = browser_cookie_login!("operator@comma.surf", @admin_origin)
    user_id = browser_session["user"]["id"]
    missing_code_id = SystemsRuntime.Proc.uuid()

    for path <- [
          "/v1/comma/admin/audit-events",
          "/v1/comma/admin/audit-events?action=update_user&actor_email=operator%40comma.surf",
          "/v1/comma/admin/lookup?q=operator",
          "/v1/comma/admin/stats/users",
          "/v1/comma/admin/users",
          "/v1/comma/admin/users/#{user_id}",
          "/v1/comma/admin/users/#{user_id}/sessions",
          "/v1/comma/admin/users/#{user_id}/workspaces",
          "/v1/comma/admin/billing/free-router-models",
          "/v1/comma/admin/billing/package-versions",
          "/v1/comma/admin/billing/redeem-codes",
          "/v1/comma/admin/billing/redemptions?redeem_code_id=#{missing_code_id}"
        ] do
      assert :get
             |> conn(path)
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> Map.fetch!(:status) == 200
    end

    assert %{"data" => [%{"match" => "email", "user" => %{"id" => ^user_id}} | _]} =
             :get
             |> conn("/v1/comma/admin/lookup?q=operator%40comma")
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    for path <- [
          "/v1/comma/admin/lookup",
          "/v1/comma/admin/audit-events?action=unknown_action",
          "/v1/comma/admin/audit-events?target_type=user"
        ] do
      assert %{"error" => "invalid_filter"} =
               :get
               |> conn(path)
               |> cookie_auth(token, @admin_origin, browser_session["session_id"])
               |> call()
               |> expect_json(400)
    end

    for path <- [
          "/v1/comma/admin/billing/redemptions",
          "/v1/comma/admin/billing/redemptions?redeem_code_id=%20"
        ] do
      assert %{"error" => "invalid_redeem_code_id"} =
               :get
               |> conn(path)
               |> cookie_auth(token, @admin_origin, browser_session["session_id"])
               |> call()
               |> expect_json(400)
    end

    assert %{"error" => "invalid_admin_reason"} =
             :post
             |> json_conn("/v1/comma/admin/users", %{"email" => "missing-contract@example.com"})
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(400)

    created_email = "human-created-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
    create_key = "human-create-#{SystemsRuntime.Proc.uuid()}"

    create_body = %{
      "email" => created_email,
      "name" => "Human Created",
      "admin_access" => "allow",
      "reason" => "Create a support-managed account",
      "idempotency_key" => create_key,
      "confirmation" => "create-user:#{created_email}"
    }

    created =
      :post
      |> json_conn("/v1/comma/admin/users", create_body)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(201)

    assert created["admin_access"]["allowed"]
    assert created["admin_access"]["source"] == "explicit_allow"

    assert created["login_methods"] == [
             %{
               "email" => created_email,
               "method" => "email_otp"
             }
           ]

    assert %{"error" => "admin_command_already_succeeded"} =
             :post
             |> json_conn("/v1/comma/admin/users", create_body)
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(409)

    assert {:ok, %{"id" => created_id}} = Comma.Accounts.get_user_by_email(created_email)
    assert created_id == created["id"]

    update_body = %{
      "name" => "Human Updated",
      "reason" => "Correct the account display name",
      "idempotency_key" => "human-update-#{SystemsRuntime.Proc.uuid()}",
      "confirmation" => "update-user:#{created["id"]}"
    }

    assert %{"name" => "Human Updated"} =
             :patch
             |> json_conn("/v1/comma/admin/users/#{created["id"]}", update_body)
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    support_conn =
      :post
      |> json_conn("/v1/comma/admin/users/#{created["id"]}/support-sessions", %{
        "reason" => "Investigate the reported account issue",
        "idempotency_key" => "human-support-#{SystemsRuntime.Proc.uuid()}",
        "confirmation" => "support-session:#{created["id"]}",
        "expires_in_seconds" => 900,
        "budget" => 3
      })
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    support_session = expect_json(support_conn, 201)
    assert support_session["restricted"] == true
    assert "comma_sess_" <> _ = support_session["token"]
    assert get_resp_header(support_conn, "cache-control") == ["no-store"]

    assert {:ok, ordinary_session} =
             Comma.Accounts.create_session(created["id"],
               auth_method: "google",
               client_kind: "web",
               device_label: "Web on macOS"
             )

    assert {:ok, expired_session} =
             Comma.Accounts.create_session(created["id"],
               client_kind: "electron",
               device_label: "Comma Desktop on Linux"
             )

    expired_session["id"]
    |> then(&Repo.get!(AuthSession, &1))
    |> Ecto.Changeset.change(expires_at: DateTime.add(SystemsClock.utc_now(), -60, :second))
    |> Repo.update!()

    sessions_conn =
      :get
      |> conn("/v1/comma/admin/users/#{created["id"]}/sessions?limit=50")
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    sessions = expect_json(sessions_conn, 200)
    assert get_resp_header(sessions_conn, "cache-control") == ["no-store"]
    assert sessions["has_more"] == false
    assert length(sessions["data"]) == 3

    filtered =
      :get
      |> conn(
        "/v1/comma/admin/users/#{created["id"]}/sessions?status=active&client_kind=web&sort=last_seen_at&limit=1"
      )
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(200)

    assert [%{"id" => filtered_id}] = filtered["data"]
    assert filtered_id == ordinary_session["id"]
    refute filtered["has_more"]

    :get
    |> conn("/v1/comma/admin/users/#{created["id"]}/sessions?status=online")
    |> cookie_auth(token, @admin_origin, browser_session["session_id"])
    |> call()
    |> expect_json(400)

    listed_ordinary =
      Enum.find(sessions["data"], &(&1["id"] == ordinary_session["id"]))

    assert listed_ordinary["auth_method"] == "google"
    assert listed_ordinary["client_kind"] == "web"
    assert listed_ordinary["device_label"] == "Web on macOS"
    refute Map.has_key?(listed_ordinary, "token")
    refute Map.has_key?(listed_ordinary, "token_hash")
    refute Map.has_key?(listed_ordinary, "user_id")
    refute Map.has_key?(listed_ordinary, "workspace_id")

    assert %{"revoked" => true, "session_id" => revoked_session_id} =
             :post
             |> json_conn(
               "/v1/comma/admin/users/#{created["id"]}/sessions/#{ordinary_session["id"]}/revoke",
               %{
                 "reason" => "End the stale browser Session",
                 "idempotency_key" => "human-revoke-#{SystemsRuntime.Proc.uuid()}",
                 "confirmation" => "revoke-session:#{ordinary_session["id"]}"
               }
             )
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    assert revoked_session_id == ordinary_session["id"]
    assert {:error, :revoked} = Comma.Accounts.validate_session(ordinary_session["token"])

    assert %{"revoked_count" => 1} =
             :post
             |> json_conn("/v1/comma/admin/users/#{created["id"]}/sessions/revoke-all", %{
               "reason" => "End every remaining target Session",
               "idempotency_key" => "human-revoke-all-#{SystemsRuntime.Proc.uuid()}",
               "confirmation" => "revoke-all-sessions:#{created["id"]}"
             })
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    assert {:error, :revoked} = Comma.Accounts.validate_session(support_session["token"])
    assert {:error, :expired} = Comma.Accounts.validate_session(expired_session["token"])
    assert Repo.get!(AuthSession, expired_session["id"]).revoked_at == nil

    workspace =
      :post
      |> json_conn("/v1/comma/admin/users/#{created["id"]}/workspaces", %{
        "reason" => "Ensure the account has its default Workspace",
        "idempotency_key" => "human-workspace-#{SystemsRuntime.Proc.uuid()}",
        "confirmation" => "default-workspace:#{created["id"]}"
      })
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(200)

    assert workspace["status"] in ["provisioning", "ready"]

    workspace_overview_conn =
      :get
      |> conn("/v1/comma/admin/users/#{created["id"]}/workspaces")
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    assert %{
             "workspace" => %{
               "id" => workspace_id,
               "billing_account_id" => billing_account_id,
               "group_id" => projected_group_id,
               "status" => projected_status,
               "tenant_id" => projected_tenant_id
             },
             "billing" => %{
               "account_id" => projected_account_id,
               "account_status" => "missing",
               "current_credits" => 0,
               "active_grants" => [],
               "has_more" => false
             }
           } = expect_json(workspace_overview_conn, 200)

    assert workspace_id == workspace["workspace"]["id"]
    assert projected_account_id == billing_account_id
    assert projected_status in ["provisioning", "ready"]

    stored_workspace = Repo.get!(Comma.Data.Workspace, workspace_id)

    assert projected_group_id == stored_workspace.salix_group_id
    assert projected_tenant_id == stored_workspace.salix_tenant_id

    assert get_resp_header(workspace_overview_conn, "cache-control") == ["no-store"]
    refute workspace_overview_conn.resp_body =~ "router_agent_id"
    refute workspace_overview_conn.resp_body =~ "policy_snapshot"
    refute workspace_overview_conn.resp_body =~ "metadata"

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn("/v1/comma/admin/users/#{created["id"]}/sessions", %{})
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(403)

    assert Repo.exists?(
             from(event in Comma.Admin.AuditEvent,
               where:
                 event.actor_key == ^user_id and
                   event.action == "create_user" and
                   event.idempotency_key == ^create_key and
                   event.outcome == "succeeded"
             )
           )

    for action <- ["revoke_user_session", "revoke_all_user_sessions"] do
      assert Repo.exists?(
               from(event in Comma.Admin.AuditEvent,
                 where:
                   event.actor_key == ^user_id and
                     event.action == ^action and
                     event.outcome == "succeeded"
               )
             )
    end

    audit_conn =
      :get
      |> conn("/v1/comma/admin/audit-events?limit=1")
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    assert %{
             "data" => [audit_event],
             "has_more" => true,
             "next_cursor" => audit_cursor
           } = expect_json(audit_conn, 200)

    assert get_resp_header(audit_conn, "cache-control") == ["no-store"]
    assert audit_event["actor"]["email"] == "operator@comma.surf"
    assert audit_event["actor"]["user_id"] == user_id
    assert audit_event["outcome"] == "succeeded"
    assert is_binary(audit_event["reason"])
    assert is_binary(audit_cursor)

    assert Map.keys(audit_event) |> Enum.sort() ==
             ~w(action actor created_at error_code id outcome reason target updated_at)

    for internal <- [
          "evidence",
          "idempotency_key",
          "lease_expires_at",
          "request_fingerprint"
        ] do
      refute Map.has_key?(audit_event, internal)
    end

    assert %{"data" => [_next_event]} =
             :get
             |> conn(
               "/v1/comma/admin/audit-events?limit=1&cursor=#{URI.encode_www_form(audit_cursor)}"
             )
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    assert %{"error" => "invalid_cursor"} =
             :get
             |> conn("/v1/comma/admin/audit-events?cursor=tampered")
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(400)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> user_auth(token)
             |> call()
             |> expect_json(401)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn("/v1/comma/admin/audit-events")
             |> user_auth(token)
             |> call()
             |> expect_json(401)
  end

  defmodule SubscriptionWorkerStub do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(state), do: {:ok, state}

    def handle_call({:start, id, data, reply_to}, _from, state) do
      command = Jason.decode!(data)

      result =
        case command["op"] do
          "/oauth/begin" ->
            %{
              "provider" => command["body"]["provider"],
              "url" => "https://example.com/authorize",
              "state" => command["body"]["state"]
            }

          "/models" ->
            %{
              "data" => [
                %{
                  "id" => command["body"]["provider"] <> "-model",
                  "name" => "Subscription model",
                  "supports_images" => false
                }
              ],
              "truncated" => false
            }

          "/quota/reset" ->
            %{"code" => "reset", "windows_reset" => 2}

          "/oauth/device/begin" ->
            # A zero interval lets the first completion request poll immediately.
            %{
              "provider" => command["body"]["provider"],
              "mode" => "device",
              "device_auth_id" => "private-device-secret",
              "user_code" => "USER-CODE",
              "interval" => 0,
              "url" => "https://example.com/device",
              "context" => %{"device_id" => "device-secret"}
            }

          "/oauth/device/poll" ->
            if command["body"]["device_auth_id"] == "private-device-secret" and
                 command["body"]["context"] == %{"device_id" => "device-secret"},
               do: %{
                 "email" => "subscriber@example.com",
                 "credentials" => %{
                   "access_token" => "subscription-secret",
                   "refresh_token" => "refresh-secret"
                 }
               },
               else: %{"status" => "pending"}

          "/v1/" <> _ = op ->
            %{"op" => op, "provider" => command["credential"]["provider"]}

          "/quota" ->
            %{
              "body" => %{
                "rate_limit" => %{
                  "primary_window" => %{
                    "used_percent" => 25,
                    "reset_at" => 1_798_761_600,
                    "limit_window_seconds" => 604_800
                  }
                }
              }
            }

          _ ->
            %{
              "email" => "subscriber@example.com",
              "credentials" => %{
                "access_token" => "subscription-secret",
                "refresh_token" => "refresh-secret"
              }
            }
        end

      SystemsRuntime.Proc.send(
        reply_to,
        {:subscription, id, %{"type" => "data", "data" => Base.encode64(Jason.encode!(result))}}
      )

      SystemsRuntime.Proc.send(reply_to, {:subscription, id, %{"type" => "done"}})
      {:reply, :ok, state}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  @tag :subscriptions
  test "new subscription providers sign in through workspace endpoints and receive pooled requests" do
    previous = SystemsRuntime.get_env(:salix_agent, :subscription_worker)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :subscription_worker, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :subscription_worker)
    end)

    SystemsRuntime.put_env(
      :salix_agent,
      :subscription_worker,
      start_supervised!(SubscriptionWorkerStub)
    )

    login = email_login!("subscription-providers@example.com")
    workspace = create_ready_workspace!(login["user"])
    token = login["token"]
    path = "/v1/comma/workspaces/#{workspace["id"]}/subscription-accounts"

    choose =
      "/v1/comma/workspaces/#{workspace["id"]}/agents/#{workspace["router_agent_id"]}/model"

    # Each plan serves a catalog model it lists, over its own wire protocol.
    for {provider, mode, model, protocol, op} <- [
          {"gemini", nil, "gemini-3-flash", "chat_completions", "/v1/chat/completions"},
          {"grok", "device", "grok-4.3", "responses", "/v1/responses"},
          {"kimi-code", "device", "kimi-for-coding-highspeed", "anthropic", "/v1/messages"},
          {"github-copilot", "device", "gemini-3.5-flash", "chat_completions",
           "/v1/chat/completions"}
        ] do
      attempt =
        :post
        |> json_conn("#{path}/oauth", %{"provider" => provider})
        |> user_auth(token)
        |> call()
        |> expect_json(200)

      # The browser sees only the user-facing code and link, never the device secret.
      assert attempt["mode"] == mode
      assert attempt["url"] =~ "https://example.com/"
      refute Jason.encode!(attempt) =~ "secret"

      # Device-only providers reject a callback sign-in instead of starting one.
      if mode == "device" do
        :post
        |> json_conn("#{path}/oauth", %{"provider" => provider, "mode" => "callback"})
        |> user_auth(token)
        |> call()
        |> expect_json(400)
      end

      account =
        :post
        |> json_conn("#{path}/oauth/#{attempt["id"]}", %{
          "code" => if(mode == "device", do: "", else: "browser-code")
        })
        |> user_auth(token)
        |> call()
        |> expect_json(200)

      assert account["provider"] == provider
      assert account["email"] == "subscriber@example.com"
      refute Jason.encode!(account) =~ "secret"

      :put
      |> json_conn(choose, %{
        "selection" => %{"kind" => "catalog", "model" => model, "allow_paid" => false}
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

      assert {:ok, config} =
               SalixAgent.AgentModel.resolve_llm_for_agent(workspace["router_agent_id"])

      assert config["catalog_model"] == model

      # Dispatch selects this provider's account and sends the protocol path to the worker.
      result =
        SalixAgent.AccountPool.dispatch(config, fn resolved ->
          assert resolved["protocol"] == protocol
          url = resolved["base_url"] <> String.replace_prefix(op, "/v1", "")

          url =
            if protocol == "anthropic", do: resolved["base_url"] <> op, else: url

          {:ok, response} =
            resolved["transport"].(url, json: %{"model" => resolved["model"], "stream" => false})

          {:final, Jason.decode!(response.body), %{}}
        end)

      assert {:final, %{"op" => ^op, "provider" => ^provider}, _} = result
    end
  end

  @tag :subscription_discovery
  test "subscription model discovery uses only an enabled account from the owner's tenant" do
    previous = SystemsRuntime.get_env(:salix_agent, :subscription_worker)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :subscription_worker, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :subscription_worker)
    end)

    worker = start_supervised!(SubscriptionWorkerStub)
    SystemsRuntime.put_env(:salix_agent, :subscription_worker, worker)
    login = email_login!("model-discovery-pool@example.com")
    workspace = create_ready_workspace!(login["user"])
    path = "/v1/comma/workspaces/#{workspace["id"]}/model-discovery"
    accounts = "/v1/comma/workspaces/#{workspace["id"]}/subscription-accounts"
    token = login["token"]

    missing =
      :post
      |> json_conn(path, %{"account_pool" => "codex"})
      |> user_auth(token)
      |> call()
      |> expect_json(400)

    assert missing["error"] == "model_discovery_no_account"

    for provider <- ["codex", "claude"] do
      account =
        :post
        |> json_conn(accounts, %{
          "provider" => provider,
          "credentials" => %{"access_token" => "import-secret"}
        })
        |> user_auth(token)
        |> call()
        |> expect_json(200)

      :patch
      |> json_conn("#{accounts}/#{account["id"]}", %{
        "version" => account["version"],
        "disabled" => true
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

      :post
      |> json_conn(path, %{"account_pool" => provider})
      |> user_auth(token)
      |> call()
      |> expect_json(400)

      listed = :get |> conn(accounts) |> user_auth(token) |> call() |> expect_json(200)
      disabled = Enum.find(listed["accounts"], &(&1["id"] == account["id"]))

      :patch
      |> json_conn("#{accounts}/#{account["id"]}", %{
        "version" => disabled["version"],
        "disabled" => false
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

      models =
        :post
        |> json_conn(path, %{"account_pool" => provider})
        |> user_auth(token)
        |> call()
        |> expect_json(200)

      assert models["data"] == [
               %{
                 "id" => provider <> "-model",
                 "name" => "Subscription model",
                 "supports_images" => false
               }
             ]

      assert models["protocol"] == if(provider == "codex", do: "responses", else: "anthropic")
      refute Jason.encode!(models) =~ "secret"
    end

    other = email_login!("model-discovery-other@example.com")
    other_workspace = create_ready_workspace!(other["user"])

    :post
    |> json_conn(path, %{"account_pool" => "codex"})
    |> user_auth(other["token"])
    |> call()
    |> expect_json(403)

    :post
    |> json_conn("/v1/comma/workspaces/#{other_workspace["id"]}/model-discovery", %{
      "account_pool" => "codex"
    })
    |> user_auth(other["token"])
    |> call()
    |> expect_json(400)

    :post
    |> json_conn(path, %{"account_pool" => "codex", "tenant_id" => workspace["salix_tenant_id"]})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    :post
    |> json_conn(path, %{"account_pool" => "invalid"})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{login["user"]["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :post
    |> json_conn(path, %{"account_pool" => "codex"})
    |> user_auth(restricted["token"])
    |> call()
    |> expect_json(403)
  end

  @tag :subscriptions
  test "workspace owners add, rename, rekey and disable API-key Profiles for a catalog source" do
    login = email_login!("api-key-profiles@example.com")
    workspace = create_ready_workspace!(login["user"])
    token = login["token"]
    path = "/v1/comma/workspaces/#{workspace["id"]}/subscription-accounts"

    send_json = fn method, url, body ->
      method |> json_conn(url, body) |> user_auth(token) |> call()
    end

    profile =
      send_json.(:post, path, %{
        "credential_kind" => "provider_api_key",
        "source" => "openrouter",
        "api_key" => "sk-or-v1-secret-0123456789"
      })
      |> expect_json(200)

    assert %{"source" => "openrouter", "status" => "active", "key_hint" => "…6789"} = profile
    refute Jason.encode!(profile) =~ "secret"

    listed =
      :get |> conn("#{path}?view=profiles") |> user_auth(token) |> call() |> expect_json(200)

    assert [%{"name" => "OpenRouter API Key"}] = listed["accounts"]

    # Apps released before Profiles parse only Codex and Claude subscriptions;
    # without the view they get no other account.
    legacy = :get |> conn(path) |> user_auth(token) |> call() |> expect_json(200)
    assert %{"accounts" => [], "next" => ""} = legacy

    renamed =
      send_json.(:patch, "#{path}/#{profile["id"]}", %{
        "name" => "Team",
        "version" => profile["version"]
      })
      |> expect_json(200)

    rekeyed =
      send_json.(:patch, "#{path}/#{profile["id"]}", %{
        "api_key" => "sk-or-v1-other-9999999999",
        "version" => renamed["version"]
      })
      |> expect_json(200)

    assert %{"name" => "Team", "key_hint" => "…9999", "disabled_models" => []} = rekeyed

    narrowed =
      send_json.(:patch, "#{path}/#{profile["id"]}", %{
        "disabled_models" => ["gpt-5.5"],
        "version" => rekeyed["version"]
      })
      |> expect_json(200)

    assert narrowed["disabled_models"] == ["gpt-5.5"]

    listed =
      :get |> conn("#{path}?view=profiles") |> user_auth(token) |> call() |> expect_json(200)

    assert [%{"disabled_models" => ["gpt-5.5"]}] = listed["accounts"]

    send_json.(:patch, "#{path}/#{profile["id"]}", %{
      "disabled_models" => "gpt-5.5",
      "version" => narrowed["version"]
    })
    |> expect_json(400)

    disabled =
      send_json.(:patch, "#{path}/#{profile["id"]}", %{
        "disabled" => true,
        "version" => narrowed["version"]
      })
      |> expect_json(200)

    assert disabled["disabled"]

    send_json.(:post, path, %{
      "credential_kind" => "provider_api_key",
      "source" => "codex",
      "api_key" => "sk-not-a-key-source"
    })
    |> expect_json(400)

    # A Custom endpoint may have no key; its hint is then null. A catalog
    # source still needs one.
    keyless =
      send_json.(:post, path, %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "base_url" => "https://ollama.example.test",
        "protocol" => "chat_completions",
        "models" => ["llama3.2:3b"]
      })
      |> expect_json(200)

    assert %{"source" => "custom", "key_hint" => nil, "models" => ["llama3.2:3b"]} = keyless
    assert Map.has_key?(keyless, "key_hint")

    send_json.(:post, path, %{
      "credential_kind" => "provider_api_key",
      "source" => "openrouter",
      "api_key" => ""
    })
    |> expect_json(400)
  end

  @tag :subscriptions
  test "workspace owners manage subscriptions without exposing credentials" do
    previous = SystemsRuntime.get_env(:salix_agent, :subscription_worker)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :subscription_worker, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :subscription_worker)
    end)

    worker = start_supervised!(SubscriptionWorkerStub)
    SystemsRuntime.put_env(:salix_agent, :subscription_worker, worker)
    login = email_login!("subscriptions@example.com")
    workspace = create_ready_workspace!(login["user"])
    token = login["token"]
    path = "/v1/comma/workspaces/#{workspace["id"]}/subscription-accounts"

    account =
      :post
      |> json_conn(path, %{
        "provider" => "codex",
        "credentials" => %{"access_token" => "import-secret"}
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    refute Jason.encode!(account) =~ "secret"
    assert account["email"] == "subscriber@example.com"
    id = account["id"]
    listed = :get |> conn(path) |> user_auth(token) |> call() |> expect_json(200)
    assert Enum.any?(listed["accounts"], &(&1["id"] == id))
    refute Jason.encode!(listed) =~ "secret"
    other = email_login!("subscriptions-other@example.com")
    other_workspace = create_ready_workspace!(other["user"])
    other_path = "/v1/comma/workspaces/#{other_workspace["id"]}/subscription-accounts"
    :get |> conn(path) |> user_auth(other["token"]) |> call() |> expect_json(403)

    :patch
    |> json_conn("#{other_path}/#{id}", %{"version" => account["version"], "disabled" => true})
    |> user_auth(other["token"])
    |> call()
    |> expect_json(404)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{login["user"]["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :get |> conn(path) |> user_auth(restricted["token"]) |> call() |> expect_json(403)

    reset_attrs = %{
      "version" => account["version"],
      "request_id" => SalixAgent.SubscriptionStore.id()
    }

    for denied_token <- [other["token"], restricted["token"]] do
      :post
      |> json_conn("#{path}/#{id}/quota/reset", reset_attrs)
      |> user_auth(denied_token)
      |> call()
      |> expect_json(403)
    end

    :post
    |> json_conn("#{other_path}/#{id}/quota/reset", reset_attrs)
    |> user_auth(other["token"])
    |> call()
    |> expect_json(404)

    :post
    |> json_conn(path, %{"provider" => "invalid", "credentials" => %{}})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    updated =
      :patch
      |> json_conn("#{path}/#{id}", %{"version" => account["version"], "disabled" => true})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert updated["disabled"]

    :patch
    |> json_conn("#{path}/#{id}", %{"version" => account["version"], "disabled" => false})
    |> user_auth(token)
    |> call()
    |> expect_json(409)

    _updated =
      :patch
      |> json_conn("#{path}/#{id}", %{"version" => updated["version"], "disabled" => false})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    quota =
      :post
      |> json_conn("#{path}/#{id}/quota", %{})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert hd(quota["quota"]["windows"])["remaining_percent"] == 75

    reset_attrs = %{reset_attrs | "version" => quota["version"]}

    reset =
      :post
      |> json_conn("#{path}/#{id}/quota/reset", reset_attrs)
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert reset["outcome"] == "reset"
    assert reset["quota_refreshed"]
    refute Jason.encode!(reset) =~ "secret"

    replay =
      :post
      |> json_conn("#{path}/#{id}/quota/reset", reset_attrs)
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert replay["outcome"] == "reset"
    quota = replay["account"]

    attempt =
      :post
      |> json_conn("#{path}/oauth", %{
        "provider" => "codex",
        "account_id" => id,
        "version" => quota["version"]
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    :post
    |> json_conn("#{other_path}/oauth/#{attempt["id"]}", %{"code" => "code"})
    |> user_auth(other["token"])
    |> call()
    |> expect_json(400)

    updated =
      :post
      |> json_conn("#{path}/oauth/#{attempt["id"]}", %{"code" => "code"})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    refute Jason.encode!(updated) =~ "secret"

    :delete
    |> json_conn("#{path}/#{id}", %{"version" => updated["version"]})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:error, :not_found} =
             SalixAgent.SubscriptionStore.get(workspace["salix_tenant_id"], id)
  end

  defmodule DiscoveryProvider do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"data" => [%{"id" => "o3"}]}))
    end
  end

  test "members see the platform model only as Comma" do
    platform = SalixAgent.AccountPool.platform_tenant()

    on_exit(fn ->
      SalixStore.S3.delete(SalixStore.Keys.ctl_system_platform_models())

      SalixAgent.SubscriptionStore.query(
        "DELETE FROM subscription_accounts WHERE tenant_id=$1",
        [platform]
      )
    end)

    {:ok, profile} =
      SalixAgent.AccountPool.create(platform, %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "api_key" => "sk-platform-0123456789",
        "base_url" => "https://internal-gateway.example.test/v1",
        "protocol" => "responses",
        "models" => ["gpt-6-sol"]
      })

    {:ok, _} =
      SalixAgent.PlatformModels.put(%{
        "tiers" => %{
          "router" => %{"profile_id" => profile["id"], "model" => "gpt-6-sol", "images" => true}
        }
      })

    login = email_login!("platform-model@example.com")
    workspace = create_ready_workspace!(login["user"])

    models =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}/agent-models")
      |> user_auth(login["token"])
      |> call()
      |> expect_json(200)

    router = get_in(models, ["agents", "router"])
    assert router["selection"] == %{"kind" => "builtin"}
    assert router["name"] == "Comma" or router["model_display_name"] == "Comma"
    assert get_in(models, ["platform_defaults", "router", "model"]) == "Comma"

    body = Jason.encode!(models)
    refute body =~ "gpt-6-sol"
    refute body =~ "internal-gateway.example.test"
  end

  @tag :byok
  test "Agents choose a catalog model and effort or the built-in model, and can be renamed" do
    login = email_login!("catalog-agent-models@example.com")
    token = login["token"]
    workspace = create_ready_workspace!(login["user"])
    base = "/v1/comma/workspaces/#{workspace["id"]}"
    models = fn -> :get |> conn(base <> "/agent-models") |> user_auth(token) |> call() end

    router = models.() |> expect_json(200) |> get_in(["agents", "router"])
    assert router["selection"] == %{"kind" => "builtin"}
    choose = base <> "/agents/#{router["agent_id"]}/model"

    selection = %{
      "kind" => "catalog",
      "model" => "gpt-5.5",
      "reasoning_effort" => "high",
      "allow_paid" => false
    }

    chosen =
      :put
      |> json_conn(choose, %{"selection" => selection})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert chosen["selection"] == Map.put(selection, "profile_id", nil)
    assert chosen["model_display_name"] == "GPT-5.5"

    assert {:ok, %{"model" => stored}} =
             SalixAgent.Control.get(router["agent_id"], workspace["salix_tenant_id"])

    assert stored == selection

    assert get_in(expect_json(models.(), 200), ["agents", "router", "selection"]) ==
             Map.put(selection, "profile_id", nil)

    for bad <- [
          %{selection | "model" => "no-such-model"},
          %{selection | "reasoning_effort" => "ultra"},
          Map.delete(selection, "allow_paid")
        ] do
      :put
      |> json_conn(choose, %{"selection" => bad})
      |> user_auth(token)
      |> call()
      |> expect_json(400)
    end

    builtin =
      :put
      |> json_conn(choose, %{"selection" => %{"kind" => "builtin"}})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert builtin["selection"] == %{"kind" => "builtin"}

    assert {:ok, %{"model" => nil}} =
             SalixAgent.Control.get(router["agent_id"], workspace["salix_tenant_id"])

    rename = base <> "/agents/#{router["agent_id"]}"

    assert %{"name" => "Dispatcher"} =
             :patch
             |> json_conn(rename, %{"name" => "  Dispatcher "})
             |> user_auth(token)
             |> call()
             |> expect_json(200)

    assert get_in(expect_json(models.(), 200), ["agents", "router", "name"]) == "Dispatcher"

    :patch
    |> json_conn(rename, %{"name" => " "})
    |> user_auth(token)
    |> call()
    |> expect_json(400)
  end

  @tag :byok
  test "the Router's reply style is the default until the owner picks concise" do
    login = email_login!("reply-style@example.com")
    token = login["token"]
    workspace = create_ready_workspace!(login["user"])
    base = "/v1/comma/workspaces/#{workspace["id"]}"

    router = fn ->
      :get
      |> conn(base <> "/agent-models")
      |> user_auth(token)
      |> call()
      |> expect_json(200)
      |> get_in(["agents", "router"])
    end

    put = fn style ->
      :put
      |> json_conn(base <> "/reply-style", %{"reply_style" => style})
      |> user_auth(token)
      |> call()
    end

    assert router.()["reply_style"] == "default"

    assert "concise" |> put.() |> expect_json(200) == %{"reply_style" => "concise"}
    assert router.()["reply_style"] == "concise"

    assert {:ok, %{"reply_style" => "concise"}} =
             SalixAgent.Control.get(router.()["agent_id"], workspace["salix_tenant_id"])

    "terse" |> put.() |> expect_json(400)
    assert router.()["reply_style"] == "concise"

    assert "default" |> put.() |> expect_json(200) == %{"reply_style" => "default"}
    assert router.()["reply_style"] == "default"
  end

  @tag :byok
  test "the Workspace's default place to run Tasks is Salix until a member picks the Cloud VM or a station" do
    login = email_login!("task-place@example.com")
    token = login["token"]
    workspace = create_ready_workspace!(login["user"])
    group_id = workspace["default_group_id"]
    base = "/v1/comma/workspaces/#{workspace["id"]}"

    models = fn ->
      :get |> conn(base <> "/agent-models") |> user_auth(token) |> call() |> expect_json(200)
    end

    put = fn place, token ->
      :put |> json_conn(base <> "/task-place", %{"place" => place}) |> user_auth(token) |> call()
    end

    assert models.()["task_place"] == %{"place" => %{"kind" => "salix"}}

    # The Cloud VM only while the Workspace's Cloud VM is on.
    assert %{"kind" => "cloud_vm"} |> put.(token) |> expect_json(400)

    {:ok, _} =
      SalixStore.CasRecord.update(
        SalixStore.Keys.ctl_group(group_id),
        &Map.put(&1, "cloud_vm_enabled", true),
        create: false
      )

    assert %{"kind" => "cloud_vm"} |> put.(token) |> expect_json(200) ==
             %{"place" => %{"kind" => "cloud_vm"}}

    # A station is one of the Workspace's devices.
    %{"kind" => "station", "device_id" => "device-elsewhere"} |> put.(token) |> expect_json(404)

    transport = "station-task-place"

    {:ok, ^transport, _record} =
      SalixEnv.Registry.connect(
        "test-node",
        %{
          "tenant_id" => workspace["salix_tenant_id"],
          "group_id" => group_id,
          "device_id" => "device-desk",
          "connector_id" => "connector-task-place",
          "name" => "Desk"
        },
        transport_id: transport
      )

    station = %{"kind" => "station", "device_id" => "device-desk"}
    assert station |> put.(token) |> expect_json(200) == %{"place" => station}
    assert models.()["task_place"] == %{"place" => station}

    other = email_login!("other-task-place@example.com")
    _other_workspace = create_ready_workspace!(other["user"])
    %{"kind" => "salix"} |> put.(other["token"]) |> expect_json(403)
    assert {:ok, ^station} = SalixAgent.TaskPlace.get(group_id)

    assert %{"kind" => "salix"} |> put.(token) |> expect_json(200) ==
             %{"place" => %{"kind" => "salix"}}
  end

  @tag :byok
  test "the Workspace's default Task model is Comma's built-in model until the member picks one" do
    login = email_login!("task-model@example.com")
    token = login["token"]
    workspace = create_ready_workspace!(login["user"])
    group_id = workspace["default_group_id"]
    base = "/v1/comma/workspaces/#{workspace["id"]}"

    models = fn ->
      :get |> conn(base <> "/agent-models") |> user_auth(token) |> call() |> expect_json(200)
    end

    put = fn selection, token ->
      :put
      |> json_conn(base <> "/task-model", %{"selection" => selection})
      |> user_auth(token)
      |> call()
    end

    assert models.()["task_model"] == %{"selection" => %{"kind" => "builtin"}}

    selection = %{
      "kind" => "catalog",
      "model" => "gpt-5.5",
      "reasoning_effort" => "high",
      "allow_paid" => false
    }

    shown = Map.put(selection, "profile_id", nil)
    assert put.(selection, token) |> expect_json(200) == %{"selection" => shown}
    assert models.()["task_model"] == %{"selection" => shown}
    assert {:ok, ^selection} = SalixAgent.TaskModel.get(group_id)

    for bad <- [
          %{selection | "model" => "no-such-model"},
          %{selection | "reasoning_effort" => "ultra"},
          Map.delete(selection, "allow_paid"),
          %{"kind" => "runtime", "provider" => "codex", "model" => "gpt-5.5"}
        ] do
      bad |> put.(token) |> expect_json(400)
    end

    other = email_login!("other-task-model@example.com")
    _other_workspace = create_ready_workspace!(other["user"])
    %{"kind" => "builtin"} |> put.(other["token"]) |> expect_json(403)
    assert {:ok, ^selection} = SalixAgent.TaskModel.get(group_id)

    # Back to Comma's model: stored as the platform model, so it outranks
    # a model the Workspace's Worker still has from earlier settings.
    assert %{"kind" => "builtin"} |> put.(token) |> expect_json(200) ==
             %{"selection" => %{"kind" => "builtin"}}

    assert {:ok, %{"kind" => "platform", "tier" => "worker"}} =
             SalixAgent.TaskModel.get(group_id)
  end

  @tag :byok
  test "old clients still read an empty Worker page with the Workspace's models" do
    login = email_login!("old-client-models@example.com")

    workspace =
      login["user"] |> create_ready_workspace!() |> CommaWeb.TestWorkers.with_default_worker!()

    base = "/v1/comma/workspaces/#{workspace["id"]}/agent-models"
    selection = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}

    # Even a Worker with its own model is listed nowhere.
    :put
    |> json_conn(
      "/v1/comma/workspaces/#{workspace["id"]}/agents/#{workspace["default_worker_agent_id"]}/model",
      %{"selection" => selection}
    )
    |> user_auth(login["token"])
    |> call()
    |> expect_json(200)

    empty = %{"items" => [], "next_cursor" => nil}

    assert %{"agents" => %{"router" => %{}}, "workers" => ^empty} =
             :get |> conn(base) |> user_auth(login["token"]) |> call() |> expect_json(200)

    assert :get
           |> conn(base <> "/workers?cursor=abc")
           |> user_auth(login["token"])
           |> call()
           |> expect_json(200) == empty

    other = email_login!("old-client-models-other@example.com")
    _other_workspace = create_ready_workspace!(other["user"])

    :get |> conn(base <> "/workers") |> user_auth(other["token"]) |> call() |> expect_json(403)
  end

  @tag :byok
  test "a release gives a Workspace its Task Worker's own model as the default Task model" do
    login = email_login!("derived-task-model@example.com")

    workspace =
      login["user"] |> create_ready_workspace!() |> CommaWeb.TestWorkers.with_default_worker!()

    group_id = workspace["default_group_id"]

    selection = %{
      "kind" => "catalog",
      "model" => "gpt-5.5",
      "reasoning_effort" => "high",
      "allow_paid" => false
    }

    # The Worker's model as Settings > Models set it before this release.
    :put
    |> json_conn(
      "/v1/comma/workspaces/#{workspace["id"]}/agents/#{workspace["default_worker_agent_id"]}/model",
      %{"selection" => selection}
    )
    |> user_auth(login["token"])
    |> call()
    |> expect_json(200)

    following =
      email_login!("following-task-model@example.com")["user"]
      |> create_ready_workspace!()
      |> CommaWeb.TestWorkers.with_default_worker!()

    assert {:ok, _counts} = Comma.Migrations.DefaultTaskModels.run(Comma.Repo)
    assert {:ok, ^selection} = SalixAgent.TaskModel.get(group_id)
    # A Worker that follows the platform model leaves the Group without one.
    assert {:ok, nil} = SalixAgent.TaskModel.get(following["default_group_id"])

    # A default the member chose since stays when the pass runs again.
    platform = SalixAgent.TaskModel.platform()
    {:ok, _} = SalixAgent.TaskModel.put(workspace["salix_tenant_id"], group_id, platform)
    assert {:ok, _counts} = Comma.Migrations.DefaultTaskModels.run(Comma.Repo)
    assert {:ok, ^platform} = SalixAgent.TaskModel.get(group_id)
  end

  @tag :byok
  test "a model choice changes only the chosen Worker of the member's own Workspace" do
    login = email_login!("worker-choices@example.com")
    token = login["token"]
    workspace = create_ready_workspace!(login["user"])
    workspace = CommaWeb.TestWorkers.with_default_worker!(workspace)
    tenant_id = workspace["salix_tenant_id"]
    base = "/v1/comma/workspaces/#{workspace["id"]}"
    selection = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}

    choose = fn agent_id ->
      :put
      |> json_conn(base <> "/agents/#{agent_id}/model", %{"selection" => selection})
      |> user_auth(token)
      |> call()
    end

    {:ok, new_worker} =
      SalixAgent.Control.create(
        %{
          "group_id" => workspace["default_group_id"],
          "role" => "worker",
          "name" => "Second Worker"
        },
        tenant_id
      )

    new_worker["agent_id"] |> choose.() |> expect_json(200)

    assert {:ok, %{"model" => ^selection}} =
             SalixAgent.Control.get(new_worker["agent_id"], tenant_id)

    # Only the Workspace's own group and its Workers are targets.
    {:ok, other_group} = Salix.Control.Groups.create(%{"name" => "Other group"}, tenant_id)

    {:ok, foreign_worker} =
      SalixAgent.Control.create(
        %{"group_id" => other_group["group_id"], "role" => "worker"},
        tenant_id
      )

    other =
      email_login!("other-worker-choices@example.com")["user"]
      |> create_ready_workspace!()
      |> CommaWeb.TestWorkers.with_default_worker!()

    for agent_id <- [foreign_worker["agent_id"], other["default_worker_agent_id"]] do
      agent_id |> choose.() |> expect_json(404)
    end

    assert {:ok, foreign} = SalixAgent.Control.get(foreign_worker["agent_id"], tenant_id)
    assert foreign["model"] == nil
  end

  @tag :byok
  test "users add their own keys and select models without revealing credentials" do
    login = email_login!("byok@example.com")
    token = login["token"]
    workspace = create_ready_workspace!(login["user"])
    workspace = CommaWeb.TestWorkers.with_default_worker!(workspace)
    base = "/v1/comma/workspaces/#{workspace["id"]}"
    worker_id = workspace["default_worker_agent_id"]
    other = email_login!("byok-other@example.com")
    _other_workspace = create_ready_workspace!(other["user"])

    discovery_path = base <> "/model-discovery"
    # A closed port on this machine: the member's endpoint never answers.
    unreachable = "https://127.0.0.1:1/v1"

    discovery_input = %{
      "base_url" => unreachable,
      "api_key" => "byok-secret",
      "protocol" => "responses"
    }

    :post |> json_conn(discovery_path, discovery_input) |> call() |> expect_json(401)

    :post
    |> json_conn(discovery_path, discovery_input)
    |> user_auth(other["token"])
    |> call()
    |> expect_json(403)

    :post
    |> json_conn(discovery_path, Map.put(discovery_input, "api_key", ""))
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{login["user"]["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :post
    |> json_conn(discovery_path, discovery_input)
    |> user_auth(restricted["token"])
    |> call()
    |> expect_json(403)

    server =
      start_supervised!(
        {Bandit, plug: DiscoveryProvider, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    response =
      :post
      |> json_conn(discovery_path, %{
        discovery_input
        | "base_url" => "http://127.0.0.1:#{port}/v1"
      })
      |> user_auth(token)
      |> call()

    assert %{"data" => [%{"id" => "o3"}]} = expect_json(response, 200)
    assert get_resp_header(response, "cache-control") == ["no-store"]
    refute response.resp_body =~ "byok-secret"

    # The member's own endpoint key serves the model they choose.
    profile =
      :post
      |> json_conn(base <> "/subscription-accounts", %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "base_url" => unreachable,
        "protocol" => "responses",
        "api_key" => "byok-secret",
        "models" => ["gpt-byok"]
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    refute Jason.encode!(profile) =~ "byok-secret"
    selection = %{"kind" => "catalog", "model" => "gpt-byok", "allow_paid" => true}

    choose = fn agent_id, selection, token ->
      :put
      |> json_conn(base <> "/agents/#{agent_id}/model", %{"selection" => selection})
      |> user_auth(token)
      |> call()
    end

    worker_id |> choose.(selection, other["token"]) |> expect_json(403)
    chosen_conn = choose.(worker_id, selection, token)
    chosen = expect_json(chosen_conn, 200)
    assert chosen["source"] == "pinned"
    assert chosen["selection"]["model"] == "gpt-byok"
    refute chosen_conn.resp_body =~ "byok-secret"

    assert {:ok, llm} = SalixAgent.AgentModel.resolve_llm_for_agent(worker_id)
    assert llm["catalog_model"] == "gpt-byok"
    assert llm["credential_scope"] == "tenant"
    refute Map.has_key?(llm, "api_key")

    # A Router on the member's own key runs without platform credits.
    workspace["router_agent_id"] |> choose.(selection, token) |> expect_json(200)

    # A Custom model id that names no known provider still shows on the page.
    relay_profile =
      :post
      |> json_conn(base <> "/subscription-accounts", %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "base_url" => unreachable,
        "protocol" => "chat_completions",
        "api_key" => "relay-secret",
        "models" => ["relay-ai/model-1"]
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    relay = %{"kind" => "catalog", "model" => "relay-ai/model-1", "allow_paid" => false}
    relayed = workspace["router_agent_id"] |> choose.(relay, token) |> expect_json(200)
    assert relayed["selection"]["model"] == "relay-ai/model-1"
    assert relayed["selection"]["allow_paid"] == true

    shown =
      :get |> conn(base <> "/agent-models") |> user_auth(token) |> call() |> expect_json(200)

    assert get_in(shown, ["agents", "router", "selection", "model"]) == "relay-ai/model-1"

    # Removing the endpoint's Profile leaves the choice readable, so the page
    # still opens and the member can choose another model.
    tenant_id = workspace["salix_tenant_id"]
    {:ok, stored_relay} = SalixAgent.SubscriptionStore.get(tenant_id, relay_profile["id"])
    SalixAgent.AccountPool.delete(tenant_id, stored_relay["id"], stored_relay["version"])

    assert {:error, :not_found} =
             SalixAgent.SubscriptionStore.get(tenant_id, relay_profile["id"])

    shown =
      :get |> conn(base <> "/agent-models") |> user_auth(token) |> call() |> expect_json(200)

    assert get_in(shown, ["agents", "router", "selection", "model"]) == "relay-ai/model-1"

    workspace["router_agent_id"] |> choose.(selection, token) |> expect_json(200)

    assert {:ok, %{fee_control: %{reason: "tenant_credentials"}}} =
             Comma.AgentPolicies.authorize_send(
               workspace,
               %{"id" => "byok-chat", "kind" => "user_chat"},
               %{},
               %{}
             )

    # A Worker the Router creates with the member's model stores that choice.
    previous_ports = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, CommaWeb.AgentManagement)
    on_exit(fn -> restore_env(:salix_agent, :agent_management_ports, previous_ports) end)

    assert {:ok, created_worker} =
             SalixAgent.AgentManagement.run(
               :create,
               %{
                 "name" => "BYOK task worker",
                 "purpose" => "User task",
                 "creation_reason" => "Exercise a Worker with the user-selected BYOK model",
                 "runtime" => %{"kind" => "internal"},
                 "model" => selection
               },
               %{
                 agent_id: workspace["router_agent_id"],
                 session_id: "byok-session",
                 tool_call_id: "byok-create"
               }
             )

    assert {:ok, %{"model" => ^selection}} =
             SalixAgent.Control.get(
               created_worker["agent"]["agent_id"],
               workspace["salix_tenant_id"]
             )

    # Back to Comma's model, which the page names.
    followed = worker_id |> choose.(%{"kind" => "builtin"}, token) |> expect_json(200)
    assert followed["source"] == "platform_default"

    # A Task runs its Session's model: the member's own key makes it private
    # though its Agent follows Comma's model; without one it follows its Agent.
    {:ok, byok_choice} = SalixAgent.ModelChoice.choose(selection, workspace["salix_tenant_id"])

    task_binding = fn attrs ->
      {:ok, %{"conversation_id" => id}} =
        SalixCluster.TaskSchedules.create_task_conversation(
          workspace["default_group_id"],
          workspace["router_agent_id"],
          worker_id,
          Map.merge(%{"content" => "Summarize the notes"}, attrs)
        )

      %{"kind" => "agent_task", "internal" => %{"salix_conversation_id" => id}}
    end

    assert Comma.Salix.Client.conversation_uses_private_model?(
             workspace,
             task_binding.(%{
               "client_request_id" => "byok-task-session",
               "session_model" => byok_choice
             })
           )

    refute Comma.Salix.Client.conversation_uses_private_model?(
             workspace,
             task_binding.(%{"client_request_id" => "byok-task-agent"})
           )

    assert followed["selection"] == %{"kind" => "builtin"}

    models =
      :get |> conn(base <> "/agent-models") |> user_auth(token) |> call() |> expect_json(200)

    assert models["platform_defaults"]["worker"]["model"] == followed["model"]

    # Desktop apps already shipped read a Worker and a Worker list: the
    # "worker" is the Group's Task agent, and the list stays empty.
    assert models["agents"]["worker"]["agent_id"] == worker_id
    assert {:ok, ^worker_id} = SalixAgent.TaskAgent.get(workspace["default_group_id"])
    assert models["workers"] == %{"items" => [], "next_cursor" => nil}

    assert %{"items" => [], "next_cursor" => nil} =
             :get
             |> conn(base <> "/agent-models/workers")
             |> user_auth(token)
             |> call()
             |> expect_json(200)
  end

  test "Admin sets and clears one Workspace's coding sandbox limit; others are refused" do
    previous = SystemsRuntime.get_env(:salix_web, :l4es)
    SystemsRuntime.put_env(:salix_web, :l4es, url: "https://l4es.test", max_sandboxes: 5)
    on_exit(fn -> restore_env(:salix_web, :l4es, previous) end)

    {operator, token} = browser_cookie_login!("limit-operator@comma.surf", @admin_origin)

    {outsider, outsider_token} =
      browser_cookie_login!("limit-outsider@example.com", @admin_origin)

    {:ok, target} = Comma.Accounts.create_user(%{"email" => "limit-target@example.com"})
    workspace = create_ready_workspace!(target)
    tenant_id = workspace["salix_tenant_id"]
    path = "/v1/comma/admin/users/#{target["id"]}/workspaces/sandbox-limit"

    command = fn max, label ->
      %{
        "max_sandboxes" => max,
        "reason" => "Workspace needs more sandboxes",
        "confirmation" => "workspace-sandbox-limit:#{target["id"]}:#{label}",
        "idempotency_key" => SystemsRuntime.Proc.uuid()
      }
    end

    as_operator = &cookie_auth(&1, token, @admin_origin, operator["session_id"])

    assert %{"override" => nil, "default" => 5, "effective" => 5, "workspace_id" => workspace_id} =
             conn(:get, path) |> as_operator.() |> call() |> expect_json(200)

    assert workspace_id == workspace["id"]

    conn(:get, path)
    |> cookie_auth(outsider_token, @admin_origin, outsider["session_id"])
    |> call()
    |> expect_json(403)

    :put |> json_conn(path, command.(8, 8)) |> call() |> expect_json(401)

    :put
    |> json_conn(path, command.(8, 8))
    |> cookie_auth(outsider_token, @admin_origin, outsider["session_id"])
    |> call()
    |> expect_json(403)

    assert SalixWeb.L4ES.max_sandboxes(tenant_id) == 5

    for bad <- [0, 101, "8", 2.5] do
      label = if is_integer(bad), do: bad, else: "default"

      assert %{"error" => "max_sandboxes must be an integer from 1 to 100"} =
               :put
               |> json_conn(path, command.(bad, label))
               |> as_operator.()
               |> call()
               |> expect_json(400)
    end

    assert %{"override" => 8, "default" => 5, "effective" => 8} =
             :put
             |> json_conn(path, command.(8, 8))
             |> as_operator.()
             |> call()
             |> expect_json(200)

    assert SalixWeb.L4ES.max_sandboxes(tenant_id) == 8

    assert %{"override" => nil, "effective" => 5} =
             :put
             |> json_conn(path, command.(nil, "default"))
             |> as_operator.()
             |> call()
             |> expect_json(200)

    assert SalixWeb.L4ES.max_sandboxes(tenant_id) == 5
  end

  @tag :workspace_cloud_vm
  test "Admin audits exact-workspace VM settings and converges the Workspace Group's Cloud VM switch" do
    previous = SystemsRuntime.get_env(:salix_agent, :cloud_vm_mod)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_mod, __MODULE__.WorkspaceVM)
    on_exit(fn -> restore_env(:salix_agent, :cloud_vm_mod, previous) end)

    SystemsRuntime.put_env(:comma_core, :salix_vm, %{
      "providers" => %{"cloudflare" => %{"enabled" => true, "token" => "test-only"}}
    })

    {operator, token} = browser_cookie_login!("vm-operator@comma.surf", @admin_origin)
    {:ok, target} = Comma.Accounts.create_user(%{"email" => "vm-target@example.com"})

    workspace =
      create_ready_workspace!(target, %{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})

    # The Group's Task agent, made after the Workspace, follows the Workspace
    # Group's switch too.
    {:ok, worker_id} = CommaWeb.AgentManagement.workspace_task_agent(workspace)
    assert {:ok, worker} = SalixAgent.Control.get(worker_id, workspace["salix_tenant_id"])
    assert SalixAgent.CloudVM.allowed?(worker)
    workspace_id = workspace["id"]
    path = "/v1/comma/admin/users/#{target["id"]}/workspaces/#{workspace_id}/vm"
    other_workspace = create_ready_workspace!(operator["user"])
    {outsider, outsider_token} = browser_cookie_login!("vm-outsider@example.com", @admin_origin)

    for enabled <- [false, true] do
      state = if enabled, do: "enable", else: "disable"

      body = %{
        "enabled" => enabled,
        "reason" => "Configure this Workspace Cloud VM",
        "confirmation" => "workspace-vm:#{workspace_id}:#{state}",
        "idempotency_key" => SystemsRuntime.Proc.uuid()
      }

      :put |> json_conn(path, body) |> call() |> expect_json(401)

      :put
      |> json_conn(path, body)
      |> cookie_auth(outsider_token, @admin_origin, outsider["session_id"])
      |> call()
      |> expect_json(403)

      :put
      |> json_conn(path, Map.put(body, "confirmation", "wrong-workspace"))
      |> cookie_auth(token, @admin_origin, operator["session_id"])
      |> call()
      |> expect_json(400)

      result =
        :put
        |> json_conn(path, body)
        |> cookie_auth(token, @admin_origin, operator["session_id"])
        |> call()

      assert %{
               "workspace_id" => ^workspace_id,
               "enabled" => ^enabled,
               "convergence_status" => "pending"
             } = expect_json(result, 202)

      assert get_resp_header(result, "cache-control") == ["no-store"]
      row = Repo.get!(Comma.Data.Workspace, workspace_id)
      assert row.vm == %{"enabled" => enabled, "provider" => "cloudflare"}
      assert Repo.get!(Comma.Data.Workspace, other_workspace["id"]).vm == %{"enabled" => false}

      operation =
        Repo.get_by!(Comma.Data.ExternalOperation,
          owner_id: workspace_id,
          operation_type: "workspace_convergence",
          generation: row.lock_version
        )

      assert Repo.exists?(
               from(job in Oban.Job,
                 where: fragment("?->>'operation_id'", job.args) == ^operation.operation_id
               )
             )

      assert {:ok, %{status: "succeeded"}} =
               Comma.Workers.WorkspaceConvergence.run(operation.operation_id)

      assert {:ok, %{"cloud_vm_enabled" => ^enabled}} =
               Salix.Control.Groups.get(
                 workspace["default_group_id"],
                 workspace["salix_tenant_id"]
               )

      for agent_id <- [workspace["router_agent_id"], worker_id] do
        assert {:ok, agent} = SalixAgent.Control.get(agent_id, workspace["salix_tenant_id"])
        refute Map.has_key?(agent, "vm")
        assert SalixAgent.CloudVM.allowed?(agent) == enabled
      end

      assert %{outcome: "succeeded", target_id: ^workspace_id} =
               Repo.get_by!(Comma.Admin.AuditEvent,
                 action: "update_workspace_vm",
                 idempotency_key: body["idempotency_key"]
               )

      :put
      |> json_conn(path, body)
      |> cookie_auth(token, @admin_origin, operator["session_id"])
      |> call()
      |> expect_json(409)

      assert Repo.get!(Comma.Data.Workspace, workspace_id).lock_version == row.lock_version
    end

    :put
    |> json_conn(path, %{
      "enabled" => "yes",
      "reason" => "Reject invalid input",
      "confirmation" => "workspace-vm:#{workspace_id}:disable",
      "idempotency_key" => SystemsRuntime.Proc.uuid()
    })
    |> cookie_auth(token, @admin_origin, operator["session_id"])
    |> call()
    |> expect_json(400)

    assert %{
             "workspace" => %{
               "cloud_vm" => %{"enabled" => true, "convergence_status" => "succeeded"}
             }
           } =
             :get
             |> conn("/v1/comma/admin/users/#{target["id"]}/workspaces")
             |> cookie_auth(token, @admin_origin, operator["session_id"])
             |> call()
             |> expect_json(200)

    assert {:error, :not_found} =
             Comma.Admin.update_user_workspace_vm(target["id"], other_workspace["id"], true)
  end

  defmodule WorkspaceVM do
    def validate_group_enabled(_tenant, _group), do: :ok
    def ensure_provisioning(_agent), do: {:ok, %{}}
    def mark_agent_settled(_agent), do: :ok
  end

  test "guest mode: admin enables it, guests reach only their Router chat, and sign-up redeems the claim" do
    {admin_session, admin_token} = browser_cookie_login!("guest-admin@comma.surf", @admin_origin)

    admin = fn conn ->
      cookie_auth(conn, admin_token, @admin_origin, admin_session["session_id"])
    end

    # The web asks with its signed-out lifecycle headers, as a browser sends them.
    guest_status = fn ->
      :get
      |> conn("/v1/comma/auth/guest")
      |> web_cookie_request(@web_origin, :none)
      |> raw_call()
    end

    assert %{"enabled" => false} = guest_status.() |> expect_json(200)

    web_guest = fn body ->
      :post
      |> json_conn("/v1/comma/auth/guest", body)
      |> web_cookie_request(@web_origin, :none)
      |> call()
    end

    assert %{"error" => "guest_mode_disabled"} = %{} |> web_guest.() |> expect_json(404)

    policy = :get |> conn("/v1/comma/admin/guest-mode") |> admin.() |> call() |> expect_json(200)

    command = fn attrs, key, confirmation ->
      Map.merge(attrs, %{
        "reason" => "Open guest mode",
        "idempotency_key" => key,
        "confirmation" => confirmation
      })
    end

    policy =
      :post
      |> json_conn(
        "/v1/comma/admin/guest-mode/tenant",
        command.(
          %{"revision" => policy["revision"]},
          "guest-tenant-1",
          "create-guest-tenant:comma"
        )
      )
      |> admin.()
      |> call()
      |> expect_json(200)

    assert is_binary(policy["salix_tenant_id"])

    assert %{"enabled" => true} =
             :put
             |> json_conn(
               "/v1/comma/admin/guest-mode",
               command.(
                 %{"enabled" => true, "revision" => policy["revision"]},
                 "guest-enable-1",
                 "update-guest-policy:comma"
               )
             )
             |> admin.()
             |> call()
             |> expect_json(200)

    assert %{"enabled" => true, "pow" => %{"difficulty" => 12}} =
             guest_status.() |> expect_json(200)

    assert %{"error" => "guest_pow_invalid"} =
             %{"client_kind" => "web"} |> web_guest.() |> expect_json(400)

    # Guest mode is web-only: a bearer client still needs to sign in.
    assert %{"error" => "guest_web_only"} =
             :post
             |> json_conn("/v1/comma/auth/guest", %{
               "client_kind" => "electron",
               "pow" => solved_guest_pow!()
             })
             |> call()
             |> expect_json(403)

    guest_conn = web_guest.(%{"client_kind" => "web", "pow" => solved_guest_pow!()})
    guest_session = expect_json(guest_conn, 200)
    refute Map.has_key?(guest_session, "token")
    assert %{"kind" => "guest"} = guest_session["user"]
    guest_cookie = guest_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()].value

    as_guest = fn conn ->
      cookie_auth(conn, guest_cookie, @web_origin, guest_session["session_id"])
    end

    assert %{"user" => %{"kind" => "guest"}} =
             :get |> conn("/v1/comma/auth/session") |> as_guest.() |> call() |> expect_json(200)

    for {method, path} <- [
          {:get, "/v1/comma/auth/sessions"},
          {:get, "/v1/comma/billing/summary"},
          {:post, "/v1/comma/guest-imports"}
        ] do
      assert %{"error" => "guest_signup_required"} =
               method |> json_conn(path, %{}) |> as_guest.() |> call() |> expect_json(403)
    end

    bootstrap = :post |> json_conn("/v1/comma/me/bootstrap", %{}) |> as_guest.() |> call()
    assert bootstrap.status in [200, 202]

    # The claim stays in an HttpOnly Cookie; the response never carries it.
    handoff_conn =
      :post |> json_conn("/v1/comma/auth/guest/handoff", %{}) |> as_guest.() |> call()

    refute Map.has_key?(expect_json(handoff_conn, 200), "claim")
    claim_cookie = handoff_conn.resp_cookies["comma_guest_claim"]
    assert claim_cookie.http_only == true
    assert claim_cookie.path == "/v1/comma"

    :get |> conn("/v1/comma/auth/session") |> as_guest.() |> call() |> expect_json(401)

    # A bearer account cannot redeem a claim, even one it learned some other way.
    account =
      email_login!("guest-signup-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com")

    assert %{"error" => "guest_claim_invalid"} =
             :post
             |> json_conn("/v1/comma/guest-imports", %{"claim" => claim_cookie.value})
             |> user_auth(account["token"])
             |> call()
             |> expect_json(404)

    {web_session, web_token} =
      browser_cookie_login!(
        "guest-web-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com",
        @web_origin
      )

    assert %{"error" => "guest_only"} =
             :post
             |> json_conn("/v1/comma/auth/guest/handoff", %{})
             |> cookie_auth(web_token, @web_origin, web_session["session_id"])
             |> call()
             |> expect_json(403)

    redeem = fn ->
      :post
      |> json_conn("/v1/comma/guest-imports", %{})
      |> put_req_header(
        "cookie",
        "#{CommaWeb.SessionCookie.cookie_name()}=#{web_token}; comma_guest_claim=#{claim_cookie.value}"
      )
      |> web_cookie_request(@web_origin, web_session["session_id"])
      |> call()
    end

    # A transient failure keeps the claim Cookie, so a later attempt can retry.
    # Here a conflicting import Operation makes the redemption fail.
    guest_id = guest_session["user"]["id"]

    conflict =
      Repo.insert!(%Comma.Data.ExternalOperation{
        operation_id: "gim_conflict_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        operation_type: "guest_import",
        owner_type: "comma_user",
        owner_id: guest_id,
        generation: 1,
        status: "pending",
        attempt: 0,
        external_idempotency_key: "guest-import-fault:#{guest_id}",
        metadata: %{}
      })

    failed_conn = redeem.()
    assert %{"error" => "guest_mode_unavailable"} = expect_json(failed_conn, 503)
    refute Map.has_key?(failed_conn.resp_cookies, "comma_guest_claim")

    Repo.delete!(conflict)

    redeem_conn = redeem.()
    assert %{"import_id" => import_id, "status" => "pending"} = expect_json(redeem_conn, 202)
    assert redeem_conn.resp_cookies["comma_guest_claim"].max_age == 0

    # A repeated redemption returns the same import.
    assert %{"import_id" => ^import_id} = redeem.() |> expect_json(202)

    assert %{"import_id" => ^import_id} =
             :get
             |> conn("/v1/comma/guest-imports/#{import_id}")
             |> cookie_auth(web_token, @web_origin, web_session["session_id"])
             |> call()
             |> expect_json(200)
  end

  test "Admin free Router policy exempts only main calls and preserves an admitted decision" do
    {browser_session, token} = browser_cookie_login!("router-policy@comma.surf", @admin_origin)
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "router-policy-target@example.com"})
    workspace = create_ready_workspace!(user)
    account_id = workspace["billing_account_id"] || "comma-ba-#{workspace["id"]}"

    assert :ok =
             BillingCore.Accounts.ensure_account(%{
               billing_account_id: account_id,
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: workspace["id"]
             })

    path = "/v1/comma/admin/billing/free-router-models"

    initial =
      :get
      |> conn(path)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(200)

    attrs = %{
      "models" => [
        %{"provider" => "OpenAI", "sku" => "gpt-5.6"},
        %{"provider" => "openai", "sku" => "unpriced-router"}
      ],
      "revision" => initial["revision"],
      "reason" => "Free Router rollout",
      "confirmation" => "update-free-router-models:comma",
      "idempotency_key" => "router-policy-add-1"
    }

    {ordinary, ordinary_token} =
      browser_cookie_login!("router-policy-member@example.com", @admin_origin)

    :put
    |> json_conn(path, attrs)
    |> cookie_auth(ordinary_token, @admin_origin, ordinary["session_id"])
    |> call()
    |> expect_json(403)

    oversized =
      Map.merge(attrs, %{
        "models" => List.duplicate(%{"provider" => "openai", "sku" => "gpt-5.6"}, 101),
        "idempotency_key" => "router-policy-invalid"
      })

    :put
    |> json_conn(path, oversized)
    |> cookie_auth(token, @admin_origin, browser_session["session_id"])
    |> call()
    |> expect_json(400)

    saved =
      :put
      |> json_conn(path, attrs)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(200)

    assert saved["models"] == [
             %{"provider" => "openai", "sku" => "gpt-5.6-sol"},
             %{"provider" => "openai", "sku" => "unpriced-router"}
           ]

    assert %{"error" => "billing_policy_conflict"} =
             :put
             |> json_conn(path, Map.put(attrs, "idempotency_key", "router-policy-stale"))
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(409)

    audit =
      Repo.one!(
        from(event in Comma.Admin.AuditEvent,
          where: event.idempotency_key == "router-policy-add-1"
        )
      )

    assert audit.evidence["before"] == initial["models"]
    assert audit.evidence["after"] == saved["models"]

    # The Router follows the platform Router model, which the policy lists.
    SalixAgent.TestSupport.configure_platform_tier!(
      "router",
      "https://api.openai.com/v1",
      "gpt-5.6-sol"
    )

    billing = %{
      "surface" => "comma",
      "product_owner_type" => "workspace",
      "product_owner_id" => workspace["id"],
      "billing_account_id" => account_id,
      "salix_agent_id" => workspace["router_agent_id"],
      "salix_tenant_id" => workspace["salix_tenant_id"]
    }

    conversation = %{"id" => "router-policy-chat", "internal" => %{"billing_context" => billing}}

    assert {:ok, _} =
             Comma.AgentPolicies.authorize_send(workspace, conversation, %{}, %{
               "client_request_id" => "free-message"
             })

    fact = %{
      model_purpose: :agent_main,
      model: "gpt-5.6",
      provider: "openai",
      billing_context: billing,
      salix_agent_id: workspace["router_agent_id"],
      tenant_id: workspace["salix_tenant_id"],
      estimated_credits: 1,
      source_key: "free-router-call",
      usage: %{prompt_tokens: 10},
      metered_at: SystemsClock.utc_now()
    }

    assert {:ok, %{billing_exemption: "free_router_model"}} =
             decision = BillingCore.LLMMetering.before_llm_call(fact)

    for other <- [
          Map.put(fact, :salix_agent_id, workspace["default_worker_agent_id"]),
          Map.put(fact, :model_purpose, :tool),
          Map.put(fact, :tenant_id, "foreign"),
          Map.put(fact, :model, "gpt-5.4"),
          Map.put(fact, :provider, "other")
        ] do
      assert {:error, {:billing_unavailable, _}} = BillingCore.LLMMetering.before_llm_call(other)
    end

    unpriced = fact |> Map.put(:model, "unpriced-router") |> Map.put(:source_key, "free-unpriced")

    assert {:ok, %{billing_exemption: "free_router_model"}} =
             unpriced_decision = BillingCore.LLMMetering.before_llm_call(unpriced)

    unpriced = SalixAgent.LLMMetering.capture_decision(unpriced, unpriced_decision)

    assert :ok =
             BillingCore.LLMMetering.deliver(
               BillingCore.LLMMetering.usage_row(unpriced),
               Map.put(unpriced, :typed_sink, SalixAnalytics.Sink.Noop)
             )

    captured = SalixAgent.LLMMetering.capture_decision(fact, decision)

    removed =
      Map.merge(attrs, %{
        "models" => [],
        "revision" => saved["revision"],
        "idempotency_key" => "router-policy-remove"
      })

    :put
    |> json_conn(path, removed)
    |> cookie_auth(token, @admin_origin, browser_session["session_id"])
    |> call()
    |> expect_json(200)

    assert {:error, {:billing_unavailable, _}} = BillingCore.LLMMetering.before_llm_call(fact)
    row = BillingCore.LLMMetering.usage_row(captured)
    assert row["charge_status"] == "free_router_model"

    assert :ok =
             BillingCore.LLMMetering.deliver(
               row,
               Map.put(captured, :typed_sink, SalixAnalytics.Sink.Noop)
             )

    assert %{rows: [[0]]} =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT count(*) FROM credit_ledger WHERE billing_account_id = $1",
               [account_id]
             )

    assert %{rows: [[0]]} =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT count(*) FROM pending_meter_charges WHERE billing_account_id = $1",
               [account_id]
             )

    # The same model on a Worker uses the normal ledger after credits are issued.
    assert {:ok, _} =
             BillingCore.Credits.issue_grant(%{
               repo: BillingCore.Repo,
               billing_account_id: account_id,
               credits: 1000,
               valid_from: DateTime.add(fact.metered_at, -60),
               expires_at: DateTime.add(fact.metered_at, 3600),
               source_type: "manual_contract",
               source_id: "router-test",
               source_event_id: "router-test",
               idempotency_key: "router-test"
             })

    worker =
      fact
      |> Map.put(:salix_agent_id, workspace["default_worker_agent_id"])
      |> Map.put(:source_key, "worker-paid")
      |> Map.put(:typed_sink, SalixAnalytics.Sink.Noop)

    assert {:ok, _} = BillingCore.LLMMetering.before_llm_call(worker)

    assert {:ok, charge} =
             BillingCore.LLMMetering.deliver(BillingCore.LLMMetering.usage_row(worker), worker)

    assert charge.charged_credits == 50
  end

  test "Admin projects and independently updates the effective Workspace Router and Worker models" do
    {browser_session, token} =
      browser_cookie_login!("workspace-model-operator@comma.surf", @admin_origin)

    actor_user_id = browser_session["user"]["id"]

    {:ok, target_user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "workspace-model-target-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
      })

    workspace = create_ready_workspace!(target_user)
    workspace = CommaWeb.TestWorkers.with_default_worker!(workspace)
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    worker_agent_id = workspace["default_worker_agent_id"]
    rotated_router_id = SalixStore.Ids.new_agent_id(group_id)

    # The projection follows the group's current Router.
    assert {:ok, _router} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "name" => "Rotated Workspace Router",
                 "role" => "router",
                 "purpose" => "workspace_model_admin_test"
               },
               tenant_id,
               rotated_router_id
             )

    assert {:ok, _group} =
             Salix.Control.Groups.update(
               group_id,
               %{"router_agent_id" => rotated_router_id},
               tenant_id
             )

    path = "/v1/comma/admin/users/#{target_user["id"]}/workspaces/agent-models"

    admin_put = fn role, model, key ->
      :put
      |> json_conn("#{path}/#{role}", %{
        "model" => model,
        "reason" => "Move the Workspace #{role} to the approved model",
        "idempotency_key" => "workspace-model-#{role}-#{SystemsRuntime.Proc.uuid()}",
        "confirmation" => "workspace-agent-model:#{target_user["id"]}:#{role}:#{key}"
      })
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
    end

    read_conn =
      :get
      |> conn(path)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    assert %{
             "workspace_id" => workspace_id,
             "agents" => %{
               "router" => %{
                 "agent_id" => ^rotated_router_id,
                 "role" => "router",
                 "source" => "platform_default",
                 "selection" => %{"kind" => "builtin"}
               },
               "worker" => %{
                 "agent_id" => ^worker_agent_id,
                 "role" => "worker",
                 "source" => "platform_default",
                 "selection" => %{"kind" => "builtin"}
               }
             },
             "platform_defaults" => %{"router" => %{}, "worker" => %{}}
           } = expect_json(read_conn, 200)

    assert workspace_id == workspace["id"]
    assert get_resp_header(read_conn, "cache-control") == ["no-store"]
    refute read_conn.resp_body =~ "provider_config"
    refute read_conn.resp_body =~ tenant_id
    refute read_conn.resp_body =~ group_id

    for {role, model, expected_agent_id} <- [
          {"router", "gpt-5.5", rotated_router_id},
          {"worker", "claude-opus-5", worker_agent_id}
        ] do
      choice = %{"kind" => "catalog", "model" => model, "allow_paid" => false}

      # The confirmation names the chosen model.
      assert %{"error" => "invalid_admin_confirmation"} =
               role |> admin_put.(choice, "default") |> expect_json(400)

      assert %{
               "agent_id" => ^expected_agent_id,
               "role" => ^role,
               "source" => "pinned",
               "selection" => %{"kind" => "catalog", "model" => ^model}
             } = role |> admin_put.(choice, "catalog:#{model}") |> expect_json(200)

      assert {:ok, %{"model" => ^choice}} = SalixAgent.Control.get(expected_agent_id, tenant_id)
    end

    assert %{
             "agents" => %{
               "router" => %{"selection" => %{"model" => "gpt-5.5"}},
               "worker" => %{"selection" => %{"model" => "claude-opus-5"}}
             }
           } =
             :get
             |> conn(path)
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    assert Repo.aggregate(
             from(event in Comma.Admin.AuditEvent,
               where:
                 event.actor_key == ^actor_user_id and
                   event.action == "update_workspace_agent_model" and
                   event.target_type == "user_workspace" and
                   event.target_id == ^target_user["id"] and
                   event.outcome == "succeeded"
             ),
             :count,
             :id
           ) == 2

    for invalid <- [
          %{"kind" => "catalog", "model" => "no-such-model", "allow_paid" => false},
          "gpt-5.5"
        ] do
      key = if is_map(invalid), do: "catalog:no-such-model", else: "invalid"

      assert %{"error" => "invalid_workspace_agent_model"} =
               "worker" |> admin_put.(invalid, key) |> expect_json(400)
    end

    assert %{"error" => "invalid_workspace_agent_role"} =
             "coordinator" |> admin_put.(nil, "default") |> expect_json(400)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn(path)
             |> user_auth(token)
             |> call()
             |> expect_json(401)

    # A model one of the Workspace's own Custom endpoints serves is a choice;
    # another tenant's is not.
    for {tenant, model} <- [
          {tenant_id, "gpt-workspace-private"},
          {SalixStore.Ids.new_tenant_id(), "gpt-foreign"}
        ] do
      {:ok, _profile} =
        SalixAgent.AccountPool.create(tenant, %{
          "credential_kind" => "provider_api_key",
          "source" => "custom",
          "api_key" => "sk-workspace-private-secret",
          "base_url" => "https://models.example.test/v1",
          "protocol" => "chat_completions",
          "models" => [model]
        })
    end

    private = %{"kind" => "catalog", "model" => "gpt-workspace-private", "allow_paid" => true}
    private_conn = admin_put.("worker", private, "catalog:gpt-workspace-private")
    assert expect_json(private_conn, 200)["selection"]["model"] == "gpt-workspace-private"
    refute private_conn.resp_body =~ "sk-workspace-private-secret"

    foreign = %{"kind" => "catalog", "model" => "gpt-foreign", "allow_paid" => true}
    "worker" |> admin_put.(foreign, "catalog:gpt-foreign") |> expect_json(400)
    assert {:ok, %{"model" => ^private}} = SalixAgent.Control.get(worker_agent_id, tenant_id)

    followed = "worker" |> admin_put.(nil, "default") |> expect_json(200)
    assert followed["source"] == "platform_default"
    assert {:ok, %{"model" => nil}} = SalixAgent.Control.get(worker_agent_id, tenant_id)
  end

  test "human Admin billing commands use a typed boundary and server operator identity" do
    package_code = "comma_admin_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      package_code,
      package_version,
      "comma",
      "one_time",
      "Admin test package"
    )

    {browser_session, token} =
      browser_cookie_login!("billing-operator@comma.surf", @admin_origin)

    session_id = browser_session["session_id"]
    actor_id = browser_session["user"]["id"]
    create_key = "human-code-#{SystemsRuntime.Proc.uuid()}"
    short_code_key = "human-short-code-#{SystemsRuntime.Proc.uuid()}"

    assert %{"error" => "invalid_redeem_code"} =
             :post
             |> json_conn("/v1/comma/admin/billing/redeem-codes", %{
               "code" => "free",
               "package_code" => package_code,
               "package_version" => package_version,
               "reason" => "Reject a code that cannot be safely redacted",
               "idempotency_key" => short_code_key,
               "confirmation" => "create-redeem-code:#{package_code}:#{package_version}"
             })
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(400)

    refute Repo.get_by(Comma.Admin.AuditEvent,
             actor_key: actor_id,
             action: "create_redeem_code",
             idempotency_key: short_code_key
           )

    assert %{"data" => []} =
             :get
             |> conn("/v1/comma/admin/billing/redeem-codes")
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(200)

    create_body = %{
      "code" => "comma-human-code-#{SystemsRuntime.Proc.unique_integer([:positive])}",
      "package_code" => package_code,
      "package_version" => package_version,
      "max_redemptions" => 5,
      "reason" => "Issue a support redemption",
      "idempotency_key" => create_key,
      "confirmation" => "create-redeem-code:#{package_code}:#{package_version}"
    }

    for forbidden <- [
          %{"admin_command_id" => SystemsRuntime.Proc.uuid()},
          %{"metadata" => %{"injected" => true}},
          %{"status" => "disabled"},
          %{"surface" => "bridge"}
        ] do
      assert %{"error" => "invalid_redeem_code"} =
               :post
               |> json_conn(
                 "/v1/comma/admin/billing/redeem-codes",
                 Map.merge(create_body, forbidden)
               )
               |> cookie_auth(token, @admin_origin, session_id)
               |> call()
               |> expect_json(400)
    end

    refute Repo.get_by(Comma.Admin.AuditEvent,
             actor_key: actor_id,
             action: "create_redeem_code",
             idempotency_key: create_key
           )

    create_conn =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes", create_body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()

    code = expect_json(create_conn, 201)
    assert is_binary(code["code"])
    assert get_resp_header(create_conn, "cache-control") == ["no-store"]

    assert %{"error" => "admin_command_already_succeeded"} =
             :post
             |> json_conn("/v1/comma/admin/billing/redeem-codes", create_body)
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(409)

    assert %{"error" => "admin_command_already_succeeded"} =
             :post
             |> json_conn(
               "/v1/comma/admin/billing/redeem-codes",
               Map.put(create_body, "code", "  #{String.upcase(create_body["code"])}  ")
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(409)

    assert %{"error" => "admin_idempotency_key_conflict"} =
             :post
             |> json_conn(
               "/v1/comma/admin/billing/redeem-codes",
               Map.put(create_body, "code", create_body["code"] <> "-changed")
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(409)

    billing_account_id = "comma-ba-admin-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    owner_id = "wsp_admin_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    apply_key = "human-apply-#{SystemsRuntime.Proc.uuid()}"

    apply_body = %{
      "id" => code["id"],
      "billing_account_id" => billing_account_id,
      "product_owner_type" => "workspace",
      "product_owner_id" => owner_id,
      "idempotency_key" => apply_key,
      "reason" => "Apply the approved support redemption",
      "confirmation" => "apply-redeem-code:#{billing_account_id}"
    }

    assert %{"error" => "invalid_redeem_request"} =
             :post
             |> json_conn(
               "/v1/comma/admin/billing/redeem-codes/apply",
               Map.merge(apply_body, %{
                 "operator" => %{"id" => "spoofed-client-operator"},
                 "surface" => "bridge"
               })
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(400)

    refute Repo.get_by(Comma.Admin.AuditEvent,
             actor_key: actor_id,
             action: "apply_redeem_code",
             idempotency_key: apply_key
           )

    applied =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/apply", apply_body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert applied["redemption"]["operator_snapshot"]["id"] == actor_id
    assert applied["redemption"]["operator_snapshot"]["type"] == "comma_admin_user"

    disabled =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/#{code["id"]}/disable", %{
        "reason" => "Retire the completed support code",
        "idempotency_key" => "human-disable-#{SystemsRuntime.Proc.uuid()}",
        "confirmation" => "disable-redeem-code:#{code["id"]}"
      })
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(200)

    assert disabled["status"] == "disabled"

    assert Repo.exists?(
             from(event in Comma.Admin.AuditEvent,
               where:
                 event.actor_key == ^actor_id and
                   event.action == "apply_redeem_code" and
                   event.idempotency_key == ^apply_key and
                   event.outcome == "succeeded"
             )
           )
  end

  test "human Admin issues package-backed credits only to the server-owned Workspace target" do
    package_code = "comma_admin_grant_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      package_code,
      package_version,
      "comma",
      "one_time",
      "Admin direct credit package"
    )

    {:ok, target_user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "billing-grant-target-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
      })

    workspace = create_ready_workspace!(target_user["id"], "Grant Target")
    workspace_id = workspace["id"]
    billing_account_id = workspace["billing_account_id"]

    {browser_session, token} =
      browser_cookie_login!("billing-grant-operator@comma.surf", @admin_origin)

    session_id = browser_session["session_id"]
    actor_id = browser_session["user"]["id"]
    idempotency_key = "human-grant-#{SystemsRuntime.Proc.uuid()}"

    body = %{
      "package_code" => package_code,
      "package_version" => package_version,
      "expires_at" => "2099-08-01T00:00:00Z",
      "reason" => "Issue an approved Workspace support grant",
      "idempotency_key" => idempotency_key,
      "confirmation" =>
        "issue-workspace-credits:#{workspace_id}:#{package_code}:#{package_version}"
    }

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn(
               "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
               body
             )
             |> admin_auth()
             |> call()
             |> expect_json(403)

    assert %{"error" => "invalid_manual_grant"} =
             :post
             |> json_conn(
               "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
               Map.merge(body, %{
                 "billing_account_id" => "comma-ba-spoofed",
                 "workspace_id" => "wsp_spoofed",
                 "operator" => %{"id" => "usr_spoofed"},
                 "source_type" => "manual_contract",
                 "valid_from" => "2026-07-01T00:00:00Z"
               })
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(400)

    refute Repo.get_by(Comma.Admin.AuditEvent,
             actor_key: actor_id,
             action: "issue_workspace_credits",
             idempotency_key: idempotency_key
           )

    result =
      :post
      |> json_conn(
        "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
        body
      )
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert result["idempotent"] == false
    assert result["grant"]["billing_account_id"] == billing_account_id
    assert result["grant"]["remaining_credits"] == 100
    assert result["manual_grant"]["package_code"] == package_code
    assert result["manual_grant"]["package_version"] == package_version
    assert result["manual_grant"]["source_type"] == "manual_adjustment"
    assert result["manual_grant"]["source_id"] == "comma_admin:#{workspace_id}"
    assert result["manual_grant"]["operator_snapshot"]["id"] == actor_id
    assert result["manual_grant"]["operator_snapshot"]["type"] == "comma_admin_user"

    audit =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: actor_id,
        action: "issue_workspace_credits",
        idempotency_key: idempotency_key
      )

    assert audit.outcome == "succeeded"
    assert audit.target_type == "workspace"
    assert audit.target_id == workspace_id
    assert result["manual_grant"]["source_event_id"] == audit.id

    billing_idempotency_key =
      BillingCommerce.ManualGrantCommands.billing_idempotency_key(audit.id)

    assert result["manual_grant"]["idempotency_key"] == nil

    assert %{
             "workspace" => %{"id" => ^workspace_id},
             "billing" => %{
               "account_id" => ^billing_account_id,
               "current_credits" => 100,
               "active_grants" => [
                 %{
                   "source_type" => "manual_adjustment",
                   "source_id" => "comma_admin:" <> ^workspace_id
                 }
               ]
             }
           } =
             :get
             |> conn("/v1/comma/admin/users/#{target_user["id"]}/workspaces")
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(200)

    assert %{"error" => "admin_command_already_succeeded"} =
             :post
             |> json_conn(
               "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
               body
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(409)

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT count(*)
               FROM billing_manual_grants
               WHERE billing_account_id = $1 AND idempotency_key = $2
               """,
               [billing_account_id, billing_idempotency_key]
             ).rows

    assert [[0]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT count(*)
               FROM billing_manual_grants
               WHERE billing_account_id = $1 AND idempotency_key = $2
               """,
               [billing_account_id, idempotency_key]
             ).rows
  end

  test "different human Admin commands cannot collide through a reused browser key" do
    first_package = "comma_admin_first_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    second_package = "comma_admin_second_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      first_package,
      package_version,
      "comma",
      "one_time",
      "First Admin direct credit package",
      100
    )

    seed_billing_package!(
      second_package,
      package_version,
      "comma",
      "one_time",
      "Second Admin direct credit package",
      900
    )

    {:ok, target_user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "billing-key-target-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
      })

    workspace = create_ready_workspace!(target_user["id"], "Idempotency Target")
    workspace_id = workspace["id"]
    billing_account_id = workspace["billing_account_id"]
    browser_key = "shared-browser-key-#{SystemsRuntime.Proc.uuid()}"

    {first_session, first_token} =
      browser_cookie_login!("billing-key-first@comma.surf", @admin_origin)

    {second_session, second_token} =
      browser_cookie_login!("billing-key-second@comma.surf", @admin_origin)

    issue = fn session, token, package_code, reason ->
      :post
      |> json_conn(
        "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
        %{
          "package_code" => package_code,
          "package_version" => package_version,
          "expires_at" => "2099-08-01T00:00:00Z",
          "reason" => reason,
          "idempotency_key" => browser_key,
          "confirmation" =>
            "issue-workspace-credits:#{workspace_id}:#{package_code}:#{package_version}"
        }
      )
      |> cookie_auth(token, @admin_origin, session["session_id"])
      |> call()
      |> expect_json(201)
    end

    first =
      issue.(
        first_session,
        first_token,
        first_package,
        "Issue the first approved direct grant"
      )

    second =
      issue.(
        second_session,
        second_token,
        second_package,
        "Issue the second approved direct grant"
      )

    assert first["idempotent"] == false
    assert first["grant"]["remaining_credits"] == 100
    assert second["idempotent"] == false
    assert second["grant"]["remaining_credits"] == 900

    first_actor_id = first_session["user"]["id"]
    second_actor_id = second_session["user"]["id"]

    first_audit =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: first_actor_id,
        action: "issue_workspace_credits",
        idempotency_key: browser_key
      )

    second_audit =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: second_actor_id,
        action: "issue_workspace_credits",
        idempotency_key: browser_key
      )

    refute first_audit.id == second_audit.id

    expected_billing_keys =
      MapSet.new([
        BillingCommerce.ManualGrantCommands.billing_idempotency_key(first_audit.id),
        BillingCommerce.ManualGrantCommands.billing_idempotency_key(second_audit.id)
      ])

    rows =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT package_code, idempotency_key, source_event_id
        FROM billing_manual_grants
        WHERE billing_account_id = $1
        ORDER BY package_code
        """,
        [billing_account_id]
      ).rows

    assert length(rows) == 2
    assert MapSet.new(Enum.map(rows, &Enum.at(&1, 1))) == expected_billing_keys

    assert MapSet.new(Enum.map(rows, &Enum.at(&1, 2))) ==
             MapSet.new([first_audit.id, second_audit.id])

    refute Enum.any?(rows, &(Enum.at(&1, 1) == browser_key))

    assert [[balance]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT COALESCE(SUM(remaining_credits), 0)
               FROM credit_grants
               WHERE billing_account_id = $1
               """,
               [billing_account_id]
             ).rows

    assert Decimal.equal?(balance, Decimal.new("1000"))
  end

  test "ops Billing compatibility is typed without narrowing legacy command fields" do
    package_code = "bridge_ops_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    package_version = "2026-07"
    organization_id = "org_ops_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    billing_account_id = "bridge-ba-#{organization_id}"
    code_id = "redeem_code_ops_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    redemption_id = "redemption_ops_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    source_event_id = "ops-source-#{SystemsRuntime.Proc.uuid()}"
    admin_command_id = SystemsRuntime.Proc.uuid()

    seed_billing_package!(
      package_code,
      package_version,
      "bridge",
      "subscription",
      "Ops compatibility package"
    )

    audit_count = Repo.aggregate(Comma.Admin.AuditEvent, :count)

    create_body = %{
      "id" => code_id,
      "admin_command_id" => admin_command_id,
      "code" => "bridge-ops-code-#{SystemsRuntime.Proc.unique_integer([:positive])}",
      "package_code" => package_code,
      "package_version" => package_version,
      "code_type" => "internal_subscription",
      "surface" => "bridge",
      "scope_product_owner_type" => "organization",
      "scope_product_owner_id" => organization_id,
      "status" => "active",
      "max_redemptions" => 3,
      "per_account_limit" => 1,
      "valid_from" => "2026-07-01T00:00:00Z",
      "metadata" => %{"source" => "deployment"}
    }

    created =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes", create_body)
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert created["id"] == code_id
    assert created["surface"] == "bridge"
    assert created["scope_product_owner_id"] == organization_id
    assert created["metadata"] == %{"source" => "deployment"}

    replayed =
      :post
      |> json_conn(
        "/v1/comma/admin/billing/redeem-codes",
        Map.put(create_body, "code", "ignored-after-owner-reconciliation")
      )
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert replayed["id"] == code_id
    refute Map.has_key?(replayed, "code")

    assert [[^code_id]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT id FROM billing_redeem_codes WHERE admin_command_id = $1",
               [admin_command_id]
             ).rows

    applied =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/apply", %{
        "id" => code_id,
        "billing_account_id" => billing_account_id,
        "surface" => "bridge",
        "product_owner_type" => "organization",
        "product_owner_id" => organization_id,
        "idempotency_key" => "ops-apply-#{SystemsRuntime.Proc.uuid()}",
        "operator" => %{
          "id" => "deployment-bearer",
          "type" => "ops",
          "reason" => "Restore an organization subscription"
        },
        "redemption_id" => redemption_id,
        "source_event_id" => source_event_id,
        "metadata" => %{"ticket" => "OPS-629"}
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert applied["redemption"]["id"] == redemption_id
    assert applied["redemption"]["source_event_id"] == source_event_id
    assert applied["redemption"]["operator_snapshot"]["id"] == "deployment-bearer"
    assert applied["redemption"]["metadata"] == %{"ticket" => "OPS-629"}

    assert %{"status" => "disabled"} =
             :post
             |> json_conn("/v1/comma/admin/billing/redeem-codes/#{code_id}/disable", %{})
             |> admin_auth()
             |> call()
             |> expect_json(200)

    assert Repo.aggregate(Comma.Admin.AuditEvent, :count) == audit_count

    assert %{"error" => "invalid_redeem_code"} =
             :post
             |> json_conn("/v1/comma/admin/billing/redeem-codes", %{
               "code" => "bridge-invalid-ops-code",
               "package_code" => package_code,
               "package_version" => package_version,
               "code_type" => "internal_subscription",
               "surface" => "bridge",
               "max_redemptions" => 2_147_483_648
             })
             |> admin_auth()
             |> call()
             |> expect_json(400)
  end

  test "human redeem apply reconciles a committed owner result after its code is retired" do
    package_code = "comma_admin_apply_recovery_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      package_code,
      package_version,
      "comma",
      "one_time",
      "Admin apply recovery package"
    )

    assert {:ok, code} =
             BillingCommerce.create_redeem_code(%{
               code: "comma-apply-recovery-#{SystemsRuntime.Proc.unique_integer([:positive])}",
               package_code: package_code,
               package_version: package_version,
               code_type: "one_time_package",
               surface: "comma"
             })

    {browser_session, token} =
      browser_cookie_login!("billing-apply-recovery@comma.surf", @admin_origin)

    session_id = browser_session["session_id"]
    actor_id = browser_session["user"]["id"]
    billing_account_id = "comma-ba-recovery-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    owner_id = "wsp_recovery_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    idempotency_key = "human-apply-recovery-#{SystemsRuntime.Proc.uuid()}"

    body = %{
      "id" => code.id,
      "billing_account_id" => billing_account_id,
      "product_owner_type" => "workspace",
      "product_owner_id" => owner_id,
      "reason" => "Recover an owner commit after the Admin response was lost",
      "idempotency_key" => idempotency_key,
      "confirmation" => "apply-redeem-code:#{billing_account_id}"
    }

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION pg_temp.fail_comma_admin_apply_audit_finalize()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.outcome = 'succeeded' THEN
          RAISE EXCEPTION 'forced admin apply audit finalize failure';
        END IF;
        RETURN NEW;
      END;
      $$
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER comma_admin_apply_audit_finalize_failure
      BEFORE UPDATE OF outcome ON comma_admin_audit_events
      FOR EACH ROW
      EXECUTE FUNCTION pg_temp.fail_comma_admin_apply_audit_finalize()
      """,
      []
    )

    first_result =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/apply", body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert first_result["idempotent"] == false
    redemption_id = first_result["redemption"]["id"]

    event =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: actor_id,
        action: "apply_redeem_code",
        idempotency_key: idempotency_key
      )

    assert event.outcome == "started"

    Ecto.Adapters.SQL.query!(
      Repo,
      "DROP TRIGGER comma_admin_apply_audit_finalize_failure ON comma_admin_audit_events",
      []
    )

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      UPDATE billing_redeem_codes
      SET status = 'disabled',
          expires_at = now() - interval '1 second'
      WHERE id = $1
      """,
      [code.id]
    )

    Repo.update_all(
      from(candidate in Comma.Admin.AuditEvent, where: candidate.id == ^event.id),
      set: [lease_expires_at: DateTime.add(SystemsClock.utc_now(), -1, :second)]
    )

    recovered =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/apply", body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert recovered["idempotent"] == true
    assert recovered["redemption"]["id"] == redemption_id

    recovered_event = Repo.get!(Comma.Admin.AuditEvent, event.id)
    assert recovered_event.outcome == "succeeded"
    assert is_nil(recovered_event.lease_expires_at)

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT count(*)
               FROM billing_redemptions
               WHERE redeem_code_id = $1 AND billing_account_id = $2
               """,
               [code.id, billing_account_id]
             ).rows
  end

  test "valid non-Admin Cookie Sessions keep lifecycle access and receive route-level 403" do
    {browser_session, token} = browser_cookie_login!("outside@example.com", @admin_origin)
    session_id = browser_session["session_id"]

    assert %{"session_id" => ^session_id} =
             :get
             |> conn("/v1/comma/auth/session")
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(200)

    denied =
      :get
      |> conn("/v1/comma/admin/users")
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()

    assert expect_json(denied, 403) == %{"error" => "forbidden"}
    assert denied.resp_cookies == %{}

    logout =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()

    assert expect_json(logout, 200) == %{"signed_out" => true}
    assert logout.resp_cookies[CommaWeb.SessionCookie.cookie_name()].max_age == 0
  end

  test "restricted, revoked, and disabled comma.surf Sessions cannot read Admin resources" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "restricted-admin@comma.surf"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => "wsp_admin_restricted"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert %{"error" => "forbidden"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(restricted["token"], @admin_origin, restricted["id"])
             |> call()
             |> expect_json(403)

    {revoked_session, revoked_token} =
      browser_cookie_login!("revoked-admin@comma.surf", @admin_origin)

    :ok = Comma.Accounts.revoke_session_token(revoked_token)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(
               revoked_token,
               @admin_origin,
               revoked_session["session_id"]
             )
             |> call()
             |> expect_json(401)

    {disabled_session, disabled_token} =
      browser_cookie_login!("disabled-admin@comma.surf", @admin_origin)

    :patch
    |> json_conn("/v1/comma/admin/users/#{disabled_session["user"]["id"]}", %{
      "status" => "disabled"
    })
    |> admin_auth()
    |> call()
    |> expect_json(200)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(
               disabled_token,
               @admin_origin,
               disabled_session["session_id"]
             )
             |> call()
             |> expect_json(401)
  end

  test "cookie mutations require an allowed Origin and reject cross-site fetch metadata" do
    for {label, email, authenticate} <- [
          {"missing Origin", "cookie-missing-origin@example.com",
           fn conn, token ->
             put_req_header(conn, "cookie", "#{CommaWeb.SessionCookie.cookie_name()}=#{token}")
           end},
          {"unapproved same-site Origin", "cookie-origin@example.com",
           &cookie_auth(&1, &2, "https://untrusted.comma.surf")}
        ] do
      session = email_login!(email)

      conn =
        :post
        |> json_conn("/v1/comma/auth/logout", %{})
        |> authenticate.(session["token"])
        |> call()

      assert conn.status == 403, label
      assert Jason.decode!(conn.resp_body)["error"] == "origin_not_allowed", label
      assert {:ok, _user, _session} = Comma.Accounts.validate_session(session["token"]), label
    end

    cross_site = email_login!("cookie-cross-site@example.com")

    conn =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> cookie_auth(cross_site["token"], "http://127.0.0.1:5174")
      |> put_req_header("sec-fetch-site", "cross-site")
      |> call()

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] == "cross_site_request"
    assert {:ok, _user, _session} = Comma.Accounts.validate_session(cross_site["token"])

    untrusted_cookie_read =
      :get
      |> conn("/v1/comma/auth/session")
      |> put_req_header(
        "cookie",
        "#{CommaWeb.SessionCookie.cookie_name()}=#{cross_site["token"]}"
      )
      |> call()

    assert untrusted_cookie_read.status == 401
    assert untrusted_cookie_read.resp_cookies == %{}
  end

  @tag database_isolation: "SERIALIZABLE"
  test "Electron Google completion exchanges the code on the server and emits bounded telemetry" do
    SystemsRuntime.put_env(
      :comma_core,
      :google_adapter_fake_exchange_pid,
      SystemsRuntime.Proc.self()
    )

    handler_id = "google-desktop-exchange-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler_id,
        [:comma_product, :operation, :stop],
        &__MODULE__.handle_google_exchange_telemetry/4,
        SystemsRuntime.Proc.self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler_id) end)

    attempt =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "electron"})
      |> call()
      |> expect_json(200)

    authorization_code = "router-desktop-authorization-code"
    code_verifier = "router-desktop-pkce-verifier-012345678901234567890"
    redirect_uri = "http://127.0.0.1:43123/oauth2/callback"

    put_google_credential!(authorization_code, attempt, %{
      "sub" => "router-desktop-google-subject",
      "email" => "router-desktop@gmail.com"
    })

    session =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "authorization_code" => authorization_code,
        "code_verifier" => code_verifier,
        "nonce" => attempt["nonce"],
        "redirect_uri" => redirect_uri
      })
      |> call()
      |> expect_json(200)

    assert "comma_sess_" <> _ = session["token"]

    assert_receive {:google_authorization_code_exchange, ^authorization_code, exchange_opts}
    assert exchange_opts[:client_id] == attempt["client_id"]
    assert exchange_opts[:client_secret] == "comma-electron-test-client-secret"
    assert exchange_opts[:nonce] == attempt["nonce"]
    assert exchange_opts[:pkce_verifier] == code_verifier
    assert exchange_opts[:redirect_uri] == redirect_uri

    assert_receive {:google_exchange_telemetry, measurements, metadata}
    assert is_integer(measurements.duration)

    assert metadata == %{
             operation: :google_desktop_exchange,
             outcome: :ok,
             provider: "google"
           }
  end

  test "Electron Google completion rejects non-loopback redirects before consuming the attempt" do
    SystemsRuntime.put_env(
      :comma_core,
      :google_adapter_fake_exchange_pid,
      SystemsRuntime.Proc.self()
    )

    attempt =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "electron"})
      |> call()
      |> expect_json(200)

    authorization_code = "router-desktop-safe-redirect-code"
    code_verifier = "router-desktop-pkce-verifier-012345678901234567890"

    put_google_credential!(authorization_code, attempt, %{
      "sub" => "router-desktop-safe-redirect-subject",
      "email" => "router-desktop-safe-redirect@gmail.com"
    })

    rejected =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "authorization_code" => authorization_code,
        "code_verifier" => code_verifier,
        "nonce" => attempt["nonce"],
        "redirect_uri" => "https://attacker.example/oauth2/callback"
      })
      |> call()
      |> expect_json(401)

    assert rejected == %{"error" => "invalid_google_credential"}
    refute_receive {:google_authorization_code_exchange, _, _}

    assert {:ok, consumed_attempt} =
             Comma.Auth.GoogleLoginAttempts.consume(
               %{
                 "attempt_id" => attempt["attempt_id"],
                 "nonce" => attempt["nonce"]
               },
               "electron"
             )

    assert consumed_attempt["platform"] == "electron"
  end

  @tag database_isolation: "SERIALIZABLE"
  test "public Google GIS endpoints validate a one-time attempt and issue an ordinary session" do
    origin = "http://127.0.0.1:5174"

    attempt =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "web"})
      |> web_cookie_request(origin, :none)
      |> call()
      |> expect_json(200)

    assert attempt["client_id"] == "comma-web-test.apps.googleusercontent.com"
    assert is_binary(attempt["attempt_id"])
    assert is_binary(attempt["nonce"])

    credential = "router-google-credential"

    SystemsRuntime.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => %{
        "iss" => "https://accounts.google.com",
        "sub" => "router-google-subject",
        "aud" => attempt["client_id"],
        "nonce" => attempt["nonce"],
        "email" => "router@gmail.com",
        "email_verified" => true,
        "name" => "Router Google"
      }
    })

    session_conn =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "nonce" => attempt["nonce"],
        "credential" => credential
      })
      |> web_cookie_request(origin, :none)
      |> call()

    session = expect_json(session_conn, 200)
    assert Map.keys(session) |> Enum.sort() == ["expires_at", "session_id", "user"]
    refute Map.has_key?(session, "token")

    assert session["user"]["email"] == "router@gmail.com"
    refute Map.has_key?(session["user"], "admin")

    cookie = session_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()]
    assert cookie.http_only == true
    assert "comma_sess_" <> _ = cookie.value

    assert 200 ==
             (:get
              |> conn("/v1/comma/workspaces")
              |> cookie_auth(cookie.value, origin)
              |> call()).status

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(cookie.value, origin)
             |> call()
             |> expect_json(403)

    replay =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "nonce" => attempt["nonce"],
        "credential" => credential
      })
      |> web_cookie_request(origin, :none)
      |> call()
      |> expect_json(401)

    assert replay["error"] == "invalid_google_attempt"
  end

  @tag database_isolation: "SERIALIZABLE"
  test "third-party Google linking requires one OTP through the public HTTP flow" do
    email = "router-google-link@example.com"
    assert {:ok, existing, :created} = Comma.Accounts.Repository.ensure_user_by_email(email)
    previous_delivery_pid = SystemsRuntime.get_env(:comma_core, :email_delivery_test_pid)

    on_exit(fn ->
      restore_env(:comma_core, :email_delivery_test_pid, previous_delivery_pid)
    end)

    SystemsRuntime.put_env(:comma_core, :email_delivery_test_pid, SystemsRuntime.Proc.self())
    update_auth(email_delivery: __MODULE__.RecordingEmailDelivery, expose_codes: false)

    attempt = google_attempt!()
    credential = "router-google-link-credential"

    put_google_credential!(credential, attempt, %{
      "sub" => "router-google-link-subject",
      "email" => email,
      "hd" => nil
    })

    pending =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "nonce" => attempt["nonce"],
        "credential" => credential
      })
      |> call()
      |> expect_json(200)

    assert pending == %{
             "challenge_id" => pending["challenge_id"],
             "email" => email,
             "status" => "otp_required"
           }

    refute Map.has_key?(pending, "code")

    assert_receive {:login_code_delivery, ^email, code, challenge_id}
    assert challenge_id == pending["challenge_id"]
    assert is_binary(code)
    assert is_nil(Comma.Repo.get_by(Comma.Accounts.Identity, user_id: existing.id))

    assert %{"error" => "invalid_verification_code"} =
             :post
             |> json_conn("/v1/comma/auth/google/link/verify", %{
               "challenge_id" => challenge_id,
               "code" => wrong_code(code)
             })
             |> call()
             |> expect_json(401)

    session =
      :post
      |> json_conn("/v1/comma/auth/google/link/verify", %{
        "challenge_id" => challenge_id,
        "code" => code
      })
      |> call()
      |> expect_json(200)

    assert "comma_sess_" <> _ = session["token"]
    assert session["user"]["id"] == existing.id

    assert %Comma.Accounts.Identity{
             user_id: user_id,
             subject: "router-google-link-subject"
           } = Comma.Repo.get_by!(Comma.Accounts.Identity, user_id: existing.id)

    assert user_id == existing.id

    assert %{"error" => "invalid_verification_code"} =
             :post
             |> json_conn("/v1/comma/auth/google/link/verify", %{
               "challenge_id" => challenge_id,
               "code" => code
             })
             |> call()
             |> expect_json(401)
  end

  @tag database_isolation: "SERIALIZABLE"
  test "a new Google subject cannot replace the user's existing Google identity" do
    email = "router-google-takeover@gmail.com"
    first_attempt = google_attempt!()

    put_google_credential!("router-google-first", first_attempt, %{
      "sub" => "router-google-first-subject",
      "email" => email
    })

    first =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => first_attempt["attempt_id"],
        "nonce" => first_attempt["nonce"],
        "credential" => "router-google-first"
      })
      |> call()
      |> expect_json(200)

    second_attempt = google_attempt!()

    put_google_credential!("router-google-second", second_attempt, %{
      "sub" => "router-google-second-subject",
      "email" => email
    })

    assert %{"error" => "provider_already_linked"} =
             :post
             |> json_conn("/v1/comma/auth/google", %{
               "attempt_id" => second_attempt["attempt_id"],
               "nonce" => second_attempt["nonce"],
               "credential" => "router-google-second"
             })
             |> call()
             |> expect_json(409)

    assert %Comma.Accounts.Identity{
             user_id: user_id,
             subject: "router-google-first-subject"
           } = Comma.Repo.one!(Comma.Accounts.Identity)

    assert user_id == first["user"]["id"]
  end

  test "neither passwordless nor ops-issued user sessions grant admin access" do
    otp_session = email_login!("not-admin@example.com")

    assert 401 ==
             (:get
              |> conn("/v1/comma/admin/users")
              |> user_auth(otp_session["token"])
              |> call()).status

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "legacy-admin-flag@example.com",
        "admin" => true
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    refute Map.has_key?(user, "admin")

    ops_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert ops_session["session_source"] == "ops_api"
    assert ops_session["auth_method"] == nil

    assert 401 ==
             (:get
              |> conn("/v1/comma/admin/users")
              |> user_auth(ops_session["token"])
              |> call()).status

    listed =
      :get
      |> conn("/v1/comma/auth/sessions")
      |> user_auth(ops_session["token"])
      |> call()
      |> expect_json(200)

    assert [%{"session_source" => "ops_api"} | _] = listed["data"]
    assert Enum.all?(listed["data"], &(not Map.has_key?(&1, "token")))

    product_conn =
      :get
      |> conn("/v1/comma/workspaces")
      |> admin_auth()
      |> CommaWeb.Auth.call([])

    assert product_conn.halted
    assert product_conn.status == 401
  end

  test "protected product API denies anonymous requests when admin token is unset" do
    SystemsRuntime.delete_env(:comma_web, :api_token)
    SystemsRuntime.delete_env(:salix_web, :api_token)

    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "anonymous-auth@example.com"})
      |> call()
      |> expect_json(200)

    assert %{"challenge_id" => _, "code" => _} = login

    response =
      :get
      |> conn("/v1/comma/workspaces")
      |> call()

    assert response.status == 401
    assert Jason.decode!(response.resp_body)["error"] == "unauthorized"
  end

  test "email login is generic and returns bounded 429 responses" do
    {:ok, _existing} = Comma.Accounts.create_user(%{"email" => "existing-login@example.com"})
    update_auth(expose_codes: false, resend_cooldown_seconds: 60)

    existing =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "existing-login@example.com"})
      |> call()
      |> expect_json(200)

    unknown =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "unknown-login@example.com"})
      |> call()
      |> expect_json(200)

    for response <- [existing, unknown] do
      assert is_binary(response["challenge_id"])
      refute Map.has_key?(response, "code")
      refute Map.has_key?(response, "email")
      assert response["expires_in"] in 1..900
      assert response["resend_after"] in 1..60
    end

    limited =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "existing-login@example.com"})
      |> call()

    assert limited.status == 429
    assert Jason.decode!(limited.resp_body) == %{"error" => "rate_limited"}
    assert [retry_after] = get_resp_header(limited, "retry-after")
    assert {seconds, ""} = Integer.parse(retry_after)
    assert seconds in 1..60
  end

  test "email verification failure windows return 429 and block a later correct guess" do
    update_auth(verification_failure_limit: 1)

    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "verify-limit@example.com"})
      |> call()
      |> expect_json(200)

    limited =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => login["challenge_id"],
        "code" => wrong_code(login["code"])
      })
      |> call()

    assert limited.status == 429
    assert Jason.decode!(limited.resp_body) == %{"error" => "rate_limited"}
    assert [_retry_after] = get_resp_header(limited, "retry-after")

    still_limited =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => login["challenge_id"],
        "code" => login["code"]
      })
      |> call()

    assert still_limited.status == 429
  end

  test "untrusted forwarded IP headers cannot bypass the peer-IP request window" do
    update_auth(ip_request_limit: 1)

    first =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "peer-limit-1@example.com"})
      |> put_req_header("cf-connecting-ip", "198.51.100.10")
      |> put_req_header("x-forwarded-for", "198.51.100.10")
      |> call()

    assert first.status == 200

    spoofed =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "peer-limit-2@example.com"})
      |> put_req_header("cf-connecting-ip", "198.51.100.11")
      |> put_req_header("x-forwarded-for", "198.51.100.11")
      |> call()

    assert spoofed.status == 429
    assert Jason.decode!(spoofed.resp_body) == %{"error" => "rate_limited"}
  end

  defp seed_billing_package!(
         package_code,
         package_version,
         surface,
         kind,
         name,
         grant_credits \\ 100
       ) do
    {:ok, _package} =
      BillingCommerce.create_package(%{
        code: package_code,
        surface: surface,
        name: name
      })

    {:ok, _version} =
      BillingCommerce.create_package_version(%{
        package_code: package_code,
        version: package_version,
        surface: surface,
        kind: kind,
        billing_period: "month",
        grant_credits: grant_credits,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 0,
        usage_policy: %{},
        effective_at: ~U[2026-07-01 00:00:00Z],
        status: "active"
      })

    :ok
  end

  defp ensure_fake_s3! do
    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  # The device-connect observer runs apart from the connection.
  defp nearby_eventually(predicate, attempts \\ 50) do
    cond do
      predicate.() -> true
      attempts == 0 -> false
      true -> SystemsRuntime.Proc.sleep(20) && nearby_eventually(predicate, attempts - 1)
    end
  end

  defp json_conn(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp wrong_code(code) do
    if code == "000000", do: "000001", else: "000000"
  end

  defp update_auth(overrides) do
    current = SystemsRuntime.get_env(:comma_core, :auth, [])
    SystemsRuntime.put_env(:comma_core, :auth, Keyword.merge(current, overrides))
  end

  defp google_attempt! do
    :post
    |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "web"})
    |> call()
    |> expect_json(200)
  end

  defp put_google_credential!(credential, attempt, overrides) do
    claims =
      Map.merge(
        %{
          "iss" => "https://accounts.google.com",
          "sub" => "router-google-subject",
          "aud" => attempt["client_id"],
          "nonce" => attempt["nonce"],
          "email" => "router-google@gmail.com",
          "email_verified" => true,
          "name" => "Router Google"
        },
        overrides
      )

    SystemsRuntime.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => claims
    })
  end

  def handle_google_exchange_telemetry(
        [:comma_product, :operation, :stop],
        measurements,
        %{operation: :google_desktop_exchange} = metadata,
        pid
      ) do
    SystemsRuntime.Proc.send(pid, {:google_exchange_telemetry, measurements, metadata})
  end

  def handle_google_exchange_telemetry(_event, _measurements, _metadata, _pid), do: :ok

  defp admin_auth(conn), do: put_req_header(conn, "authorization", "Bearer #{@admin_token}")
  defp user_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp cookie_auth(conn, token, origin, expectation \\ nil) do
    expectation = expectation || session_id_for_token(token)

    conn
    |> put_req_header("cookie", "#{CommaWeb.SessionCookie.cookie_name()}=#{token}")
    |> web_cookie_request(origin, expectation)
  end

  defp web_cookie_request(conn, origin, expectation) do
    conn
    |> put_req_header("origin", origin)
    |> put_req_header("x-comma-session-transport", "cookie")
    |> put_req_header("x-comma-session-lifecycle-version", "1")
    |> put_req_header(
      "x-comma-expected-auth-session-id",
      lifecycle_expectation_header(expectation)
    )
  end

  defp lifecycle_expectation_header(:unknown), do: "unknown"
  defp lifecycle_expectation_header(:none), do: "none"
  defp lifecycle_expectation_header(session_id) when is_binary(session_id), do: session_id

  defp session_id_for_token(token) do
    token_hash = :crypto.hash(:sha256, token)

    Repo.one!(
      from(session in AuthSession,
        where: session.token_hash == ^token_hash,
        select: session.id
      )
    )
  end

  defp call(conn) do
    conn
    |> default_native_auth_transport()
    |> raw_call()
  end

  defp raw_call(conn), do: CommaWeb.Router.call(conn, @opts)

  defp default_native_auth_transport(conn) do
    no_origin? = get_req_header(conn, "origin") == []
    no_transport? = get_req_header(conn, "x-comma-session-transport") == []
    native_auth? = String.starts_with?(conn.request_path, "/v1/comma/auth/")

    if conn.method != "OPTIONS" and no_origin? and no_transport? and native_auth? do
      put_req_header(conn, "x-comma-session-transport", "bearer")
    else
      conn
    end
  end

  defp email_login!(email) do
    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => email})
      |> call()
      |> expect_json(200)

    :post
    |> json_conn("/v1/comma/auth/email/verify", %{
      "challenge_id" => login["challenge_id"],
      "code" => login["code"]
    })
    |> call()
    |> expect_json(200)
  end

  defp browser_cookie_login!(email, origin) do
    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => email})
      |> web_cookie_request(origin, :none)
      |> call()
      |> expect_json(200)

    verify_conn =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => login["challenge_id"],
        "code" => login["code"]
      })
      |> web_cookie_request(origin, :none)
      |> call()

    session = expect_json(verify_conn, 200)
    cookie = verify_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()]

    assert cookie.http_only == true
    assert "comma_sess_" <> _ = cookie.value

    {session, cookie.value}
  end

  defp solved_guest_pow! do
    %{"pow" => %{"challenge" => challenge, "difficulty" => difficulty}} =
      :get |> conn("/v1/comma/auth/guest") |> call() |> expect_json(200)

    nonce =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&Integer.to_string/1)
      |> Enum.find(fn nonce ->
        :crypto.hash(:sha256, challenge <> ":" <> nonce)
        |> Comma.GuestPow.leading_zero_bits() >= difficulty
      end)

    %{"challenge" => challenge, "nonce" => nonce}
  end

  # Every string and number of a decoded JSON body, as strings.
  defp json_strings(%{} = map),
    do: Enum.flat_map(map, fn {key, value} -> [key | json_strings(value)] end)

  defp json_strings(list) when is_list(list), do: Enum.flat_map(list, &json_strings/1)
  defp json_strings(value) when is_binary(value), do: [value]
  defp json_strings(value) when is_number(value), do: [to_string(value)]
  defp json_strings(_value), do: []

  defp expect_json(conn, status) do
    assert conn.status == status
    Jason.decode!(conn.resp_body)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defmodule RejectingEmailDelivery do
    @behaviour Comma.EmailDelivery

    @impl true
    def send_login_code(_email, _code, _opts), do: {:error, {:postmark, 503, 0}}
  end

  defmodule RecordingEmailDelivery do
    @behaviour Comma.EmailDelivery

    @impl true
    def send_login_code(email, code, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_core, :email_delivery_test_pid),
        {:login_code_delivery, email, code, opts[:challenge_id]}
      )

      :ok
    end
  end

  defmodule UnavailableChallengeStore do
    @behaviour Comma.AuthChallengeStore

    @impl true
    def reserve(_challenge, _ttl_seconds, _opts), do: {:error, :redis_down}

    @impl true
    def reserve_attempt(_challenge, _ttl_seconds, _opts), do: {:error, :redis_down}

    @impl true
    def verify(_id, _code_hash, _max_attempts, _opts), do: {:error, :redis_down}

    @impl true
    def verify(_id, _code_hash, _max_attempts), do: {:error, :redis_down}

    @impl true
    def record_delivery(_outcome, _opts), do: {:error, :redis_down}

    @impl true
    def delete(_id), do: {:error, :redis_down}
  end

  defmodule RecordingSalixClient do
    @behaviour Comma.Salix.Client

    @impl true
    def provision_workspace_scope(workspace) do
      SystemsRuntime.Proc.send(test_pid!(), {:provision_workspace_scope, workspace})

      if workspace["provisioning_generation"] == 1 do
        CommaWeb.SalixClient.provision_workspace_scope(workspace)
      else
        :ok
      end
    end

    @impl true
    def resolve_workspace_scope(workspace), do: {:ok, workspace}

    @impl true
    def update_workspace_vm(workspace, vm) do
      SystemsRuntime.Proc.send(test_pid!(), {:update_workspace_vm, workspace, vm})
      :ok
    end

    @impl true
    def create_group_conversation(_workspace, _attrs), do: {:error, :not_implemented}

    @impl true
    def get_group_conversation_messages(_workspace, _conversation_id),
      do: {:error, :not_implemented}

    @impl true
    def append_group_conversation_message(_workspace, _conversation_id, _attrs),
      do: {:error, :not_implemented}

    @impl true
    def reconcile_group_conversation_router_participant(_workspace, conversation_id) do
      {:ok, %{"conversation_id" => conversation_id}}
    end

    @impl true
    def conversation_activity_context(_workspace, _conversation_id),
      do: {:error, :not_implemented}

    @impl true
    def list_agent_skills(_workspace), do: {:ok, %{"skills" => []}}

    @impl true
    def write_agent_file(workspace, path, body) do
      SystemsRuntime.Proc.send(test_pid!(), {:write_agent_file, workspace, path, body})
      {:ok, %{"path" => path}}
    end

    @impl true
    def read_agent_file(_workspace, _path, _max_bytes), do: {:error, :not_found}

    defp test_pid! do
      SystemsRuntime.fetch_env!(:comma_core, :salix_client_test_pid)
    end
  end

  defmodule SynchConflictClient do
    @behaviour Comma.Synchronicity.Client

    @impl true
    def provision_workspace(_workspace_id, _name, _owner),
      do: {:error, {:retryable, :unused}}

    @impl true
    def enroll_device(_workspace_id, _nk, _label, _owner),
      do: {:error, {:invalid, {:conflict, "device_org_conflict"}}}

    @impl true
    def mint_api_key(_workspace_id, _owner, _name), do: {:error, {:retryable, :unused}}

    @impl true
    def revoke_api_key(_workspace_id, _key_id), do: {:error, {:retryable, :unused}}
  end
end
