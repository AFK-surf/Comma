defmodule BridgeForTeamsWeb.Dashboard.ProjectShowLiveTest do
  @moduledoc """
  Tests for the Agent Swarm pages ProjectLive.Show still serves (Integrations,
  Connections, Plugins and Skills) and task detail: render of each tab and its
  key write interactions.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Memberships,
    Observability,
    ProjectIMConnects,
    Projects,
    TestBandit
  }

  alias BridgeForTeams.Salix.Reconciler

  defmodule MockFeishuAPI do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/open-apis/auth/v3/tenant_access_token/internal"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"code" => 0, "tenant_access_token" => "test-token"}))
    end

    def call(%{request_path: "/open-apis/bot/v3/info"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"code" => 0, "bot" => %{"open_id" => "ou_test_bot"}}))
    end

    def call(%{request_path: "/v1/im/feishu/events"} = conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      challenge =
        case Jason.decode(raw) do
          {:ok, %{"challenge" => challenge}} -> challenge
          _ -> ""
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"challenge" => challenge}))
    end
  end

  # The integrations tab previews the Slack manifest on load, so every stub used
  # before mounting must answer slack_manifest/1.

  defmodule RejectingSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    def slack_manifest(_app_name), do: {:error, :unavailable}

    def create_feishu_im_connect(_tenant_id, _group_id, _attrs),
      do: {:error, {:bad_request, "provider rejected credential validation"}}
  end

  defmodule AppInUseSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    def slack_manifest(_app_name), do: {:error, :unavailable}

    def create_feishu_im_connect(_tenant_id, _group_id, _attrs),
      do: {:error, {:bad_request, "feishu app_id is already used by another connect"}}
  end

  # Composio configured org with one notion account already connected. The
  # connections tab also lists managed-OAuth bindings, so the client answers
  # `list_group_oauth_bindings/1` (empty) alongside the composio functions.
  defmodule ComposioSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_oauth_provider_apps(_tenant_id), do: []
    def list_group_oauth_bindings(_group_id), do: []

    def get_composio_settings(_tenant_id),
      do: %{
        "enabled" => true,
        "api_key_configured" => true,
        "base_url" => "",
        "source" => "tenant"
      }

    def list_composio_connected_accounts(_tenant_id, group_id) do
      {:ok,
       [
         %{
           "id" => "ca_notion",
           "user_id" => group_id,
           "toolkit" => %{"slug" => "notion"},
           "status" => "ACTIVE"
         }
       ]}
    end

    def create_composio_connect_link(_tenant_id, _group_id, toolkit, attrs) do
      if pid = Application.get_env(:bridge_for_teams_core, :composio_test_pid) do
        send(pid, {:composio_connect_link_requested, toolkit, attrs})
      end

      {:ok,
       %{
         "redirect_url" => "https://connect.composio.dev/link/lk_dashboard",
         "connected_account_id" => "ca_new"
       }}
    end

    def delete_composio_connected_account(_tenant_id, _group_id, account_id) do
      if pid = Application.get_env(:bridge_for_teams_core, :composio_test_pid) do
        send(pid, {:composio_disconnect_requested, account_id})
      end

      {:ok, :ok}
    end
  end

  # Org that never opted into Composio: settings resolve to no source, so
  # `configured?/1` is false and the toolkits render as needing setup.
  defmodule ComposioUnconfiguredSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_oauth_provider_apps(_tenant_id), do: []
    def list_group_oauth_bindings(_group_id), do: []

    def get_composio_settings(_tenant_id),
      do: %{
        "enabled" => false,
        "api_key_configured" => false,
        "base_url" => "",
        "source" => "none"
      }
  end

  defmodule DirtyWebhookSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def slack_manifest(_app_name), do: {:error, :unavailable}

    def list_group_im_connects(group_id, _provider) do
      {:ok,
       [
         %{
           "connect_id" => "feishu-dirty-url",
           "provider" => "feishu",
           "group_id" => group_id,
           "app_id" => "cli_app",
           "webhook_url" =>
             "https://bridge.example.test/v1/im/feishu/events?app_secret=fake-app-value&verification_token=fake-verification-value&encrypt_key=fake-encryption-value",
           "status" => "connected",
           "app_secret_configured" => true,
           "verification_token_configured" => true,
           "encrypt_key_configured" => true,
           "created_at" => 1_700_000_000,
           "updated_at" => 1_700_000_000
         }
       ]}
    end
  end

  defmodule MalformedWebhookSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def slack_manifest(_app_name), do: {:error, :unavailable}

    def list_group_im_connects(group_id, _provider) do
      {:ok,
       [
         %{
           "connect_id" => "feishu-malformed-url",
           "provider" => "feishu",
           "group_id" => group_id,
           "app_id" => "cli_app",
           "webhook_url" =>
             "https://bridge.example.test/v1/im/feishu/events?app_secret=fake-app-value%",
           "status" => "connected",
           "app_secret_configured" => true,
           "verification_token_configured" => true,
           "encrypt_key_configured" => true,
           "created_at" => 1_700_000_000,
           "updated_at" => 1_700_000_000
         }
       ]}
    end
  end

  defmodule FeishuChecksSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def slack_manifest(_app_name), do: {:error, :unavailable}

    def list_group_im_connects(group_id, _provider) do
      {:ok,
       [
         %{
           "connect_id" => "feishu-ready",
           "provider" => "feishu",
           "group_id" => group_id,
           "app_id" => "cli_app",
           "webhook_url" => "https://bridge.example.test/v1/im/feishu/events?app_id=cli_app",
           "status" => "connected",
           "app_secret_configured" => true,
           "verification_token_configured" => true,
           "encrypt_key_configured" => false,
           "created_at" => 1_700_000_000,
           "updated_at" => 1_700_000_000
         }
       ]}
    end

    def get_group(group_id), do: Salix.Control.Groups.get(group_id)

    def feishu_bot_identity(%{"connect_id" => "feishu-ready"}),
      do: {:ok, %{"open_id" => "ou_ready"}}

    def meeting_calendar_policy(%{
          "agent_id" => agent_id,
          "connect_id" => "feishu-ready"
        }) do
      Application.get_env(
        :bridge_for_teams_core,
        :project_show_calendar_policy_test_result,
        {:ok,
         %{
           "connected_account_id" => "ca_google",
           "calendar_id" => "cal_comma",
           "calendar_name" => "Comma Event",
           "watched_calendars" => ["Comma Event"],
           "mode" => "notify",
           "chat_id" => "oc_team",
           "readiness" => "ACTIVE",
           "router_agent_id" => agent_id
         }}
      )
    end

    def feishu_callback_preflight_for_connect(%{"connect_id" => "feishu-ready"}) do
      {:ok,
       %{
         "app_id" => "cli_app",
         "url_verification" => "ok"
       }}
    end
  end

  defmodule SlackCalendarChecksSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def slack_manifest(_app_name), do: {:error, :unavailable}

    def list_group_im_connects(group_id, provider) when provider in [nil, "slack"] do
      {:ok,
       [
         slack_connect(group_id, "slack-newer", "T_NEWER", 1_700_000_100),
         slack_connect(group_id, "slack-ready", "T_READY", 1_700_000_000)
       ]}
    end

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    def get_group(group_id), do: Salix.Control.Groups.get(group_id)

    def meeting_calendar_policy(%{
          "agent_id" => agent_id,
          "connect_id" => connect_id
        }) do
      if pid = Application.get_env(:bridge_for_teams_core, :project_show_slack_checks_test_pid) do
        send(pid, {:slack_calendar_policy_connect_id, connect_id})
      end

      if connect_id == "slack-ready" do
        Application.get_env(
          :bridge_for_teams_core,
          :project_show_slack_calendar_policy_test_result,
          {:ok,
           %{
             "connected_account_ids" => ["ca_google"],
             "calendar_ids" => ["cal_comma"],
             "meeting_calendar_id" => "cal_meetings",
             "watched_calendars" => ["Comma Event"],
             "mode" => "join",
             "channel" => "#botarena",
             "channel_id" => "C0BOTARENA",
             "readiness" => "ACTIVE",
             "router_agent_id" => agent_id
           }}
        )
      else
        {:error, :calendar_policy_not_configured}
      end
    end

    defp slack_connect(group_id, connect_id, workspace_id, updated_at) do
      %{
        "connect_id" => connect_id,
        "provider" => "slack",
        "group_id" => group_id,
        "status" => "connected",
        "workspace_id" => workspace_id,
        "workspace_name" => workspace_id,
        "oauth_completed_at" => updated_at,
        "client_secret_configured" => true,
        "signing_secret_configured" => true,
        "created_at" => updated_at,
        "updated_at" => updated_at
      }
    end
  end

  defmodule FeishuIdentityMissingSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def slack_manifest(_app_name), do: {:error, :unavailable}

    def list_group_im_connects(group_id, provider) when provider in ["feishu", nil] do
      {:ok,
       [
         %{
           "connect_id" => "feishu-no-bot-identity",
           "provider" => "feishu",
           "group_id" => group_id,
           "app_id" => "cli_app",
           "webhook_url" => "https://salix.example.test/v1/im/feishu/events",
           "status" => "connected",
           "app_secret_configured" => true,
           "verification_token_configured" => true,
           "encrypt_key_configured" => false,
           "created_at" => 1_700_000_000,
           "updated_at" => 1_700_000_000
         }
       ]}
    end

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}

    def get_group(group_id), do: Salix.Control.Groups.get(group_id)

    def feishu_bot_identity(%{"connect_id" => "feishu-no-bot-identity"}),
      do: {:error, :bot_identity_missing}

    def feishu_callback_preflight_for_connect(%{"connect_id" => "feishu-no-bot-identity"}),
      do: {:ok, %{"ok" => true, "redacted" => true, "challenge_mode" => "plain"}}
  end

  # A Salix client without the optional Signal callbacks.
  defmodule NoSignalSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    def slack_manifest(_app_name), do: {:error, :unavailable}
  end

  setup_all do
    prev_feishu_api_base = Application.get_env(:salix_im, :feishu_api_base_url)
    prev_feishu_public_base = Application.get_env(:salix_im, :public_base_url)

    %{pid: bandit, url: mock_feishu_url} =
      TestBandit.start_unlinked!(
        plug: MockFeishuAPI,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    Application.put_env(:salix_im, :feishu_api_base_url, mock_feishu_url <> "/open-apis")
    Application.put_env(:salix_im, :public_base_url, mock_feishu_url)

    on_exit(fn ->
      restore_env(:salix_im, :feishu_api_base_url, prev_feishu_api_base)
      restore_env(:salix_im, :public_base_url, prev_feishu_public_base)

      if Process.alive?(bandit) do
        Supervisor.stop(bandit)
      end
    end)

    %{mock_feishu_url: mock_feishu_url}
  end

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    drain_all()
    %{conn: conn, user: user, org: org, project: project}
  end

  test "the integrations tab creates a Signal code and disconnects a connected chat", %{
    conn: conn,
    org: org,
    project: project
  } do
    n = :rand.uniform(9_999_999)
    number = "+1555" <> String.pad_leading(Integer.to_string(n), 7, "0")
    identity = SalixSignalProto.Keys.ec_keypair()

    {:ok, account_id} =
      SalixSignal.Accounts.create(%{
        aci: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0"),
        pni: nil,
        e164: number,
        device_id: 1,
        password: "device-password",
        identities: %{aci: identity, pni: nil},
        registration_ids: %{aci: 1, pni: 0},
        profile_key: :binary.copy(<<7>>, 32),
        pre_keys: %{},
        scope: :platform,
        environment: :staging
      })

    {:ok, _} = SalixSignal.Settings.set_platform_number(number)

    on_exit(fn ->
      _ = SalixSignal.Settings.set_platform_number(nil)

      SalixStore.Repo.query("DELETE FROM signal_accounts WHERE id = $1", [
        Ecto.UUID.dump!(account_id)
      ])
    end)

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
    assert html =~ "No Signal chats are connected yet."
    assert html =~ number

    html = view |> element("#signal-new-code") |> render_click()
    [command] = Regex.run(~r/comma connect [2-9A-Z]{4}-[2-9A-Z]{4}/, html)
    html = view |> element("#signal-code button", "Done") |> render_click()
    refute html =~ command

    "comma connect " <> code = command
    alice = "00000000-0000-4000-8000-000000000011"

    assert {:ok, _bound} =
             SalixIM.SignalConnects.redeem_claim(account_id, code, %{
               "kind" => "user",
               "peer" => alice,
               "display_name" => "Alice"
             })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
    assert html =~ "Alice"

    html = view |> element("#project-signal button", "Disconnect") |> render_click()
    assert html =~ "Signal chat disconnected."
    assert html =~ "No Signal chats are connected yet."
    assert {:error, :not_found} = SalixIM.SignalConnects.find_signal_connect(account_id, alice)
  end

  test "the integrations tab shows Signal as unavailable when the Salix client lacks it", %{
    conn: conn,
    org: org,
    project: project
  } do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, NoSignalSalixClient)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, previous) end)

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

    assert html =~ "Signal is unavailable right now."
    refute html =~ ~s(id="signal-new-code")
  end

  test "concurrent mock Feishu servers use unique kernel-assigned ports" do
    parent = self()

    tasks =
      for _ <- 1..16 do
        Task.async(fn ->
          send(parent, {:mock_server_ready, self()})

          receive do
            :start_mock_server ->
              TestBandit.start_unlinked!(
                plug: MockFeishuAPI,
                ip: {127, 0, 0, 1},
                startup_log: false
              )
          end
        end)
      end

    ready_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:mock_server_ready, pid}, 10_000
        pid
      end)

    assert MapSet.new(ready_pids) == MapSet.new(Enum.map(tasks, & &1.pid))
    Enum.each(ready_pids, &send(&1, :start_mock_server))

    servers = Task.await_many(tasks, 30_000)

    on_exit(fn ->
      Enum.each(servers, fn %{pid: pid} ->
        if Process.alive?(pid), do: Supervisor.stop(pid)
      end)
    end)

    ports = Enum.map(servers, & &1.port)
    assert Enum.all?(ports, &(&1 > 0))
    assert MapSet.size(MapSet.new(ports)) == length(ports)

    Enum.each(servers, fn %{url: url} ->
      assert {:ok,
              %Req.Response{
                status: 200,
                body: %{"code" => 0, "tenant_access_token" => "test-token"}
              }} =
               Req.post(
                 url <> "/open-apis/auth/v3/tenant_access_token/internal",
                 json: %{}
               )
    end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp create_provisioned_agent(project_id, attrs) do
    with {:ok, agent} <- Agents.create_agent(project_id, attrs) do
      drain_all()
      Agents.get_agent(agent.id)
    end
  end

  defp slack_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        app_name: "Comma",
        app_id: "A123",
        client_id: "cid",
        client_secret: "fake-client-secret",
        signing_secret: "fake-signing-secret"
      },
      attrs
    )
  end

  # Seed an org-level bot-enabled Feishu app binding (RFC §4.5). The binding fans
  # the bot secret out to the in-process Salix tenant store, so a subsequent
  # project connect can source it by app_id without re-entering credentials.
  defp seed_feishu_bot_binding(org, attrs \\ %{}) do
    {:ok, binding} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(
        org.id,
        Map.merge(
          %{
            "app_id" => "cli_app",
            "display_name" => "Acme Feishu",
            "bot_enabled" => true,
            "app_secret" => "fake-app-value",
            "verification_token" => "fake-verification-value",
            "encrypt_key" => "fake-encryption-value"
          },
          attrs
        )
      )

    binding
  end

  describe "Project navigation and settings" do
    test "renders the Agent Swarm navigation in the sidebar", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")
      base = "/orgs/#{org.slug}/projects/#{project.id}"

      assert has_element?(view, "nav[aria-label='Primary navigation']")
      assert has_element?(view, "section[aria-label='Current Agent Swarm']")
      assert has_element?(view, "#agent-swarm-navigation-#{project.id}[open]")
      assert has_element?(view, "#agent-swarm-navigation-#{project.id} > summary")

      refute has_element?(
               view,
               "#agent-swarm-navigation-#{project.id} summary",
               "Current Agent Swarm"
             )

      refute has_element?(view, "#agent-swarm-navigation-#{project.id} summary .rounded-full")
      assert has_element?(view, "[data-navigation-search-trigger]")
      assert has_element?(view, "button[data-navigation-open-trigger].h-10.w-10")
      assert has_element?(view, "#navigation-search-dialog[aria-hidden='true']")
      assert has_element?(view, "button[data-navigation-search-close][tabindex='-1']")
      assert has_element?(view, "nav[aria-label='Administration']")

      assert has_element?(
               view,
               "#agent-swarm-navigation-#{project.id} > summary a[aria-label='Agent Swarm settings'][href='#{base}/settings']"
             )

      assert has_element?(
               view,
               "[data-navigation-search-input][aria-labelledby='navigation-search-title']"
             )

      refute has_element?(view, "#section-tabs")

      assert has_element?(view, "a[href='#{base}']", "Overview")
      assert has_element?(view, "a[aria-current='page'][href='#{base}/plugins']", "Plugins")
      refute has_element?(view, "a[aria-current='page'][href='/orgs/#{org.slug}/projects']")

      for path <- ~w(agents tasks plugins skills integrations connections devices settings) do
        assert has_element?(view, "a[href='#{base}/#{path}']")
      end

      assert has_element?(
               view,
               "#agent-swarm-navigation-#{project.id} a[href='#{base}/connections']",
               "Connections"
             )

      refute has_element?(view, "section[aria-label='Access']")
      refute has_element?(view, "a[href='#{base}/access']")
    end

    test "the sidebar shows the org icon and links Settings for admins only", %{
      conn: conn,
      org: org,
      project: project
    } do
      icon = "data:image/png;base64,iVBORw0KGgo="
      {:ok, _updated} = BridgeForTeams.Orgs.update_org(org, %{icon: icon})
      path = ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins"

      {:ok, view, html} = live(conn, path)
      assert html =~ icon

      for page <- ["", "/models", "/sso", "/integrations"] do
        assert has_element?(view, ~s(aside a[href="/orgs/#{org.slug}/settings#{page}"]))
      end

      member = user_fixture(email: "settings-nav-member@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")

      {:ok, _view, html} = conn |> log_in_user(member) |> live(path)
      refute html =~ "/orgs/#{org.slug}/settings"
    end

    test "marks the active Agent Swarm destination", %{conn: conn, org: org, project: project} do
      path = ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins"
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "a[aria-current='page'][href='#{path}']", "Plugins")
      refute has_element?(view, "#section-tabs")
    end

    test "redirects when the project does not belong to the org", %{conn: conn, org: org} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/orgs/#{org.slug}/projects/#{bogus}/plugins")

      assert to == ~p"/orgs/#{org.slug}/projects"
    end
  end

  describe "Agent Swarm visibility" do
    test "ordinary org member without ACL cannot open the Agent Swarm", %{
      conn: conn,
      org: org,
      project: project
    } do
      user = user_fixture(email: "plain@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")

      assert to == ~p"/orgs/#{org.slug}/projects"
    end
  end

  describe "Task detail access" do
    test "task detail rejects users without project access", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      assert {:ok, conversation} =
               SalixIM.ConversationServer.create_group_conversation(project.salix_group_id, %{
                 "title" => "Private",
                 "kind" => "user_chat",
                 "status" => "active"
               })

      user = user_fixture(email: "conversation-outsider@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

      assert {:error, {:live_redirect, %{to: to}}} =
               conn
               |> log_in_user(user)
               |> live(
                 ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation["conversation_id"]}"
               )

      assert to == ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks"
    end
  end

  defp open_integration_setup(view, provider) do
    view
    |> element("#integration-provider-#{provider} button", "Configure")
    |> render_click()

    view
  end

  describe "Integrations tab" do
    test "lists integrations first and opens provider setup on demand", %{
      conn: conn,
      org: org,
      project: project
    } do
      seed_feishu_bot_binding(org)
      drain_all()

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      assert has_element?(view, "#integration-provider-list")
      assert has_element?(view, "#integration-provider-feishu")
      assert has_element?(view, "#integration-provider-slack")
      assert html =~ "0 connections"
      refute has_element?(view, "#create-feishu-connect-form")
      refute has_element?(view, "#create-slack-connect-form")

      view
      |> element("button", "Add")
      |> render_click()

      assert has_element?(view, "#integration-setup-panel")

      view
      |> element("#integration-setup-panel button", "Feishu")
      |> render_click()

      html = render(view)
      assert html =~ "No Feishu connects yet"
      assert html =~ "Message route details"
      assert html =~ "not connected"
      assert html =~ "Feishu callback HTTP 200"
      assert html =~ "Router"
      # The card selects an org Feishu app binding instead of collecting credentials.
      assert has_element?(view, "#create-feishu-connect-form")
      assert has_element?(view, "#create-feishu-connect-form select")
      assert html =~ "Acme Feishu"
      assert html =~ "one Feishu app can be connected to one Agent Swarm"
      # No credential inputs on the project card anymore.
      refute has_element?(view, "#create-feishu-connect-form input[type=password]")

      open_integration_setup(view, "slack")
      assert has_element?(view, "#create-slack-connect-form")
    end

    test "with NO bot binding, the Feishu card prompts to create an org app", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      # The list stays compact; Feishu setup gives the org-app guidance on demand.
      refute has_element?(view, "#create-feishu-connect-form")
      open_integration_setup(view, "feishu")
      html = render(view)
      # No binding → no create form, a prompt linking to org Feishu apps instead.
      refute has_element?(view, "#create-feishu-connect-form")
      assert html =~ "No org Feishu app has bot enabled yet."
      assert html =~ ~p"/orgs/#{org.slug}/settings/feishu"
      # Slack is unaffected.
      open_integration_setup(view, "slack")
      assert has_element?(view, "#create-slack-connect-form")
    end

    test "Feishu Run checks points admins to the scope batch import JSON", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        BridgeForTeamsWeb.Dashboard.ProjectShowLiveTest.FeishuChecksSalixClient
      )

      on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev_client) end)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
      open_integration_setup(view, "feishu")

      html =
        view
        |> element("button", "Run checks")
        |> render_click()

      assert html =~ "Feishu console steps completed"
      assert html =~ ~p"/orgs/#{org.slug}/settings/feishu"
      assert html =~ "Permissions &amp; Scopes → Batch import/export scopes → Import JSON"
      assert html =~ "im:message:send_as_bot"
      assert html =~ "im:message.group_at_msg:readonly"
      assert html =~ "im:message.p2p_msg:readonly"
      assert html =~ "im:chat:read"
      assert html =~ "im:chat.members:read"
      assert html =~ "im:message:readonly"
      assert html =~ "im:message.group_msg"
      assert html =~ "im:message:update"
      assert html =~ "im:message:recall"
      assert html =~ "im:message.reactions:read"
      assert html =~ "im:message.reactions:write_only"
      assert html =~ "im:message.pins:read"
      assert html =~ "im:message.pins:write_only"
      assert html =~ "im:resource"
      assert html =~ "contact:contact.base:readonly"
      assert html =~ "contact:user.base:readonly"
      assert html =~ "contact:department.base:readonly"
      assert html =~ "new members are not allowed to view earlier chat history"
      assert html =~ "external chat policy blocks this resource"
      assert html =~ "confidential/restricted mode blocks resource download"
      assert html =~ "permission-bearing app version is not published/installed"
      assert html =~ "Google Calendar meeting notifications"
      assert html =~ "Google Calendar is ACTIVE"
      assert html =~ "Comma Event"
      assert html =~ "oc_team"
      assert html =~ "notify"
      refute html =~ "docx:document"
      refute html =~ "contact:user.department:readonly"
      refute html =~ "im:chat.member:readonly"
      refute html =~ "im:chat:readonly"
    end

    test "Feishu Run checks explains optional, pending, and failed calendar setup", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      prev_policy_result =
        Application.get_env(
          :bridge_for_teams_core,
          :project_show_calendar_policy_test_result
        )

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        BridgeForTeamsWeb.Dashboard.ProjectShowLiveTest.FeishuChecksSalixClient
      )

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_calendar_policy_test_result,
        {:error, :calendar_policy_not_configured}
      )

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)

        restore_env(
          :bridge_for_teams_core,
          :project_show_calendar_policy_test_result,
          prev_policy_result
        )
      end)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
      open_integration_setup(view, "feishu")

      html = view |> element("button", "Run checks") |> render_click()

      assert html =~ "Calendar event creation remains available"
      assert html =~ "calendar policy not configured"

      next_retry_at = DateTime.to_unix(~U[2026-08-01 10:00:00Z], :millisecond)

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_calendar_policy_test_result,
        {:error,
         {:calendar_source_maintenance, {:calendar_source_bootstrap_pending, next_retry_at}}}
      )

      html = view |> element("button", "Run checks") |> render_click()

      assert html =~ "Pending"
      assert html =~ "calendar initial sync pending"
      assert html =~ "Initial calendar sync has not completed yet"
      assert html =~ "retry becomes eligible at the time below"
      assert html =~ "bounded worker cadence determines when it runs"
      assert html =~ "2026-08-01T10:00:00"
      refute html =~ "calendar_source_maintenance"

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_calendar_policy_test_result,
        {:error, {:calendar_source_maintenance, {:google_calendar_http, 403}}}
      )

      html = view |> element("button", "Run checks") |> render_click()

      assert html =~ "Failed"
      assert html =~ "calendar source maintenance failed"
      assert html =~ "requires correction"
      assert html =~ "Google Calendar authorization"

      html = view |> element("button", "Run checks") |> render_click()
      assert html =~ "Failed"
      assert html =~ "calendar source maintenance failed"

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_calendar_policy_test_result,
        {:error, {:calendar_source_maintenance, :calendar_source_refresh_unsettled}}
      )

      html = view |> element("button", "Run checks") |> render_click()

      assert html =~ "Pending"
      assert html =~ "calendar source maintenance retrying"
      assert html =~ "temporarily unavailable"
      refute html =~ "requires correction"

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_calendar_policy_test_result,
        {:error,
         {:calendar_source_maintenance,
          {:google_calendar_rate_limited, 403, ["rateLimitExceeded"]}}}
      )

      html = view |> element("button", "Run checks") |> render_click()

      assert html =~ "Pending"
      assert html =~ "calendar source maintenance retrying"
      assert html =~ "eligible after 60 seconds"

      quota_envelope = %{
        "successful" => false,
        "error" => %{
          "status" => 429,
          "message" => "sensitive-run-check-diagnostic",
          "api_key" => "secret-run-check-api-key",
          "errors" => [%{"reason" => "quotaExceeded"}]
        }
      }

      rate_limit_reason =
        Salix.Bindings.GoogleCalendarError.from_composio_envelope(quota_envelope)

      for policy_reason <- [
            {:calendar_source_maintenance, rate_limit_reason},
            {:calendar_enrollment_list, rate_limit_reason}
          ] do
        Application.put_env(
          :bridge_for_teams_core,
          :project_show_calendar_policy_test_result,
          {:error, policy_reason}
        )

        html = view |> element("button", "Run checks") |> render_click()

        assert html =~ "Pending"
        assert html =~ "retrying"
        assert html =~ "eligible after 60 seconds"
        assert html =~ "quotaExceeded"
        refute html =~ "sensitive-run-check-diagnostic"
        refute html =~ "secret-run-check-api-key"
      end

      for transient_reason <- [
            {:calendar_enrollment_list, :timeout},
            {:calendar_enrollment_account, {:http, 429}},
            {:calendar_enrollment_list, {:transport, :econnrefused}},
            {:calendar_enrollment_connect_lookup, {:ambiguous, :temporarily_inconsistent}}
          ] do
        Application.put_env(
          :bridge_for_teams_core,
          :project_show_calendar_policy_test_result,
          {:error, transient_reason}
        )

        html = view |> element("button", "Run checks") |> render_click()

        assert html =~ "Pending"
        assert html =~ "calendar enrollment retrying"
        assert html =~ "eligible after 60 seconds"
        assert html =~ "six hours plus source jitter"
      end

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_calendar_policy_test_result,
        {:error, :calendar_enrollment_no_active_account}
      )

      html = view |> element("button", "Run checks") |> render_click()

      assert html =~ "Failed"
      assert html =~ "calendar enrollment no active account"
      assert html =~ "Connect an ACTIVE Google Calendar account owned by this Agent Swarm"

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_calendar_policy_test_result,
        {:error, {:calendar_not_found, "Comma Event"}}
      )

      html = view |> element("button", "Run checks") |> render_click()

      assert html =~ "calendar not found"
      assert html =~ "stable calendar ID in meetings.calendar_autojoin.calendars"
      assert html =~ "keep create_calendar equal to one of those entries"
      assert html =~ "Comma Event"
    end

    test "Slack Run checks reports optional, pending, failed, and ACTIVE calendar auto-join", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      prev_policy_result =
        Application.get_env(
          :bridge_for_teams_core,
          :project_show_slack_calendar_policy_test_result
        )

      prev_test_pid =
        Application.get_env(:bridge_for_teams_core, :project_show_slack_checks_test_pid)

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        BridgeForTeamsWeb.Dashboard.ProjectShowLiveTest.SlackCalendarChecksSalixClient
      )

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_slack_calendar_policy_test_result,
        {:error, :calendar_policy_not_configured}
      )

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_slack_checks_test_pid,
        self()
      )

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)

        restore_env(
          :bridge_for_teams_core,
          :project_show_slack_calendar_policy_test_result,
          prev_policy_result
        )

        restore_env(
          :bridge_for_teams_core,
          :project_show_slack_checks_test_pid,
          prev_test_pid
        )
      end)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
      open_integration_setup(view, "slack")

      assert has_element?(
               view,
               "#slack-connects button[phx-click='run-slack-calendar-checks']",
               "Run checks"
             )

      check_button =
        "#slack-connects button[phx-click='run-slack-calendar-checks'][phx-value-id='slack-ready']"

      html = view |> element(check_button, "Run checks") |> render_click()

      assert_receive {:slack_calendar_policy_connect_id, "slack-ready"}

      assert html =~ "Google Calendar meeting auto-join"
      assert html =~ "Skipped"
      assert html =~ "Meeting auto-join is optional"
      assert html =~ "a Slack channel and explicit watched calendars"

      next_retry_at = DateTime.to_unix(~U[2026-08-01 10:00:00Z], :millisecond)

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_slack_calendar_policy_test_result,
        {:error, {:calendar_source_bootstrap_pending, next_retry_at}}
      )

      html = view |> element(check_button, "Run checks") |> render_click()

      assert html =~ "Pending"
      assert html =~ "Initial calendar sync has not completed yet"
      assert html =~ "2026-08-01T10:00:00"

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_slack_calendar_policy_test_result,
        {:error, {:calendar_source_maintenance, {:google_calendar_http, 403}}}
      )

      html = view |> element(check_button, "Run checks") |> render_click()

      assert html =~ "Failed"
      assert html =~ "calendar source maintenance failed"
      assert html =~ "requires correction"
      assert html =~ "Google Calendar authorization"
      refute html =~ "keep create_calendar equal"

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_slack_calendar_policy_test_result,
        {:error, :calendar_policy_group_conflict}
      )

      html = view |> element(check_button, "Run checks") |> render_click()

      assert html =~ "Failed"
      assert html =~ "calendar policy group conflict"
      assert html =~ "Keep exactly one Slack or Feishu connect entry"

      assert [slack_check | _] =
               Observability.list_check_results(org.id,
                 project_id: project.id,
                 surface: "slack_calendar"
               )

      assert slack_check.status == "fail"
      assert slack_check.reason_class == "calendar_policy_group_conflict"
      assert slack_check.subject_type == "project"
      assert slack_check.subject_id == project.id

      Application.delete_env(
        :bridge_for_teams_core,
        :project_show_slack_calendar_policy_test_result
      )

      html = view |> element(check_button, "Run checks") |> render_click()

      assert html =~ "OK"
      assert html =~ "Google Calendar is ACTIVE"
      assert html =~ "automatic meeting join"
      assert html =~ "#botarena"
      assert html =~ "join"
    end

    test "Feishu and Slack checks persist independent check results", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      prev_feishu_policy =
        Application.get_env(
          :bridge_for_teams_core,
          :project_show_calendar_policy_test_result
        )

      prev_slack_policy =
        Application.get_env(
          :bridge_for_teams_core,
          :project_show_slack_calendar_policy_test_result
        )

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)

        restore_env(
          :bridge_for_teams_core,
          :project_show_calendar_policy_test_result,
          prev_feishu_policy
        )

        restore_env(
          :bridge_for_teams_core,
          :project_show_slack_calendar_policy_test_result,
          prev_slack_policy
        )
      end)

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        BridgeForTeamsWeb.Dashboard.ProjectShowLiveTest.FeishuChecksSalixClient
      )

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_calendar_policy_test_result,
        {:error, :calendar_enrollment_no_active_account}
      )

      {:ok, feishu_view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      open_integration_setup(feishu_view, "feishu")
      assert feishu_view |> element("button", "Run checks") |> render_click() =~ "Failed"

      assert [feishu_check] =
               Observability.list_check_results(org.id,
                 project_id: project.id,
                 surface: "bot"
               )

      assert feishu_check.status == "needs_manual"
      assert feishu_check.reason_class == "explicit_admin_action_required"

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        BridgeForTeamsWeb.Dashboard.ProjectShowLiveTest.SlackCalendarChecksSalixClient
      )

      Application.put_env(
        :bridge_for_teams_core,
        :project_show_slack_calendar_policy_test_result,
        {:error, {:calendar_source_maintenance, {:google_calendar_http, 403}}}
      )

      {:ok, slack_view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      open_integration_setup(slack_view, "slack")

      slack_button =
        "#slack-connects button[phx-click='run-slack-calendar-checks'][phx-value-id='slack-ready']"

      assert slack_view |> element(slack_button, "Run checks") |> render_click() =~ "Failed"
      assert slack_view |> element(slack_button, "Run checks") |> render_click() =~ "Failed"

      assert [slack_check, previous_slack_check] =
               Observability.list_check_results(org.id,
                 project_id: project.id,
                 surface: "slack_calendar"
               )

      assert slack_check.status == "fail"
      assert previous_slack_check.status == "fail"
      assert slack_check.reason_class == "calendar_source_maintenance_failed"
      assert previous_slack_check.reason_class == "calendar_source_maintenance_failed"
    end

    test "Slack card previews an App Manifest with scopes + URLs", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
      open_integration_setup(view, "slack")
      html = render(view)

      assert html =~ "Create the Slack app from this manifest"
      assert has_element?(view, "#slack-manifest-json")
      # The manifest carries the bot scopes, the events request URL, and the
      # default app name.
      assert html =~ "chat:write"
      assert html =~ "app_mentions:read"
      assert html =~ "files:read"
      assert html =~ "files:write"
      assert html =~ "/v1/im/slack/events"
      assert html =~ "/v1/im/slack/oauth/callback"
      # The bot's app name defaults to the project's name.
      assert html =~ project.name

      # A one-click link opens Slack's "Create app from manifest" flow with the
      # manifest pre-filled, so the user never copy/pastes the JSON manually.
      assert has_element?(
               view,
               ~s{a[href^="https://api.slack.com/apps?"][href*="new_app=1"][href*="manifest_json="]},
               "Create app on Slack"
             )
    end

    test "project users cannot manage IM connects through forged events", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      user = user_fixture(email: "integrations-user@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      refute html =~ "Create connect"

      view
      |> render_click("open_integration_setup", %{"provider" => "feishu"})

      refute has_element?(view, "#integration-setup-panel")

      assert render_submit(view, "create_slack_connect", %{"slack_connect" => slack_attrs()}) =~
               "Only Agent Swarm admins can manage integrations"

      assert render_click(view, "disable_connect", %{"id" => "slack-forged"}) =~
               "Only Agent Swarm admins can manage integrations"

      assert render_click(view, "run-feishu-checks") =~
               "Only Agent Swarm admins can manage integrations"

      assert render_click(view, "run-slack-calendar-checks", %{"id" => "slack-forged"}) =~
               "Only Agent Swarm admins can manage integrations"

      assert [create_audit] =
               Observability.list_audit_logs(org.id,
                 action: "integration.slack.created",
                 result: "denied"
               )

      assert create_audit.actor_user_id == user.id
      assert create_audit.resource_type == "project_im_connect"
      assert create_audit.reason_class == "forbidden"
      assert create_audit.metadata["project_id"] == project.id
      assert create_audit.metadata["surface"] == "integration"
      assert create_audit.metadata["provider_configured"] in [true, "true"]
      refute inspect(create_audit) =~ "fake-client-secret"
      refute inspect(create_audit) =~ "fake-signing-secret"

      assert [lifecycle_audit] =
               Observability.list_audit_logs(org.id,
                 action: "integration.connect.disabled",
                 result: "denied"
               )

      assert lifecycle_audit.actor_user_id == user.id
      assert lifecycle_audit.resource_type == "project_im_connect"
      assert lifecycle_audit.reason_class == "forbidden"
      assert lifecycle_audit.metadata["connect_id_configured"] in [true, "true"]
      refute inspect(lifecycle_audit) =~ "slack-forged"

      assert [checks_audit] =
               Observability.list_audit_logs(org.id,
                 action: "integration.feishu.checks_run",
                 result: "denied"
               )

      assert checks_audit.actor_user_id == user.id
      assert checks_audit.resource_type == "project_im_connect"
      assert checks_audit.reason_class == "forbidden"
      assert checks_audit.metadata["project_id"] == project.id
      assert checks_audit.metadata["surface"] == "integration"

      assert [slack_checks_audit] =
               Observability.list_audit_logs(org.id,
                 action: "integration.slack.calendar_checks_run",
                 result: "denied"
               )

      assert slack_checks_audit.actor_user_id == user.id
      assert slack_checks_audit.resource_type == "project_im_connect"
      assert slack_checks_audit.reason_class == "forbidden"
      assert slack_checks_audit.metadata["project_id"] == project.id
      assert slack_checks_audit.metadata["surface"] == "integration"
      assert slack_checks_audit.metadata["operation"] == "run_calendar_checks"
      assert slack_checks_audit.metadata["connect_id_configured"] in [true, "true"]
      assert checks_audit.metadata["operation"] == "run_checks"

      assert [event] = Observability.list_events(org.id, audit_log_id: lifecycle_audit.id)
      assert event.status == "denied"
      assert event.reason_class == "forbidden"
    end

    test "editing the Slack app name regenerates the manifest", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
      open_integration_setup(view, "slack")

      refute has_element?(view, "#slack-manifest-json", "Acme Bridge Bot")

      view
      |> form("#create-slack-connect-form", slack_connect: %{app_name: "Acme Bridge Bot"})
      |> render_change()

      # The rendered manifest itself, not the echoed input, carries the new name.
      assert has_element?(view, "#slack-manifest-json", ~s("display_name": "Acme Bridge Bot"))
    end

    test "integrations load self-heals the group without an explicit reconcile", %{
      conn: conn,
      org: org,
      project: project
    } do
      seed_feishu_bot_binding(org)
      # No drain_all/0: load_tab drains the outbox itself so the connect forms
      # render for a freshly created project.
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      assert has_element?(view, "#integration-provider-list")
      refute has_element?(view, "#create-feishu-connect-form")
      refute has_element?(view, "#create-slack-connect-form")
      open_integration_setup(view, "feishu")
      html = render(view)
      assert html =~ "No Feishu connects yet"
      assert has_element?(view, "#create-feishu-connect-form")
      open_integration_setup(view, "slack")
      assert has_element?(view, "#create-slack-connect-form")
    end

    test "selecting a binding creates a Feishu connect with secrets sourced in Salix", %{
      conn: conn,
      org: org,
      project: project
    } do
      # The binding fans its bot secret out to the in-process Salix tenant store;
      # the project card forwards only the chosen app_id and Salix sources the rest.
      seed_feishu_bot_binding(org)
      drain_all()

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      open_integration_setup(view, "feishu")

      html =
        view
        |> form("#create-feishu-connect-form", feishu_connect: %{app_id: "cli_app"})
        |> render_submit()

      assert html =~ "Feishu webhook connect ready"

      html = render(view)
      assert html =~ "/v1/im/feishu/events"
      assert html =~ "feishu-"
      # The bot secret was sourced from the tenant store, so the connect is fully
      # configured even though no secret was typed on the project card.
      assert html =~ "secret set"
      assert html =~ "verification set"
      assert html =~ "encryption set"
      assert html =~ "route ready"
      assert html =~ "Feishu group messages for this connect route to this Agent Swarm"
      # No secret bytes ever rendered.
      refute html =~ "fake-app-value"
      refute html =~ "fake-verification-value"
      refute html =~ "fake-encryption-value"

      html =
        view
        |> element("button", "Run checks")
        |> render_click()

      assert html =~ "Callback reachable + URL verification"
      assert html =~ "Encrypted callback verification failed."
      assert html =~ "Bot chat access + Agent Swarm route"
      assert html =~ "Route and bot identity are ready; chat/member probing needs a runtime call"
      assert html =~ "router agent name"
      assert html =~ "Router"

      {:ok, _group} =
        Salix.Control.Groups.update(project.salix_group_id, %{
          "router_agent_id" => nil
        })

      html =
        view
        |> element("button", "Run checks")
        |> render_click()

      assert html =~ "Bot chat access + Agent Swarm route"
      assert html =~ "The Agent Swarm router is not ready"
      refute html =~ "Route and bot identity are ready; chat/member probing needs a runtime call"
    end

    test "resubmitting the same binding resyncs instead of claiming a fresh create", %{
      conn: conn,
      org: org,
      project: project
    } do
      seed_feishu_bot_binding(org)
      drain_all()

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      open_integration_setup(view, "feishu")

      view
      |> form("#create-feishu-connect-form", feishu_connect: %{app_id: "cli_app"})
      |> render_submit()

      # Same app_id again: honest resync message, never a silent drop / fake create.
      html =
        view
        |> form("#create-feishu-connect-form", feishu_connect: %{app_id: "cli_app"})
        |> render_submit()

      assert html =~ "Reused the existing Feishu connect"
    end

    test "Run checks surfaces missing Feishu bot open_id before first message", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        BridgeForTeamsWeb.Dashboard.ProjectShowLiveTest.FeishuIdentityMissingSalixClient
      )

      on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev_client) end)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
      open_integration_setup(view, "feishu")
      html = render(view)

      assert html =~ "Run checks"

      html =
        view
        |> element("button", "Run checks")
        |> render_click()

      assert html =~ "Bot chat access + Agent Swarm route"
      assert html =~ "bot identity missing"
      assert html =~ "Salix has not resolved the Feishu bot open_id yet"
      assert html =~ "Callback reachable and URL verification passed"
    end

    test "creates a project Slack connect and shows the install URL", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      {:ok, worker} =
        create_provisioned_agent(project.id, %{"name" => "slack-worker", "role" => "worker"})

      drain_all()

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      open_integration_setup(view, "slack")

      html =
        view
        |> form(
          "#create-slack-connect-form",
          slack_connect: slack_attrs(%{inbound_agent_id: worker.salix_agent_id})
        )
        |> render_submit()

      assert html =~ "Slack connect created"

      html = render(view)
      assert html =~ "slack-"
      assert html =~ "Open install URL"
      assert html =~ "slack-worker · worker"
      assert html =~ "client set"
      assert html =~ "signing set"
      refute html =~ "fake-client-secret"
      refute html =~ "fake-signing-secret"
    end

    test "Feishu webhook URL display keeps only app_id query", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, DirtyWebhookSalixClient)

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)
      end)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
      open_integration_setup(view, "feishu")
      html = render(view)

      assert html =~ "/v1/im/feishu/events?app_id=cli_app"
      refute html =~ "app_secret="
      refute html =~ "verification_token="
      refute html =~ "encrypt_key="
      refute html =~ "fake-app-value"
      refute html =~ "fake-verification-value"
      refute html =~ "fake-encryption-value"
    end

    test "malformed Feishu webhook URL display does not fall back to raw query", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, MalformedWebhookSalixClient)

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)
      end)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
      open_integration_setup(view, "feishu")
      html = render(view)

      assert html =~ "feishu-malformed-url"
      refute html =~ "app_secret="
      refute html =~ "fake-app-value"
    end

    test "disable then delete a connect via the UI", %{conn: conn, org: org, project: project} do
      drain_all()

      assert {:ok, connect} =
               ProjectIMConnects.create_project_connect(
                 org.id,
                 project.id,
                 "slack",
                 slack_attrs()
               )

      connect_id = connect["connect_id"]

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")
      open_integration_setup(view, "slack")

      view
      |> element("button[phx-value-id='#{connect_id}']", "Disable")
      |> render_click()

      assert render(view) =~ "Connect disabled"
      assert render(view) =~ "disabled"

      view
      |> element("button[phx-value-id='#{connect_id}']", "Delete")
      |> render_click()

      assert render(view) =~ "Connect deleted"
      assert render(view) =~ "No Slack connects yet"
    end

    test "Salix unavailable state renders actionable copy", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [])

      on_exit(fn ->
        Application.delete_env(:bridge_for_teams_core, :salix_nodes_override)
      end)

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      assert html =~ "Salix unavailable"
      assert html =~ "Retry shortly"
    end

    test "provider validation rejection renders redacted copy", %{
      conn: conn,
      org: org,
      project: project
    } do
      # Seed the binding with the real client first (its bot fan-out needs the
      # in-process tenant store), THEN swap to the rejecting client for the submit.
      seed_feishu_bot_binding(org)
      drain_all()

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, RejectingSalixClient)

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)
      end)

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      open_integration_setup(view, "feishu")

      html =
        view
        |> form("#create-feishu-connect-form", feishu_connect: %{app_id: "cli_app"})
        |> render_submit()

      assert html =~ "The provider rejected the connect setup"
      refute html =~ "provider rejected credential validation"
      refute html =~ "fake-app-value"
      refute html =~ "fake-verification-value"
      refute html =~ "fake-encryption-value"
    end

    test "Feishu app identity conflict renders the one-active-app limitation", %{
      conn: conn,
      org: org,
      project: project
    } do
      seed_feishu_bot_binding(org)
      drain_all()

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, AppInUseSalixClient)

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)
      end)

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations")

      open_integration_setup(view, "feishu")

      html =
        view
        |> form("#create-feishu-connect-form", feishu_connect: %{app_id: "cli_app"})
        |> render_submit()

      assert html =~ "already connected to another Agent Swarm"
      assert html =~ "one Feishu app can serve one Agent Swarm"
    end
  end

  describe "Connections tab" do
    alias BridgeForTeams.OrgOAuthApps

    defp configure_org_oauth(org, provider) do
      {:ok, _} =
        OrgOAuthApps.upsert_org_oauth_app(org.id, provider, %{
          "client_id" => "#{provider}-client-id",
          "client_secret" => "#{provider}-secret"
        })
    end

    defp seed_oauth_connection(org, project, provider, alias_name, account_name) do
      connection_id = "conn-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

      :ok =
        SalixStore.OAuth.put(connection_id, %{
          "connection_id" => connection_id,
          "tenant" => org.salix_tenant_id,
          "provider" => provider,
          "provider_account_id" => "acct-123",
          "provider_account_name" => account_name,
          "access_token" => "secret-access-token",
          "scopes" => ["read"],
          "status" => "active",
          "created_at" => 1,
          "updated_at" => 1
        })

      {:ok, binding, _prev} =
        Salix.Control.OAuthBindings.put(
          org.salix_tenant_id,
          project.salix_group_id,
          provider,
          alias_name,
          connection_id
        )

      binding
    end

    test "lists supported OAuth platforms with authorization readiness", %{
      conn: conn,
      org: org,
      project: project
    } do
      configure_org_oauth(org, "notion")

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      assert html =~ "Connect an account"
      assert html =~ "Notion"
      assert has_element?(view, "#connect-oauth-notion-form")
      assert has_element?(view, "#oauth-provider-notion")
      assert has_element?(view, "#oauth-provider-github")
      refute has_element?(view, "#connect-oauth-github-form")
      assert html =~ "setup required"
      assert html =~ "No connected accounts yet"
    end

    test "shows supported providers as setup-required before org OAuth app setup", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      assert has_element?(view, "#oauth-provider-github")
      assert has_element?(view, "#oauth-provider-notion")
      refute has_element?(view, "#connect-oauth-github-form")
      refute has_element?(view, "#connect-oauth-notion-form")
      assert html =~ "setup required"
      assert html =~ "Configure in org settings"
    end

    test "lists connected accounts without leaking tokens", %{
      conn: conn,
      org: org,
      project: project
    } do
      configure_org_oauth(org, "notion")
      seed_oauth_connection(org, project, "notion", "Work", "Acme Workspace")

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      assert html =~ "Connected accounts"
      assert html =~ "Acme Workspace"
      assert html =~ "Work"
      refute html =~ "secret-access-token"
    end

    test "admin connecting an account is redirected to the provider consent URL", %{
      conn: conn,
      org: org,
      project: project
    } do
      configure_org_oauth(org, "notion")

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      view
      |> form("#connect-oauth-notion-form", oauth: %{alias: "Work"})
      |> render_submit()

      assert has_element?(view, "#connection-detail-modal", "Managed OAuth")

      assert {:error, {:redirect, %{to: url}}} =
               view |> element("#continue-connection") |> render_click()

      assert url =~ "api.notion.com"
      assert url =~ "notion-client-id"

      # The pending account connection was persisted against the project group,
      # carrying a redirect back to this connections page.
      state = URI.parse(url).query |> URI.decode_query() |> Map.fetch!("state")
      assert {:ok, pending} = SalixStore.OAuth.AuthState.get(state)
      assert pending["provider"] == "notion"
      assert pending["alias"] == "Work"
      assert pending["group_id"] == project.salix_group_id

      assert pending["redirect_after"] =~
               "/orgs/#{org.slug}/projects/#{project.id}/connections"
    end

    test "admin disconnects a connected account", %{conn: conn, org: org, project: project} do
      configure_org_oauth(org, "notion")
      binding = seed_oauth_connection(org, project, "notion", "Work", "Acme Workspace")

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      view
      |> element("button[phx-value-id='#{binding["binding_id"]}']", "Disconnect")
      |> render_click()

      assert render(view) =~ "Account disconnected"
      assert render(view) =~ "No connected accounts yet"
    end

    test "admin disables and re-enables a connected account without deleting it", %{
      conn: conn,
      org: org,
      project: project
    } do
      configure_org_oauth(org, "notion")
      binding = seed_oauth_connection(org, project, "notion", "Work", "Acme Workspace")

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      view
      |> element("button[phx-click='disable_oauth'][phx-value-id='#{binding["binding_id"]}']")
      |> render_click()

      assert render(view) =~ "Account disabled."
      assert [disabled] = Salix.Control.OAuthBindings.list(project.salix_group_id)
      assert disabled["binding_id"] == binding["binding_id"]
      assert disabled["enabled"] == false

      view
      |> element("button[phx-click='enable_oauth'][phx-value-id='#{binding["binding_id"]}']")
      |> render_click()

      assert render(view) =~ "Account enabled."
      assert [enabled] = Salix.Control.OAuthBindings.list(project.salix_group_id)
      assert enabled["binding_id"] == binding["binding_id"]
      assert enabled["enabled"] == true
    end

    test "project users cannot connect accounts through forged events", %{
      conn: conn,
      org: org,
      project: project
    } do
      configure_org_oauth(org, "notion")

      user = user_fixture(email: "connections-user@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      # Non-admins see the platform but no connect form.
      assert html =~ "Notion"
      refute has_element?(view, "#connect-oauth-notion-form")

      assert render_submit(view, "connect_oauth", %{"oauth" => %{"provider" => "notion"}}) =~
               "Only Agent Swarm admins can connect accounts"

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_oauth_connection.authorization_started",
                 result: "denied"
               )

      assert audit.actor_user_id == user.id
      assert audit.resource_type == "project_oauth_connection"
      assert audit.reason_class == "forbidden"
      assert audit.metadata["project_id"] == project.id
      assert audit.metadata["surface"] == "oauth"
      assert audit.metadata["provider_configured"] in [true, "true"]

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.status == "denied"
      assert event.reason_class == "forbidden"
    end

    test "renders correct Chinese for a zh_Hans user (no mistranslation)", %{
      conn: conn,
      user: user,
      org: org,
      project: project
    } do
      {:ok, _user} = Accounts.update_locale(user, "zh_Hans")
      configure_org_oauth(org, "notion")

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      # The connect surface renders in Chinese …
      assert html =~ "连接账号"
      assert html =~ "已连接的账号"
      # … including the Composio section, without leaking its English source.
      assert html =~ "通过 Composio 连接应用"
      refute html =~ "App connections via Composio"
      # … and the previous bad fuzzy translation ("Connect" → "已删除连接。") is gone.
      refute html =~ "已删除连接。"
      # The English source string is no longer leaking through untranslated.
      refute html =~ "Connect an account"
    end

    defp with_composio_client(mod) do
      prev = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, mod)
      Application.put_env(:bridge_for_teams_core, :composio_test_pid, self())

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev)
        Application.delete_env(:bridge_for_teams_core, :composio_test_pid)
      end)
    end

    test "renders configured Composio toolkits with connect and disconnect controls", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_composio_client(ComposioSalixClient)

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      assert html =~ "App connections via Composio"
      assert html =~ "Gmail"
      assert html =~ "Notion"

      # The already-connected notion account shows as connected with a
      # disconnect control; unconnected toolkits offer a Connect button.
      assert has_element?(
               view,
               "button[phx-click='disconnect_composio'][phx-value-id='ca_notion']"
             )

      assert has_element?(
               view,
               "button[phx-click='connect_composio'][phx-value-toolkit='gmail']",
               "Connect"
             )

      refute html =~ "Configure in Settings"
    end

    test "admin connecting a toolkit is redirected to the Composio Connect Link", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_composio_client(ComposioSalixClient)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      view
      |> element("button[phx-click='connect_composio'][phx-value-toolkit='gmail']", "Connect")
      |> render_click()

      assert has_element?(view, "#connection-detail-modal", "Composio direct API")
      view |> element("#continue-connection") |> render_click()

      assert_redirect(view, "https://connect.composio.dev/link/lk_dashboard")

      # The Connect Link round-trips the browser back to this connections tab.
      assert_received {:composio_connect_link_requested, "gmail", attrs}
      assert attrs["callback_url"] =~ "/orgs/#{org.slug}/projects/#{project.id}/connections"
    end

    test "admin disconnects a connected Composio account", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_composio_client(ComposioSalixClient)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      view
      |> element(
        "button[phx-click='disconnect_composio'][phx-value-id='ca_notion']",
        "Disconnect"
      )
      |> render_click()

      assert render(view) =~ "Account disconnected."
      assert_received {:composio_disconnect_requested, "ca_notion"}

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_composio_connection.deleted"
               )

      assert audit.resource_type == "composio_connection"
    end

    test "an unconfigured org shows setup guidance linking to Composio settings", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_composio_client(ComposioUnconfiguredSalixClient)

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      assert html =~ "App connections via Composio"
      assert html =~ "Connections need a Composio API key configured once for your organization."
      assert html =~ "/orgs/#{org.slug}/settings/composio"

      # No connectable toolkits until the org opts in.
      refute has_element?(
               view,
               "button[phx-click='connect_composio'][phx-value-toolkit='gmail']"
             )
    end

    test "project users cannot connect Composio accounts through forged events", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_composio_client(ComposioSalixClient)

      user = user_fixture(email: "composio-user@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      # Non-admins see the toolkits but no connect controls.
      refute has_element?(
               view,
               "button[phx-click='connect_composio'][phx-value-toolkit='gmail']"
             )

      assert render_submit(view, "connect_composio", %{"toolkit" => "gmail"}) =~
               "Only Agent Swarm admins can connect accounts"

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_composio_connection.authorization_started",
                 result: "denied"
               )

      assert audit.actor_user_id == user.id
      assert audit.resource_type == "composio_connection"
      assert audit.reason_class == "forbidden"
      assert audit.metadata["surface"] == "composio"
    end
  end

  test "sidebar destinations are reachable", %{
    conn: conn,
    org: org,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")
    nav = "#agent-swarm-navigation-#{project.id}"

    assert has_element?(
             view,
             "#{nav} a[href='/orgs/#{org.slug}/projects/#{project.id}']",
             "Overview"
           )

    assert has_element?(view, "#{nav} a", "Agents")
    assert has_element?(view, "#{nav} a", "Tasks")
    assert has_element?(view, "#{nav} a", "Integrations")
    assert has_element?(view, "#{nav} a", "Connections")
    assert has_element?(view, "#{nav} a", "Devices")
    assert has_element?(view, "#{nav} a[aria-label='Agent Swarm settings']")
  end

  describe "Task detail page" do
    test "renders messages and sends a steering message to the task conversation", %{
      conn: conn,
      org: org,
      project: project,
      user: user
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "helper", "role" => "worker"})

      drain_all()

      assert {:ok, conversation} =
               SalixIM.ConversationInput.create_group_conversation(
                 project.salix_group_id,
                 %{
                   "title" => "Agent chat",
                   "kind" => "user_chat",
                   "status" => "active",
                   "participants" => [
                     %{
                       "actor_type" => "user",
                       "user_id" => user.id,
                       "state" => "active",
                       "notification_filter" => %{"messages" => "all", "statuses" => "none"}
                     },
                     %{
                       "actor_type" => "agent",
                       "agent_id" => agent.salix_agent_id,
                       "agent_name" => "helper",
                       "state" => "active",
                       "notification_filter" => %{"messages" => "all", "statuses" => "none"}
                     }
                   ]
                 }
               )

      conversation_id = conversation["conversation_id"]

      assert {:ok, %{"participants" => participants}} =
               SalixIM.Conversations.list_group_conversation_participants(
                 project.salix_group_id,
                 conversation_id
               )

      agent_participant = Enum.find(participants, &(&1["agent_id"] == agent.salix_agent_id))

      assert {:ok, _} =
               SalixIM.ConversationServer.append_group_conversation_message(
                 project.salix_group_id,
                 conversation_id,
                 %{
                   "client_request_id" => "dash-1",
                   "kind" => "message",
                   "actor_type" => "user",
                   "content" => [%{"type" => "text", "text" => "Hi **there**\n\n- one"}],
                   "created_at" => 1_700_000_000_500
                 }
               )

      assert {:ok, _} =
               SalixIM.ConversationServer.append_group_conversation_agent_message(
                 project.salix_group_id,
                 conversation_id,
                 agent.salix_agent_id,
                 %{
                   "client_request_id" => "m-1",
                   "kind" => "message",
                   "agent_name" => "helper",
                   "content" => [
                     %{
                       "type" => "text",
                       "text" =>
                         "How can `I` help?\n\n[Docs](https://example.com)\n\n<script>alert('x')</script>"
                     }
                   ],
                   "created_at" => 1_700_000_001
                 }
               )

      {:ok, view, html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation_id}")

      assert has_element?(view, "a[aria-current='page']", "Tasks")
      assert html =~ "Agent chat"
      assert html =~ "<strong>there</strong>"
      assert html =~ "<li>one</li>"
      assert html =~ "How can <code>I</code> help?"
      assert html =~ ~s(href="https://example.com")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")
      # Check the message times only: the page also carries random tokens and
      # ids, which can contain "UTC" by chance.
      assert has_element?(view, "time", "2023-11-14")
      refute has_element?(view, "time", "UTC")
      refute html =~ "<script>"
      refute html =~ "alert(&#39;x&#39;)"
      refute html =~ "Debug trace unavailable"
      assert html =~ "/session?participant=#{agent_participant["participant_id"]}"

      assert :binary.match(html, "Hi ") < :binary.match(html, "How can")

      view
      |> form("#message-form", message: %{text: "Please summarize the deployment."})
      |> render_submit()

      assert {:ok, messages} =
               SalixIM.Conversations.list_group_conversation_messages(
                 project.salix_group_id,
                 conversation_id,
                 limit: 100
               )

      assert Enum.any?(messages, fn message ->
               message["actor_type"] == "provider_user" and message["provider"] == "bft" and
                 message["content"] == [
                   %{"type" => "text", "text" => "Please summarize the deployment."}
                 ]
             end)

      [event] =
        Observability.list_events(org.id,
          domain: "conversation",
          event_type: "conversation.message.sent"
        )

      assert event.status == "ok"
      assert event.actor_user_id == user.id
      assert event.resource_type == "project_conversation"
      assert event.resource_id == conversation_id
      assert event.evidence["conversation_id"] == conversation_id
      assert event.evidence["request_id"] == event.correlation_id
      assert SalixStore.Ids.valid_message_id?(event.evidence["message_id"])
      assert event.evidence["delivery_status"] == "queued"
      refute inspect(event) =~ "Please summarize the deployment."

      [audit] =
        Observability.list_audit_logs(org.id,
          action: "project_conversation.message_sent",
          result: "ok"
        )

      assert audit.actor_user_id == user.id
      assert audit.resource_id == conversation_id
      assert audit.request_id == event.correlation_id
      assert audit.metadata["message_id"] == event.evidence["message_id"]
      refute inspect(audit) =~ "Please summarize the deployment."
    end

    test "adds one BFT participant before sending to a provider-backed task", %{
      conn: conn,
      org: org,
      project: project,
      user: user
    } do
      {:ok, worker} =
        create_provisioned_agent(project.id, %{"name" => "slack-worker", "role" => "worker"})

      drain_all()

      assert {:ok, conversation} =
               SalixIM.ConversationInput.create_group_conversation(
                 project.salix_group_id,
                 %{
                   "title" => "Slack direct task",
                   "kind" => "agent_task",
                   "status" => "active",
                   "participants" => [
                     %{
                       "actor_type" => "provider",
                       "provider" => "slack",
                       "role_label" => "slack_thread",
                       "payload" => %{
                         "connect_id" => "sl-worker",
                         "channel_id" => "C1",
                         "thread_ts" => "100.000"
                       }
                     },
                     %{
                       "actor_type" => "agent",
                       "agent_id" => worker.salix_agent_id,
                       "agent_name" => "slack-worker",
                       "role_label" => "worker"
                     }
                   ],
                   "messages" => []
                 }
               )

      conversation_id = conversation["conversation_id"]

      assert {:ok, %{"participants" => participants}} =
               SalixIM.Conversations.list_group_conversation_participants(
                 project.salix_group_id,
                 conversation_id
               )

      worker_participant = Enum.find(participants, &(&1["agent_id"] == worker.salix_agent_id))
      session_id = get_in(worker_participant, ["payload", "session_id"])

      assert SalixStore.Ids.valid_session_id?(session_id)

      {:ok, view, html} =
        live(
          conn,
          ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation_id}"
        )

      assert html =~ "Participants"
      assert html =~ "slack-worker"
      assert html =~ "worker"
      assert html =~ "slack · slack_thread"
      refute html =~ session_id
      assert html =~ "View timeline"
      assert html =~ ~s(href="/orgs/#{org.slug}/projects/#{project.id}/agents/#{worker.id}")

      assert html =~
               ~s(href="/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation_id}/session?participant=#{worker_participant["participant_id"]}")

      for text <- ["Investigate the failed deploy.", "Send me the result."] do
        view
        |> form("#message-form", message: %{text: text})
        |> render_submit()
      end

      assert {:ok, %{"participants" => updated_participants}} =
               SalixIM.Conversations.list_group_conversation_participants(
                 project.salix_group_id,
                 conversation_id
               )

      assert [bft_participant] =
               Enum.filter(updated_participants, fn participant ->
                 participant["actor_type"] == "provider" and participant["provider"] == "bft"
               end)

      assert {:ok, messages} =
               SalixIM.Conversations.list_group_conversation_messages(
                 project.salix_group_id,
                 conversation_id,
                 limit: 100
               )

      assert Enum.map(
               messages,
               &{&1["participant_id"], &1["actor_type"], &1["user_id"], &1["content"]}
             ) == [
               {bft_participant["participant_id"], "provider_user", user.id,
                [%{"type" => "text", "text" => "Investigate the failed deploy."}]},
               {bft_participant["participant_id"], "provider_user", user.id,
                [%{"type" => "text", "text" => "Send me the result."}]}
             ]
    end

    test "redirects when the conversation cannot be found", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/missing")

      assert to == ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks"
    end
  end
end
