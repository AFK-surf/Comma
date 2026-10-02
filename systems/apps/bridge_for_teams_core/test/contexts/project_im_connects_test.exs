defmodule BridgeForTeams.ProjectIMConnectsTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Agents, Observability, Orgs, ProjectIMConnects, Projects, TestBandit}
  import ExUnit.CaptureLog

  defmodule RejectingSalixClient do
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}

    def create_feishu_im_connect(_tenant_id, _group_id, _attrs),
      do: {:error, {:bad_request, "Feishu credential validation failed"}}
  end

  defmodule RejectingListSalixClient do
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:error, :unavailable}
  end

  defmodule AppInUseSalixClient do
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}

    def create_feishu_im_connect(_tenant_id, _group_id, _attrs),
      do: {:error, {:bad_request, "feishu app_id is already used by another connect"}}
  end

  defmodule RejectingUpdateSalixClient do
    @moduledoc false

    def update_feishu_im_connect(_tenant_id, _group_id, _connect_id, _attrs),
      do: {:error, {:bad_request, "Feishu credential validation failed"}}
  end

  # Records each route read; the group id picks the answer.
  defmodule RouteListSalixClient do
    @moduledoc false

    def list_group_im_connects(group_id, provider, opts) do
      send(self(), {:route_list_read, group_id, provider, opts})

      case group_id do
        "g-ok" -> {:ok, [%{"connect_id" => "c-1", "app_id" => "cli_app"}]}
        "g-missing" -> {:error, :not_found}
        "g-rejected" -> {:error, {:error, :boom}}
        _ -> {:error, :timeout}
      end
    end
  end

  defmodule GroupMissingSalixClient do
    @moduledoc false

    # The group lookup never resolves, so the drain-and-retry still ends in
    # group_not_ready.
    def list_group_im_connects(_group_id, _provider), do: {:error, :not_found}
  end

  defmodule SecretBearingErrorSalixClient do
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}

    def create_feishu_im_connect(_tenant_id, _group_id, _attrs) do
      {:error,
       {:provider_error,
        %{
          "app_secret" => "fake-app-value",
          "nested" => [%{"encrypt_key" => "fake-encryption-value"}],
          "provider_message" => "credential check included fake-provider-string-value",
          verification_token: "fake-verification-value"
        }}}
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
  end

  setup do
    SalixStore.S3.Fake.reset()
    prev_feishu_api_base = Application.get_env(:salix_im, :feishu_api_base_url)

    %{url: feishu_url} =
      TestBandit.start_supervised!(plug: MockFeishuAPI, startup_log: false)

    Application.put_env(:salix_im, :feishu_api_base_url, feishu_url <> "/open-apis")
    on_exit(fn -> restore_env(:salix_im, :feishu_api_base_url, prev_feishu_api_base) end)

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, project} = Projects.create_project(org.id, %{name: "Bridge", slug: "bridge"})
    seed_feishu_tenant_app(org.salix_tenant_id)
    %{org: org, project: project}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp drain_all do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp feishu_creds(attrs \\ %{}) do
    Map.merge(
      %{
        "app_id" => "cli_app"
      },
      attrs
    )
  end

  defp seed_feishu_tenant_app(tenant_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "app_id" => "cli_app",
          "app_secret" => "fake-app-value",
          "verification_token" => "fake-verification-value",
          "encrypt_key" => "fake-encryption-value"
        },
        attrs
      )

    assert {:ok, _app} = Salix.Control.Tenants.put_feishu_tenant_app(tenant_id, attrs)
  end

  defp slack_creds(attrs \\ %{}) do
    Map.merge(
      %{
        "app_id" => "A123",
        "client_id" => "cid",
        "client_secret" => "csecret",
        "signing_secret" => "ssecret"
      },
      attrs
    )
  end

  defp with_client(mod) do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, mod)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev) end)
  end

  test "a stale dashboard cannot reconnect or enable routes after archival", %{
    org: org,
    project: project
  } do
    assert {:ok, _} = Projects.archive_project(project)

    assert {:error, :not_found} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds()
             )

    assert {:error, :not_found} =
             ProjectIMConnects.enable_project_connect(org.id, project.id, "old-connect")
  end

  test "slack_manifest builds a paste-ready Slack App Manifest" do
    assert {:ok, payload} = ProjectIMConnects.slack_manifest("Acme Bridge Bot")

    assert payload["redirect_url"] =~ "/v1/im/slack/oauth/callback"
    assert payload["events_url"] =~ "/v1/im/slack/events"
    assert payload["interactions_url"] =~ "/v1/im/slack/interactions"

    manifest = payload["manifest"]
    assert manifest["display_information"]["name"] == "Acme Bridge Bot"

    assert get_in(manifest, ["features", "app_home"]) == %{
             "home_tab_enabled" => true,
             "messages_tab_enabled" => true,
             "messages_tab_read_only_enabled" => false
           }

    scopes = manifest["oauth_config"]["scopes"]["bot"]
    assert "chat:write" in scopes
    assert "app_mentions:read" in scopes
    assert "channels:join" in scopes
    assert "emoji:read" in scopes
    assert "files:read" in scopes
    assert "files:write" in scopes
    assert "reactions:read" in scopes

    settings = manifest["settings"]
    assert settings["event_subscriptions"]["request_url"] == payload["events_url"]

    assert settings["interactivity"] == %{
             "is_enabled" => true,
             "request_url" => payload["interactions_url"]
           }

    assert "app_mention" in settings["event_subscriptions"]["bot_events"]
    assert "channel_created" in settings["event_subscriptions"]["bot_events"]
  end

  test "slack_manifest builds URLs from the configured Salix public base URL" do
    prev = Application.get_env(:salix_im, :public_base_url)
    Application.put_env(:salix_im, :public_base_url, "https://salix.example.test")
    on_exit(fn -> restore_env(:salix_im, :public_base_url, prev) end)

    assert {:ok, payload} = ProjectIMConnects.slack_manifest("Bot")

    assert payload["redirect_url"] == "https://salix.example.test/v1/im/slack/oauth/callback"
    assert payload["events_url"] == "https://salix.example.test/v1/im/slack/events"

    assert payload["interactions_url"] ==
             "https://salix.example.test/v1/im/slack/interactions"

    assert payload["manifest"]["oauth_config"]["redirect_urls"] == [
             "https://salix.example.test/v1/im/slack/oauth/callback"
           ]
  end

  test "unsupported provider is rejected", %{org: org, project: project} do
    drain_all()

    assert {:error, :unsupported_provider} =
             ProjectIMConnects.create_project_connect(org.id, project.id, "telegram", %{})
  end

  test "missing required credential fields are field-specific", %{org: org, project: project} do
    drain_all()

    # Feishu project connects require only app_id at this boundary. Bot secrets are
    # sourced inside Salix from the tenant Feishu app store.
    assert {:error, {:missing_credentials, ["app_id"]}} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds(%{"app_id" => ""})
             )

    assert {:error, {:missing_credentials, ["signing_secret"]}} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "slack",
               slack_creds(%{"signing_secret" => ""})
             )
  end

  test "create drains the outbox to reconcile the group on first use", %{
    org: org,
    project: project
  } do
    # No explicit drain_all/0: the context drains the reconcile outbox itself so
    # a freshly created project's Salix group exists before the connect is made.
    assert {:ok, connect} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds()
             )

    assert connect["provider"] == "feishu"
    assert connect["group_id"] == project.salix_group_id
  end

  test "list surfaces group_not_ready when the group cannot be resolved", %{
    org: org,
    project: project
  } do
    drain_all()
    # With a stub whose group lookups never resolve, the drain-and-retry still
    # yields group_not_ready rather than raising.
    with_client(GroupMissingSalixClient)

    assert {:error, :group_not_ready} =
             ProjectIMConnects.list_project_connects(org.id, project.id, "feishu")
  end

  test "the route lookup of many projects stops at the first Salix timeout" do
    projects =
      Enum.map(
        ~w(g-ok g-missing g-rejected g-slow g-after),
        &%BridgeForTeams.Schema.Project{id: &1, salix_group_id: &1}
      )

    with_client(RouteListSalixClient)

    assert {[{%{id: "g-ok"}, %{"connect_id" => "c-1"}}], :timeout} =
             ProjectIMConnects.list_connects_for_projects(projects, "feishu")

    for group_id <- ~w(g-ok g-missing g-rejected g-slow) do
      assert_received {:route_list_read, ^group_id, "feishu", [timeout: 3_000]}
    end

    refute_received {:route_list_read, "g-after", _provider, _opts}
  end

  test "list records an Operations diagnostic when Salix IM connects are unreachable", %{
    org: org,
    project: project
  } do
    drain_all()
    with_client(RejectingListSalixClient)

    assert {:error, :unavailable} =
             ProjectIMConnects.list_project_connects(org.id, project.id, "feishu")

    assert {:error, :unavailable} =
             ProjectIMConnects.list_project_connects(org.id, project.id, "feishu")

    assert [event] =
             Observability.list_events(org.id,
               event_type: "project.im_connects.unavailable",
               limit: 10
             )

    assert event.domain == "integration"
    assert event.project_id == project.id
    assert event.resource_type == "project_im_connect_index"
    assert event.resource_id == project.id
    assert event.source == "salix.im"
    assert event.severity == "warning"
    assert event.status == "unavailable"
    assert event.reason_class == "unavailable"
    assert event.correlation_id == "project:#{project.id}:im-connects:feishu"
    assert event.evidence["provider"] == "feishu"
    assert event.evidence["surface"] == "project_integrations"
    refute inspect(event.evidence) =~ "webhook_url"
    refute inspect(event.evidence) =~ "oauth_url"
    refute inspect(event.evidence) =~ "fake-app-value"
  end

  test "successful IM connect reads do not record unavailable diagnostics", %{
    org: org,
    project: project
  } do
    drain_all()
    with_client(RejectingSalixClient)

    assert {:ok, []} = ProjectIMConnects.list_project_connects(org.id, project.id, nil)

    assert [] =
             Observability.list_events(org.id,
               event_type: "project.im_connects.unavailable",
               limit: 10
             )
  end

  test "Salix Feishu validation rejection is normalized", %{org: org, project: project} do
    drain_all()
    with_client(RejectingSalixClient)

    assert {:error, :connect_rejected} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds()
             )
  end

  test "failed project IM connect writes failed audit without provider details", %{
    org: org,
    project: project
  } do
    drain_all()
    with_client(RejectingSalixClient)

    assert {:error, :connect_rejected} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds(),
               actor_label: "project-admin@example.com",
               request_id: "req_project_im_failed"
             )

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.feishu.updated")

    assert audit.result == "failed"
    assert audit.reason_class == "connect_rejected"
    assert audit.request_id == "req_project_im_failed"
    assert audit.resource_type == "project_im_connect"
    assert audit.resource_id == "feishu"
    assert audit.metadata["project_id"] == project.id
    assert audit.metadata["provider"] == "feishu"
    refute inspect(audit) =~ "Feishu credential validation failed"
    refute inspect(audit) =~ "fake-app-value"
  end

  test "Salix Feishu app identity conflicts get a specific project error", %{
    org: org,
    project: project
  } do
    drain_all()
    with_client(AppInUseSalixClient)

    assert {:error, :provider_app_in_use} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds()
             )
  end

  test "create failure logs redact credential-shaped provider details", %{
    org: org,
    project: project
  } do
    drain_all()
    with_client(SecretBearingErrorSalixClient)

    log =
      capture_log(fn ->
        assert {:error, {:provider_error, _reason}} =
                 ProjectIMConnects.create_project_connect(
                   org.id,
                   project.id,
                   "feishu",
                   feishu_creds()
                 )
      end)

    assert log =~ "project_im_connect_failed"
    assert log =~ "[REDACTED]"
    refute log =~ "fake-app-value"
    refute log =~ "fake-verification-value"
    refute log =~ "fake-encryption-value"
    refute log =~ "fake-provider-string-value"
  end

  test "creates and lists safe public Feishu connect metadata", %{org: org, project: project} do
    drain_all()

    assert {:ok, connect} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds()
             )

    assert connect["provider"] == "feishu"
    assert connect["group_id"] == project.salix_group_id
    assert connect["webhook_url"] =~ "/v1/im/feishu/events"
    assert connect["app_secret_configured"] == true
    assert connect["verification_token_configured"] == true
    assert connect["encrypt_key_configured"] == true
    refute Map.has_key?(connect, "app_secret")
    refute Map.has_key?(connect, "verification_token")
    refute Map.has_key?(connect, "encrypt_key")

    assert {:ok, [listed]} =
             ProjectIMConnects.list_project_connects(org.id, project.id, "feishu")

    assert listed["connect_id"] == connect["connect_id"]
    refute Map.has_key?(listed, "app_secret")
  end

  test "successful project IM connect writes audit without secrets", %{org: org, project: project} do
    drain_all()

    assert {:ok, connect} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds(),
               actor_label: "project-admin@example.com",
               request_id: "req_project_im_create"
             )

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.feishu.created")

    assert audit.result == "ok"
    assert audit.request_id == "req_project_im_create"
    assert audit.resource_type == "project_im_connect"
    assert audit.resource_id == connect["connect_id"]
    assert audit.metadata["project_id"] == project.id
    assert audit.metadata["provider"] == "feishu"
    assert audit.metadata["connect_id"] == connect["connect_id"]
    assert audit.metadata["app_id_configured"] == "true"
    assert audit.metadata["app_secret_configured"] == "true"
    refute inspect(audit) =~ "fake-app-value"
    refute inspect(audit) =~ "fake-verification-value"
    refute inspect(audit) =~ "fake-encryption-value"

    assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
    assert event.domain == "audit"
    assert event.event_type == "audit.integration.feishu.created"
    assert event.correlation_id == "req_project_im_create"
  end

  test "creates a Slack connect with an install URL and safe metadata", %{
    org: org,
    project: project
  } do
    drain_all()
    [router] = Agents.list_agents(project.id)

    assert {:ok, connect} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "slack",
               slack_creds(%{"inbound_agent_id" => router.salix_agent_id})
             )

    assert connect["provider"] == "slack"
    assert connect["group_id"] == project.salix_group_id
    assert connect["inbound_agent_id"] == router.salix_agent_id
    assert connect["client_secret_configured"] == true
    assert connect["signing_secret_configured"] == true
    assert is_binary(connect["oauth_url"])

    oauth_scopes =
      connect["oauth_url"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("scope")
      |> String.split(",")

    assert "files:read" in oauth_scopes
    assert "files:write" in oauth_scopes
    assert "channels:join" in oauth_scopes

    refute Map.has_key?(connect, "client_secret")
    refute Map.has_key?(connect, "signing_secret")

    assert {:ok, [listed]} = ProjectIMConnects.list_project_connects(org.id, project.id, "slack")
    assert listed["connect_id"] == connect["connect_id"]
    assert listed["inbound_agent_id"] == router.salix_agent_id
  end

  test "rejects a Slack inbound agent outside the project", %{org: org, project: project} do
    drain_all()

    assert {:error, :invalid_inbound_agent} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "slack",
               slack_creds(%{"inbound_agent_id" => "agent_missing"})
             )
  end

  test "list with no provider returns connects across providers", %{org: org, project: project} do
    drain_all()

    {:ok, _feishu} =
      ProjectIMConnects.create_project_connect(org.id, project.id, "feishu", feishu_creds())

    {:ok, _slack} =
      ProjectIMConnects.create_project_connect(org.id, project.id, "slack", slack_creds())

    assert {:ok, connects} = ProjectIMConnects.list_project_connects(org.id, project.id, nil)
    providers = connects |> Enum.map(& &1["provider"]) |> Enum.sort()
    assert providers == ["feishu", "slack"]
  end

  test "duplicate create for the same app_id resyncs instead of silently dropping (RFC §5)", %{
    org: org,
    project: project
  } do
    drain_all()

    assert {:ok, first} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds()
             )

    # A fresh route is tagged "created" so the caller can flash an honest message.
    assert first["action"] == "created"

    # Resubmitting the same app_id is NOT silently dropped: it routes through the
    # update path and is tagged "resynced" so the admin is told it was a refresh,
    # never claimed as a brand-new create.
    assert {:ok, second} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds()
             )

    assert second["action"] == "resynced"
    assert second["connect_id"] == first["connect_id"]

    # The project still has exactly one connect against that app_id.
    assert {:ok, [listed]} = ProjectIMConnects.list_project_connects(org.id, project.id, "feishu")
    assert listed["connect_id"] == first["connect_id"]
  end

  test "a tenant Feishu app cannot be connected to two projects", %{org: org, project: project} do
    drain_all()
    {:ok, other_project} = Projects.create_project(org.id, %{name: "Other", slug: "other"})
    drain_all()

    assert {:ok, first} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds()
             )

    assert {:error, :provider_app_in_use} =
             ProjectIMConnects.create_project_connect(
               org.id,
               other_project.id,
               "feishu",
               feishu_creds()
             )

    assert first["group_id"] == project.salix_group_id
  end

  test "update resync rejection is normalized", %{org: org, project: project} do
    drain_all()

    assert {:ok, connect} =
             ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               "feishu",
               feishu_creds()
             )

    with_client(RejectingUpdateSalixClient)

    assert {:error, :connect_rejected} =
             ProjectIMConnects.update_project_connect(
               org.id,
               project.id,
               "feishu",
               connect["connect_id"],
               feishu_creds()
             )
  end

  test "disable, enable and delete drive the connect lifecycle", %{org: org, project: project} do
    drain_all()

    assert {:error, :connect_not_found} =
             ProjectIMConnects.disable_project_connect(org.id, project.id, "conn_missing")

    assert {:ok, connect} =
             ProjectIMConnects.create_project_connect(org.id, project.id, "slack", slack_creds())

    connect_id = connect["connect_id"]

    audit_opts = [
      actor_label: "project-admin@example.com",
      request_id: "req_project_im_lifecycle"
    ]

    assert {:ok, _} =
             ProjectIMConnects.disable_project_connect(org.id, project.id, connect_id, audit_opts)

    assert {:ok, [disabled]} =
             ProjectIMConnects.list_project_connects(org.id, project.id, "slack")

    assert disabled["disabled_at"]

    assert {:ok, _} =
             ProjectIMConnects.enable_project_connect(org.id, project.id, connect_id, audit_opts)

    assert {:ok, [enabled]} = ProjectIMConnects.list_project_connects(org.id, project.id, "slack")
    refute enabled["disabled_at"]

    assert {:ok, _} =
             ProjectIMConnects.delete_project_connect(org.id, project.id, connect_id, audit_opts)

    assert {:ok, []} = ProjectIMConnects.list_project_connects(org.id, project.id, "slack")

    actions =
      org.id
      |> Observability.list_audit_logs(limit: 20)
      |> Enum.map(& &1.action)

    assert "integration.slack.disabled" in actions
    assert "integration.slack.enabled" in actions
    assert "integration.slack.deleted" in actions
  end

  test "project org mismatch is rejected", %{project: project} do
    {:ok, other_org} = Orgs.create_org(%{name: "Other", slug: "other"})

    assert {:error, :not_found} =
             ProjectIMConnects.create_project_connect(
               other_org.id,
               project.id,
               "feishu",
               %{}
             )

    assert {:error, :not_found} =
             ProjectIMConnects.list_project_connects(other_org.id, project.id, "feishu")
  end
end
