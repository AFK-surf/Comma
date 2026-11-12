defmodule Salix.Bindings.DailyBriefMemberAuthTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.DailyBriefMemberAuth
  alias SalixStore.{CasRecord, Keys}
  alias SalixWeb.OAuthFlow

  defmodule SlackOAuth do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      owner = SystemsRuntime.fetch_env!(:salix_web, :daily_brief_auth_owner)
      SystemsRuntime.Proc.send(owner, {:slack, conn.request_path, URI.decode_query(body)})

      response =
        case conn.request_path do
          "/token" ->
            %{
              "ok" => true,
              "app_id" => "A_BOT",
              "authed_user" => %{
                "id" => "UALICE1",
                "access_token" => "xoxp-alice",
                "scope" => "im:history,search:read"
              },
              "team" => %{"id" => "T1", "name" => "Team"}
            }

          _other ->
            %{"ok" => true}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(response))
    end
  end

  @member %{org_id: "org-1", member_id: "member-1", user_id: "user-1"}

  setup do
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_overrides = SystemsRuntime.get_env(:salix_store, :oauth_endpoint_overrides)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    :ok = SalixStore.S3.Fake.reset()
    SystemsRuntime.put_env(:salix_web, :daily_brief_auth_owner, SystemsRuntime.Proc.self())

    bandit =
      start_supervised!(
        {Bandit, plug: SlackOAuth, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    base = "http://127.0.0.1:#{port}"

    SystemsRuntime.put_env(:salix_store, :oauth_endpoint_overrides, %{
      "slack" => %{
        "authorize_url" => base <> "/authorize",
        "token_url" => base <> "/token",
        "revoke_url" => base <> "/revoke"
      }
    })

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)

      if prev_overrides,
        do: SystemsRuntime.put_env(:salix_store, :oauth_endpoint_overrides, prev_overrides),
        else: SystemsRuntime.delete_env(:salix_store, :oauth_endpoint_overrides)

      SystemsRuntime.delete_env(:salix_web, :daily_brief_auth_owner)
    end)

    tenant = "tenant-brief-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    on_exit(fn -> Salix.Control.OAuthApps.delete(tenant, "slack") end)

    connect = %{
      "provider" => "slack",
      "tenant_id" => tenant,
      "group_id" => "group-1",
      "connect_id" => "imc-1",
      "workspace_id" => "T1",
      "app_id" => "A_BOT",
      "bot_token" => "xoxb-bot",
      "client_id" => "bot-client",
      "client_secret" => "bot-secret",
      "created_at" => 1,
      "updated_at" => 1
    }

    {:ok, _} = CasRecord.create(Keys.ctl_im_connect("group-1", "imc-1"), connect)
    {:ok, tenant: tenant}
  end

  test "a member's grant goes through the Swarm's bot app and reports their Slack account", %{
    tenant: tenant
  } do
    assert {:ok, %{"authorization_url" => url, "state" => state}} =
             DailyBriefMemberAuth.start(request(tenant))

    query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert query["client_id"] == "bot-client"
    assert query["user_scope"] =~ "im:history"

    assert {:redirect, "https://bft.test/connected"} =
             OAuthFlow.handle_callback("slack", %{"state" => state, "code" => "code-1"})

    assert_received {:slack, "/token",
                     %{"client_id" => "bot-client", "client_secret" => "bot-secret"}}

    assert {:ok, grant} =
             DailyBriefMemberAuth.result(%{
               tenant_id: tenant,
               state: state,
               bft_member: @member
             })

    assert grant.status == "completed"
    assert grant.slack_user_id == "UALICE1"
    assert grant.slack_workspace_id == "T1"
    assert Salix.Control.OAuthBindings.list("group-1") == []

    other = %{@member | member_id: "member-2"}

    assert {:error, :not_found} =
             DailyBriefMemberAuth.result(%{
               tenant_id: tenant,
               state: state,
               bft_member: other
             })
  end

  test "refuses when the bot app is also the tenant's Slack OAuth app", %{tenant: tenant} do
    {:ok, _} =
      Salix.Control.OAuthApps.put(tenant, "slack", %{
        "client_id" => "bot-client",
        "client_secret" => "bot-secret"
      })

    assert {:error, :shared_slack_app} = DailyBriefMemberAuth.start(request(tenant))
  end

  test "a bot app that becomes the tenant's OAuth app is refused at the callback", %{
    tenant: tenant
  } do
    assert {:ok, %{"state" => state}} = DailyBriefMemberAuth.start(request(tenant))

    {:ok, _} =
      Salix.Control.OAuthApps.put(tenant, "slack", %{
        "client_id" => "bot-client",
        "client_secret" => "bot-secret"
      })

    assert {:redirect, url} =
             OAuthFlow.handle_callback("slack", %{"state" => state, "code" => "code-1"})

    assert url =~ "oauth_error"
    refute_received {:slack, "/token", _}

    assert {:ok, %{status: "failed"}} =
             DailyBriefMemberAuth.result(%{tenant_id: tenant, state: state, bft_member: @member})
  end

  test "a bot-app grant without a member owner cannot start", %{tenant: tenant} do
    assert {:error, {:bad_request, _}} =
             OAuthFlow.start_authorization(
               tenant,
               "group-1",
               "slack",
               %{"alias" => "agent", "scopes" => ["im:history"]},
               app_source: %{
                 "kind" => "slack_im_connect",
                 "group_id" => "group-1",
                 "connect_id" => "imc-1"
               }
             )
  end

  defp request(tenant),
    do: %{
      tenant_id: tenant,
      group_id: "group-1",
      connect_id: "imc-1",
      bft_member: @member,
      redirect_after: "https://bft.test/connected"
    }
end
