defmodule BridgeForTeamsWeb.DashboardAPISwarmConnectionsTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The Connections API behind the React Agent Swarm Connections page:
  messaging (Feishu and Slack connects with their Run checks, Signal chats)
  and accounts (managed OAuth and Composio). Swarm admins write; a swarm
  member's write is refused with a denied audit; someone outside the swarm
  gets 404. Run checks record their results for the Health page.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Memberships,
    Observability,
    Onboarding,
    OrgOAuthApps,
    ProjectIMConnects,
    Projects,
    TestBandit
  }

  alias BridgeForTeams.Salix.Reconciler

  # The page reads every section, so a stub that replaces one Salix
  # integration answers the others as the real client does.
  defmodule PageClient do
    @moduledoc false
    defmacro __using__(_opts) do
      quote do
        use BridgeForTeams.TestSupport.CanonicalAgentClient

        defdelegate list_group_im_connects(group_id, provider), to: BridgeForTeams.Salix.Erpc
        defdelegate slack_manifest(app_name), to: BridgeForTeams.Salix.Erpc
        defdelegate get_group(group_id), to: BridgeForTeams.Salix.Erpc
        defdelegate list_oauth_provider_apps(tenant_id), to: BridgeForTeams.Salix.Erpc
        defdelegate list_group_oauth_bindings(group_id), to: BridgeForTeams.Salix.Erpc
        defdelegate get_composio_settings(tenant_id), to: BridgeForTeams.Salix.Erpc

        defdelegate list_composio_connected_accounts(tenant_id, group_id),
          to: BridgeForTeams.Salix.Erpc

        defdelegate put_oauth_provider_app(tenant_id, provider, attrs),
          to: BridgeForTeams.Salix.Erpc

        defoverridable list_group_im_connects: 2,
                       slack_manifest: 1,
                       get_group: 1,
                       list_oauth_provider_apps: 1,
                       list_group_oauth_bindings: 1,
                       get_composio_settings: 1,
                       list_composio_connected_accounts: 2,
                       put_oauth_provider_app: 3
      end
    end
  end

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

    # The QQ bot OpenAPI: a token for any pair but the wrong secret, and the bot.
    def call(%{request_path: "/app/getAppAccessToken"} = conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      {status, body} =
        case Jason.decode!(raw) do
          %{"clientSecret" => "wrong-secret"} ->
            {400, %{"code" => 100_007, "message" => "invalid appid or secret"}}

          _valid ->
            {200, %{"access_token" => "qq-test-token", "expires_in" => "7200"}}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end

    def call(%{request_path: "/users/@me"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"id" => "6158788878435714165", "username" => "bft"}))
    end

    # The bot has no command panel until Salix makes one.
    def call(%{request_path: "/v2/panels"} = conn, _opts) do
      body =
        if conn.method == "GET",
          do: %{"records" => [], "is_end" => true},
          else: %{"panel_id" => "p_1"}

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end

    # The Lark request URL of this deployment, as Salix serves it.
    def call(%{request_path: "/v1/im/lark/events"} = conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      conn = fetch_query_params(conn)

      {status, body} =
        case SalixIM.ProviderHTTP.handle_lark_request(
               conn.query_params["app_id"],
               Jason.decode!(raw),
               conn.req_headers,
               raw
             ) do
          {:ok, body} -> {200, body}
          {:error, reason} -> {401, %{"error" => "invalid Lark #{reason}"}}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
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
    use PageClient
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    def slack_manifest(_app_name), do: {:error, :unavailable}

    def create_feishu_im_connect(_tenant_id, _group_id, _attrs),
      do: {:error, {:bad_request, "provider rejected credential validation"}}
  end

  defmodule AppInUseSalixClient do
    use PageClient
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
    use PageClient
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
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :composio_test_pid) do
        SystemsRuntime.Proc.send(pid, {:composio_connect_link_requested, toolkit, attrs})
      end

      {:ok,
       %{
         "redirect_url" => "https://connect.composio.dev/link/lk_dashboard",
         "connected_account_id" => "ca_new"
       }}
    end

    def delete_composio_connected_account(_tenant_id, _group_id, account_id) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :composio_test_pid) do
        SystemsRuntime.Proc.send(pid, {:composio_disconnect_requested, account_id})
      end

      {:ok, :ok}
    end
  end

  # Org that never opted into Composio: settings resolve to no source, so
  # `configured?/1` is false and the toolkits render as needing setup.
  defmodule ComposioUnconfiguredSalixClient do
    use PageClient
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
    use PageClient
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
    use PageClient
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
    use PageClient
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
      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :swarm_connections_feishu_policy,
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
    use PageClient
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
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :swarm_connections_slack_checks_pid) do
        SystemsRuntime.Proc.send(pid, {:slack_calendar_policy_connect_id, connect_id})
      end

      if connect_id == "slack-ready" do
        SystemsRuntime.get_env(
          :bridge_for_teams_core,
          :swarm_connections_slack_policy,
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
    use PageClient
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

  # One Lark connect whose probes answer what the test puts in the env.
  defmodule LarkChecksSalixClient do
    use PageClient
    @moduledoc false

    def slack_manifest(_app_name), do: {:error, :unavailable}

    def list_group_im_connects(group_id, provider) when provider in ["lark", nil] do
      {:ok,
       [
         %{
           "connect_id" => "lark-ready",
           "provider" => "lark",
           "group_id" => group_id,
           "app_id" => "cli_lark_app",
           "webhook_url" =>
             "https://bridge.example.test/v1/im/lark/events?app_id=cli_lark_app&encrypt_key=fake-lark-key",
           "status" => "connected",
           "app_secret_configured" => true,
           "verification_token_configured" => false,
           "encrypt_key_configured" => true,
           "created_at" => 1_700_000_000,
           "updated_at" => 1_700_000_000
         }
       ]}
    end

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    def get_group(group_id), do: Salix.Control.Groups.get(group_id)

    def lark_callback_preflight_for_connect(%{"connect_id" => "lark-ready"}),
      do: answer(:callback, {:ok, %{"ok" => true, "challenge_mode" => "encrypted"}})

    def lark_bot_identity(%{"connect_id" => "lark-ready"}),
      do: answer(:identity, {:ok, %{"open_id_fingerprint" => "0123456789ab"}})

    def meeting_calendar_policy(%{"agent_id" => _agent_id, "connect_id" => "lark-ready"}),
      do: answer(:calendar, {:error, :calendar_policy_not_configured})

    defp answer(probe, default) do
      :bridge_for_teams_core
      |> SystemsRuntime.get_env(:swarm_connections_lark_probes, %{})
      |> Map.get(probe, default)
    end
  end

  # A Salix client without the optional Signal callbacks.
  defmodule NoSignalSalixClient do
    use PageClient
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    def slack_manifest(_app_name), do: {:error, :unavailable}
  end

  # A swarm with more agents than one page: the router is past the page.
  defmodule RouterPastPageSalixClient do
    use PageClient
    @moduledoc false

    def page_group_agents(tenant_id, group_id, opts) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :swarm_connections_agents_pid) do
        SystemsRuntime.Proc.send(pid, {:page_group_agents, opts})
      end

      {:ok, page} = BridgeForTeams.Salix.Erpc.page_group_agents(tenant_id, group_id, opts)
      items = Enum.reject(page.items, &(&1["role"] == "router"))
      {:ok, %{page | items: items, next_cursor: "more"}}
    end
  end

  # The Composio API behind the real Salix.Composio: one account owned by
  # the group in `:composio_account_group`.
  defmodule FakeComposioAPI do
    @moduledoc false

    def get_connected_account(_settings, "ca_owned" = id, _opts \\ []),
      do:
        {:ok,
         %{"id" => id, "user_id" => SystemsRuntime.get_env(:salix_web, :composio_account_group)}}

    def delete_connected_account(_settings, id) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.get_env(:salix_web, :composio_test_pid),
        {:composio_api_delete, id}
      )

      {:ok, :ok}
    end
  end

  defmodule FakeComposioSettings do
    @moduledoc false
    def get(_tenant_id), do: {:ok, %{"api_key" => "fake-composio-key"}}
  end

  setup_all do
    prev_feishu_api_base = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)
    prev_feishu_public_base = SystemsRuntime.get_env(:salix_im, :public_base_url)
    prev_qq_api_base = SystemsRuntime.get_env(:salix_im, :qq_api_base_url)
    prev_lark_api_base = SystemsRuntime.get_env(:salix_im, :lark_api_base_url)

    %{pid: bandit, url: mock_feishu_url} =
      TestBandit.start_unlinked!(
        plug: MockFeishuAPI,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, mock_feishu_url <> "/open-apis")
    SystemsRuntime.put_env(:salix_im, :public_base_url, mock_feishu_url)
    SystemsRuntime.put_env(:salix_im, :qq_api_base_url, mock_feishu_url)
    # The Lark open platform answers on the same paths as Feishu's.
    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, mock_feishu_url <> "/open-apis")

    on_exit(fn ->
      restore_env(:salix_im, :qq_api_base_url, prev_qq_api_base)
      restore_env(:salix_im, :lark_api_base_url, prev_lark_api_base)
      restore_env(:salix_im, :feishu_api_base_url, prev_feishu_api_base)
      restore_env(:salix_im, :public_base_url, prev_feishu_public_base)

      if SystemsRuntime.Proc.alive?(bandit) do
        Supervisor.stop(bandit)
      end
    end)

    %{mock_feishu_url: mock_feishu_url}
  end

  # A Salix client listing `count` Slack connects, for the query bound.
  defmodule ManyConnectsSalixClient do
    use PageClient
    @moduledoc false

    def slack_manifest(_app_name), do: {:error, :unavailable}

    def list_group_im_connects(group_id, _provider) do
      count = SystemsRuntime.get_env(:bridge_for_teams_core, :swarm_connections_count, 1)

      {:ok,
       for index <- 1..count do
         %{
           "connect_id" => "slack-#{index}",
           "provider" => "slack",
           "group_id" => group_id,
           "workspace_id" => "T#{index}",
           "oauth_completed_at" => 1_700_000_000,
           "client_secret_configured" => true,
           "signing_secret_configured" => true,
           "updated_at" => 1_700_000_000
         }
       end}
    end
  end

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    drain_all()
    %{conn: conn, user: user, org: org, project: project}
  end

  describe "page" do
    test "lists the org's bot apps, the Slack manifest and every section", %{
      conn: conn,
      org: org,
      project: project
    } do
      seed_feishu_bot_binding(org)
      # A second app without the bot is not offered.
      seed_feishu_bot_binding(org, %{"app_id" => "cli_sso", "bot_enabled" => false})

      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()

      assert data["project"] == %{"id" => project.id, "name" => "Acme", "role" => "admin"}
      assert data["org_admin"] == true

      assert %{"status" => "ok", "feishu" => feishu, "slack" => slack} = data["messaging"]
      assert feishu["apps"] == [%{"app_id" => "cli_app", "name" => "Acme Feishu"}]
      assert feishu["connects"] == []

      assert feishu["route"] == %{
               "status" => "not_connected",
               "connect_id" => nil,
               "router" => nil
             }

      # The Slack bot's name defaults to the swarm's, and its manifest carries
      # the bot scopes and callback addresses.
      assert slack["app_name"] == "Acme"
      assert slack["connects"] == []
      manifest = slack["manifest"]

      for scope <- ~w(chat:write app_mentions:read files:read files:write) do
        assert manifest["json"] =~ scope
      end

      assert manifest["json"] =~ ~s("display_name": "Acme")
      assert manifest["events_url"] =~ "/v1/im/slack/events"
      assert manifest["redirect_url"] =~ "/v1/im/slack/oauth/callback"
      assert manifest["create_url"] =~ "https://api.slack.com/apps?"
      assert manifest["create_url"] =~ "new_app=1"
      assert manifest["create_url"] =~ "manifest_json="

      assert data["signal"]["status"] in ["ok", "unavailable"]
      assert %{"status" => "ok", "connections" => [], "providers" => providers} = data["accounts"]
      assert Enum.all?(providers, &(&1["ready"] == false))
      assert %{"configured" => false, "toolkits" => [_ | _]} = data["composio"]
    end

    test "costs the same queries however many connects Salix lists", %{
      conn: conn,
      org: org,
      project: project
    } do
      put_env(:salix_client, ManyConnectsSalixClient)
      conn |> get(connections_path(org, project)) |> json_response(200)
      one = query_count(conn, connections_path(org, project))

      put_env(:swarm_connections_count, 60)
      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()
      assert length(data["messaging"]["slack"]["connects"]) == 60
      assert query_count(conn, connections_path(org, project)) == one
    end

    test "an org member without a grant, or an outsider, gets 404", %{
      org: org,
      project: project
    } do
      plain = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, plain.id, "member")
      path = connections_path(org, project)

      assert %{"error" => %{"code" => "project_not_found"}} =
               build_conn() |> log_in_user(plain) |> get(path) |> json_response(404)

      assert %{"error" => %{"code" => "org_not_found"}} =
               build_conn() |> log_in_user(user_fixture()) |> get(path) |> json_response(404)

      assert %{"error" => %{"code" => "project_not_found"}} =
               build_conn()
               |> log_in_user(plain)
               |> get(
                 "/dashboard/api/v1/orgs/#{org.slug}/projects/#{SystemsRuntime.Proc.uuid()}/connections"
               )
               |> json_response(404)
    end
  end

  describe "Feishu" do
    test "connecting a bot app sources its secrets in Salix; checks follow the route", %{
      conn: conn,
      org: org,
      project: project
    } do
      # The binding fans its bot secret out to the in-process tenant store; the
      # page forwards only the chosen app_id.
      seed_feishu_bot_binding(org)

      assert %{"notice" => "Feishu webhook connect ready."} =
               conn
               |> post(connections_path(org, project, "/feishu"), %{"app_id" => "cli_app"})
               |> json_response(201)
               |> data()

      body = conn |> get(connections_path(org, project)) |> response(200)
      refute body =~ "fake-app-value"
      refute body =~ "fake-verification-value"
      refute body =~ "fake-encryption-value"

      feishu = body |> Jason.decode!() |> data() |> get_in(["messaging", "feishu"])

      assert [
               %{
                 "connect_id" => "imc1_" <> _,
                 "disabled" => false,
                 "app_secret_configured" => true,
                 "verification_token_configured" => true,
                 "encrypt_key_configured" => true,
                 "webhook_url" => webhook
               }
             ] = feishu["connects"]

      assert webhook =~ "/v1/im/feishu/events"
      assert %{"status" => "ready", "router" => router} = feishu["route"]
      assert is_binary(router)

      checks = run_checks(conn, connections_path(org, project, "/feishu/checks"))
      text = Jason.encode!(checks)

      assert text =~ "Callback reachable + URL verification"
      assert text =~ "Encrypted callback verification failed."
      assert text =~ "Bot chat access + Agent Swarm route"
      assert text =~ "Route and bot identity are ready; chat/member probing needs a runtime call"
      assert text =~ "router_agent_name"

      {:ok, _group} =
        Salix.Control.Groups.update(project.salix_group_id, %{"router_agent_id" => nil})

      text = Jason.encode!(run_checks(conn, connections_path(org, project, "/feishu/checks")))
      assert text =~ "Bot chat access + Agent Swarm route"
      assert text =~ "The Agent Swarm router is not ready"
      refute text =~ "Route and bot identity are ready; chat/member probing needs a runtime call"

      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()
      assert data["messaging"]["feishu"]["route"]["status"] == "unknown"
    end

    test "a provider rejection is redacted", %{conn: conn, org: org, project: project} do
      # Seed with the real client first (its bot fan-out needs the tenant store).
      seed_feishu_bot_binding(org)
      put_env(:salix_client, RejectingSalixClient)

      body =
        conn
        |> post(connections_path(org, project, "/feishu"), %{"app_id" => "cli_app"})
        |> response(422)

      assert %{"error" => %{"code" => "connect_rejected", "message" => message}} =
               Jason.decode!(body)

      assert message =~ "The provider rejected the connect setup"
      refute body =~ "provider rejected credential validation"
      refute body =~ "fake-app-value"
    end
  end

  describe "Lark" do
    test "connecting an app shows its request URL, never a secret", %{
      conn: conn,
      org: org,
      project: project
    } do
      app = %{
        "app_id" => "cli_lark_app",
        "app_secret" => "fake-lark-app-secret",
        "verification_token" => "fake-lark-token"
      }

      assert %{
               "notice" =>
                 "Lark app connected. Save the request URL in the Lark Developer Console."
             } =
               conn
               |> post(connections_path(org, project, "/lark"), app)
               |> json_response(201)
               |> data()

      body = conn |> get(connections_path(org, project)) |> response(200)
      refute body =~ "fake-lark-app-secret"
      refute body =~ "fake-lark-token"
      messaging = body |> Jason.decode!() |> data() |> Map.fetch!("messaging")

      assert [
               %{
                 "connect_id" => "imc1_" <> _ = connect_id,
                 "disabled" => false,
                 "app_id" => "cli_lark_app",
                 "app_secret_configured" => true,
                 "verification_token_configured" => true,
                 "encrypt_key_configured" => false,
                 "webhook_url" => webhook
               }
             ] = messaging["lark"]["connects"]

      assert webhook =~ "/v1/im/lark/events?app_id=cli_lark_app"
      assert %{"status" => "ready", "connect_id" => ^connect_id} = messaging["lark"]["route"]

      # The same app again refreshes its connect instead of adding one.
      assert %{"notice" => "Updated the Lark app's credentials."} =
               conn
               |> post(connections_path(org, project, "/lark"), app)
               |> json_response(201)
               |> data()

      assert %{"notice" => "Connect disabled."} =
               conn
               |> put(connections_path(org, project, "/im/#{connect_id}/enablement"), %{
                 "enabled" => false
               })
               |> json_response(200)
               |> data()

      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()
      assert [%{"disabled" => true}] = data["messaging"]["lark"]["connects"]
    end

    test "an app without a Verification Token or an Encrypt Key is not connected", %{
      conn: conn,
      org: org,
      project: project
    } do
      body =
        conn
        |> post(connections_path(org, project, "/lark"), %{
          "app_id" => "cli_lark_app",
          "app_secret" => "fake-lark-app-secret"
        })
        |> response(422)

      assert %{"error" => %{"code" => "missing_credentials", "message" => message}} =
               Jason.decode!(body)

      assert message =~ "Verification Token or the Encrypt Key"
      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()
      assert data["messaging"]["lark"]["connects"] == []
    end

    test "the page has the scope JSON for the Lark Developer Console", %{
      conn: conn,
      org: org,
      project: project
    } do
      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()

      assert %{"scopes" => %{"tenant" => scopes}} =
               Jason.decode!(data["messaging"]["lark"]["scope_json"])

      assert "im:message.group_msg" in scopes
      assert "wiki:space:retrieve" in scopes
    end

    test "run checks verify the connect's own request URL and are recorded", %{
      conn: conn,
      org: org,
      project: project
    } do
      # The real Salix: the preflight posts to the request URL of the connect,
      # and the Lark ingress verifies it with the connect's own token.
      conn
      |> post(connections_path(org, project, "/lark"), %{
        "app_id" => "cli_lark_app",
        "app_secret" => "fake-lark-app-secret",
        "verification_token" => "fake-lark-token"
      })
      |> json_response(201)

      {:ok, [%{"connect_id" => connect_id}]} =
        ProjectIMConnects.list_project_connects(org.id, project.id, "lark")

      body =
        conn
        |> post(connections_path(org, project, "/lark/#{connect_id}/checks"))
        |> response(200)

      refute body =~ "fake-lark-app-secret"
      refute body =~ "fake-lark-token"
      refute body =~ "ou_test_bot"

      assert %{"checks" => checks, "recorded" => true} = body |> Jason.decode!() |> data()
      assert checks["surface"] == "lark_bot"
      assert checks["connect_ref"] == connect_id

      assert Enum.map(checks["gates"], & &1["gate_id"]) ==
               ~w(bot.credentials bot.callback bot.chat_access bot.calendar bot.first_message bot.manual)

      gates = Map.new(checks["gates"], &{&1["gate_id"], &1})

      assert %{"status" => "ok", "reason_class" => "url_verification_passed"} =
               gates["bot.callback"]

      assert gates["bot.callback"]["evidence"]["preflight"]["challenge_mode"] == "plain"
      assert gates["bot.callback"]["evidence"]["webhook_url"] =~ "?app_id=cli_lark_app"

      assert %{"status" => "skipped", "reason_class" => "validated_on_save"} =
               gates["bot.credentials"]

      assert %{"status" => "skipped", "reason_class" => "chat_probe_missing"} =
               gates["bot.chat_access"]

      assert gates["bot.chat_access"]["evidence"]["bot_identity_status"] == "ok"
      assert gates["bot.calendar"]["required"] == false
      assert gates["bot.first_message"]["status"] == "needs_manual"

      assert %{"status" => "needs_manual", "evidence" => manual} = gates["bot.manual"]
      assert "im:message.group_msg" in manual["required_scopes"]
      assert manual["settings_path"] =~ "/projects/#{project.id}/connections?provider=lark"

      # Health reads the result as the swarm's Lark checks, apart from Feishu's.
      assert [recorded] = Observability.list_check_results(org.id, surface: "lark_bot")
      assert recorded.subject_type == "project"
      assert recorded.subject_id == project.id
      assert recorded.status == "needs_manual"

      # Without a Router the route gate fails.
      {:ok, _group} =
        Salix.Control.Groups.update(project.salix_group_id, %{"router_agent_id" => nil})

      checks = run_checks(conn, connections_path(org, project, "/lark/#{connect_id}/checks"))
      gates = Map.new(checks["checks"]["gates"], &{&1["gate_id"], &1})

      assert %{"status" => "fail", "reason_class" => "router_not_configured"} =
               gates["bot.chat_access"]

      assert %{"error" => %{"code" => "connect_not_found"}} =
               conn
               |> post(connections_path(org, project, "/lark/imc1_unknown/checks"))
               |> json_response(404)
    end

    test "a failed probe names the gate and the next step, without a secret", %{
      conn: conn,
      org: org,
      project: project
    } do
      put_env(:salix_client, LarkChecksSalixClient)
      path = connections_path(org, project, "/lark/lark-ready/checks")
      gates = fn -> Map.new(run_checks(conn, path)["checks"]["gates"], &{&1["gate_id"], &1}) end

      # The probes pass; the request URL is shown with its app_id only.
      passed = gates.()
      assert passed["bot.callback"]["status"] == "ok"

      assert passed["bot.callback"]["evidence"]["webhook_url"] ==
               "https://bridge.example.test/v1/im/lark/events?app_id=cli_lark_app"

      # The shared serializer writes a flag of the evidence as a string.
      assert passed["bot.callback"]["evidence"]["encrypted_callback"] in [true, "true"]
      assert passed["bot.calendar"]["reason_class"] == "calendar_policy_not_configured"
      assert passed["bot.calendar"]["next_action"] =~ "notify a Lark chat"
      refute Jason.encode!(passed) =~ "fake-lark-key"
      refute Jason.encode!(passed) =~ "0123456789ab"

      put_env(:swarm_connections_lark_probes, %{
        callback: {:error, :decrypt_signature},
        identity: {:error, :bot_identity_missing},
        calendar: {:ok, %{"mode" => "notify", "chat_id" => "oc_team", "readiness" => "ACTIVE"}}
      })

      failed = gates.()

      assert %{"status" => "fail", "reason_class" => "decrypt_signature", "next_action" => next} =
               failed["bot.callback"]

      assert next =~ "Encrypt Key"

      assert %{"status" => "fail", "reason_class" => "bot_identity_missing"} =
               failed["bot.chat_access"]

      assert %{"status" => "ok", "reason_class" => "active"} = failed["bot.calendar"]
      assert failed["bot.calendar"]["evidence"]["mode"] == "notify"

      # Salix away: nothing is called a failure.
      put_env(:swarm_connections_lark_probes, %{
        callback: {:error, :unavailable},
        identity: {:error, :timeout},
        calendar: {:error, :timeout}
      })

      away = gates.()
      assert away["bot.callback"]["status"] == "skipped"
      assert away["bot.chat_access"]["status"] == "skipped"
      assert away["bot.calendar"]["status"] == "needs_manual"
    end
  end

  describe "QQ" do
    test "connecting a bot shows its callback address, never the secret", %{
      conn: conn,
      org: org,
      project: project
    } do
      bot = %{"app_id" => "1900012345", "app_secret" => "fake-qq-app-secret"}

      assert %{
               "notice" => "QQ bot connected. Save the callback address in the QQ bot console."
             } =
               conn
               |> post(connections_path(org, project, "/qq"), bot)
               |> json_response(201)
               |> data()

      body = conn |> get(connections_path(org, project)) |> response(200)
      refute body =~ "fake-qq-app-secret"
      qq = body |> Jason.decode!() |> data() |> get_in(["messaging", "qq"])

      assert [
               %{
                 "connect_id" => "imc1_" <> _ = connect_id,
                 "disabled" => false,
                 "app_id" => "1900012345",
                 "bot_name" => "bft",
                 "app_secret_configured" => true,
                 "webhook_url" => webhook
               }
             ] = qq["connects"]

      assert webhook =~ "/v1/im/qq/events?app_id=1900012345"
      assert %{"status" => "ready", "connect_id" => ^connect_id} = qq["route"]

      # The same bot again refreshes its connect instead of adding one.
      assert %{"notice" => "Updated the QQ bot's credentials."} =
               conn
               |> post(connections_path(org, project, "/qq"), bot)
               |> json_response(201)
               |> data()

      # The connect is turned off and deleted like any other.
      assert %{"notice" => "Connect disabled."} =
               conn
               |> put(connections_path(org, project, "/im/#{connect_id}/enablement"), %{
                 "enabled" => false
               })
               |> json_response(200)
               |> data()

      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()
      assert [%{"disabled" => true}] = data["messaging"]["qq"]["connects"]
      assert data["messaging"]["qq"]["route"]["status"] == "disabled"
    end

    test "an admin edits the shortcuts of the bot's command menu", %{
      conn: conn,
      org: org,
      project: project
    } do
      bot = %{"app_id" => "1900012345", "app_secret" => "fake-qq-app-secret"}
      conn |> post(connections_path(org, project, "/qq"), bot) |> json_response(201)

      connect = fn ->
        conn
        |> get(connections_path(org, project))
        |> json_response(200)
        |> data()
        |> get_in(["messaging", "qq", "connects"])
        |> hd()
      end

      # A new bot has the default shortcut, and QQ took its menu.
      assert %{
               "connect_id" => connect_id,
               "command_menu" => [%{"name" => "总结群聊", "scope" => "group"}],
               "command_menu_sync" => %{"private" => "synced", "group" => "synced"}
             } = connect.()

      menu_path = connections_path(org, project, "/qq/#{connect_id}/menu")

      item = %{
        "name" => "周报",
        "description" => "生成本周周报",
        "prompt" => "根据本周群聊生成周报",
        "scope" => "group",
        "admin_only" => true
      }

      assert %{"notice" => "Menu saved and sent to QQ."} =
               conn |> put(menu_path, %{"items" => [item]}) |> json_response(200) |> data()

      assert connect.()["command_menu"] == [item]

      # Salix says what is wrong with a menu, and the stored one stays.
      assert %{
               "error" => %{
                 "code" => "invalid_menu",
                 "message" => "clear is a control command and cannot be a menu item"
               }
             } =
               conn
               |> put(menu_path, %{"items" => [%{"name" => "clear"}]})
               |> json_response(422)

      assert connect.()["command_menu"] == [item]
    end

    test "missing or wrong credentials are refused without echoing them", %{
      conn: conn,
      org: org,
      project: project
    } do
      assert %{"error" => %{"code" => "missing_credentials", "details" => details}} =
               conn
               |> post(connections_path(org, project, "/qq"), %{"app_id" => "1900012345"})
               |> json_response(422)

      assert details["fields"] == ["app_secret"]

      body =
        conn
        |> post(connections_path(org, project, "/qq"), %{
          "app_id" => "1900012345",
          "app_secret" => "wrong-secret"
        })
        |> response(422)

      assert %{"error" => %{"code" => "connect_rejected", "message" => message}} =
               Jason.decode!(body)

      assert message =~ "QQ rejected these credentials"
      refute body =~ "wrong-secret"

      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()
      assert data["messaging"]["qq"]["connects"] == []
    end
  end

  describe "Slack" do
    test "creating a connect shows the install address, never the secrets", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, router} = Agents.current_router(project)

      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()

      assert [%{"id" => router_id, "label" => "Router · router"}] =
               data["messaging"]["slack"]["inbound_agents"]

      assert router_id == router.salix_agent_id

      assert %{
               "notice" =>
                 "Slack connect created. Open the install URL to finish the OAuth install."
             } =
               conn
               |> post(
                 connections_path(org, project, "/slack"),
                 slack_attrs(%{"inbound_agent_id" => router.salix_agent_id})
               )
               |> json_response(201)
               |> data()

      body = conn |> get(connections_path(org, project)) |> response(200)
      refute body =~ "fake-client-secret"
      refute body =~ "fake-signing-secret"

      assert [connect] =
               body |> Jason.decode!() |> data() |> get_in(["messaging", "slack", "connects"])

      assert %{
               "connect_id" => "imc1_" <> _,
               "installed" => false,
               "disabled" => false,
               "inbound_agent" => "Router · router",
               "client_secret_configured" => true,
               "signing_secret_configured" => true,
               "install_url" => "https://" <> _
             } = connect
    end

    test "an inbound agent outside the swarm is a field error", %{
      conn: conn,
      org: org,
      project: project
    } do
      assert %{
               "error" => %{
                 "code" => "invalid_inbound_agent",
                 "message" => message,
                 "details" => %{"fields" => %{"inbound_agent_id" => [message]}}
               }
             } =
               conn
               |> post(
                 connections_path(org, project, "/slack"),
                 slack_attrs(%{"inbound_agent_id" => "agt_not_in_swarm"})
               )
               |> json_response(422)

      assert message == "Choose the Router of this Agent Swarm, or Tasks."
      assert slack_connects(conn, org, project) == []
    end

    test "a connect is disabled, enabled and deleted", %{conn: conn, org: org, project: project} do
      assert {:ok, %{"connect_id" => connect_id}} =
               ProjectIMConnects.create_project_connect(
                 org.id,
                 project.id,
                 "slack",
                 slack_attrs()
               )

      enablement = connections_path(org, project, "/im/#{connect_id}/enablement")

      assert %{"notice" => "Connect disabled."} =
               conn |> put(enablement, %{"enabled" => false}) |> json_response(200) |> data()

      assert [%{"disabled" => true}] = slack_connects(conn, org, project)

      assert %{"notice" => "Connect enabled."} =
               conn |> put(enablement, %{"enabled" => true}) |> json_response(200) |> data()

      assert [%{"disabled" => false}] = slack_connects(conn, org, project)

      assert %{"error" => %{"code" => "invalid_enablement"}} =
               conn |> put(enablement, %{"enabled" => "yes"}) |> json_response(422)

      assert %{"notice" => "Connect deleted."} =
               conn
               |> delete(connections_path(org, project, "/im/#{connect_id}"))
               |> json_response(200)
               |> data()

      assert [] = slack_connects(conn, org, project)

      assert %{"error" => %{"code" => "connect_not_found"}} =
               conn
               |> delete(connections_path(org, project, "/im/#{connect_id}"))
               |> json_response(404)
    end
  end

  describe "Signal" do
    test "creates a one-time code and disconnects a connected chat", %{
      conn: conn,
      org: org,
      project: project
    } do
      {account_id, number} = signal_account!()

      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()

      assert data["signal"] == %{
               "status" => "ok",
               "number" => number,
               "bindings" => [],
               "bindings_truncated" => false
             }

      assert %{"claim" => %{"number" => ^number, "command" => command}} =
               conn
               |> post(connections_path(org, project, "/signal/claims"))
               |> json_response(201)
               |> data()

      assert [_, code] = Regex.run(~r/^comma connect ([2-9A-Z]{4}-[2-9A-Z]{4})$/, command)
      alice = "00000000-0000-4000-8000-000000000011"

      assert {:ok, _bound} =
               SalixIM.SignalConnects.redeem_claim(account_id, code, %{
                 "kind" => "user",
                 "peer" => alice,
                 "display_name" => "Alice"
               })

      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()

      assert [%{"binding_id" => binding_id, "display_name" => "Alice", "kind" => "person"}] =
               data["signal"]["bindings"]

      assert %{"notice" => "Signal chat disconnected."} =
               conn
               |> delete(connections_path(org, project, "/signal/bindings/#{binding_id}"))
               |> json_response(200)
               |> data()

      assert {:error, :not_found} = SalixIM.SignalConnects.find_signal_connect(account_id, alice)
      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()
      assert data["signal"]["bindings"] == []
    end
  end

  describe "Tailscale" do
    test "an admin connects the swarm with a login link, a member sees no link", %{
      conn: conn,
      org: org,
      project: project,
      user: user
    } do
      peer = SalixAgent.TailnetTestPeer.start!()

      read = fn conn ->
        conn |> get(connections_path(org, project)) |> json_response(200) |> data()
      end

      assert %{"status" => "ok", "state" => "disabled", "enabled" => false} =
               read.(conn)["tailnet"]

      assert %{"tailnet" => %{"state" => "needs_login", "login_url" => url} = pending} =
               conn
               |> put(connections_path(org, project, "/tailnet"), %{
                 "tags" => ["tag:comma-agent", "tag:bft"],
                 "expected_tailnet" => ""
               })
               |> json_response(200)
               |> data()

      assert pending["settings"]["tags"] == ["tag:bft", "tag:comma-agent"]

      # Whoever opens the link adds the node to their tailnet: members never see it.
      {member_conn, _member} = member_conn(org, project)
      member_view = read.(member_conn)["tailnet"]
      assert member_view["state"] == "needs_login"
      refute Map.has_key?(member_view, "login_url")
      assert read.(conn)["tailnet"]["login_url"] == url

      {:ok, %{salix_group_id: group_id}} = Projects.get_project(project.id)

      assert {:ok, %{"updated_by" => "bft_user:" <> user_id}} =
               SalixAgent.Tailnet.status(group_id)

      assert user_id == to_string(user.id)

      SalixAgent.TailnetTestPeer.approve!(peer, url)
      running = SalixAgent.TailnetTestPeer.await_state!(group_id, "running")
      assert read.(conn)["tailnet"]["node_name"] == running["node_name"]

      assert [_audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_tailnet.connected",
                 result: "ok"
               )

      assert %{"tailnet" => %{"state" => "disabled"}, "notice" => "Tailscale disconnected."} =
               conn
               |> delete(connections_path(org, project, "/tailnet"))
               |> json_response(200)
               |> data()
    end
  end

  describe "accounts" do
    test "lists connected accounts without their tokens and records the onboarding step", %{
      conn: conn,
      user: user,
      org: org,
      project: project
    } do
      configure_org_oauth(org, "notion")
      seed_oauth_connection(org, project, "notion", "Work", "Acme Workspace")
      refute Onboarding.get_state(org.id, user.id).connected_at

      body = conn |> get(connections_path(org, project)) |> response(200)
      refute body =~ "secret-access-token"

      assert [
               %{
                 "provider" => "notion",
                 "alias" => "Work",
                 "account" => "Acme Workspace",
                 "scopes" => ["read"],
                 "enabled" => true
               }
             ] = body |> Jason.decode!() |> data() |> get_in(["accounts", "connections"])

      assert Onboarding.get_state(org.id, user.id).connected_at
    end

    test "connecting an account starts the provider consent for this swarm", %{
      conn: conn,
      org: org,
      project: project
    } do
      configure_org_oauth(org, "notion")

      assert %{"redirect_url" => url} =
               conn
               |> post(connections_path(org, project, "/accounts"), %{
                 "provider" => "notion",
                 "alias" => "Work"
               })
               |> json_response(200)
               |> data()

      assert url =~ "api.notion.com"
      assert url =~ "notion-client-id"

      # The pending connection belongs to the swarm's group and returns the
      # browser to the Connections page.
      state = URI.parse(url).query |> URI.decode_query() |> Map.fetch!("state")
      assert {:ok, pending} = SalixStore.OAuth.AuthState.get(state)
      assert pending["provider"] == "notion"
      assert pending["alias"] == "Work"
      assert pending["group_id"] == project.salix_group_id

      assert String.ends_with?(
               pending["redirect_after"],
               "/orgs/#{org.slug}/projects/#{project.id}/connections"
             )
    end

    test "an account is disabled, enabled and disconnected", %{
      conn: conn,
      org: org,
      project: project
    } do
      configure_org_oauth(org, "notion")
      binding = seed_oauth_connection(org, project, "notion", "Work", "Acme Workspace")
      account = connections_path(org, project, "/accounts/#{binding["binding_id"]}")

      assert %{"notice" => "Account disabled."} =
               conn
               |> put(account <> "/enablement", %{"enabled" => false})
               |> json_response(200)
               |> data()

      assert [%{"enabled" => false}] = Salix.Control.OAuthBindings.list(project.salix_group_id)

      assert %{"notice" => "Account enabled."} =
               conn
               |> put(account <> "/enablement", %{"enabled" => true})
               |> json_response(200)
               |> data()

      assert [%{"enabled" => true}] = Salix.Control.OAuthBindings.list(project.salix_group_id)

      assert %{"notice" => "Account disconnected."} =
               conn |> delete(account) |> json_response(200) |> data()

      data = conn |> get(connections_path(org, project)) |> json_response(200) |> data()
      assert data["accounts"]["connections"] == []
    end
  end

  describe "Composio" do
    test "connecting a toolkit opens the Composio Connect Link", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_composio_client(ComposioSalixClient)

      assert %{"redirect_url" => "https://connect.composio.dev/link/lk_dashboard"} =
               conn
               |> post(connections_path(org, project, "/composio/gmail/connect"))
               |> json_response(200)
               |> data()

      # The Connect Link returns the browser to the Connections page.
      assert_received {:composio_connect_link_requested, "gmail", attrs}

      assert String.ends_with?(
               attrs["callback_url"],
               "/orgs/#{org.slug}/projects/#{project.id}/connections"
             )
    end
  end

  describe "another swarm's ids" do
    setup %{org: org} do
      {:ok, other} = Projects.create_project(org.id, %{"name" => "Other", "slug" => "other"})
      drain_all()
      %{other: other}
    end

    test "a connect of another swarm is not found and stays as it was", %{
      conn: conn,
      org: org,
      project: project,
      other: other
    } do
      {:ok, %{"connect_id" => connect_id}} =
        ProjectIMConnects.create_project_connect(org.id, other.id, "slack", slack_attrs())

      im = connections_path(org, project, "/im/#{connect_id}")

      assert %{"error" => %{"code" => "connect_not_found"}} =
               conn |> put(im <> "/enablement", %{"enabled" => false}) |> json_response(404)

      assert %{"error" => %{"code" => "connect_not_found"}} =
               conn |> delete(im) |> json_response(404)

      assert %{"error" => %{"code" => "connect_not_found"}} =
               conn
               |> post(connections_path(org, project, "/slack/#{connect_id}/checks"))
               |> json_response(404)

      assert [%{"connect_id" => ^connect_id, "disabled" => false}] =
               slack_connects(conn, org, other)
    end

    test "an OAuth account of another swarm is not found and stays as it was", %{
      conn: conn,
      org: org,
      project: project,
      other: other
    } do
      configure_org_oauth(org, "notion")
      binding = seed_oauth_connection(org, other, "notion", "Work", "Acme Workspace")
      account = connections_path(org, project, "/accounts/#{binding["binding_id"]}")

      assert %{"error" => %{"code" => "account_not_found"}} =
               conn |> put(account <> "/enablement", %{"enabled" => false}) |> json_response(404)

      assert %{"error" => %{"code" => "account_not_found"}} =
               conn |> delete(account) |> json_response(404)

      assert [%{"enabled" => true}] = Salix.Control.OAuthBindings.list(other.salix_group_id)
    end

    test "a Signal chat of another swarm is not found and stays connected", %{
      conn: conn,
      org: org,
      project: project,
      other: other
    } do
      {account_id, _number} = signal_account!()

      %{"claim" => %{"command" => command}} =
        conn
        |> post(connections_path(org, other, "/signal/claims"))
        |> json_response(201)
        |> data()

      [_, code] = Regex.run(~r/^comma connect (\S+)$/, command)
      alice = "00000000-0000-4000-8000-000000000012"

      {:ok, _bound} =
        SalixIM.SignalConnects.redeem_claim(account_id, code, %{
          "kind" => "user",
          "peer" => alice,
          "display_name" => "Alice"
        })

      read = fn swarm ->
        conn |> get(connections_path(org, swarm)) |> json_response(200) |> data()
      end

      assert [%{"binding_id" => binding_id}] = read.(other)["signal"]["bindings"]

      assert %{"error" => %{"code" => "signal_chat_not_found"}} =
               conn
               |> delete(connections_path(org, project, "/signal/bindings/#{binding_id}"))
               |> json_response(404)

      assert [%{"binding_id" => ^binding_id}] = read.(other)["signal"]["bindings"]
      assert {:ok, _connect} = SalixIM.SignalConnects.find_signal_connect(account_id, alice)
    end

    test "a Composio account of another swarm is refused by its owner check", %{
      conn: conn,
      org: org,
      project: project,
      other: other
    } do
      # The real Salix.Composio checks the account's owner group; only the
      # Composio API and settings are stubbed.
      for {key, value} <- [
            composio_client_mod: FakeComposioAPI,
            composio_settings_mod: FakeComposioSettings,
            composio_account_group: other.salix_group_id,
            composio_test_pid: SystemsRuntime.Proc.self()
          ] do
        previous = SystemsRuntime.get_env(:salix_web, key)
        SystemsRuntime.put_env(:salix_web, key, value)
        on_exit(fn -> restore_env(:salix_web, key, previous) end)
      end

      assert %{"error" => %{"code" => "account_not_found"}} =
               conn
               |> delete(connections_path(org, project, "/composio/ca_owned"))
               |> json_response(404)

      refute_received {:composio_api_delete, _id}

      assert %{"notice" => "Account disconnected."} =
               conn
               |> delete(connections_path(org, other, "/composio/ca_owned"))
               |> json_response(200)
               |> data()

      assert_received {:composio_api_delete, "ca_owned"}
    end
  end

  describe "authorization" do
    test "a swarm member cannot write; each attempt is audited", %{
      org: org,
      project: project
    } do
      with_composio_client(ComposioSalixClient)
      configure_org_oauth(org, "notion")
      {member_conn, member} = member_conn(org, project)

      writes = [
        {:post, "/feishu", %{"app_id" => "cli_app"}, "integration.feishu.created",
         "project_im_connect", "integration", "Only Agent Swarm admins can manage integrations."},
        {:post, "/slack", slack_attrs(), "integration.slack.created", "project_im_connect",
         "integration", "Only Agent Swarm admins can manage integrations."},
        {:put, "/im/slack-forged/enablement", %{"enabled" => false},
         "integration.connect.disabled", "project_im_connect", "integration",
         "Only Agent Swarm admins can manage integrations."},
        {:delete, "/im/slack-forged", %{}, "integration.connect.deleted", "project_im_connect",
         "integration", "Only Agent Swarm admins can manage integrations."},
        {:post, "/feishu/checks", %{}, "integration.feishu.checks_run", "project_im_connect",
         "integration", "Only Agent Swarm admins can manage integrations."},
        {:post, "/slack/slack-forged/checks", %{}, "integration.slack.calendar_checks_run",
         "project_im_connect", "integration", "Only Agent Swarm admins can manage integrations."},
        {:post, "/lark/lark-forged/checks", %{}, "integration.lark.checks_run",
         "project_im_connect", "integration", "Only Agent Swarm admins can manage integrations."},
        {:post, "/signal/claims", %{}, "project_signal.claim_started", "project_signal", "signal",
         "Only project admins can do this."},
        {:delete, "/signal/bindings/b-1", %{}, "project_signal.binding_removed", "project_signal",
         "signal", "Only project admins can do this."},
        {:post, "/accounts", %{"provider" => "notion"},
         "project_oauth_connection.authorization_started", "project_oauth_connection", "oauth",
         "Only Agent Swarm admins can connect accounts."},
        {:put, "/accounts/binding-1/enablement", %{"enabled" => false},
         "project_oauth_connection.disabled", "project_oauth_connection", "oauth",
         "Only Agent Swarm admins can manage connected accounts."},
        {:delete, "/accounts/binding-1", %{}, "project_oauth_connection.deleted",
         "project_oauth_connection", "oauth",
         "Only Agent Swarm admins can manage connected accounts."},
        {:post, "/composio/gmail/connect", %{},
         "project_composio_connection.authorization_started", "composio_connection", "composio",
         "Only Agent Swarm admins can connect accounts."},
        {:delete, "/composio/ca_notion", %{}, "project_composio_connection.deleted",
         "composio_connection", "composio",
         "Only Agent Swarm admins can manage connected accounts."},
        {:put, "/tailnet", %{"tags" => ["tag:comma-agent"]}, "project_tailnet.connected",
         "project_tailnet", "tailnet", "Only Agent Swarm admins can manage Tailscale."},
        {:delete, "/tailnet", %{}, "project_tailnet.disconnected", "project_tailnet", "tailnet",
         "Only Agent Swarm admins can manage Tailscale."}
      ]

      for {method, path, body, action, resource_type, surface, message} <- writes do
        response =
          member_conn
          |> dispatch(@endpoint, method, connections_path(org, project, path), body)
          |> response(403)

        assert %{"error" => %{"code" => "forbidden", "message" => ^message}} =
                 Jason.decode!(response)

        refute response =~ "fake-client-secret"

        assert [audit] = Observability.list_audit_logs(org.id, action: action, result: "denied")
        assert audit.actor_user_id == member.id
        assert audit.resource_type == resource_type
        assert audit.reason_class == "forbidden"
        assert audit.metadata["project_id"] == project.id
        assert audit.metadata["surface"] == surface
        refute inspect(audit) =~ "fake-client-secret"
        refute inspect(audit) =~ "fake-signing-secret"
        refute inspect(audit) =~ "slack-forged"
        refute inspect(audit) =~ "lark-forged"
      end

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "integration.slack.calendar_checks_run",
                 result: "denied"
               )

      assert audit.metadata["operation"] == "run_calendar_checks"
      assert audit.metadata["connect_id_configured"] in [true, "true"]

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.status == "denied"
      assert event.reason_class == "forbidden"

      refute_received {:composio_connect_link_requested, _, _}
      refute_received {:composio_disconnect_requested, _}
    end

    test "writes need the page's CSRF token", %{conn: conn, org: org, project: project} do
      conn = get(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/connections")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)
      path = connections_path(org, project, "/im/slack-1/enablement")

      assert_error_sent(403, fn -> put(conn, path, %{"enabled" => "maybe"}) end)

      # With the token the write is read, and refused for its body.
      assert %{"error" => %{"code" => "invalid_enablement"}} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> put(path, %{"enabled" => "maybe"})
               |> json_response(422)
    end
  end

  # ---- helpers ----

  defp connections_path(org, project, rest \\ ""),
    do: "/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/connections#{rest}"

  defp data(%{"data" => data}), do: data

  defp slack_connects(conn, org, project) do
    conn
    |> get(connections_path(org, project))
    |> json_response(200)
    |> get_in(["data", "messaging", "slack", "connects"])
  end

  defp run_checks(conn, path), do: conn |> post(path) |> json_response(200) |> data()

  defp member_conn(org, project) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")
    {log_in_user(build_conn(), member), member}
  end

  defp put_env(key, value) do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, key)
    SystemsRuntime.put_env(:bridge_for_teams_core, key, value)
    on_exit(fn -> restore_env(:bridge_for_teams_core, key, previous) end)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp with_composio_client(module) do
    put_env(:salix_client, module)
    put_env(:composio_test_pid, SystemsRuntime.Proc.self())
  end

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp slack_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        "app_name" => "Comma",
        "app_id" => "A123",
        "client_id" => "cid",
        "client_secret" => "fake-client-secret",
        "signing_secret" => "fake-signing-secret"
      },
      attrs
    )
  end

  # An org-level bot-enabled Feishu app. The binding fans the bot secret out to
  # the in-process Salix tenant store, so a swarm connect can source it by
  # app_id without the secrets.
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

  # The platform Signal number with its account.
  defp signal_account! do
    n = SystemsRuntime.Proc.uniform(9_999_999)
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

    {account_id, number}
  end

  defp configure_org_oauth(org, provider) do
    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, provider, %{
        "client_id" => "#{provider}-client-id",
        "client_secret" => "#{provider}-secret"
      })
  end

  defp seed_oauth_connection(org, project, provider, alias_name, account_name) do
    connection_id =
      "conn-" <> (SystemsRuntime.Proc.random_bytes(8) |> Base.encode16(case: :lower))

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

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "swarm-connections-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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
