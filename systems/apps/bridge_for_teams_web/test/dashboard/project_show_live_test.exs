defmodule BridgeForTeamsWeb.Dashboard.ProjectShowLiveTest do
  @moduledoc """
  Tests for the project-detail slice: ProjectLive.Show with the Agents,
  Settings, and Devices tabs. Covers render of each tab and the key write
  interactions (create agent, configure agent → enqueues reconcile, add
  device → mints + shows the connector token once).
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query, only: [from: 2]

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Environments,
    Memberships,
    Observability,
    ProjectIMConnects,
    Projects,
    TestBandit
  }

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Salix.Reconciler
  alias BridgeForTeams.Schema.{Agent, ProjectDeviceProjection, ReconcileOutbox}
  alias SalixStore.RuntimeIds

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

  defmodule WorkloadPickerSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def get_agent_projection(agent_id, tenant_id),
      do: SalixAgent.Control.get(agent_id, tenant_id)

    def page_external_worker_targets(tenant_id, "project", project_id, group_id, provider, opts) do
      send(Application.fetch_env!(:bridge_for_teams_core, :workload_picker_test_pid), {
        :workload_page,
        tenant_id,
        project_id,
        group_id,
        provider,
        opts
      })

      case Application.get_env(:bridge_for_teams_core, :workload_picker_page_result, :items) do
        :items ->
          all = Application.fetch_env!(:bridge_for_teams_core, :workload_picker_items)
          query = opts |> Keyword.get(:query, "") |> String.downcase()

          matching =
            Enum.filter(all, fn item ->
              item.provider == provider and
                (query == "" or
                   String.contains?(String.downcase(item.workload_id), query) or
                   String.contains?(String.downcase(item.label), query))
            end)

          limit = Keyword.fetch!(opts, :limit)

          page =
            case Keyword.get(opts, :cursor) do
              nil -> 1
              "page-" <> page -> String.to_integer(page)
            end

          items =
            matching
            |> Enum.drop((page - 1) * limit)
            |> Enum.take(limit)
            |> Enum.filter(&(Keyword.get(opts, :include_unavailable, false) or &1.selectable))

          next? = length(matching) > page * limit

          {:ok,
           %{
             items: items,
             next_cursor: if(next?, do: "page-#{page + 1}", else: nil),
             read_at: DateTime.utc_now()
           }}

        {:error, _reason} = error ->
          error
      end
    end

    def validate_external_worker_target(
          tenant_id,
          "project",
          project_id,
          group_id,
          provider,
          workload_id,
          fence
        ) do
      send(Application.fetch_env!(:bridge_for_teams_core, :workload_picker_test_pid), {
        :workload_validate,
        tenant_id,
        project_id,
        group_id,
        provider,
        workload_id,
        fence
      })

      case Enum.find(
             Application.fetch_env!(:bridge_for_teams_core, :workload_picker_items),
             &(&1.provider == provider and &1.workload_id == workload_id)
           ) do
        nil -> {:error, :not_found}
        %{selection_fence: ^fence} = item -> {:ok, item}
        _ -> {:error, :selection_changed}
      end
    end
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

  defmodule AgentProjectionTimeoutSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_envs(group_id, tenant_id) do
      BridgeForTeams.Salix.Erpc.list_group_envs(group_id, tenant_id)
    end

    def get_agent_projection(_agent_id, _tenant_id), do: {:error, :timeout}
  end

  defmodule DeviceProjectionOnlySalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def get_tenant_config(_tenant_id, "android_control", default) do
      {:ok, Application.get_env(:bridge_for_teams_core, :device_projection_android, default)}
    end

    def list_group_envs(_group_id, _tenant_id),
      do: raise("device LiveView read must not call list_group_envs")

    def page_group_envs(_group_id, _tenant_id, _opts),
      do: raise("device LiveView read must not call page_group_envs")

    def get_agent_projection(_agent_id, _tenant_id),
      do: raise("agent LiveView read must not call get_agent_projection")

    def list_runtime_auth_requests(_group_id, _tenant_id, opts) do
      if pid = Application.get_env(:bridge_for_teams_core, :runtime_auth_page_test_pid) do
        send(pid, {:runtime_auth_page, opts})
      end

      pages = Application.get_env(:bridge_for_teams_core, :runtime_auth_page_test_pages, %{})
      {:ok, Map.get(pages, opts[:cursor], %{"requests" => [], "next_cursor" => nil})}
    end

    def get_runtime_auth_request(_group_id, request_id, _tenant_id) do
      pages = Application.get_env(:bridge_for_teams_core, :runtime_auth_page_test_pages, %{})

      request =
        pages
        |> Map.values()
        |> Enum.flat_map(&(&1["requests"] || []))
        |> Enum.find(&(&1["request_id"] == request_id))

      if request, do: {:ok, request}, else: {:error, :not_found}
    end
  end

  defmodule AgentPageQueryProbeSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def get_group(group_id), do: BridgeForTeams.Salix.Erpc.get_group(group_id)

    def list_group_envs(group_id, tenant_id) do
      notify(:list_group_envs)
      BridgeForTeams.Salix.Erpc.list_group_envs(group_id, tenant_id)
    end

    def get_agent_projection(agent_id, tenant_id) do
      BridgeForTeams.Salix.Erpc.get_agent_projection(agent_id, tenant_id)
    end

    defp notify(query) do
      if pid = Application.get_env(:bridge_for_teams_core, :agent_page_query_test_pid) do
        send(pid, {:agent_page_query, query})
      end
    end
  end

  defmodule AgentDetailQueryProbeSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def get_template(template_id, _tenant_id) do
      notify({:get_template, template_id})
      {:ok, %{"template_id" => template_id, "model" => "gpt-direct-read"}}
    end

    defp notify(query) do
      if pid = Application.get_env(:bridge_for_teams_core, :agent_detail_query_test_pid) do
        send(pid, {:agent_detail_query, query})
      end
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

  defmodule SitesSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    # Every provisioned agent reports one website; the websites tab aggregates
    # them across the project's agents.
    def list_agent_sites(agent_id) do
      {:ok, [%{"name" => "marketing", "url" => "https://marketing-#{agent_id}.example.test"}]}
    end
  end

  defmodule SchedulesSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    # Cluster-wide schedules live in application env so deletes can mutate them;
    # the schedules tab scopes them to its project agents or Task receiver payload.
    def list_schedules_for_owners(_agent_ids, _group_id) do
      {:ok, Application.get_env(:bridge_for_teams_core, :test_schedules, [])}
    end

    def delete_schedule(id) do
      remaining =
        :bridge_for_teams_core
        |> Application.get_env(:test_schedules, [])
        |> Enum.reject(&(&1["id"] == id))

      Application.put_env(:bridge_for_teams_core, :test_schedules, remaining)
      :ok
    end

    def update_task_schedule(_group_id, conversation_id, nil) do
      remaining =
        :bridge_for_teams_core
        |> Application.get_env(:test_schedules, [])
        |> Enum.reject(fn schedule ->
          get_in(schedule, ["payload", "conversation_id"]) == conversation_id
        end)

      Application.put_env(:bridge_for_teams_core, :test_schedules, remaining)

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "schedule" => %{"schedule_id" => nil}
       }}
    end
  end

  defmodule UnavailableSchedulesClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:error, :unavailable}
  end

  # Reports no IM connects but surfaces the app-env schedules, so the archive
  # precondition reaches (and trips on) the schedule check.
  defmodule ScheduleBlockingArchiveClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false
    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    defdelegate triage_worker_configuration(group_id, opts), to: BridgeForTeams.Salix.Erpc

    def list_schedules_for_owners(_agent_ids, _group_id) do
      {:ok, Application.get_env(:bridge_for_teams_core, :test_schedules, [])}
    end
  end

  # A Salix client without the optional Signal callbacks.
  defmodule NoSignalSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
    def slack_manifest(_app_name), do: {:error, :unavailable}
  end

  defmodule EmptyModelCatalogClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    def list_templates(_tenant_id), do: []
    def effective_agent_defaults(_tenant_id), do: {:ok, %{"router" => nil, "worker" => nil}}
    def get_template(_template_id, _tenant_id), do: {:error, :not_found}
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

  defp drain_workload_page_messages do
    receive do
      {:workload_page, _tenant_id, _project_id, _group_id, _provider, _opts} ->
        drain_workload_page_messages()
    after
      0 -> :ok
    end
  end

  defp create_provisioned_agent(project_id, attrs) do
    with {:ok, agent} <- Agents.create_agent(project_id, attrs) do
      drain_all()
      Agents.get_agent(agent.id)
    end
  end

  defp ensure_salix_group(_org, _project), do: drain_all()

  defp register_codex_runtime(org, project, env_id, runtime_config) do
    {:ok, _transport_id, _record} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        %{
          "tenant_id" => org.salix_tenant_id,
          "group_id" => project.salix_group_id,
          "device_id" => runtime_config["device_id"],
          "connector_id" => "connector-" <> env_id,
          "name" => "Mac Studio",
          "agent_runtimes" => [
            %{
              "kind" => "external",
              "provider" => "codex",
              "runtime_id" => runtime_config["runtime_id"],
              "device_runtime_id" => runtime_config["device_runtime_id"],
              "command" => "/usr/local/bin/codex",
              "version" => "codex-test",
              "status" => "available",
              "version_detected" => true,
              "ready" => true,
              "auth_ready" => true,
              "native_server_startable" => true,
              "readiness_checked_at" => System.system_time(:millisecond),
              "readiness_valid_until" => System.system_time(:millisecond) + 600_000
            }
            |> Map.merge(Map.take(runtime_config, ~w(model model_provider)))
          ]
        },
        transport_id: env_id
      )

    refresh_device_projection(project.id, runtime_config["device_id"])
    :ok
  end

  defp refresh_device_projection(project_id, device_id, attempts \\ 20)

  defp refresh_device_projection(_project_id, _device_id, 0) do
    flunk("device projection did not converge")
  end

  defp refresh_device_projection(project_id, device_id, attempts) do
    assert {:ok, _result} =
             Environments.reconcile_device_projection(projection_page_limit: 100)

    if Repo.get_by(ProjectDeviceProjection, project_id: project_id, device_id: device_id) do
      :ok
    else
      refresh_device_projection(project_id, device_id, attempts - 1)
    end
  end

  defp insert_runtime_auth_projection(project, attrs \\ %{}) do
    now = DateTime.utc_now()
    device_id = Map.get(attrs, :device_id, "device-runtime-auth")
    device_runtime_id = Map.get(attrs, :device_runtime_id, "runtime-codex")
    auth_status = Map.get(attrs, :auth_status, "unauthenticated")
    runtime_auth_supported = Map.get(attrs, :runtime_auth_supported, true)

    runtime = %{
      "provider" => "codex",
      "runtime_id" => "codex",
      "device_runtime_id" => device_runtime_id,
      "version" => "codex-test",
      "status" => "available",
      "ready" => auth_status == "authenticated",
      "auth" => %{
        "schema_version" => 1,
        "status" => auth_status,
        "mode" => "chatgpt",
        "requires_openai_auth" => true,
        "observed_at" => DateTime.to_unix(now, :millisecond)
      }
    }

    %ProjectDeviceProjection{}
    |> ProjectDeviceProjection.changeset(%{
      project_id: project.id,
      device_id: device_id,
      connector_run_id: "run-#{device_id}",
      connector_id: "connector-#{device_id}",
      name: "Runtime Mac",
      status: "connected",
      source_updated_at: DateTime.to_unix(now, :millisecond),
      observed_generation: 1,
      runtime_inventory: %{
        "items" => [runtime],
        "capabilities" => %{"runtime_auth_v1" => runtime_auth_supported}
      }
    })
    |> Repo.insert!()

    %{device_id: device_id, device_runtime_id: device_runtime_id}
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
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}")
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

      refute has_element?(view, "a[href='#{base}']", "Overview")
      assert has_element?(view, "a[aria-current='page'][href='#{base}/agents']", "Agents")
      refute has_element?(view, "a[aria-current='page'][href='/orgs/#{org.slug}/projects']")

      for path <-
            ~w(agents tasks schedules plugins skills integrations connections devices websites) do
        assert has_element?(view, "a[href='#{base}/#{path}']")
      end

      refute has_element?(view, "section[aria-label='Access']")
      refute has_element?(view, "a[href='#{base}/access']")
    end

    test "marks the active Agent Swarm destination", %{conn: conn, org: org, project: project} do
      path = ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins"
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "a[aria-current='page'][href='#{path}']", "Plugins")
      refute has_element?(view, "#section-tabs")
    end

    test "keeps project identity and lifecycle controls in settings", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, view, html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      assert html =~ "Acme"
      assert html =~ "Agent Swarm"
      assert html =~ "General"
      assert html =~ "Access"
      assert html =~ "Danger zone"
      refute has_element?(view, "#project-settings dt", "Organization runtime id")
      refute has_element?(view, "#project-settings dt", "Agent Swarm runtime id")
      assert has_element?(view, "#project-runtime-ids-trigger-#{project.id}", project.name)
      assert has_element?(view, "#project-runtime-ids-#{project.id}")
      refute has_element?(view, "#agent-swarm-navigation-#{project.id} [aria-controls]")
      assert has_element?(view, "#organization-runtime-id-#{project.id}", org.salix_tenant_id)
      assert has_element?(view, "#agent-swarm-runtime-id-#{project.id}", project.salix_group_id)
      assert has_element?(view, "#copy-organization-runtime-id-#{project.id}")
      assert has_element?(view, "#copy-agent-swarm-runtime-id-#{project.id}")
      refute html =~ "Reconcile outbox"
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/delivery?project_id=#{project.id}")
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/events?project_id=#{project.id}")
    end

    test "redirects when the project does not belong to the org", %{conn: conn, org: org} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/orgs/#{org.slug}/projects/#{bogus}")

      assert to == ~p"/orgs/#{org.slug}/projects"
    end

    test "admin renames the Agent Swarm", %{conn: conn, org: org, project: project} do
      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      view
      |> form("#rename-project-form", rename: %{name: "Renamed Swarm"})
      |> render_submit()

      html = render(view)
      assert html =~ "renamed to"
      assert html =~ "Renamed Swarm"

      assert {:ok, reloaded} = Projects.get_project(project.id)
      assert reloaded.name == "Renamed Swarm"
      # The slug is left untouched so existing URLs keep working.
      assert reloaded.slug == project.slug
    end

    test "rename surfaces a validation error for a blank name", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      html =
        view
        |> form("#rename-project-form", rename: %{name: "   "})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert {:ok, reloaded} = Projects.get_project(project.id)
      assert reloaded.name == "Acme"
    end

    test "archiving is blocked until every IM connection is disabled", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      assert {:ok, connect} =
               ProjectIMConnects.create_project_connect(
                 org.id,
                 project.id,
                 "slack",
                 slack_attrs()
               )

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      view
      |> element("button", "Archive Agent Swarm")
      |> render_click()

      assert render(view) =~ "Disable every IM connection"
      assert {:ok, reloaded} = Projects.get_project(project.id)
      refute reloaded.status == "archived"
      refute reloaded.archived_at

      # Once the connect is disabled, archiving succeeds and returns to the list.
      assert {:ok, _} =
               ProjectIMConnects.disable_project_connect(
                 org.id,
                 project.id,
                 connect["connect_id"]
               )

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("button", "Archive Agent Swarm")
               |> render_click()

      assert to == ~p"/orgs/#{org.slug}/projects"
      assert {:ok, archived} = Projects.get_project(project.id)
      assert archived.status == "archived"
      assert archived.archived_at
    end

    test "admin archives a swarm with no IM connections", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("button", "Archive Agent Swarm")
               |> render_click()

      assert to == ~p"/orgs/#{org.slug}/projects"
      assert {:ok, archived} = Projects.get_project(project.id)
      assert archived.status == "archived"
    end

    test "archiving is blocked while an agent still owns a schedule", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()
      # The default router agent owns a recurring schedule on the Salix side.
      [router] = Agents.list_agents(project.id)

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, ScheduleBlockingArchiveClient)

      Application.put_env(:bridge_for_teams_core, :test_schedules, [
        %{
          "id" => "sched-live",
          "agent_id" => router.salix_agent_id,
          "prompt" => "daily digest",
          "interval_minutes" => 60,
          "created_at" => 1_700_000_000_000,
          "last_run" => nil
        }
      ])

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)
        Application.delete_env(:bridge_for_teams_core, :test_schedules)
      end)

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      view
      |> element("button", "Archive Agent Swarm")
      |> render_click()

      assert render(view) =~ "Delete every schedule"
      assert {:ok, reloaded} = Projects.get_project(project.id)
      refute reloaded.status == "archived"
      refute reloaded.archived_at

      # Once the schedule is gone, archiving succeeds and returns to the list.
      Application.put_env(:bridge_for_teams_core, :test_schedules, [])

      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("button", "Archive Agent Swarm")
               |> render_click()

      assert to == ~p"/orgs/#{org.slug}/projects"
      assert {:ok, archived} = Projects.get_project(project.id)
      assert archived.status == "archived"
    end

    test "project users cannot rename or archive through forged events", %{
      conn: conn,
      org: org,
      project: project
    } do
      user = user_fixture(email: "overview-user@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      refute has_element?(view, "#rename-project-form")
      refute html =~ ~s(/orgs/#{org.slug}/operations)

      assert render_submit(view, "rename_project", %{"rename" => %{"name" => "Forged"}}) =~
               "Only Agent Swarm admins can rename"

      assert render_click(view, "archive_project") =~ "Only Agent Swarm admins can archive"

      assert {:ok, reloaded} = Projects.get_project(project.id)
      assert reloaded.name == "Acme"
      refute reloaded.status == "archived"

      assert [rename_audit] =
               Observability.list_audit_logs(org.id,
                 action: "project.renamed",
                 result: "denied"
               )

      assert [archive_audit] =
               Observability.list_audit_logs(org.id,
                 action: "project.archived",
                 result: "denied"
               )

      for audit <- [rename_audit, archive_audit] do
        assert audit.actor_user_id == user.id
        assert audit.resource_type == "project"
        assert audit.resource_id == project.id
        assert audit.resource_label == project.name
        assert audit.reason_class == "forbidden"
        assert audit.metadata["project_id"] == project.id
      end
    end
  end

  describe "Agents tab" do
    test "mount and navigation read bounded canonical pages from a large group", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, router} = Agents.current_router(project)
      {:ok, base} = SalixAgent.Control.get(router.salix_agent_id)

      for index <- 1..1000 do
        id = SalixStore.Ids.new_agent_id(project.salix_group_id)

        record =
          base
          |> Map.put("agent_id", id)
          |> Map.put("role", "worker")
          |> Map.put("name", "live-worker-#{index}")
          |> Map.put("db_namespace", "salix:" <> id)
          |> Map.put("heartbeat_schedule_id", SalixStore.Ids.new_schedule_id())
          |> Map.delete("router_session_id")

        assert {:ok, _} = SalixStore.S3.put(SalixStore.Keys.ctl_agent(id), Jason.encode!(record))
      end

      previous = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, DeviceProjectionOnlySalixClient)
      on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, previous) end)
      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      assert length(Regex.scan(~r/id="agent-[0-9a-f-]{36}"/, html)) == 500
      assert has_element?(view, "button[phx-click='next_agent_page']")
      SalixStore.S3.Fake.reset_read_log()
      next = render_click(view, "next_agent_page")
      assert length(Regex.scan(~r/id="agent-[0-9a-f-]{36}"/, next)) == 500
      prefix = SalixStore.Keys.ctl_agents_prefix_for_group(project.salix_group_id)

      reads =
        Enum.filter(SalixStore.S3.Fake.read_log(), fn
          {:get, key} -> String.starts_with?(key, prefix)
          {:list, key, _opts} -> key == prefix
          _ -> false
        end)

      assert Enum.count(reads, &match?({:list, _, _}, &1)) == 1
      assert Enum.count(reads, &match?({:get, _}, &1)) <= 500
      last = render_click(view, "next_agent_page")
      assert length(Regex.scan(~r/id="agent-[0-9a-f-]{36}"/, last)) == 1
      refute has_element?(view, "button[phx-click='next_agent_page']")
    end

    test "loads environments only when an agent action needs them", %{
      conn: conn,
      org: org,
      project: project
    } do
      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      prev_pid = Application.get_env(:bridge_for_teams_core, :agent_page_query_test_pid)

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        AgentPageQueryProbeSalixClient
      )

      Application.put_env(:bridge_for_teams_core, :agent_page_query_test_pid, self())

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)
        restore_env(:bridge_for_teams_core, :agent_page_query_test_pid, prev_pid)
      end)

      {:ok, worker} =
        create_provisioned_agent(project.id, %{"name" => "worker", "role" => "worker"})

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      refute_received {:agent_page_query, :list_group_envs}

      render_click(view, "new_agent")
      refute_received {:agent_page_query, :list_group_envs}

      html =
        view
        |> form("#new-agent-form", agent: %{agent_type: "external", name: "external-worker"})
        |> render_change()

      refute_received {:agent_page_query, :list_group_envs}
      assert html =~ "No connected devices are available"

      render_click(view, "close_agent_form")
      render_click(view, "rebind_agent", %{"id" => worker.id})

      refute_received {:agent_page_query, :list_group_envs}
      assert has_element?(view, "#rebind-agent-runtime-form")
    end

    test "renders the default router then lists additional agents", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      html = render(view)
      assert html =~ "Router"
      assert html =~ "router"
      refute html =~ "No agents yet"

      router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "triage", "role" => "worker"})

      drain_all()

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      html = render(view)
      assert html =~ "triage"
      assert html =~ "router"
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/events?)
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/audit?)
      assert html =~ "domain=agent"
      assert html =~ "project_id=#{project.id}"
      assert html =~ "resource_type=agent"
      assert html =~ "resource_id=#{agent.id}"
      assert has_element?(view, "h2", "Agents")
      refute has_element?(view, "#project-header", "active")
      refute has_element?(view, "th", "Agent runtime id")
      refute has_element?(view, "button", "Set as router")
      refute has_element?(view, "#agent-#{router.id} button", "Archive")

      for action <- ["Events", "Audit", "Configure", "Archive"] do
        assert has_element?(view, "#agent-#{agent.id} .whitespace-nowrap", action)
      end

      refute has_element?(view, "#agent-#{agent.id} button", "Rebind")
    end

    test "create agent via modal", %{conn: conn, org: org, project: project, user: admin} do
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      render_click(view, "new_agent")
      assert has_element?(view, "#new-agent-form")
      assert has_element?(view, "#agent_agent_type_internal[type='radio'][checked]")
      assert has_element?(view, "#agent_agent_type_external[type='radio']")
      refute has_element?(view, "select[name='agent[agent_type]']")
      refute has_element?(view, "select[name='agent[role]']")

      render_submit(view, "create_agent", %{
        "agent" => %{"name" => "worker-1", "role" => "router"}
      })

      assert render(view) =~ "Agent creation accepted"
      drain_all()
      html = render_click(view, "retry_agents")
      assert html =~ "worker-1"

      agents = Agents.list_agents(project.id)
      assert Enum.any?(agents, &(&1.salix["name"] == "Router" and &1.role == "router"))

      worker = Enum.find(agents, &(&1.salix["name"] == "worker-1" and &1.role == "worker"))
      assert worker

      assert [audit] = Observability.list_audit_logs(org.id, action: "agent.created")
      assert audit.actor_user_id == admin.id
      assert audit.resource_id == worker.id
      assert audit.metadata["project_id"] == project.id
      assert audit.redacted_diff["role"] == %{"from" => nil, "to" => "worker"}
    end

    test "create external Codex agent via modal", %{conn: conn, org: org, project: project} do
      drain_all()
      env_id = "transport-#{Ecto.UUID.generate()}"
      device_id = "device-" <> env_id
      device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", "runtime-codex")
      readiness_checked_at = System.system_time(:millisecond)

      {:ok, _transport_id, _record} =
        SalixEnv.Registry.connect(
          "nonode@nohost",
          %{
            "tenant_id" => org.salix_tenant_id,
            "group_id" => project.salix_group_id,
            "device_id" => device_id,
            "connector_id" => "connector-" <> env_id,
            "name" => "Mac Studio",
            "agent_runtimes" => [
              %{
                "kind" => "external",
                "provider" => "codex",
                "runtime_id" => "runtime-codex",
                "device_runtime_id" => device_runtime_id,
                "command" => "/usr/local/bin/codex",
                "version" => "codex-test",
                "status" => "available",
                "version_detected" => true,
                "ready" => true,
                "auth_ready" => true,
                "native_server_startable" => true,
                "readiness_checked_at" => readiness_checked_at,
                "readiness_valid_until" => readiness_checked_at + 600_000
              },
              %{"id" => "internal-codex", "kind" => "internal", "provider" => "codex"},
              %{"id" => "other-runtime", "kind" => "external", "provider" => "other"}
            ]
          },
          transport_id: env_id
        )

      refresh_device_projection(project.id, device_id)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      render_click(view, "new_agent")

      html =
        view
        |> form("#new-agent-form", agent: %{agent_type: "external", name: "codex-worker"})
        |> render_change()

      assert html =~ "Mac Studio"

      html =
        view
        |> form("#new-agent-form",
          agent: %{agent_type: "external", name: "codex-worker", device_id: device_id}
        )
        |> render_change()

      assert html =~ "codex-test"
      refute html =~ "internal-codex"
      refute html =~ "other-runtime"

      view
      |> form("#new-agent-form",
        agent: %{
          agent_type: "external",
          name: "codex-worker",
          device_id: device_id,
          device_runtime_id: device_runtime_id
        }
      )
      |> render_submit()

      assert render(view) =~ "Agent creation accepted"

      drain_all()
      render_click(view, "retry_agents")
      agent = Agents.list_agents(project.id) |> Enum.find(&(&1.salix["name"] == "codex-worker"))
      assert agent.role == "worker"
      assert agent.salix["runtime_config"]["device_runtime_id"] == device_runtime_id
    end

    test "Compute Workload picker exposes Claude, replaces bounded pages, drops stale selection, and submits the selected Pi creation input",
         %{
           conn: conn,
           org: org,
           project: project
         } do
      previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      previous_pid = Application.get_env(:bridge_for_teams_core, :workload_picker_test_pid)
      previous_items = Application.get_env(:bridge_for_teams_core, :workload_picker_items)

      previous_page_result =
        Application.get_env(:bridge_for_teams_core, :workload_picker_page_result)

      pi_items =
        for index <- 1..151 do
          %{
            workload_id: "pi-workload-#{index}",
            label: "Pi Workload #{index}",
            provider: "pi",
            node: %{id: "node-1", label: "Mac Studio"},
            selectable: index != 2,
            reason: if(index == 2, do: "runtime_not_ready", else: nil),
            reconcile_error:
              if(index == 2,
                do: %{
                  "code" => "resource_capacity_exhausted",
                  "stage" => "import_admission",
                  "resource" => "storage_headroom",
                  "message" => "Guest storage headroom is unavailable.",
                  "available_bytes" => 1_073_741_824,
                  "required_bytes" => 2_147_483_648
                },
                else: nil
              ),
            updated_at: DateTime.utc_now(),
            selection_fence: %{
              "workload_revision" => index,
              "runtime_connection_epoch" => 7
            }
          }
        end

      items = [
        %{
          workload_id: "claude-workload-1",
          label: "Claude Workload 1",
          provider: "claude",
          node: %{id: "node-1", label: "Mac Studio"},
          selectable: true,
          reason: nil,
          updated_at: DateTime.utc_now(),
          selection_fence: %{
            "workload_revision" => 1,
            "runtime_connection_epoch" => 7
          }
        }
        | pi_items
      ]

      Application.put_env(:bridge_for_teams_core, :salix_client, WorkloadPickerSalixClient)
      Application.put_env(:bridge_for_teams_core, :workload_picker_test_pid, self())
      Application.put_env(:bridge_for_teams_core, :workload_picker_items, items)
      Application.put_env(:bridge_for_teams_core, :workload_picker_page_result, :items)

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, previous_client)
        restore_env(:bridge_for_teams_core, :workload_picker_test_pid, previous_pid)
        restore_env(:bridge_for_teams_core, :workload_picker_items, previous_items)

        restore_env(
          :bridge_for_teams_core,
          :workload_picker_page_result,
          previous_page_result
        )
      end)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      render_click(view, "new_agent")

      view
      |> form("#new-agent-form", agent: %{agent_type: "external", name: "pi-compute"})
      |> render_change()

      view
      |> form("#new-agent-form",
        agent: %{agent_type: "external", name: "pi-compute", runtime_location: "compute"}
      )
      |> render_change()

      html =
        view
        |> form("#new-agent-form",
          agent: %{
            agent_type: "external",
            name: "pi-compute",
            runtime_location: "compute",
            workload_provider: "pi"
          }
        )
        |> render_change()

      assert length(Regex.scan(~r/name="agent\[workload_id\]"/, html)) == 49
      refute html =~ ~s(name="agent[workload_provider]" value="kimi")
      assert html =~ ~s(name="agent[workload_provider]" value="claude")
      refute has_element?(view, "input[name='agent[workload_id]'][checked]")
      refute has_element?(view, "input[value='pi-workload-2']")
      refute has_element?(view, "input[value='pi-workload-51']")
      assert has_element?(view, "input[name='agent[show_unavailable_workloads]']")
      refute has_element?(view, "input[name='agent[show_unavailable_workloads]'][checked]")

      assert_receive {:workload_page, _tenant_id, project_id, _group_id, "pi", page_opts}
      assert project_id == project.id
      assert page_opts[:include_unavailable] == false

      html =
        render_change(view, "validate_agent", %{
          "agent" => %{
            "agent_type" => "external",
            "name" => "claude-compute",
            "runtime_location" => "compute",
            "workload_provider" => "claude"
          }
        })

      assert has_element?(view, "input[value='claude-workload-1']")
      refute html =~ ~s(value="pi-workload-1")

      html =
        view
        |> form("#new-agent-form",
          agent: %{
            agent_type: "external",
            name: "pi-compute",
            runtime_location: "compute",
            workload_provider: "pi",
            show_unavailable_workloads: "true"
          }
        )
        |> render_change()

      assert length(Regex.scan(~r/name="agent\[workload_id\]"/, html)) == 50
      assert has_element?(view, "input[value='pi-workload-2'][disabled]")
      assert has_element?(view, "input[name='agent[show_unavailable_workloads]'][checked]")

      assert html =~
               "code=resource_capacity_exhausted / stage=import_admission / resource=storage_headroom / message=Guest storage headroom is unavailable. / available_bytes=1073741824 / required_bytes=2147483648"

      assert_receive {:workload_page, _tenant_id, ^project_id, _group_id, "pi", page_opts}
      assert page_opts[:include_unavailable] == true

      html =
        render_change(view, "validate_agent", %{
          "agent" => %{
            "agent_type" => "external",
            "name" => "pi-compute",
            "runtime_location" => "compute",
            "workload_provider" => "pi"
          }
        })

      assert length(Regex.scan(~r/name="agent\[workload_id\]"/, html)) == 49
      refute has_element?(view, "input[value='pi-workload-2']")
      refute has_element?(view, "input[name='agent[show_unavailable_workloads]'][checked]")

      html =
        render_change(view, "validate_agent", %{
          "agent" => %{
            "agent_type" => "external",
            "name" => "pi-compute",
            "runtime_location" => "compute",
            "workload_provider" => "codex",
            "workload_query" => "151"
          }
        })

      assert Regex.scan(~r/name="agent\[workload_id\]"/, html) == []

      html =
        view
        |> form("#new-agent-form",
          agent: %{
            agent_type: "external",
            name: "pi-compute",
            runtime_location: "compute",
            workload_provider: "pi",
            workload_query: "151"
          }
        )
        |> render_change()

      assert length(Regex.scan(~r/name="agent\[workload_id\]"/, html)) == 1
      assert has_element?(view, "input[value='pi-workload-151']")
      refute has_element?(view, "button", "Next page")

      html =
        render_change(view, "validate_agent", %{
          "agent" => %{
            "agent_type" => "external",
            "name" => "pi-compute",
            "runtime_location" => "compute",
            "workload_provider" => "pi"
          }
        })

      assert length(Regex.scan(~r/name="agent\[workload_id\]"/, html)) == 49

      Application.put_env(
        :bridge_for_teams_core,
        :workload_picker_page_result,
        {:error, :unavailable}
      )

      html = render_click(view, "refresh_external_workloads")
      assert html =~ "Compute Workloads are unavailable. Refresh and try again."
      assert Regex.scan(~r/name="agent\[workload_id\]"/, html) == []

      Application.put_env(:bridge_for_teams_core, :workload_picker_page_result, :items)
      html = render_click(view, "refresh_external_workloads")
      assert length(Regex.scan(~r/name="agent\[workload_id\]"/, html)) == 49

      view
      |> form("#new-agent-form",
        agent: %{
          agent_type: "external",
          name: "pi-compute",
          runtime_location: "compute",
          workload_provider: "pi",
          workload_id: "pi-workload-1"
        }
      )
      |> render_change()

      assert has_element?(view, "input[value='pi-workload-1'][checked]")

      html = render_click(view, "next_external_workloads")
      assert length(Regex.scan(~r/name="agent\[workload_id\]"/, html)) == 50
      refute has_element?(view, "input[value='pi-workload-1']")
      refute has_element?(view, "input[name='agent[workload_id]'][checked]")
      assert has_element?(view, "input[value='pi-workload-51']")

      html =
        render_submit(view, "create_agent", %{
          "agent" => %{
            "agent_type" => "external",
            "name" => "pi-compute",
            "runtime_location" => "compute",
            "workload_provider" => "pi",
            "workload_id" => "pi-workload-1"
          }
        })

      assert html =~ "Select a Compute Workload."
      refute Enum.any?(Agents.list_agents(project.id), &(&1.salix["name"] == "pi-compute"))

      html = render_click(view, "next_external_workloads")
      assert length(Regex.scan(~r/name="agent\[workload_id\]"/, html)) == 50
      refute has_element?(view, "input[value='pi-workload-51']")
      assert has_element?(view, "input[value='pi-workload-101']")

      html = render_click(view, "next_external_workloads")
      assert length(Regex.scan(~r/name="agent\[workload_id\]"/, html)) == 1
      refute has_element?(view, "input[value='pi-workload-101']")
      assert has_element?(view, "input[value='pi-workload-151']")
      refute has_element?(view, "button", "Next page")

      view
      |> form("#new-agent-form",
        agent: %{
          agent_type: "external",
          name: "pi-compute",
          runtime_location: "compute",
          workload_provider: "pi",
          workload_id: "pi-workload-151"
        }
      )
      |> render_submit()

      assert render(view) =~ "Agent creation accepted"

      row =
        Repo.one!(
          from(r in ReconcileOutbox,
            where:
              r.op == "create_owned_agent" and
                fragment("?->'attrs'->>'name' = ?", r.payload, "pi-compute"),
            limit: 1
          )
        )

      {:ok, agent} = Agents.get_agent(row.aggregate_id)
      assert BridgeForTeams.Schema.Agent.lifecycle(agent) == "provisioning"
      refute Repo.get!(Agent, agent.id).salix["runtime_config"]
      assert agent.salix["runtime_config"]["kind"] == "compute_workload"
      assert agent.salix["runtime_config"]["runtime_spec"] == %{"provider" => "pi"}

      assert agent.salix["runtime_config"]["owner_scope"] == %{
               "type" => "project",
               "id" => project.id
             }

      assert agent.salix["runtime_config"]["binding_revision"] == 1

      tenant_id = org.salix_tenant_id
      group_id = project.salix_group_id

      assert_received {:workload_validate, ^tenant_id, ^project_id, ^group_id, "codex",
                       "pi-workload-151", _fence}

      assert_received {:workload_validate, ^tenant_id, ^project_id, ^group_id, "pi",
                       "pi-workload-151", _fence}

      drain_workload_page_messages()
      html = render_click(view, "rebind_agent", %{"id" => agent.id})
      refute html =~ ~s(value="pi-workload-2")

      assert_receive {:workload_page, _tenant_id, ^project_id, _group_id, "pi", page_opts}
      assert page_opts[:include_unavailable] == false

      html =
        view
        |> form("#rebind-agent-runtime-form",
          agent: %{
            runtime_location: "compute",
            workload_provider: "pi",
            show_unavailable_workloads: "true",
            expected_binding_revision: "1"
          }
        )
        |> render_change()

      assert html =~ ~s(value="pi-workload-2")
      assert has_element?(view, "input[value='pi-workload-2'][disabled]")

      assert_receive {:workload_page, _tenant_id, ^project_id, _group_id, "pi", page_opts}
      assert page_opts[:include_unavailable] == true
    end

    test "rebind external Codex agent via modal", %{conn: conn, org: org, project: project} do
      drain_all()
      initial_env_id = "transport-#{Ecto.UUID.generate()}"
      initial_device_id = "device-" <> initial_env_id
      initial_runtime_id = "runtime-codex-initial"

      initial_device_runtime_id =
        RuntimeIds.device_runtime_id(initial_device_id, "codex", initial_runtime_id)

      next_env_id = "transport-#{Ecto.UUID.generate()}"
      next_device_id = "device-" <> next_env_id
      next_runtime_id = "runtime-codex-next"

      next_device_runtime_id =
        RuntimeIds.device_runtime_id(next_device_id, "codex", next_runtime_id)

      initial_runtime_config = %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => initial_device_id,
        "runtime_id" => initial_runtime_id,
        "device_runtime_id" => initial_device_runtime_id
      }

      next_runtime_config = %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => next_device_id,
        "runtime_id" => next_runtime_id,
        "device_runtime_id" => next_device_runtime_id,
        "model" => "claude-sonnet-4",
        "model_provider" => "anthropic"
      }

      register_codex_runtime(org, project, initial_env_id, initial_runtime_config)
      register_codex_runtime(org, project, next_env_id, next_runtime_config)

      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "codex-worker",
          "role" => "worker",
          "runtime_config" => initial_runtime_config
        })

      :ok = ensure_salix_group(org, project)

      {:ok, _salix_agent} =
        SalixAgent.Control.create_preallocated(
          %{
            "group_id" => project.salix_group_id,
            "role" => "worker",
            "name" => agent.salix["name"],
            "runtime_config" => initial_runtime_config
          },
          org.salix_tenant_id,
          agent.salix_agent_id
        )

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      assert has_element?(
               view,
               ~s(button[phx-click="rebind_agent"][phx-value-id="#{agent.id}"])
             )

      render_click(view, "rebind_agent", %{"id" => agent.id})
      assert has_element?(view, "#rebind-agent-runtime-form")
      modal_html = render(view)
      assert modal_html =~ "Target for new sessions"
      refute modal_html =~ "Desired location"
      assert modal_html =~ "Active tasks keep their current runtime"

      assert has_element?(
               view,
               ~s(#rebind_agent_device_id option[value="#{initial_device_id}"][selected])
             )

      assert has_element?(
               view,
               ~s(#rebind_agent_device_runtime_id option[value="#{initial_device_runtime_id}"][selected])
             )

      html =
        view
        |> form("#rebind-agent-runtime-form", agent: %{device_id: next_device_id})
        |> render_change()

      assert html =~ next_device_runtime_id

      html =
        view
        |> form("#rebind-agent-runtime-form",
          agent: %{device_id: next_device_id, device_runtime_id: next_device_runtime_id}
        )
        |> render_change()

      assert html =~ ~s(data-testid="rebind-codex-runtime-readiness")
      assert html =~ "codex-test"

      view
      |> form("#rebind-agent-runtime-form",
        agent: %{device_id: next_device_id, device_runtime_id: next_device_runtime_id}
      )
      |> render_submit()

      assert render(view) =~ "Agent runtime rebound."

      expected_binding = %{
        "kind" => "connected_runtime",
        "provider" => "codex",
        "device_id" => next_device_id,
        "runtime_id" => next_runtime_id,
        "device_runtime_id" => next_device_runtime_id,
        "owner_scope" => %{"type" => "group", "id" => project.salix_group_id},
        "binding_revision" => 1
      }

      refute Repo.get!(Agent, agent.id).salix["runtime_config"]
      assert {:ok, record} = SalixAgent.Control.get(agent.salix_agent_id)
      assert record["runtime_config"] == expected_binding
    end

    test "rebind modal remains available when agent runtime projection times out", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()
      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev_client) end)

      env_id = "transport-#{Ecto.UUID.generate()}"
      device_id = "device-" <> env_id
      runtime_id = "runtime-codex-ready"
      device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)

      runtime_config = %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => device_id,
        "runtime_id" => runtime_id,
        "device_runtime_id" => device_runtime_id,
        "model" => "claude-sonnet-4",
        "model_provider" => "anthropic"
      }

      register_codex_runtime(org, project, env_id, runtime_config)

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        AgentProjectionTimeoutSalixClient
      )

      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "projection-timeout-worker",
          "role" => "worker",
          "runtime_config" => runtime_config
        })

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      assert has_element?(
               view,
               ~s(button[phx-click="rebind_agent"][phx-value-id="#{agent.id}"])
             )

      render_click(view, "rebind_agent", %{"id" => agent.id})
      assert has_element?(view, "#rebind-agent-runtime-form")

      html =
        view
        |> form("#rebind-agent-runtime-form", agent: %{device_id: device_id})
        |> render_change()

      assert html =~ device_runtime_id

      view
      |> form("#rebind-agent-runtime-form",
        agent: %{device_id: device_id, device_runtime_id: device_runtime_id}
      )
      |> render_submit()

      assert render(view) =~ "Agent runtime rebound."

      assert {:ok, record} = SalixAgent.Control.get(agent.salix_agent_id)
      refute Repo.get!(Agent, agent.id).salix["runtime_config"]

      assert record["runtime_config"] == %{
               "kind" => "connected_runtime",
               "provider" => "codex",
               "device_id" => device_id,
               "runtime_id" => runtime_id,
               "device_runtime_id" => device_runtime_id,
               "owner_scope" => %{"type" => "group", "id" => project.salix_group_id},
               "binding_revision" => 1
             }
    end

    test "external agent modal shows Codex runtime readiness diagnostics", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()
      env_id = "transport-#{Ecto.UUID.generate()}"
      device_id = "device-" <> env_id
      device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", "runtime-codex")
      readiness_checked_at = System.system_time(:millisecond)

      expected_checked_at =
        readiness_checked_at
        |> DateTime.from_unix!(:millisecond)
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

      {:ok, _transport_id, _record} =
        SalixEnv.Registry.connect(
          "nonode@nohost",
          %{
            "tenant_id" => org.salix_tenant_id,
            "group_id" => project.salix_group_id,
            "device_id" => device_id,
            "connector_id" => "connector-" <> env_id,
            "name" => "Mac Studio",
            "agent_runtimes" => [
              %{
                "kind" => "external",
                "provider" => "codex",
                "runtime_id" => "runtime-codex",
                "device_runtime_id" => device_runtime_id,
                "command" => "/usr/local/bin/codex",
                "version" => "codex-cli 1.2.3",
                "version_detected" => true,
                "status" => "available",
                "ready" => true,
                "app_server_startable" => true,
                "native_server_startable" => true,
                "auth_ready" => true,
                "readiness_checked_at" => readiness_checked_at,
                "readiness_valid_until" => readiness_checked_at + 600_000
              }
            ]
          },
          transport_id: env_id
        )

      refresh_device_projection(project.id, device_id)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      render_click(view, "new_agent")

      view
      |> form("#new-agent-form", agent: %{agent_type: "external", name: "codex-worker"})
      |> render_change()

      view
      |> form("#new-agent-form",
        agent: %{agent_type: "external", name: "codex-worker", device_id: device_id}
      )
      |> render_change()

      html =
        view
        |> form("#new-agent-form",
          agent: %{
            agent_type: "external",
            name: "codex-worker",
            device_id: device_id,
            device_runtime_id: device_runtime_id
          }
        )
        |> render_change()

      assert html =~ ~s(data-testid="codex-runtime-readiness")
      assert html =~ "ready"
      assert html =~ "codex-cli 1.2.3"
      refute html =~ "/usr/local/bin/codex"
      assert html =~ expected_checked_at
    end

    test "external agent modal warns when the selected Codex runtime is not ready", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()
      env_id = "transport-#{Ecto.UUID.generate()}"
      device_id = "device-" <> env_id
      device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", "runtime-codex")

      {:ok, _transport_id, _record} =
        SalixEnv.Registry.connect(
          "nonode@nohost",
          %{
            "tenant_id" => org.salix_tenant_id,
            "group_id" => project.salix_group_id,
            "device_id" => device_id,
            "connector_id" => "connector-" <> env_id,
            "name" => "Mac Studio",
            "agent_runtimes" => [
              %{
                "kind" => "external",
                "provider" => "codex",
                "runtime_id" => "runtime-codex",
                "device_runtime_id" => device_runtime_id,
                "command" => "/usr/local/bin/codex",
                "version" => "unknown",
                "version_detected" => false,
                "status" => "unavailable",
                "ready" => false,
                "app_server_startable" => false,
                "auth_ready" => false,
                "last_error" => "Codex CLI is not authenticated"
              }
            ]
          },
          transport_id: env_id
        )

      refresh_device_projection(project.id, device_id)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      render_click(view, "new_agent")

      view
      |> form("#new-agent-form", agent: %{agent_type: "external", name: "codex-worker"})
      |> render_change()

      view
      |> form("#new-agent-form",
        agent: %{agent_type: "external", name: "codex-worker", device_id: device_id}
      )
      |> render_change()

      html =
        view
        |> form("#new-agent-form",
          agent: %{
            agent_type: "external",
            name: "codex-worker",
            device_id: device_id,
            device_runtime_id: device_runtime_id
          }
        )
        |> render_change()

      assert html =~ "unavailable"
      assert html =~ "readiness_incomplete"
      assert html =~ "This runtime is not ready"
      refute html =~ "Codex CLI is not authenticated"
    end

    test "external agent modal explains when no connected devices exist", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      render_click(view, "new_agent")

      html =
        view
        |> form("#new-agent-form", agent: %{agent_type: "external", name: "codex-worker"})
        |> render_change()

      assert html =~ "No connected devices are available"
      assert has_element?(view, "#agent_device_id")
    end

    test "changing to a private subscription template preserves an unset system prompt", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, tmpl} =
        SalixAgent.SubscriptionTemplates.save(org.salix_tenant_id, nil, %{
          "name" => "Codex",
          "model" => "gpt-5.6-sol",
          "subscription_provider" => "codex"
        })

      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "Router", "role" => "router"})

      assert agent.salix["system_prompt"] in [nil, ""]
      {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      view |> element("button[phx-value-id='#{agent.id}']", "Configure") |> render_click()

      view
      |> form("#configure-agent-form",
        agent: %{template_id: tmpl["template_id"], system_prompt: ""}
      )
      |> render_submit()

      refute has_element?(view, "#configure-agent-form")
      {:ok, saved} = Agents.get_agent(agent.id)
      assert saved.salix["template_id"] == tmpl["template_id"]
      assert saved.salix["system_prompt"] == agent.salix["system_prompt"]
    end

    test "clearing an existing prompt shows an inline error and preserves configuration", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, tmpl} = SalixAgent.Templates.create(%{"name" => "Other model", "model" => "gpt-5"})

      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "Configured",
          "role" => "worker",
          "system_prompt" => "Keep these instructions."
        })

      {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      view |> element("button[phx-value-id='#{agent.id}']", "Configure") |> render_click()

      view
      |> form("#configure-agent-form",
        agent: %{template_id: tmpl["template_id"], system_prompt: ""}
      )
      |> render_submit()

      assert has_element?(
               view,
               "#configure-agent-form",
               "An existing system prompt cannot be cleared."
             )

      {:ok, saved} = Agents.get_agent(agent.id)
      assert saved.salix["system_prompt"] == "Keep these instructions."
      assert saved.salix["template_id"] == agent.salix["template_id"]
    end

    test "configure preserves a legacy default choice and can switch to platform Default", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "Legacy default",
          "role" => "worker",
          "template_id" => "default"
        })

      {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      view |> element("button[phx-value-id='#{agent.id}']", "Configure") |> render_click()

      assert has_element?(
               view,
               "#agent_template_id option[value=default][selected]",
               "current choice"
             )

      view |> form("#configure-agent-form", agent: %{template_id: ""}) |> render_submit()
      {:ok, updated} = Agents.get_agent(agent.id)
      refute updated.salix["template_id"]
    end

    test "configure agent submits a catalog model to Salix", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      {:ok, tmpl} =
        SalixAgent.Templates.create(%{"name" => "Opus", "model" => "claude-opus-4-8"})

      {:ok, agent} = create_provisioned_agent(project.id, %{"name" => "cfg", "role" => "worker"})

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      view |> element("button[phx-value-id='#{agent.id}']", "Configure") |> render_click()
      assert has_element?(view, "#configure-agent-form")
      # Dropdown-only: the catalog model is offered as a <select> option.
      assert has_element?(view, "#agent_template_id option[value='#{tmpl["template_id"]}']")

      view
      |> form("#configure-agent-form",
        agent: %{template_id: tmpl["template_id"], system_prompt: "Be helpful."}
      )
      |> render_submit()

      assert render(view) =~ "configuration saved"

      {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.role == "worker"
      assert reloaded.salix["template_id"] == tmpl["template_id"]
      assert reloaded.salix["system_prompt"] == "Be helpful."

      view |> element("button[phx-value-id='#{agent.id}']", "Configure") |> render_click()
      assert has_element?(view, "#agent_system_prompt", "Be helpful.")

      refute Repo.exists?(
               from(o in ReconcileOutbox,
                 where:
                   o.aggregate == "agent" and o.aggregate_id == ^reloaded.id and
                     o.op == "update_agent"
               )
             )

      assert [audit] = Observability.list_audit_logs(org.id, action: "agent.config_updated")
      assert audit.actor_user_id == admin.id
      assert audit.resource_id == agent.id
      refute Map.has_key?(audit.redacted_diff, "role")
      refute Repo.get!(Agent, agent.id).salix["system_prompt"]

      assert audit.redacted_diff["instructions_configured"] == %{
               "from" => "false",
               "to" => "true"
             }

      refute inspect(audit) =~ "Be helpful."
    end

    test "configure agent displays the backend model even when excluded by the org allowlist", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, current} =
        SalixAgent.Templates.create(%{"name" => "Current router", "model" => "deepseek-flash"})

      {:ok, allowed} =
        SalixAgent.Templates.create(%{"name" => "Allowed alternative", "model" => "gpt-5"})

      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "Router",
          "role" => "router",
          "template_id" => current["template_id"]
        })

      {:ok, org} =
        BridgeForTeams.Orgs.update_org(org, %{
          "allowed_template_ids" => [allowed["template_id"]]
        })

      {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      view |> element("button[phx-value-id='#{agent.id}']", "Configure") |> render_click()

      assert has_element?(
               view,
               "#agent_template_id option[value='#{current["template_id"]}'][selected][disabled]",
               "deepseek-flash (current; unavailable for selection)"
             )

      refute has_element?(
               view,
               "#agent_template_id option[value='#{allowed["template_id"]}'][selected]"
             )

      # Submitting without an explicit allowed selection must not change the model.
      view |> form("#configure-agent-form") |> render_submit()
      assert render(view) =~ "Choose a model from the list before saving."
      {:ok, unchanged} = Agents.get_agent(agent.id)
      assert unchanged.salix["template_id"] == current["template_id"]

      view
      |> form("#configure-agent-form", agent: %{template_id: allowed["template_id"]})
      |> render_submit()

      {:ok, changed} = Agents.get_agent(agent.id)
      assert changed.salix["template_id"] == allowed["template_id"]

      view |> element("button[phx-value-id='#{agent.id}']", "Configure") |> render_click()

      assert has_element?(
               view,
               "#agent_template_id option[value='#{allowed["template_id"]}'][selected]:not([disabled])"
             )

      # Following the role default remains an explicit selectable option,
      # separate from the disabled placeholder for an unavailable current pin.
      view
      |> form("#configure-agent-form", agent: %{template_id: ""})
      |> render_submit()

      {:ok, following} = Agents.get_agent(agent.id)
      refute following.salix["template_id"]

      view |> element("button[phx-value-id='#{agent.id}']", "Configure") |> render_click()

      assert has_element?(
               view,
               "#agent_template_id option[value='']:not([disabled])",
               "Default ("
             )

      refute has_element?(
               view,
               "#agent_template_id option[value='#{allowed["template_id"]}'][selected]"
             )
    end

    test "configure agent shows a hint when no models are available", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, pinned} =
        SalixAgent.Templates.create(%{"name" => "Pinned model", "model" => "mock"})

      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "cfg2",
          "role" => "worker",
          "template_id" => pinned["template_id"]
        })

      previous = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, EmptyModelCatalogClient)
      on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, previous) end)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      view |> element("button[phx-value-id='#{agent.id}']", "Configure") |> render_click()

      # Preserve the current value even when no replacement can be assigned.
      assert has_element?(
               view,
               "#agent_template_id[disabled] option[selected][disabled]",
               agent.salix["template_id"]
             )

      assert render(view) =~ "No models are available"
    end

    test "archive agent removes it from the list", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      {:ok, agent} = create_provisioned_agent(project.id, %{"name" => "gone", "role" => "worker"})

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      assert has_element?(
               view,
               "button[phx-value-id='#{agent.id}']:not([data-confirm])",
               "Archive"
             )

      view
      |> element("button[phx-value-id='#{agent.id}']", "Archive")
      |> render_click()

      assert has_element?(view, "#archive-agent-modal", "Archive gone?")

      view
      |> element("#archive-agent-modal button[phx-value-id='#{agent.id}']", "Archive")
      |> render_click()

      assert render(view) =~ "Agent archived"
      agents = Agents.list_agents(project.id)
      refute Enum.any?(agents, &(&1.id == agent.id))
      assert Enum.any?(agents, &(&1.salix["name"] == "Router" and &1.role == "router"))

      assert [audit] = Observability.list_audit_logs(org.id, action: "agent.archived")
      assert audit.actor_user_id == admin.id
      assert audit.resource_id == agent.id

      assert audit.redacted_diff["status"] == %{
               "from" => BridgeForTeams.Schema.Agent.lifecycle(agent),
               "to" => "archived"
             }
    end

    @tag :triage_archive
    test "archiving a Triage Worker requires an impact confirmation and stops new assignments", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, worker} =
        create_provisioned_agent(project.id, %{"name" => "Investigator", "role" => "worker"})

      router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

      assert {:ok, binding} =
               SalixAgent.TriageWorker.configure(
                 project.salix_group_id,
                 router.salix_agent_id,
                 worker.salix_agent_id,
                 0,
                 %{"actor_user_id" => "admin", "request_id" => "select"}
               )

      {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      assert has_element?(view, "#agent-#{worker.id}", "Used by Triage")
      # A forged submit cannot skip the server-owned confirmation snapshot.
      assert render_click(view, "archive_agent", %{"id" => worker.id}) =~ "Open Archive again"
      assert Enum.any?(Agents.list_agents(project.id), &(&1.id == worker.id))
      view |> element("#agent-#{worker.id} button", "Archive") |> render_click()
      assert has_element?(view, "#archive-triage-warning", project.name)

      assert has_element?(
               view,
               "#archive-triage-warning a[href='/orgs/#{org.slug}/triage?agent=#{router.id}#triage-worker-configuration']",
               "Choose another Worker in Triage"
             )

      view |> element("#archive-agent-modal button", "Archive and pause Triage") |> render_click()
      refute Enum.any?(Agents.list_agents(project.id), &(&1.id == worker.id))

      assert {:error, :triage_worker_unavailable} =
               SalixAgent.TriageWorker.ensure(project.salix_group_id, router.salix_agent_id)

      assert {:ok, ^binding} = SalixAgent.TriageWorker.get(project.salix_group_id)
    end

    @tag :triage_archive
    test "a changed Triage selection must be reviewed before archive", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, worker} =
        create_provisioned_agent(project.id, %{"name" => "Investigator", "role" => "worker"})

      router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))
      {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      view |> element("#agent-#{worker.id} button", "Archive") |> render_click()
      refute has_element?(view, "#archive-triage-warning")

      assert {:ok, _} =
               SalixAgent.TriageWorker.configure(
                 project.salix_group_id,
                 router.salix_agent_id,
                 worker.salix_agent_id,
                 0,
                 %{"actor_user_id" => "other-admin", "request_id" => "late-select"}
               )

      view |> element("#archive-agent-modal button", "Archive") |> render_click()
      assert Enum.any?(Agents.list_agents(project.id), &(&1.id == worker.id))
      assert render(view) =~ "Open Archive again"
      # Choosing another Worker releases the original without pausing Triage.
      {:ok, replacement} =
        create_provisioned_agent(project.id, %{"name" => "Replacement", "role" => "worker"})

      assert {:ok, _} =
               SalixAgent.TriageWorker.configure(
                 project.salix_group_id,
                 router.salix_agent_id,
                 replacement.salix_agent_id,
                 1,
                 %{"actor_user_id" => "admin", "request_id" => "replace"}
               )

      view |> element("#agent-#{worker.id} button", "Archive") |> render_click()
      refute has_element?(view, "#archive-triage-warning")
      view |> element("#archive-agent-modal button", "Archive") |> render_click()

      assert {:ok, selected} =
               SalixAgent.TriageWorker.ensure(project.salix_group_id, router.salix_agent_id)

      assert selected == replacement.salix_agent_id
    end

    test "router agents cannot be archived through forged events", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")
      refute has_element?(view, "#agent-#{router.id} button", "Archive")

      assert render_click(view, "archive_agent", %{"id" => router.id}) =~
               "Router agents cannot be archived"

      assert Enum.any?(Agents.list_agents(project.id), &(&1.id == router.id))

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "agent.archived",
                 result: "failed"
               )

      assert audit.actor_user_id == admin.id
      assert audit.resource_id == router.id
      assert audit.reason_class == "router_agent"
    end

    test "clicking an agent row navigates to the agent detail page", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "detail", "role" => "worker"})

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#agent-#{agent.id}")
               |> render_click()

      assert to == ~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}"
    end

    test "project users cannot manage agents through forged events", %{
      conn: conn,
      org: org,
      project: project
    } do
      user = user_fixture(email: "agent-user@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/agents")

      assert html =~ "Router"
      refute html =~ ~s(/orgs/#{org.slug}/operations)
      refute html =~ ~s(/orgs/#{org.slug}/operations/audit)
      refute html =~ "New agent"
      refute has_element?(view, "button", "Configure")
      refute html =~ "Archive"

      assert render_click(view, "new_agent") =~ "Only Agent Swarm admins can manage agents"

      assert render_submit(view, "create_agent", %{
               "agent" => %{"name" => "forged-worker", "role" => "worker"}
             }) =~ "Only Agent Swarm admins can manage agents"

      refute Enum.any?(Agents.list_agents(project.id), &(&1.salix["name"] == "forged-worker"))

      assert [audit] = Observability.list_audit_logs(org.id, action: "agent.created")
      assert audit.actor_user_id == user.id
      assert audit.result == "denied"
      assert audit.reason_class == "forbidden"
      assert audit.resource_type == "agent"
      assert is_nil(audit.resource_id)
      assert audit.metadata["project_id"] == project.id
    end
  end

  describe "Access tab" do
    test "admin grants, changes, and removes Agent Swarm access", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      {:ok, view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      html = render(view)
      assert html =~ "Access"
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/audit?resource_type=project_member")
      refute has_element?(view, "#grant-access-form")

      view
      |> element("button", "Add user")
      |> render_click()

      assert has_element?(view, "#grant-access-modal")

      view
      |> form("#grant-access-form", access: %{email: "member@example.com", role: "user"})
      |> render_submit()

      {:ok, member} = Accounts.get_user_by_email("member@example.com")
      assert {:ok, "user"} = Memberships.project_role(project.id, member.id)
      assert render(view) =~ "member@example.com"
      refute has_element?(view, "#grant-access-modal")

      assert [grant] =
               Observability.list_audit_logs(org.id, action: "project_member.granted")

      assert grant.actor_user_id == admin.id
      assert grant.resource_id == member.id
      assert is_binary(grant.request_id)
      assert grant.request_id != ""
      assert grant.metadata["project_id"] == project.id
      assert grant.redacted_diff["role"] == %{"from" => nil, "to" => "user"}

      view
      |> element("#project-access-#{member.id} form")
      |> render_change(%{"user-id" => member.id, "role" => "admin"})

      assert {:ok, "admin"} = Memberships.project_role(project.id, member.id)

      assert [role_change] =
               Observability.list_audit_logs(org.id, action: "project_member.role_changed")

      assert role_change.actor_user_id == admin.id
      assert role_change.resource_id == member.id
      assert is_binary(role_change.request_id)
      assert role_change.request_id != ""
      assert role_change.redacted_diff["role"] == %{"from" => "user", "to" => "admin"}

      view
      |> element("button[phx-value-user-id='#{member.id}']", "Remove")
      |> render_click()

      assert {:error, :not_found} = Memberships.project_role(project.id, member.id)

      assert [removal] =
               Observability.list_audit_logs(org.id, action: "project_member.removed")

      assert removal.actor_user_id == admin.id
      assert removal.resource_id == member.id
      assert is_binary(removal.request_id)
      assert removal.request_id != ""
      assert removal.redacted_diff["role"] == %{"from" => "admin", "to" => nil}
    end

    test "project users cannot manage access through forged events", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      user = user_fixture(email: "access-user@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      refute html =~ "grant-access-form"
      refute html =~ ~s(/orgs/#{org.slug}/operations)

      assert render_submit(view, "grant_access", %{
               "access" => %{"email" => "forged-access@example.com", "role" => "admin"}
             }) =~ "Only Agent Swarm admins can manage access"

      assert render_change(view, "change_access_role", %{
               "user-id" => admin.id,
               "role" => "admin"
             }) =~ "Only Agent Swarm admins can manage access"

      assert render_click(view, "remove_access", %{"user-id" => admin.id}) =~
               "Only Agent Swarm admins can manage access"

      assert {:error, :not_found} = Accounts.get_user_by_email("forged-access@example.com")

      assert [grant] =
               Observability.list_audit_logs(org.id,
                 action: "project_member.granted",
                 result: "denied"
               )

      assert is_nil(grant.resource_id)
      assert grant.actor_user_id == user.id
      assert grant.reason_class == "forbidden"
      assert grant.metadata["project_id"] == project.id
      assert grant.metadata["attempted_email_configured"] == "true"
      assert grant.metadata["attempted_role"] == "admin"
      refute inspect(grant.metadata) =~ "forged-access"

      assert [role_change] =
               Observability.list_audit_logs(org.id,
                 action: "project_member.role_changed",
                 result: "denied"
               )

      assert role_change.resource_id == admin.id
      assert role_change.metadata["attempted_role"] == "admin"
      assert role_change.metadata["surface"] == "project_access"

      assert [removal] =
               Observability.list_audit_logs(org.id,
                 action: "project_member.removed",
                 result: "denied"
               )

      assert removal.resource_id == admin.id
      assert removal.metadata["surface"] == "project_access"
    end

    test "ordinary org member without ACL cannot open the Agent Swarm", %{
      conn: conn,
      org: org,
      project: project
    } do
      user = user_fixture(email: "plain@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}")

      assert to == ~p"/orgs/#{org.slug}/projects"
    end

    test "admin mints a data-import token the import endpoint accepts", %{
      conn: conn,
      org: org,
      project: project,
      user: admin
    } do
      {:ok, view, html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      # The affordance is visible to a project admin.
      assert html =~ "Data import"

      render_click(view, "mint_import_token")
      shown = render(view)

      # The token is shown once, with a copy-ready curl example.
      assert shown =~ "Data-import token"
      assert shown =~ "curl -sS -X POST"
      token = extract_import_token(shown)
      assert String.starts_with?(token, "bfti_")

      # A mint audit was recorded.
      assert [audit] =
               Observability.list_audit_logs(org.id, action: "dashboard_import_token.created")

      assert audit.actor_user_id == admin.id

      # The import endpoint accepts the freshly minted token (no CLI session).
      body =
        Jason.encode!(%{
          "format" => "bft.myspace.import",
          "version" => 1,
          "items" => [%{"external_id" => "ui-1", "category" => "general", "title" => "Card"}]
        })

      resp =
        :post
        |> build_conn("/v1/orgs/#{org.slug}/projects/#{project.slug}/dashboard/import", body)
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> BridgeForTeamsWeb.DashboardEndpoint.call([])

      assert resp.status == 200
      assert %{"ok" => true, "data" => %{"created" => 1}} = Jason.decode!(resp.resp_body)
    end

    test "plain project user does not see the Data import affordance", %{
      conn: conn,
      org: org,
      project: project
    } do
      user = user_fixture(email: "import-plain@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/settings")

      refute html =~ "Data import"

      # Even a forged mint event is denied for a non-admin.
      assert render_click(view, "mint_import_token") =~
               "Only Agent Swarm admins can mint a data-import token"
    end
  end

  defp extract_import_token(html) do
    [_, token] = Regex.run(~r/(bfti_[A-Za-z0-9_-]+)/, html)
    token
  end

  describe "Tasks tab" do
    test "renders project tasks from Salix without exposing Salix identifiers", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      assert {:ok, incident} =
               SalixIM.ConversationServer.create_group_conversation(
                 project.salix_group_id,
                 %{
                   "title" => "Incident triage",
                   "kind" => "user_chat",
                   "status" => "active",
                   "participants" => [],
                   "updated_at" => 1_700_000_000
                 }
               )

      assert {:ok, untitled} =
               SalixIM.ConversationServer.create_group_conversation(
                 project.salix_group_id,
                 %{
                   "title" => "",
                   "kind" => "user_chat",
                   "status" => "active",
                   "participants" => [],
                   "updated_at" => 1_700_000_001
                 }
               )

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks")

      assert html =~ "Incident triage"
      assert html =~ "Untitled task"

      refute has_element?(
               view,
               "#conversation-#{incident["conversation_id"]} .font-mono",
               incident["conversation_id"]
             )

      refute has_element?(
               view,
               "#conversation-#{untitled["conversation_id"]} .font-mono",
               untitled["conversation_id"]
             )

      assert html =~ "User chat"
      assert html =~ "2023-11-14 22:13:20 UTC"
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/events?)
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/audit?)
      assert html =~ "domain=conversation"
      assert html =~ "project_id=#{project.id}"
      assert html =~ "resource_type=project_conversation"
      assert html =~ "resource_id=#{incident["conversation_id"]}"
    end

    test "renders empty state when Salix has no conversations", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, _agent} =
        create_provisioned_agent(project.id, %{"name" => "helper", "role" => "worker"})

      drain_all()

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks")

      assert html =~ "No tasks yet"
    end

    test "creates a conversation for a selected agent", %{
      conn: conn,
      org: org,
      project: project,
      user: user
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "helper", "role" => "worker"})

      drain_all()

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks")

      render_click(view, "new_conversation")
      assert has_element?(view, "#new-conversation-form")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#new-conversation-form",
                 conversation: %{title: "Launch support", agent_id: agent.id}
               )
               |> render_submit()

      assert to =~ ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks"

      assert {:ok, %{"data" => conversations}} =
               SalixIM.Conversations.list_group_conversations(project.salix_group_id, limit: 100)

      conversation = Enum.find(conversations, &(&1["title"] == "Launch support"))
      assert conversation

      assert {:ok, conversation} =
               SalixIM.Conversations.get_group_conversation(
                 project.salix_group_id,
                 conversation["conversation_id"]
               )

      assert conversation["title"] == "Launch support"

      assert {:ok, %{"participants" => participants}} =
               SalixIM.Conversations.list_group_conversation_participants(
                 project.salix_group_id,
                 conversation["conversation_id"]
               )

      refute Enum.any?(participants, &(&1["actor_type"] == "user"))
      agent_participant = Enum.find(participants, &(&1["actor_type"] == "agent"))
      assert agent_participant["actor_type"] == "agent"
      assert agent_participant["agent_id"] == agent.salix_agent_id
      refute Map.has_key?(agent_participant, "session_id")

      [event] = Observability.list_events(org.id, domain: "conversation")
      assert event.event_type == "conversation.created"
      assert event.status == "ok"
      assert event.project_id == project.id
      assert event.actor_user_id == user.id
      assert event.resource_type == "project_conversation"
      assert event.resource_id == conversation["conversation_id"]
      assert event.evidence["conversation_id"] == conversation["conversation_id"]
      assert event.evidence["agent_id"] == agent.id
      refute inspect(event) =~ "Launch support"

      audit =
        org.id
        |> Observability.list_audit_logs(action: "project_conversation.created")
        |> List.first()

      assert audit
      assert audit.actor_user_id == user.id
      assert audit.resource_type == "project_conversation"
      assert audit.resource_id == conversation["conversation_id"]
      assert audit.metadata["project_id"] == project.id
      assert audit.metadata["agent_id"] == agent.id
      refute inspect(audit) =~ "Launch support"
    end

    test "project users cannot create conversations through forged events", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "helper", "role" => "worker"})

      drain_all()

      user = user_fixture(email: "conversation-user@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/tasks")

      refute html =~ ~s(/orgs/#{org.slug}/operations)
      refute html =~ ~s(/orgs/#{org.slug}/operations/audit)

      assert render_submit(view, "create_conversation", %{
               "conversation" => %{"title" => "forged secret topic", "agent_id" => agent.id}
             }) =~ "Only Agent Swarm admins can manage tasks"

      assert {:ok, %{"data" => []}} =
               SalixIM.Conversations.list_group_conversations(project.salix_group_id, limit: 100)

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_conversation.created",
                 result: "denied"
               )

      assert audit.actor_user_id == user.id
      assert audit.resource_type == "project_conversation"
      assert audit.reason_class == "forbidden"
      assert audit.metadata["project_id"] == project.id
      assert audit.metadata["surface"] == "conversation"
      assert audit.metadata["agent_id_configured"] in [true, "true"]
      refute inspect(audit) =~ "forged secret topic"

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.status == "denied"
      assert event.reason_class == "forbidden"
    end

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

    test "creates a conversation when the title is blank", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "helper", "role" => "worker"})

      drain_all()

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks")

      render_click(view, "new_conversation")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#new-conversation-form",
                 conversation: %{title: "", agent_id: agent.id}
               )
               |> render_submit()

      assert to =~ ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks"

      assert {:ok, %{"data" => conversations}} =
               SalixIM.Conversations.list_group_conversations(project.salix_group_id, limit: 100)

      conversation = Enum.find(conversations, &(&1["title"] == ""))
      assert conversation

      assert {:ok, conversation} =
               SalixIM.Conversations.get_group_conversation(
                 project.salix_group_id,
                 conversation["conversation_id"]
               )

      assert conversation["title"] == ""

      assert {:ok, %{"participants" => participants}} =
               SalixIM.Conversations.list_group_conversation_participants(
                 project.salix_group_id,
                 conversation["conversation_id"]
               )

      assert Enum.map(participants, & &1["actor_type"]) == ["agent"]
    end

    test "clicking a task row navigates to the task detail page", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      assert {:ok, conversation} =
               SalixIM.ConversationServer.create_group_conversation(
                 project.salix_group_id,
                 %{
                   "title" => "Route me",
                   "kind" => "user_chat",
                   "status" => "active",
                   "updated_at" => 1_700_000_000
                 }
               )

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element(
                 "#conversation-#{conversation["conversation_id"]} a[aria-label='Route me']"
               )
               |> render_click()

      assert to ==
               ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation["conversation_id"]}"
    end

    test "filters tasks by the statuses and titles returned by Salix", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      conversations =
        for {key, title, status, schedule} <- [
              {:active, "Investigate webhook", "active", nil},
              {:done, "Summarize findings", "done",
               %{
                 "schedule_id" => SalixStore.Ids.new_schedule_id(),
                 "command" => "Summarize findings"
               }}
            ],
            into: %{} do
          attrs =
            %{
              "title" => title,
              "kind" => "agent_task",
              "status" => status,
              "participants" => []
            }
            |> then(fn attrs ->
              if schedule, do: Map.put(attrs, "schedule", schedule), else: attrs
            end)

          assert {:ok, conversation} =
                   SalixIM.ConversationServer.create_group_conversation(
                     project.salix_group_id,
                     attrs
                   )

          {key, conversation}
        end

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks")

      assert has_element?(view, "h2", "Tasks")
      assert html =~ "Investigate webhook"
      assert html =~ "Summarize findings"
      assert has_element?(view, "#task-group-active")
      assert has_element?(view, "#task-group-done")

      assert has_element?(
               view,
               "#conversation-#{conversations.done["conversation_id"]}",
               "Scheduled"
             )

      refute has_element?(
               view,
               "#conversation-#{conversations.active["conversation_id"]}",
               "Scheduled"
             )

      html = render_click(view, "set_conversation_status_filter", %{"status" => "scheduled"})
      refute html =~ "Investigate webhook"
      assert html =~ "Summarize findings"

      html = render_click(view, "set_conversation_status_filter", %{"status" => "done"})
      refute html =~ "Investigate webhook"
      assert html =~ "Summarize findings"

      render_click(view, "set_conversation_status_filter", %{"status" => "all"})
      html = render_change(view, "filter_conversations", %{"query" => "webhook"})
      assert html =~ "Investigate webhook"
      refute html =~ "Summarize findings"
    end
  end

  describe "Devices tab" do
    test "creates a Shell workload in the project environment and drains it", %{
      conn: conn,
      org: org,
      project: project
    } do
      previous = Application.get_env(:salix_store, :runtime_bundle_root)

      Application.put_env(
        :salix_store,
        :runtime_bundle_root,
        Path.expand("../../../salix_store/test/fixtures/runtime-bundle", __DIR__)
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:salix_store, :runtime_bundle_root, previous),
          else: Application.delete_env(:salix_store, :runtime_bundle_root)
      end)

      suffix = System.unique_integer([:positive])

      {:ok, pool} =
        SalixStore.Compute.create_pool(%{
          id: "live-compute-pool-#{suffix}",
          tenant_id: org.salix_tenant_id,
          name: "project compute",
          region: "local",
          provider_policy: %{"providers" => ["agent_vmm"]},
          capabilities: ["runtime_exec"]
        })

      {:ok, environment} =
        SalixStore.Compute.create_environment(%{
          id: "live-compute-environment-#{suffix}",
          tenant_id: org.salix_tenant_id,
          owner_type: "project",
          owner_id: project.id,
          pool_id: pool.id
        })

      SalixStore.Repo.insert!(%SalixStore.Compute.ProviderBinding{
        id: "shell-binding-#{suffix}",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: "shell-host",
        status: "available",
        generation: 1,
        revision: 1,
        observation: %{},
        updated_at: DateTime.utc_now()
      })

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")
      assert html =~ "Compute environments"
      assert has_element?(view, "#compute-environment-#{environment.id}", environment.id)
      refute html =~ "agent_vmm"

      assert view
             |> element("#compute-environment-#{environment.id} button", "Create Shell workload")
             |> render_click() =~ "Shell workload accepted"

      assert has_element?(view, "#compute-workloads", "shell")

      assert render_click(view, "create_shell_workload", %{"id" => "foreign-environment"}) =~
               "Workload creation failed"

      view
      |> element("#compute-environment-#{environment.id} button", "Drain")
      |> render_click()

      assert has_element?(view, "#compute-environment-#{environment.id}", "draining")
    end

    test "renders the PostgreSQL device projection while Salix is unavailable", %{
      conn: conn,
      org: org,
      project: project
    } do
      now = DateTime.utc_now()

      %ProjectDeviceProjection{}
      |> ProjectDeviceProjection.changeset(%{
        project_id: project.id,
        device_id: "device-projected-live",
        connector_run_id: "run-projected-live",
        connector_id: "connector-projected-live",
        name: "Projected Mac",
        status: "connected",
        source_updated_at: DateTime.to_unix(now, :millisecond),
        observed_generation: 1,
        runtime_inventory: %{"items" => []}
      })
      |> Repo.insert!()

      previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        DeviceProjectionOnlySalixClient
      )

      on_exit(fn ->
        if previous_client,
          do: Application.put_env(:bridge_for_teams_core, :salix_client, previous_client),
          else: Application.delete_env(:bridge_for_teams_core, :salix_client)
      end)

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      assert html =~ "Projected Mac"
      assert has_element?(view, "#environments")
    end

    test "renders Android status and slots from the device capability projection", %{
      conn: conn,
      org: org,
      project: project
    } do
      now = DateTime.utc_now()

      %ProjectDeviceProjection{}
      |> ProjectDeviceProjection.changeset(%{
        project_id: project.id,
        device_id: "device-android-live",
        connector_run_id: "run-android-live",
        connector_id: "connector-android-live",
        name: "Android N2",
        status: "connected",
        source_updated_at: DateTime.to_unix(now, :millisecond),
        observed_generation: 1,
        runtime_inventory: %{
          "items" => [],
          "capabilities" => %{
            "android_device_tool" => true,
            "android" => %{
              "profiles" => ["api30-phone", "api35-phone-google-apis"],
              "default_profile" => "api35-phone-google-apis",
              "active_profile" => "api30-phone",
              "target_profile" => "api35-phone-google-apis",
              "phase" => "waiting_ready",
              "state" => "preparing",
              "available_slots" => 0,
              "capacity" => 1
            }
          }
        }
      })
      |> Repo.insert!()

      previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      Application.put_env(:bridge_for_teams_core, :salix_client, DeviceProjectionOnlySalixClient)

      Application.put_env(:bridge_for_teams_core, :device_projection_android, %{
        "version" => 2,
        "enabled" => true,
        "allowed_modes" => ["connected"],
        "allowed_profiles" => ["api30-phone"],
        "max_concurrent_leases" => 1,
        "max_lease_seconds" => 3600
      })

      on_exit(fn ->
        Application.delete_env(:bridge_for_teams_core, :device_projection_android)

        if previous_client,
          do: Application.put_env(:bridge_for_teams_core, :salix_client, previous_client),
          else: Application.delete_env(:bridge_for_teams_core, :salix_client)
      end)

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      assert html =~ "Android N2"
      assert html =~ "Allowed profiles: api30-phone"
      assert html =~ "Android: Preparing"
      assert html =~ "Configured profiles: api30-phone, api35-phone-google-apis"
      assert html =~ "Default: api35-phone-google-apis"
      assert html =~ "Current: api30-phone"
      assert html =~ "Target: api35-phone-google-apis"
      assert html =~ "Phase: Waiting for Android"
      assert html =~ "0 of 1 slots available"
      assert html =~ "The Android connector is registered to this Agent Swarm."
    end

    test "renders connected runtimes through the shared auth panel without the legacy login path",
         %{conn: conn, project: project, org: org} do
      target = insert_runtime_auth_projection(project)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      assert has_element?(view, "#runtime-auth")
      assert has_element?(view, "#runtime-auth-targets", target.device_runtime_id)
      refute has_element?(view, "#runtime-auth-login-modal")
      refute render(view) =~ "start_runtime_auth_login"
      view |> element("#runtime-auth-#{target.device_runtime_id} button") |> render_click()

      assert has_element?(
               view,
               "#managed-runtime-auth-controls[data-endpoint$='/runtimes/#{target.device_runtime_id}/managed-auth']"
             )

      assert has_element?(view, "#runtime-auth-private-controls[hidden]")
    end

    test "pages Router auth requests even when a filtered storage page is empty",
         %{conn: conn, project: project, org: org} do
      previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      request = %{
        "request_id" => "runtime-auth-page-two",
        "status" => "pending",
        "request_payload" => %{
          "runtime_auth" => %{
            "action" => "verify",
            "target" => %{
              "kind" => "compute_workload",
              "workload_id" => "workload-page-two",
              "project_id" => project.id
            }
          }
        }
      }

      Application.put_env(:bridge_for_teams_core, :salix_client, DeviceProjectionOnlySalixClient)
      Application.put_env(:bridge_for_teams_core, :runtime_auth_page_test_pid, self())

      Application.put_env(:bridge_for_teams_core, :runtime_auth_page_test_pages, %{
        nil => %{"requests" => [], "next_cursor" => "page-two"},
        "page-two" => %{"requests" => [request], "next_cursor" => nil}
      })

      on_exit(fn ->
        if previous_client,
          do: Application.put_env(:bridge_for_teams_core, :salix_client, previous_client),
          else: Application.delete_env(:bridge_for_teams_core, :salix_client)

        Application.delete_env(:bridge_for_teams_core, :runtime_auth_page_test_pid)
        Application.delete_env(:bridge_for_teams_core, :runtime_auth_page_test_pages)
      end)

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      assert_receive {:runtime_auth_page, [cursor: nil, limit: 50]}
      assert has_element?(view, "#runtime-auth-requests-next")
      refute has_element?(view, "#runtime-auth-request-runtime-auth-page-two")

      view |> element("#runtime-auth-requests-next") |> render_click()

      assert_receive {:runtime_auth_page, [cursor: "page-two", limit: 50]}
      assert has_element?(view, "#runtime-auth-request-runtime-auth-page-two")
      refute has_element?(view, "#runtime-auth-requests-next")

      view
      |> element("#runtime-auth-request-runtime-auth-page-two button")
      |> render_click()

      assert has_element?(
               view,
               "#runtime-auth-private-controls[data-request-id='runtime-auth-page-two']"
             )

      {:ok, linked_view, _html} =
        live(
          conn,
          ~p"/orgs/#{org.slug}/projects/#{project.id}/devices?runtime_auth_target=workload-page-two&runtime_auth_request=runtime-auth-page-two"
        )

      assert has_element?(
               linked_view,
               "#runtime-auth-private-controls[data-request-id='runtime-auth-page-two']"
             )
    end

    test "renders the fixed cloud computer without external devices", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")
      assert has_element?(view, "#device-cloud-computer", "Cloud computer")
      assert has_element?(view, "#device-cloud-computer", "Fixed · managed by Comma")
      assert has_element?(view, "#device-cloud-computer button", "Disable")
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/runners?project_id=#{project.id}")
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/events?)
      assert html =~ "domain=device"
      assert html =~ "project_id=#{project.id}"
    end

    test "cloud computer remains listed while disabled and can be re-enabled", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      view |> element("#device-cloud-computer button", "Disable") |> render_click()

      assert has_element?(view, "#device-cloud-computer", "disabled")
      assert has_element?(view, "#device-cloud-computer button", "Enable")
      assert {:ok, %{vm_enabled: false}} = Projects.get_project(project.id)

      view |> element("#device-cloud-computer button", "Enable") |> render_click()

      assert has_element?(view, "#device-cloud-computer", "enabled")
      assert {:ok, %{vm_enabled: true}} = Projects.get_project(project.id)
    end

    test "project users cannot create devices through forged events", %{
      conn: conn,
      org: org,
      project: project
    } do
      user = user_fixture(email: "env-user@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      suffix = System.unique_integer([:positive])

      {:ok, pool} =
        SalixStore.Compute.create_pool(%{
          id: "member-compute-pool-#{suffix}",
          tenant_id: org.salix_tenant_id,
          name: "member projection",
          region: "local"
        })

      {:ok, compute_environment} =
        SalixStore.Compute.create_environment(%{
          id: "member-compute-environment-#{suffix}",
          tenant_id: org.salix_tenant_id,
          owner_type: "project",
          owner_id: project.id,
          pool_id: pool.id
        })

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      refute html =~ "Add device"
      refute html =~ ~s(/orgs/#{org.slug}/operations)
      assert html =~ compute_environment.id
      refute has_element?(view, "#compute-environment-#{compute_environment.id} button")

      assert render_click(view, "compute_environment_intent", %{
               "id" => compute_environment.id,
               "revision" => "1",
               "intent" => "drain"
             }) =~ "Only Agent Swarm admins can manage Compute"

      assert render_click(view, "new_environment") =~
               "Only Agent Swarm admins can manage devices"

      assert render_submit(view, "create_environment", %{"device" => %{"name" => "forged"}}) =~
               "Only Agent Swarm admins can manage devices"

      assert render_click(view, "delete_environment", %{"id" => "forged-device"}) =~
               "Only Agent Swarm admins can manage devices"

      refute render(view) =~ "salix_conn_"

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "device.provision_requested",
                 result: "denied"
               )

      assert audit.actor_user_id == user.id
      assert audit.resource_type == "device_provision_request"
      assert audit.reason_class == "forbidden"
      assert audit.metadata["project_id"] == project.id
      assert audit.metadata["surface"] == "device"
      assert audit.metadata["provisioner_id_configured"] in [false, "false"]
      refute inspect(audit) =~ "forged"

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.status == "denied"
      assert event.reason_class == "forbidden"

      assert [delete_audit] =
               Observability.list_audit_logs(org.id,
                 action: "device.deleted",
                 result: "denied"
               )

      assert delete_audit.actor_user_id == user.id
      assert delete_audit.resource_type == "device"
      assert delete_audit.reason_class == "forbidden"
      assert delete_audit.metadata["device_id_configured"] in [true, "true"]
      refute inspect(delete_audit) =~ "forged-device"
    end

    test "add device creates a provisioner-backed request when an org provisioner exists",
         %{conn: conn, org: org, project: project} do
      drain_all()

      {:ok, provisioner} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "mac-mini-1",
          "name" => "Lab Mac mini",
          "capabilities" => %{"fin" => true}
        })

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      render_click(view, "new_environment")
      assert has_element?(view, "#new-env-form")
      assert render(view) =~ "Create on runner"
      assert render(view) =~ "Lab Mac mini"

      view
      |> form("#new-env-form",
        device: %{
          name: "production",
          alias: "prod-mac",
          provisioner_id: provisioner.id
        }
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Device connection request created."
      assert has_element?(view, "#environments")
      refute has_element?(view, "#environment-provision-requests")
      refute html =~ "production"
      refute html =~ "prod-mac"
      refute html =~ "Connect this device"
      refute html =~ "salix_conn_"

      assert [request] = Environments.list_device_provision_requests(project.id)
      assert request.provisioner_id == provisioner.id
      assert request.salix_group_id == project.salix_group_id
      assert {:ok, []} = Environments.list_environments(project.id)
    end

    test "stale Runners are hidden from device creation and rejected",
         %{conn: conn, org: org, project: project} do
      drain_all()

      {:ok, provisioner} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "stale-mac-mini",
          "name" => "Stale Mac mini",
          "status" => "online",
          "last_seen_at" => DateTime.add(DateTime.utc_now(), -90, :second)
        })

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      render_click(view, "new_environment")
      html = render(view)

      assert html =~ "No runners connected"
      assert html =~ ~s(href="/orgs/#{org.slug}/fin")
      refute has_element?(view, "#new-env-form")
      refute html =~ "Create on runner"
      refute html =~ "Stale Mac mini"

      assert render_submit(view, "create_environment", %{
               "device" => %{
                 "name" => "forged-stale",
                 "provisioner_id" => provisioner.id
               }
             }) =~ "Runner is offline."
    end

    test "refreshes Mac mini candidates before opening the environment form",
         %{conn: conn, org: org, project: project} do
      drain_all()

      {:ok, provisioner} =
        Environments.register_mac_mini_provisioner(org.id, %{
          "stable_id" => "mac-mini-1",
          "name" => "Lab Mac mini",
          "status" => "online",
          "last_seen_at" => DateTime.utc_now()
        })

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      assert html =~ "Add device"

      stale_last_seen = DateTime.add(DateTime.utc_now(), -90, :second)

      Repo.update_all(
        from(p in BridgeForTeams.Schema.MacMiniProvisioner, where: p.id == ^provisioner.id),
        set: [last_seen_at: stale_last_seen]
      )

      render_click(view, "new_environment")
      html = render(view)

      assert html =~ "No runners connected"
      assert html =~ ~s(href="/orgs/#{org.slug}/fin")
      refute has_element?(view, "#new-env-form")
      refute html =~ "Create on runner"
      refute html =~ "Lab Mac mini"
    end

    test "add-device modal routes runner management to Fin when none are online",
         %{conn: conn, org: org, project: project} do
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")

      html = render_click(view, "new_environment")
      assert html =~ "No runners connected"
      assert html =~ "Connect a runner in Fin before creating a project device."
      assert html =~ ~s(href="/orgs/#{org.slug}/fin")
      assert html =~ "Open Fin"
      refute has_element?(view, "#new-env-form")
      refute html =~ ~s(phx-click="create_runner_install_command")
      refute html =~ "install.sh?"
    end

    test "lists live Salix device connectors and supports disconnecting and deleting", %{
      conn: conn,
      org: org,
      project: project
    } do
      drain_all()

      env_id = "transport-#{Ecto.UUID.generate()}"
      device_id = "device-" <> env_id

      {:ok, _transport_id, _record} =
        SalixEnv.Registry.connect(
          "nonode@nohost",
          %{
            "tenant_id" => org.salix_tenant_id,
            "group_id" => project.salix_group_id,
            "device_id" => device_id,
            "connector_id" => "connector-" <> env_id,
            "name" => "staging-box"
          },
          transport_id: env_id
        )

      refresh_device_projection(project.id, device_id)

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/devices")
      assert html =~ "staging-box"
      assert has_element?(view, "#device-#{device_id} button", "Delete")

      view |> element("button[phx-value-id='#{device_id}']", "Disconnect") |> render_click()

      assert render(view) =~ "Device disconnected"
      assert {:ok, rec} = Environments.get_environment(project.id, device_id)
      assert rec["status"] == "disconnected"
      assert has_element?(view, "#device-#{device_id} button", "Delete")

      view |> element("#device-#{device_id} button", "Delete") |> render_click()

      assert render(view) =~ "Device deleted"
      refute has_element?(view, "#device-#{device_id}")
      assert {:error, :not_found} = Environments.get_environment(project.id, device_id)

      assert [audit] = Observability.list_audit_logs(org.id, action: "device.deleted")
      assert audit.result == "ok"
      assert audit.resource_id == device_id
    end
  end

  describe "Websites tab" do
    test "renders empty state when no agent has a site", %{conn: conn, org: org, project: project} do
      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/websites")
      assert html =~ "No websites yet"
    end

    test "lists websites deployed by the project's agents", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "publisher", "role" => "router"})

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, SitesSalixClient)
      on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev_client) end)

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/websites")

      assert html =~ "marketing"
      assert html =~ "https://marketing-#{agent.salix_agent_id}.example.test"
      # The site is linked to its owning agent.
      assert html =~ "publisher"
      assert html =~ ~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}"
    end
  end

  describe "Schedules tab" do
    test "renders empty state when no agent owns a schedule", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/schedules")
      assert html =~ "No schedules yet"
    end

    test "lists agent schedules with human recurrence and deletes one", %{
      conn: conn,
      org: org,
      project: project,
      user: user
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "scheduler", "role" => "router"})

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, SchedulesSalixClient)

      Application.put_env(:bridge_for_teams_core, :test_schedules, [
        %{
          "id" => "sched-keep",
          "agent_id" => agent.salix_agent_id,
          "prompt" => "daily standup digest",
          "interval_minutes" => 60,
          "created_at" => 1_700_000_000_000,
          "last_run" => nil
        },
        %{
          "id" => "sched-drop",
          "agent_id" => agent.salix_agent_id,
          "prompt" => "weekly report",
          "cron" => "0 9 * * 1",
          "timezone" => "America/New_York",
          "created_at" => 1_700_000_000_000,
          "last_run" => 1_700_003_600_000
        },
        # Another swarm's schedule — must never appear.
        %{
          "id" => "sched-foreign",
          "agent_id" => "agent_someone_else",
          "prompt" => "not ours",
          "interval_minutes" => 5,
          "created_at" => 1_700_000_000_000,
          "last_run" => nil
        }
      ])

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)
        Application.delete_env(:bridge_for_teams_core, :test_schedules)
      end)

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/schedules")

      assert html =~ "daily standup digest"
      assert html =~ "Every hour"
      assert html =~ "weekly report"
      assert html =~ "Every Monday at 9 AM (America/New_York)"
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/events?)
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/audit?)
      assert html =~ "domain=schedule"
      assert html =~ "project_id=#{project.id}"
      assert html =~ "resource_type=project_schedule"
      assert html =~ "resource_id=sched-keep"
      assert html =~ "resource_id=sched-drop"
      # Linked to the owning agent; the foreign schedule is excluded.
      assert html =~ "scheduler"
      assert html =~ ~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}"
      refute html =~ "not ours"

      view
      |> element("#schedule-sched-drop button", "Delete")
      |> render_click()

      assert render(view) =~ "Schedule deleted"
      refute render(view) =~ "weekly report"
      assert render(view) =~ "daily standup digest"

      assert [audit] =
               Observability.list_audit_logs(org.id, action: "project_schedule.deleted")

      assert audit.result == "ok"
      assert audit.actor_user_id == user.id
      assert audit.resource_type == "project_schedule"
      assert audit.resource_id == "sched-drop"
      assert audit.metadata["project_id"] == project.id
      refute inspect(audit) =~ "weekly report"
      refute inspect(audit) =~ "0 9 * * 1"
    end

    test "lists a Task schedule, links to its task, and clears its binding on delete", %{
      conn: conn,
      org: org,
      project: project,
      user: user
    } do
      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, SchedulesSalixClient)

      Application.put_env(:bridge_for_teams_core, :test_schedules, [
        %{
          "id" => "sched-task",
          "receiver" => "task",
          "payload" => %{
            "agent_group_id" => project.salix_group_id,
            "conversation_id" => "cnv1_task_schedule"
          },
          "cron" => "30 18 * * 3",
          "timezone" => "Asia/Shanghai",
          "created_at" => 1_700_000_000_000,
          "last_run" => nil
        }
      ])

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, prev_client)
        Application.delete_env(:bridge_for_teams_core, :test_schedules)
      end)

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/schedules")

      assert html =~ "Every Wednesday at 6:30 PM (Asia/Shanghai)"

      assert has_element?(
               view,
               "#schedule-sched-task a[href='/orgs/#{org.slug}/projects/#{project.id}/tasks/cnv1_task_schedule']",
               "Task"
             )

      assert has_element?(view, "#schedule-sched-task", "Runs this task")

      view
      |> element("#schedule-sched-task button", "Delete")
      |> render_click()

      assert render(view) =~ "Schedule deleted"
      refute has_element?(view, "#schedule-sched-task")
      assert Application.get_env(:bridge_for_teams_core, :test_schedules) == []

      assert [audit] =
               Observability.list_audit_logs(org.id, action: "project_task_schedule.delete")

      assert audit.result == "ok"
      assert audit.actor_user_id == user.id
      assert audit.resource_type == "task_schedule"
      assert audit.resource_id == "cnv1_task_schedule"
      assert audit.metadata["project_id"] == project.id
    end

    test "project users cannot delete schedules through forged events", %{
      conn: conn,
      org: org,
      project: project
    } do
      user = user_fixture(email: "schedule-user@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/schedules")

      refute html =~ ~s(/orgs/#{org.slug}/operations)
      refute html =~ ~s(/orgs/#{org.slug}/operations/audit)

      assert render_click(view, "delete_schedule", %{"id" => "sched-secret-forged"}) =~
               "Only Agent Swarm admins can manage schedules"

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_schedule.deleted",
                 result: "denied"
               )

      assert audit.actor_user_id == user.id
      assert audit.resource_type == "project_schedule"
      assert audit.reason_class == "forbidden"
      assert audit.metadata["project_id"] == project.id
      assert audit.metadata["surface"] == "schedule"
      assert audit.metadata["schedule_id_configured"] in [true, "true"]
      refute inspect(audit) =~ "sched-secret-forged"

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.status == "denied"
      assert event.reason_class == "forbidden"
    end

    test "surfaces an unavailable Salix runtime", %{conn: conn, org: org, project: project} do
      {:ok, _agent} = create_provisioned_agent(project.id, %{"name" => "a", "role" => "router"})

      prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        BridgeForTeamsWeb.Dashboard.ProjectShowLiveTest.UnavailableSchedulesClient
      )

      on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev_client) end)

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/schedules")
      assert html =~ "Salix unavailable"
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
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/integrations?)
      assert html =~ ~s(href="/orgs/#{org.slug}/operations/checks?)
      assert html =~ "project_id=#{project.id}"
      assert html =~ "surface=bot"
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

    test "Feishu and Slack checks persist independent Operations posture end to end", %{
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

      {:ok, operations_view, _html} =
        live(conn, ~p"/orgs/#{org.slug}/operations/integrations")

      feishu_row = operations_view |> element("#operations-integration-feishu") |> render()
      assert feishu_row =~ "Feishu"
      assert feishu_row =~ "needs manual"
      assert feishu_row =~ "explicit admin action required"

      slack_row = operations_view |> element("#operations-integration-slack") |> render()
      assert slack_row =~ "Slack"
      assert slack_row =~ "fail"
      assert slack_row =~ "calendar source maintenance failed"
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
      refute html =~ ~s(/orgs/#{org.slug}/operations)

      view
      |> render_click("open_integration_setup", %{"provider" => "feishu"})

      refute has_element?(view, "#integration-setup-panel")

      assert render_submit(view, "create_slack_connect", %{"slack_connect" => slack_attrs()}) =~
               "Only Agent Swarm admins can manage integrations"

      assert render_click(view, "disable_connect", %{"id" => "slack-forged"}) =~
               "Only Agent Swarm admins can manage integrations"

      assert render_click(view, "send-feishu-test-message") =~
               "Only Agent Swarm admins can run the first-message smoke"

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

      assert [smoke_audit] =
               Observability.list_audit_logs(org.id,
                 action: "integration.feishu.first_message_smoke",
                 result: "denied"
               )

      assert smoke_audit.actor_user_id == user.id
      assert smoke_audit.resource_type == "project_im_connect"
      assert smoke_audit.reason_class == "forbidden"
      assert smoke_audit.metadata["project_id"] == project.id
      assert smoke_audit.metadata["surface"] == "integration"
      assert smoke_audit.metadata["side_effects"] == "billable_llm_wake"

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

      html =
        view
        |> form("#create-slack-connect-form", slack_connect: %{app_name: "Acme Bridge Bot"})
        |> render_change()

      assert html =~ "Acme Bridge Bot"
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

    test "renders the connections tab link", %{conn: conn, org: org, project: project} do
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}")
      assert has_element?(view, "a", "Connections")
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
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}")
    nav = "#agent-swarm-navigation-#{project.id}"

    refute has_element?(view, "#{nav} a", "Overview")
    assert has_element?(view, "#{nav} a", "Agents")
    assert has_element?(view, "#{nav} a", "Tasks")
    assert has_element?(view, "#{nav} a", "Integrations")
    assert has_element?(view, "#{nav} a", "Connections")
    assert has_element?(view, "#{nav} a", "Devices")
    assert has_element?(view, "#{nav} a", "Websites")
    assert has_element?(view, "#{nav} a[aria-label='Agent Swarm settings']")
  end

  describe "Agent detail page" do
    test "renders agent details and Salix state", %{conn: conn, org: org, project: project} do
      {:ok, template} =
        SalixAgent.Templates.create(%{
          "name" => "Test GPT",
          "model" => "gpt-test",
          "provider" => "mock"
        })

      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "worker-detail",
          "role" => "worker",
          "template_id" => template["template_id"],
          "system_prompt" => "Summarize tickets."
        })

      {:ok, view, html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}")

      assert html =~ "worker-detail"
      assert html =~ "gpt-test"
      assert html =~ "Summarize tickets."
      assert html =~ agent.salix_agent_id
      refute html =~ "Runtime sessions"
      assert has_element?(view, "a[aria-current='page']", "Agents")
    end

    test "reads one template without loading runtime sessions", %{
      conn: conn,
      org: org,
      project: project
    } do
      previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
      previous_pid = Application.get_env(:bridge_for_teams_core, :agent_detail_query_test_pid)

      Application.put_env(
        :bridge_for_teams_core,
        :salix_client,
        AgentDetailQueryProbeSalixClient
      )

      Application.put_env(:bridge_for_teams_core, :agent_detail_query_test_pid, self())

      on_exit(fn ->
        restore_env(:bridge_for_teams_core, :salix_client, previous_client)
        restore_env(:bridge_for_teams_core, :agent_detail_query_test_pid, previous_pid)
      end)

      {:ok, _} =
        SalixAgent.Templates.create(%{
          "template_id" => "tmpl-detail",
          "name" => "Direct",
          "model" => "gpt-direct-read",
          "provider" => "mock"
        })

      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "lazy-detail",
          "role" => "worker",
          "template_id" => "tmpl-detail"
        })

      {:ok, view, html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}")

      assert html =~ "gpt-direct-read"
      refute html =~ "Runtime sessions"
      refute has_element?(view, "button[phx-click='load_runtime_sessions']")
      assert_receive {:agent_detail_query, {:get_template, "tmpl-detail"}}
      refute_receive {:agent_detail_query, {:list_sessions, _agent_id}}
    end

    test "admin starts a fresh canonical Router session", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "router-detail",
          "role" => "router"
        })

      drain_all()

      assert {:ok, before} =
               SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)

      old_session_id = before["router_session_id"]

      {:ok, view, html} =
        live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}")

      assert html =~ "Canonical Router session"
      assert html =~ old_session_id

      html =
        view
        |> element("#switch-router-session")
        |> render_click()

      assert html =~ "Started a new canonical Router session."

      assert {:ok, after_switch} =
               SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)

      new_session_id = after_switch["router_session_id"]
      assert new_session_id != old_session_id
      assert render(view) =~ new_session_id
      refute render(view) =~ old_session_id

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "agent.router_session_switched",
                 result: "ok"
               )

      assert audit.resource_id == agent.id

      assert audit.redacted_diff["router_session_id"] == %{
               "from" => old_session_id,
               "to" => new_session_id
             }
    end

    test "project users cannot switch a Router session through a forged event", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{
          "name" => "router-read-only",
          "role" => "router"
        })

      drain_all()

      assert {:ok, before} =
               SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)

      user = user_fixture(email: "router-reader@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}")

      refute has_element?(view, "#switch-router-session")

      assert render_click(view, "switch_router_session", %{
               "expected_session_id" => before["router_session_id"]
             }) =~ "Only Agent Swarm admins can switch the Router session."

      assert {:ok, unchanged} =
               SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)

      assert unchanged["router_session_id"] == before["router_session_id"]
    end

    test "redirects when the agent does not belong to the project", %{
      conn: conn,
      org: org,
      project: project
    } do
      {:ok, other_project} =
        Projects.create_project(org.id, %{"name" => "Other", "slug" => "other"})

      {:ok, agent} =
        create_provisioned_agent(other_project.id, %{"name" => "foreign", "role" => "worker"})

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}")

      assert to == ~p"/orgs/#{org.slug}/projects/#{project.id}/agents"
    end

    test "rejects users without project access", %{conn: conn, org: org, project: project} do
      {:ok, agent} =
        create_provisioned_agent(project.id, %{"name" => "private", "role" => "worker"})

      user = user_fixture(email: "agent-detail-outsider@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

      assert {:error, {:live_redirect, %{to: to}}} =
               conn
               |> log_in_user(user)
               |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}")

      assert to == ~p"/orgs/#{org.slug}/projects/#{project.id}/agents"
    end
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
