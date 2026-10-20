defmodule BridgeForTeamsWeb.CLIControllerTest do
  require SystemsRuntime.Proc

  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.CLI.Login, as: CLILogin

  alias BridgeForTeams.{
    Environments,
    FeishuScopes,
    Memberships,
    Observability,
    Orgs,
    Repo,
    TestBandit
  }

  alias BridgeForTeams.Schema.{OrgSsoIdentity, ReconcileOutbox}
  alias BridgeForTeamsWeb.DashboardEndpoint
  alias SalixMeet.CalendarProjection
  alias SalixStore.{CasRecord, Ids, Keys}

  defmodule FeishuTenantAppClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def slack_manifest(app_name) do
      %{
        "redirect_url" => "https://salix.example.test/v1/im/slack/oauth/callback",
        "events_url" => "https://salix.example.test/v1/im/slack/events",
        "interactions_url" => "https://salix.example.test/v1/im/slack/interactions",
        "manifest" => %{
          "display_information" => %{"name" => app_name},
          "features" => %{
            "app_home" => %{
              "home_tab_enabled" => true,
              "messages_tab_enabled" => true,
              "messages_tab_read_only_enabled" => false
            }
          },
          "oauth_config" => %{"scopes" => %{"bot" => ["app_mentions:read", "chat:write"]}}
        }
      }
    end

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}

    def put_feishu_tenant_app(_tenant_id, attrs) do
      {:ok,
       %{
         "app_id" => attrs["app_id"],
         "app_secret_configured" => true,
         "verification_token_configured" => Map.has_key?(attrs, "verification_token"),
         "encrypt_key_configured" => Map.has_key?(attrs, "encrypt_key")
       }}
    end
  end

  defmodule ConversationSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    @conversation %{
      "conversation_id" => "task-cli-1",
      "title" => "CLI task conversation",
      "kind" => "work_session",
      "status" => "active",
      "updated_at" => 1_782_000_000,
      "participants" => [
        %{
          "participant_id" => "delegator",
          "actor_type" => "agent",
          "agent_id" => "agent-router",
          "role_label" => "delegator",
          "payload" => %{"session_id" => "router-payload-session"}
        },
        %{
          "participant_id" => "worker",
          "actor_type" => "agent",
          "agent_id" => "agent-worker",
          "role_label" => "worker",
          "payload" => %{"session_id" => "im-task-cli-1"}
        }
      ]
    }

    @messages [
      %{
        "message_id" => "msg-router",
        "actor_type" => "agent",
        "participant_id" => "delegator",
        "content" => [%{"type" => "text", "text" => "please report pwd"}],
        "created_at" => 1_782_000_001
      },
      %{
        "message_id" => "msg-worker",
        "actor_type" => "agent",
        "participant_id" => "worker",
        "content" => [%{"type" => "text", "text" => "pwd=/tmp/comma"}],
        "created_at" => 1_782_000_002
      }
    ]

    @missing_trace_conversation %{
      "conversation_id" => "no-trace",
      "title" => "Conversation without trace target",
      "kind" => "work_session",
      "status" => "active",
      "participants" => []
    }

    @single_trace_conversation %{
      "conversation_id" => "single-trace",
      "title" => "Single participant trace",
      "kind" => "user_chat",
      "status" => "active",
      "participants" => [
        %{
          "participant_id" => "agent",
          "actor_type" => "agent",
          "agent_id" => "agent-single",
          "role_label" => "agent",
          "payload" => %{"session_id" => "single-session"}
        }
      ]
    }

    @missing_runtime_trace_conversation %{
      "conversation_id" => "trace-gone",
      "title" => "Conversation with missing runtime trace",
      "kind" => "work_session",
      "status" => "active",
      "participants" => [
        %{
          "participant_id" => "delegator",
          "actor_type" => "agent",
          "agent_id" => "agent-router",
          "role_label" => "delegator",
          "payload" => %{"session_id" => "im-trace-gone"}
        }
      ]
    }

    def list_group_conversations(_group_id, opts) do
      Process.put(:conversation_list_limit, Keyword.get(opts, :limit))
      {:ok, %{"data" => [@conversation]}}
    end

    def get_group_conversation(_group_id, "task-cli-1"),
      do: {:ok, Map.delete(@conversation, "participants")}

    def get_group_conversation(_group_id, "no-trace"),
      do: {:ok, Map.delete(@missing_trace_conversation, "participants")}

    def get_group_conversation(_group_id, "single-trace"),
      do: {:ok, Map.delete(@single_trace_conversation, "participants")}

    def get_group_conversation(_group_id, "trace-gone"),
      do: {:ok, Map.delete(@missing_runtime_trace_conversation, "participants")}

    def get_group_conversation(_group_id, _conversation_id), do: {:error, :not_found}

    def list_group_conversation_participants(_group_id, conversation_id, _opts) do
      conversation =
        case conversation_id do
          "task-cli-1" -> @conversation
          "no-trace" -> @missing_trace_conversation
          "single-trace" -> @single_trace_conversation
          "trace-gone" -> @missing_runtime_trace_conversation
        end

      Process.put(:conversation_participants_read, conversation_id)

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participants" => conversation["participants"]
       }}
    end

    def list_group_conversation_messages(_group_id, "task-cli-1", opts) do
      Process.put(:conversation_messages_limit, Keyword.get(opts, :limit))
      {:ok, @messages}
    end

    def list_group_conversation_messages(_group_id, _conversation_id, _opts),
      do: {:error, :not_found}

    def ensure_group_conversation_provider_participant(_group_id, "task-cli-1", attrs) do
      Process.put(:conversation_send_participant_attrs, attrs)
      {:ok, %{"participant_id" => "ptp1_2094170633557508096"}}
    end

    def append_group_conversation_message(_group_id, "task-cli-1", attrs) do
      Process.put(:conversation_send_attrs, attrs)
      {:ok, %{"message_id" => "msg-cli-send", "client_request_id" => attrs["client_request_id"]}}
    end

    def get_group_conversation_with_messages(group_id, conversation_id, opts) do
      with {:ok, conversation} <- get_group_conversation(group_id, conversation_id),
           {:ok, messages} <- list_group_conversation_messages(group_id, conversation_id, opts) do
        {:ok, %{"conversation" => conversation, "messages" => messages}}
      end
    end

    def session_trace(_agent_id, "im-trace-gone", opts) do
      Process.put(:conversation_trace_limit, Keyword.get(opts, :limit))
      {:error, :not_found}
    end

    def session_trace("agent-single" = agent_id, "single-session" = session_id, opts) do
      Process.put(:conversation_trace_limit, Keyword.get(opts, :limit))
      Process.put(:conversation_trace_target, {agent_id, session_id})

      {:ok,
       %{
         "agent_id" => agent_id,
         "session_id" => session_id,
         "events" => [%{"method" => "turn/completed"}]
       }}
    end

    def session_trace("agent-worker" = agent_id, "im-task-cli-1" = session_id, opts) do
      Process.put(:conversation_trace_limit, Keyword.get(opts, :limit))
      Process.put(:conversation_trace_target, {agent_id, session_id})

      {:ok,
       %{
         "agent_id" => agent_id,
         "session_id" => session_id,
         "token" => "secret-token",
         "events" => [
           %{
             "method" => "turn/completed",
             "callback_url" => "https://example.test/callback?token=secret-token&ok=1"
           }
         ]
       }}
    end

    def session_trace("agent-router" = agent_id, "router-payload-session" = session_id, opts) do
      Process.put(:conversation_trace_limit, Keyword.get(opts, :limit))
      Process.put(:conversation_trace_target, {agent_id, session_id})

      {:ok,
       %{
         "agent_id" => agent_id,
         "session_id" => session_id,
         "events" => [%{"method" => "router/notified"}]
       }}
    end

    def session_trace(agent_id, session_id, _opts),
      do: {:error, {:unexpected_trace_target, agent_id, session_id}}

    def group_conversation_delivery_status(_group_id, "task-cli-1", opts) do
      Process.put(:conversation_delivery_limit, Keyword.get(opts, :limit))

      Process.put(
        :conversation_delivery_filter,
        Keyword.take(opts, [:participant_id, :message_id])
      )

      {:ok,
       %{
         "agent_group_id" => "group-cli",
         "conversation_id" => "task-cli-1",
         "participant_id" => Keyword.fetch!(opts, :participant_id),
         "message_id" => Keyword.get(opts, :message_id),
         "participant" => %{
           "participant_id" => "worker",
           "actor_type" => "agent",
           "agent_id" => "agent-worker",
           "session_id" => "im-task-cli-1"
         },
         "deliveries" => [
           %{
             "delivery_id" => "delivery-cli-1",
             "message_id" => "msg-worker",
             "participant_actor_type" => "agent",
             "participant_id" => "worker",
             "participant_agent_id" => "agent-worker",
             "participant_payload" => %{"session_id" => "im-task-cli-1"},
             "source_user_id" => "provider-user-secret",
             "from_user_id" => "provider-from-secret",
             "sender_user_id" => "provider-sender-secret",
             "sender_open_id" => "provider-open-secret",
             "sender_union_id" => "provider-union-secret",
             "status" => "delivered",
             "delivery" => %{"status" => "delivered"},
             "session" => %{
               "exists" => true,
               "status" => "ready",
               "runtime_kind" => "internal"
             }
           }
         ],
         "limit" => Keyword.get(opts, :limit)
       }}
    end

    def group_conversation_delivery_status(_group_id, _conversation_id, _opts),
      do: {:error, :not_found}

    def redeliver_group_conversation_agent_message(_group_id, "task-cli-1", attrs) do
      Process.put(:conversation_redelivery_attrs, attrs)

      {:ok,
       Map.merge(attrs, %{
         "conversation_id" => "task-cli-1",
         "delivery_status" => "queued"
       })}
    end

    def get_conversation_participant_status(_group_id, "task-cli-1", "worker") do
      Process.put(:conversation_status_participant, "worker")

      {:ok,
       %{
         "conversation_id" => "task-cli-1",
         "participant_id" => "worker",
         "activity" => %{
           "kind" => "running",
           "description" => "handling task"
         }
       }}
    end

    def get_conversation_participant_status(_group_id, _conversation_id, _participant_id),
      do: {:error, :not_found}
  end

  defmodule CalendarStatusSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def list_group_im_connects(_group_id, "slack") do
      Process.get(:calendar_connects_result) ||
        {:ok,
         [
           %{
             "connect_id" => "conn-calendar",
             "provider" => "slack",
             "workspace_id" => "T-CALENDAR",
             "workspace_name" => "Calendar Workspace",
             "disabled_at" => nil
           }
         ]}
    end

    def get_group(_group_id),
      do: {:ok, %{"router_agent_id" => Process.get(:calendar_router_agent_id)}}

    def meeting_calendar_policy(_params),
      do: raise("the public status command must not call the mutating policy probe")

    def meeting_calendar_policy_status(%{
          "agent_id" => agent_id,
          "connect_id" => "conn-calendar"
        }) do
      Process.put(:calendar_policy_status_agent_id, agent_id)

      Process.get(:calendar_policy_status_result) ||
        {:ok,
         %{
           "readiness" => "ACTIVE",
           "watched_calendars" => ["Comma Event"],
           "channel" => "#meeting-prep",
           "channel_id" => "C-MEETING-PREP",
           "internal_router_agent_id" => "agt-private-policy-router",
           "provider_debug" =>
             "PRIVATE_POLICY_GATE_CANARY https://meet.google.com:443/private-room"
         }}
    end

    def meeting_calendar_status(params) do
      Process.put(:calendar_status_params, params)

      Process.get(:calendar_status_result) ||
        {:ok, healthy_calendar_status(params["limit"])}
    end

    def healthy_calendar_status(limit) do
      %{
        "health" => "ok",
        "reason" => "eligible_meetings_projected",
        "connect_id" => "conn-calendar",
        "group_id" => "grp-calendar",
        "internal_router_agent_id" => "agt-private-router",
        "window_hours" => 24,
        "runtime" => %{
          "status" => "running",
          "configured" => true,
          "running" => true,
          "scan_interval_ms" => 120_000
        },
        "projection" => %{
          "state" => "active",
          "calendar_id" => "cal-calendar",
          "updated_at" => 1_786_009_000_000,
          "age_ms" => 1_000,
          "stale_after_ms" => 360_000,
          "stale" => false,
          "fresh_count" => 1,
          "recovery_count" => 0,
          "candidate_count" => 1,
          "returned_count" => 1,
          "limit" => limit,
          "truncated" => false
        },
        "summary" => %{
          "candidate_count" => 1,
          "returned_count" => 1,
          "planned_count" => 1,
          "plan_error_count" => 0,
          "candidate_error_count" => 0,
          "autojoin_error_count" => 0
        },
        "events" => [
          %{
            "candidate_kind" => "fresh",
            "meeting_id" => "mtg-cal-calendar",
            "event_id" => "event-calendar",
            "title" =>
              "Agenda https://docs.example.test/brief,Meet:https://meet.google.com:443/abc-defg-hij",
            "meet_url" => "https://meet.google.com:443/abc-defg-hij",
            "start_ms" => 1_786_009_200_000,
            "end_ms" => 1_786_011_000_000,
            "calendar_id" => "cal-calendar",
            "calendar_item_id" => "citem-calendar",
            "meeting_plan_id" => "mplan-calendar",
            "google_meet_eligible" => true,
            "candidate_updated_at" => 1_786_009_000_000,
            "recovery_started_at" => nil,
            "last_error_present" => false,
            "plan" => %{
              "status" => "planned",
              "conversation_id" => "cnv-calendar",
              "revision" => 1,
              "updated_at" => 1_786_009_000_000,
              "preparation" => %{
                "decision_at" => nil,
                "publish_start_at" => nil,
                "publish_deadline_at" => nil,
                "research_decision" => "pending",
                "deadline_status" => "pending",
                "baseline" => "PRIVATE_PREPARATION_BASELINE"
              }
            },
            "autojoin" => %{
              "status" => "not_started",
              "start_at" => nil,
              "join_requested_at" => nil,
              "joined_at" => nil,
              "abandoned_at" => nil,
              "error_present" => false,
              "error" => "PRIVATE_AUTOJOIN_ERROR"
            }
          }
        ]
      }
    end

    def create_tenant(attrs), do: record_mutation(:create_tenant, attrs)
    def create_group(attrs), do: record_mutation(:create_group, attrs)
    def create_agent(attrs), do: record_mutation(:create_agent, attrs)

    defp record_mutation(operation, attrs) do
      Process.put(
        :calendar_mutation_calls,
        [{operation, attrs} | Process.get(:calendar_mutation_calls, [])]
      )

      {:ok, %{}}
    end
  end

  defmodule ActualCalendarStatusSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    defdelegate list_group_im_connects(group_id, provider),
      to: BridgeForTeamsWeb.CLIControllerTest.CalendarStatusSalixClient

    defdelegate get_group(group_id),
      to: BridgeForTeamsWeb.CLIControllerTest.CalendarStatusSalixClient

    defdelegate meeting_calendar_policy_status(params),
      to: BridgeForTeamsWeb.CLIControllerTest.CalendarStatusSalixClient

    def meeting_calendar_policy(_params),
      do: raise("the public status command must not call the mutating policy probe")

    def meeting_calendar_status(%{
          "agent_id" => agent_id,
          "connect_id" => connect_id,
          "limit" => limit
        }) do
      Salix.Bindings.MeetingCalendarStatus.get(agent_id, connect_id, limit)
    end
  end

  defmodule MeetingReplaySalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def replay_meeting_summary(group_id, meeting_id, opts) do
      Process.put(:meeting_replay_request, {group_id, meeting_id, opts})

      {:ok,
       %{
         "mode" => if(opts[:run_model], do: "model_replay", else: "plan_only"),
         "passed" => true,
         "delivery_writes" => false
       }}
    end
  end

  defmodule ArtifactServer do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    match _ do
      root =
        :bridge_for_teams_web
        |> SystemsRuntime.fetch_env!(:bft_cli_artifact_test_root)
        |> Path.expand()

      path =
        conn.request_path
        |> String.trim_leading("/")
        |> then(&Path.expand(&1, root))

      if String.starts_with?(path, root <> "/") and File.regular?(path) do
        send_file(conn, 200, path)
      else
        send_resp(conn, 404, "not found")
      end
    end
  end

  setup do
    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)

    on_exit(fn ->
      if previous_client do
        SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      else
        SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, FeishuTenantAppClient)

    %{user: user, org: org} = org_with_owner_fixture(org: %{slug: "acme", name: "Acme"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Support",
        "slug" => "support"
      })

    {:ok, %{token: token, session: session}} = Sessions.create(user, device: "bft-cli")
    {:ok, _grants} = CLILogin.grant_cli_session_orgs(session, [org.id], user.id)

    %{user: user, org: org, project: project, token: token, session: session}
  end

  test "requires a bearer CLI token", %{org: org, project: project} do
    conn = api(:get, "/v1/cli/context?org=#{org.slug}&project=#{project.slug}", nil, nil)

    assert conn.status == 401

    assert %{"ok" => false, "error" => %{"code" => "unauthenticated"}} =
             Jason.decode!(conn.resp_body)
  end

  test "runner install target is scoped to the requested organization", %{org: org, token: token} do
    {:ok, other_org} =
      Orgs.create_org(%{
        "name" => "Other Runner Org",
        "slug" => "other-runner-org-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      })

    assert {:ok, runner} =
             Environments.register_mac_mini_provisioner(other_org.id, %{
               "stable_id" => "other-org-runner",
               "name" => "Other org runner"
             })

    conn =
      api(
        :post,
        "/v1/orgs/#{org.slug}/runners/install-command?runner=#{runner.stable_id}",
        token
      )

    assert conn.status == 404

    assert %{"ok" => false, "error" => %{"code" => "runner_not_found"}} =
             Jason.decode!(conn.resp_body)
  end

  test "public bft CLI installer downloads the configured artifact" do
    previous_base = SystemsRuntime.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_artifact = SystemsRuntime.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    previous_sha = SystemsRuntime.get_env(:bridge_for_teams_web, :bft_cli_sha256)
    previous_public_base_url = SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url)

    SystemsRuntime.delete_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)

    SystemsRuntime.put_env(
      :bridge_for_teams_web,
      :bft_cli_artifact_url,
      "https://r2.example.test/bft"
    )

    SystemsRuntime.put_env(:bridge_for_teams_web, :bft_cli_sha256, "abc123")
    SystemsRuntime.put_env(:bridge_for_teams_web, :public_base_url, "https://teams.example.test/")

    on_exit(fn ->
      restore_web_env(:bft_cli_artifact_base_url, previous_base)
      restore_web_env(:bft_cli_artifact_url, previous_artifact)
      restore_web_env(:bft_cli_sha256, previous_sha)
      restore_web_env(:public_base_url, previous_public_base_url)
    end)

    conn = api(:get, "/v1/cli/install.sh", nil)

    assert conn.status == 200
    assert conn.resp_body =~ "curl -fsSL 'https://r2.example.test/bft'"
    assert conn.resp_body =~ "verify_sha256 'abc123' \"$tmp\""
    assert conn.resp_body =~ "sha256sum -c -"
    assert conn.resp_body =~ "mv \"$tmp\" \"$target\""
    assert conn.resp_body =~ ~s(printf '  "api_base_url": %s\\n')
    assert conn.resp_body =~ ~s('"https://teams.example.test"')
    assert conn.resp_body =~ "chmod 0600 \"$config_path\""
    assert conn.resp_body =~ "bft auth login --url https://teams.example.test --output text"
  end

  test "public bft CLI installer executes against platform-specific artifacts" do
    previous_base = SystemsRuntime.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_release = SystemsRuntime.get_env(:bridge_for_teams_web, :bft_cli_release_id)
    previous_artifact = SystemsRuntime.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    previous_public_base_url = SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url)

    previous_test_root =
      SystemsRuntime.get_env(:bridge_for_teams_web, :bft_cli_artifact_test_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "bft-cli-install-test-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf(root)
      restore_web_env(:bft_cli_artifact_base_url, previous_base)
      restore_web_env(:bft_cli_release_id, previous_release)
      restore_web_env(:bft_cli_artifact_url, previous_artifact)
      restore_web_env(:public_base_url, previous_public_base_url)
      restore_web_env(:bft_cli_artifact_test_root, previous_test_root)
    end)

    release_id = "bft-cli-install-test"
    platform = local_platform()
    artifact_dir = Path.join([root, "bft-cli", "releases", release_id, platform])
    File.mkdir_p!(artifact_dir)

    artifact_path = Path.join(artifact_dir, "bft")
    File.write!(artifact_path, "#!/usr/bin/env sh\nprintf 'installed-bft\\n'\n")
    File.chmod!(artifact_path, 0o755)

    sha256 =
      artifact_path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    File.write!(artifact_path <> ".sha256", "#{sha256}  bft\n")

    SystemsRuntime.put_env(:bridge_for_teams_web, :bft_cli_artifact_test_root, root)

    %{port: port} =
      TestBandit.start_supervised!(
        plug: ArtifactServer,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    SystemsRuntime.put_env(
      :bridge_for_teams_web,
      :bft_cli_artifact_base_url,
      "http://127.0.0.1:#{port}/bft-cli"
    )

    SystemsRuntime.put_env(:bridge_for_teams_web, :bft_cli_release_id, release_id)
    SystemsRuntime.put_env(:bridge_for_teams_web, :public_base_url, "https://teams.example.test/")
    SystemsRuntime.delete_env(:bridge_for_teams_web, :bft_cli_artifact_url)

    install_script =
      :get
      |> api("/v1/cli/install.sh", nil)
      |> Map.fetch!(:resp_body)

    installer_path = Path.join(root, "install.sh")
    File.write!(installer_path, install_script)

    home = Path.join(root, "home")
    install_dir = Path.join(root, "bin")
    tmp_dir = Path.join(root, "tmp")
    File.mkdir_p!(home)
    File.mkdir_p!(install_dir)
    File.mkdir_p!(tmp_dir)

    {output, status} =
      System.cmd("sh", [installer_path],
        env: [
          {"HOME", home},
          {"BFT_CLI_INSTALL_DIR", install_dir},
          {"TMPDIR", tmp_dir}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Installing BridgeForTeams bft CLI for #{platform}"
    assert output =~ "[ok] bft installed"

    installed_bft = Path.join(install_dir, "bft")
    assert File.exists?(installed_bft)
    assert {"installed-bft\n", 0} = System.cmd(installed_bft, [])

    config_path = Path.join([home, ".bridge-for-teams", "cli.json"])

    assert %{"api_base_url" => "https://teams.example.test"} =
             config_path |> File.read!() |> Jason.decode!()

    assert Bitwise.band(File.stat!(config_path).mode, 0o777) == 0o600
  end

  test "CLI device login is approved in the dashboard and revoked from the dashboard", %{
    user: user,
    org: org,
    project: project
  } do
    start =
      :post
      |> api("/v1/cli/auth/device", nil, %{"client_name" => "agent laptop"})
      |> json_data()

    device_code = Map.fetch!(start, "device_code")
    user_code = Map.fetch!(start, "user_code")
    assert start["mode"] == "auth_device_start"
    assert start["verification_uri"] =~ "/cli/device-login"
    refute start["verification_uri"] =~ user_code
    assert start["verification_uri_complete"] =~ "/cli/device-login/#{user_code}"

    rejected_device_code =
      api(:get, "/v1/cli/context?org=#{org.slug}&project=#{project.slug}", device_code)

    assert rejected_device_code.status == 401

    pending =
      :post
      |> api("/v1/cli/auth/device/poll", nil, %{"device_code" => device_code})
      |> json_data()

    assert pending["status"] == "pending"
    assert pending["user_code"] == user_code

    approve =
      :post
      |> dashboard_api("/dashboard/api/v1/cli/device-login/#{user_code}/approve", user, %{
        "org_ids" => [org.id]
      })
      |> json_data()

    assert approve["request"]["status"] == "approved"
    assert approve["request"]["client_name"] == "agent laptop"

    approved =
      :post
      |> api("/v1/cli/auth/device/poll", nil, %{"device_code" => device_code})
      |> json_data()

    cli_token = Map.fetch!(approved, "token")
    assert approved["status"] == "approved"
    assert approved["token_type"] == "bearer"
    assert Enum.map(approved["granted_orgs"], & &1["id"]) == [org.id]

    context =
      api(:get, "/v1/cli/context?org=#{org.slug}&project=#{project.slug}", cli_token)
      |> json_data()

    assert context["context"]["org"]["id"] == org.id
    assert context["context"]["project"]["id"] == project.id

    sessions =
      :get
      |> dashboard_api("/dashboard/cli/sessions", user, %{})
      |> json_data()
      |> Map.fetch!("sessions")

    assert %{"id" => session_id, "client_name" => "agent laptop"} =
             Enum.find(sessions, &(&1["client_name"] == "agent laptop"))

    revoke =
      :delete
      |> dashboard_api("/dashboard/cli/sessions/#{session_id}", user, %{})
      |> json_data()

    assert revoke["revoked"] == true

    rejected_after_revoke =
      api(:get, "/v1/cli/context?org=#{org.slug}&project=#{project.slug}", cli_token)

    assert rejected_after_revoke.status == 401

    consumed =
      :post
      |> api("/v1/cli/auth/device/poll", nil, %{"device_code" => device_code})
      |> json_data()

    assert consumed["status"] == "consumed"
    refute Map.has_key?(consumed, "token")
  end

  test "CLI device login rejects orgs the approver does not manage", %{user: user, org: org} do
    %{org: other_org} = org_with_owner_fixture(org: %{slug: "other-approval"})

    start =
      :post
      |> api("/v1/cli/auth/device", nil, %{"client_name" => "agent laptop"})
      |> json_data()

    user_code = Map.fetch!(start, "user_code")

    approve_conn =
      :post
      |> dashboard_api("/dashboard/api/v1/cli/device-login/#{user_code}/approve", user, %{
        "org_ids" => [org.id, other_org.id]
      })

    assert approve_conn.status == 403
    assert %{"error" => %{"code" => "forbidden"}} = Jason.decode!(approve_conn.resp_body)
  end

  test "CLI session can add and revoke one organization grant", %{
    user: user,
    org: org,
    project: project,
    token: token
  } do
    {:ok, other_org} = Orgs.create_org(%{"name" => "Other Granted", "slug" => "other-granted"})
    {:ok, _membership} = Memberships.put_org_member(other_org.id, user.id, "owner")

    {:ok, other_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(other_org.id, %{
        "name" => "Other Project",
        "slug" => "other-project"
      })

    missing_grant =
      api(:get, "/v1/cli/context?org=#{other_org.slug}&project=#{other_project.slug}", token)

    assert missing_grant.status == 403

    start =
      :post
      |> api("/v1/cli/auth/orgs/device", token, %{"client_name" => "agent laptop"})
      |> json_data()

    device_code = Map.fetch!(start, "device_code")
    user_code = Map.fetch!(start, "user_code")

    approve =
      :post
      |> dashboard_api("/dashboard/api/v1/cli/device-login/#{user_code}/approve", user, %{
        "org_ids" => [other_org.id]
      })
      |> json_data()

    assert approve["request"]["status"] == "approved"

    granted =
      :post
      |> api("/v1/cli/auth/orgs/device/poll", token, %{"device_code" => device_code})
      |> json_data()

    assert granted["status"] == "approved"
    assert Enum.map(granted["granted_orgs"], & &1["id"]) == [org.id, other_org.id]

    added_context =
      api(:get, "/v1/cli/context?org=#{other_org.slug}&project=#{other_project.slug}", token)
      |> json_data()

    assert added_context["context"]["org"]["id"] == other_org.id

    revoked =
      :post
      |> api("/v1/cli/auth/orgs/revoke", token, %{"org" => other_org.slug})
      |> json_data()

    assert revoked["revoked"] == true
    assert Enum.map(revoked["granted_orgs"], & &1["id"]) == [org.id]

    rejected_after_revoke =
      api(:get, "/v1/cli/context?org=#{other_org.slug}&project=#{other_project.slug}", token)

    assert rejected_after_revoke.status == 403

    original_context =
      api(:get, "/v1/cli/context?org=#{org.slug}&project=#{project.slug}", token)
      |> json_data()

    assert original_context["context"]["org"]["id"] == org.id
  end

  test "ordinary org members cannot manage CLI device login requests", %{org: org} do
    member = user_fixture(email: "cli-device-member@example.com")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")

    start =
      :post
      |> api("/v1/cli/auth/device", nil, %{"client_name" => "agent laptop"})
      |> json_data()

    device_code = Map.fetch!(start, "device_code")
    user_code = Map.fetch!(start, "user_code")

    status_conn =
      :get
      |> dashboard_api("/dashboard/api/v1/cli/device-login/#{user_code}", member, %{})

    assert status_conn.status == 403

    approve_conn =
      :post
      |> dashboard_api("/dashboard/api/v1/cli/device-login/#{user_code}/approve", member, %{})

    assert approve_conn.status == 403

    cancel_conn =
      :post
      |> dashboard_api("/dashboard/api/v1/cli/device-login/#{user_code}/deny", member, %{})

    assert cancel_conn.status == 403

    poll =
      :post
      |> api("/v1/cli/auth/device/poll", nil, %{"device_code" => device_code})
      |> json_data()

    assert poll["status"] == "pending"
    refute Map.has_key?(poll, "token")
  end

  defmodule LarkSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_im_connects(_group_id, _provider),
      do: {:ok, SystemsRuntime.get_env(:bridge_for_teams_web, :cli_test_lark_connects, [])}

    def create_lark_im_connect(tenant_id, group_id, attrs) do
      connect = %{
        "connect_id" => "imc1_lark",
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "provider" => "lark",
        "app_id" => attrs["app_id"],
        "app_name" => "Acme helper",
        "status" => "connected",
        "app_secret_configured" => true,
        "verification_token_configured" => is_binary(attrs["verification_token"]),
        "webhook_url" => "https://salix.example.test/v1/im/lark/events?app_id=#{attrs["app_id"]}"
      }

      SystemsRuntime.put_env(:bridge_for_teams_web, :cli_test_lark_connects, [connect])
      {:ok, connect}
    end

    def lark_callback_preflight_for_connect(%{"connect_id" => "imc1_lark"}),
      do: {:error, :token_mismatch}

    def lark_bot_identity(%{"connect_id" => "imc1_lark"}),
      do: {:ok, %{"open_id_fingerprint" => "0123456789ab"}}
  end

  test "a project admin connects a Lark app and reads it back, without a secret", %{
    org: org,
    project: project,
    token: token
  } do
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, LarkSalixClient)
    on_exit(fn -> SystemsRuntime.delete_env(:bridge_for_teams_web, :cli_test_lark_connects) end)
    scope = %{"org" => org.slug, "project" => project.slug}
    app = Map.merge(scope, %{"app_id" => "cli_acme", "app_secret" => "fake-lark-app-secret"})

    # Lark verifies a callback by one of the two values, so one is required.
    missing = api(:post, "/v1/cli/lark/connect", token, app)
    assert missing.status == 400

    assert %{"error" => %{"code" => "missing_lark_credentials", "details" => details}} =
             Jason.decode!(missing.resp_body)

    assert details["fields"] == ["verification_token"]

    conn =
      api(
        :post,
        "/v1/cli/lark/connect",
        token,
        Map.put(app, "verification_token", "fake-lark-token")
      )

    assert conn.status == 200
    refute conn.resp_body =~ "fake-lark-app-secret"
    refute conn.resp_body =~ "fake-lark-token"
    data = json_data(conn)
    assert data["mode"] == "lark_connect"
    assert data["action"] == "created"
    assert data["connect"]["connect_id"] == "imc1_lark"
    assert data["callback_url"] == "https://salix.example.test/v1/im/lark/events?app_id=cli_acme"
    assert Enum.any?(data["manual_checklist"], &String.contains?(&1, "im.message.receive_v1"))

    status =
      :get
      |> api("/v1/cli/lark/status?org=#{org.slug}&project=#{project.slug}", token)
      |> json_data()

    assert status["mode"] == "lark_status"
    assert [%{"connect_id" => "imc1_lark", "callback_url" => url}] = status["connects"]
    assert url =~ "/v1/im/lark/events?app_id=cli_acme"
  end

  test "Lark checks run for a project member and name the failed gate", %{
    org: org,
    project: project,
    token: token
  } do
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, LarkSalixClient)
    on_exit(fn -> SystemsRuntime.delete_env(:bridge_for_teams_web, :cli_test_lark_connects) end)
    scope = %{"org" => org.slug, "project" => project.slug}

    # No Lark app yet: every gate waits for the connect.
    data = :post |> api("/v1/cli/lark/checks", token, scope) |> json_data()
    assert data["mode"] == "lark_checks"
    assert data["checks"]["surface"] == "lark_bot"
    assert data["checks"]["connect_ref"] == nil
    assert Enum.all?(data["checks"]["gates"], &(&1["reason_class"] == "not_connected"))

    api(
      :post,
      "/v1/cli/lark/connect",
      token,
      Map.merge(scope, %{
        "app_id" => "cli_acme",
        "app_secret" => "fake-lark-app-secret",
        "verification_token" => "fake-lark-token"
      })
    )

    conn = api(:post, "/v1/cli/lark/checks", token, Map.put(scope, "connect_id", "imc1_lark"))
    assert conn.status == 200
    refute conn.resp_body =~ "fake-lark"
    checks = json_data(conn)["checks"]
    assert checks["connect_ref"] == "imc1_lark"
    gates = Map.new(checks["gates"], &{&1["gate_id"], &1})

    assert %{"status" => "fail", "reason_class" => "token_mismatch", "next_action" => next} =
             gates["bot.callback"]

    assert next =~ "Verification Token mismatch"
    assert gates["bot.credentials"]["reason_class"] == "validated_on_save"

    missing = api(:post, "/v1/cli/lark/checks", token, Map.put(scope, "connect_id", "imc1_none"))
    assert missing.status == 404
    assert %{"error" => %{"code" => "connect_not_found"}} = Jason.decode!(missing.resp_body)
  end

  test "Lark scopes are the batch-import JSON of the Lark Developer Console", %{token: token} do
    data = :get |> api("/v1/cli/lark/scopes", token) |> json_data()

    assert data["mode"] == "lark_scopes"
    assert %{"scopes" => %{"tenant" => tenant, "user" => user}} = data["batch_import_payload"]
    assert tenant == data["required_scopes"]
    assert "vc:meeting.search:read" in user
    assert "im:message:send_as_bot" in data["required_scopes"]
    assert data["import_path"] =~ "Permissions & Scopes"
  end

  defmodule QQSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def list_group_im_connects(_group_id, _provider),
      do: {:ok, SystemsRuntime.get_env(:bridge_for_teams_web, :cli_test_qq_connects, [])}

    def create_qq_im_connect(_tenant_id, group_id, %{"app_secret" => "wrong-secret"}),
      do: {:error, {:bad_request, "QQ credential check failed for #{group_id}"}}

    def create_qq_im_connect(tenant_id, group_id, attrs) do
      connect = %{
        "connect_id" => "imc1_qq",
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "provider" => "qq",
        "app_id" => attrs["app_id"],
        "bot_username" => "Acme helper",
        "status" => "connected",
        "app_secret_configured" => true,
        "webhook_url" => "https://salix.example.test/v1/im/qq/events?app_id=#{attrs["app_id"]}"
      }

      SystemsRuntime.put_env(:bridge_for_teams_web, :cli_test_qq_connects, [connect])
      {:ok, connect}
    end

    def update_qq_im_connect(_tenant_id, _group_id, _connect_id, %{
          "command_menu" => [%{"name" => "clear"}]
        }),
        do: {:error, {:bad_request, "clear is a control command and cannot be a menu item"}}

    def update_qq_im_connect(_tenant_id, _group_id, connect_id, %{"command_menu" => items}) do
      [%{"connect_id" => ^connect_id} = connect] =
        SystemsRuntime.get_env(:bridge_for_teams_web, :cli_test_qq_connects, [])

      connect =
        Map.merge(connect, %{
          "command_menu" => items,
          "command_menu_sync" => %{"private" => "synced", "group" => "synced"}
        })

      SystemsRuntime.put_env(:bridge_for_teams_web, :cli_test_qq_connects, [connect])
      {:ok, connect}
    end
  end

  test "a project admin connects a QQ bot and reads it back, without the secret", %{
    org: org,
    project: project,
    token: token
  } do
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, QQSalixClient)
    on_exit(fn -> SystemsRuntime.delete_env(:bridge_for_teams_web, :cli_test_qq_connects) end)
    scope = %{"org" => org.slug, "project" => project.slug}

    missing = api(:post, "/v1/cli/qq/connect", token, Map.put(scope, "app_id", "1900012345"))
    assert missing.status == 400

    assert %{"error" => %{"code" => "missing_qq_credentials", "details" => details}} =
             Jason.decode!(missing.resp_body)

    assert details["fields"] == ["app_secret"]

    rejected =
      api(
        :post,
        "/v1/cli/qq/connect",
        token,
        Map.merge(scope, %{"app_id" => "1900012345", "app_secret" => "wrong-secret"})
      )

    assert rejected.status >= 400
    refute rejected.resp_body =~ "wrong-secret"

    conn =
      api(
        :post,
        "/v1/cli/qq/connect",
        token,
        Map.merge(scope, %{"app_id" => "1900012345", "app_secret" => "fake-qq-app-secret"})
      )

    assert conn.status == 200
    refute conn.resp_body =~ "fake-qq-app-secret"
    data = json_data(conn)
    assert data["mode"] == "qq_connect"
    assert data["action"] == "created"
    assert data["connect"]["connect_id"] == "imc1_qq"
    assert data["callback_url"] == "https://salix.example.test/v1/im/qq/events?app_id=1900012345"
    assert Enum.any?(data["manual_checklist"], &String.contains?(&1, "Webhook"))

    status =
      :get
      |> api("/v1/cli/qq/status?org=#{org.slug}&project=#{project.slug}", token)
      |> json_data()

    assert status["mode"] == "qq_status"

    assert [%{"connect_id" => "imc1_qq", "bot_username" => "Acme helper", "callback_url" => url}] =
             status["connects"]

    assert url =~ "/v1/im/qq/events?app_id=1900012345"

    # The command menu of the project's only bot is replaced and read back.
    item = %{"name" => "周报", "description" => "生成本周周报", "scope" => "group"}

    menu =
      :post
      |> api("/v1/cli/qq/menu", token, Map.put(scope, "items", [item]))
      |> json_data()

    assert menu["mode"] == "qq_menu"
    assert menu["connect"]["command_menu"] == [item]

    assert [%{"command_menu" => [^item]}] =
             :get
             |> api("/v1/cli/qq/status?org=#{org.slug}&project=#{project.slug}", token)
             |> json_data()
             |> Map.fetch!("connects")

    refused =
      api(:post, "/v1/cli/qq/menu", token, Map.put(scope, "items", [%{"name" => "clear"}]))

    assert %{
             "error" => %{
               "code" => "invalid_qq_menu",
               "message" => "clear is a control command and cannot be a menu item"
             }
           } = Jason.decode!(refused.resp_body)

    assert refused.status == 400

    other_bot =
      api(:post, "/v1/cli/qq/menu", token, Map.merge(scope, %{"items" => [], "app_id" => "1"}))

    assert %{"error" => %{"code" => "qq_bot_not_found"}} = Jason.decode!(other_bot.resp_body)
  end

  test "Slack setup is a read-only project operation", %{org: org, project: project} do
    member = user_fixture(email: "slack-setup-reader@example.com")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _project_membership} = Memberships.put_project_member(project.id, member.id, "user")

    {:ok, %{token: member_token, session: member_session}} =
      Sessions.create(member, device: "bft-cli")

    {:ok, _grants} = CLILogin.grant_cli_session_orgs(member_session, [org.id], member.id)

    conn =
      api(:post, "/v1/cli/slack/setup", member_token, %{
        "org" => org.slug,
        "project" => project.slug,
        "app_name" => "Project Slack"
      })

    assert conn.status == 200
    data = json_data(conn)
    assert data["mode"] == "slack_setup"
    assert data["project"]["id"] == project.id
    assert data["manifest"]["display_information"]["name"] == "Project Slack"

    assert get_in(data, ["manifest", "features", "app_home"]) == %{
             "home_tab_enabled" => true,
             "messages_tab_enabled" => true,
             "messages_tab_read_only_enabled" => false
           }

    assert data["slack_apps_url"] == "https://api.slack.com/apps"
    assert data["interactions_url"] == "https://salix.example.test/v1/im/slack/interactions"
    assert data["create_connect_command"] =~ "bft slack connects create"
    refute data["create_connect_command"] =~ "--inbound-agent"
    assert data["create_task_connect_command"] =~ "bft slack connects create"
    assert data["create_task_connect_command"] =~ "--tasks"
    assert Enum.any?(data["manual_checklist"], &String.contains?(&1, "private target channels"))
    assert Enum.any?(data["manual_checklist"], &String.contains?(&1, "Interactivity"))

    assert Enum.any?(
             data["manual_checklist"],
             &String.contains?(&1, "automatically joins newly created public channels")
           )

    assert Enum.any?(
             data["manual_checklist"],
             &String.contains?(&1, "join an existing public channel on request")
           )

    guide_by_field = Map.new(data["credential_guide"], &{&1["field"], &1})
    assert guide_by_field["app_id"]["flag"] == "--app-id"
    assert guide_by_field["app_id"]["source"] =~ "App ID"
    assert guide_by_field["client_id"]["flag"] == "--client-id"
    assert guide_by_field["client_secret"]["flag"] == "--client-secret-env"
    assert guide_by_field["signing_secret"]["source"] =~ "Signing Secret"
    assert guide_by_field["inbound_tasks"]["flag"] == "--tasks"
    assert guide_by_field["inbound_tasks"]["source"] =~ "Optional"
    assert guide_by_field["inbound_tasks"]["source"] =~ "Router"
  end

  test "meeting calendar status returns configuration evidence and bounded projected events", %{
    org: org,
    project: project,
    token: token
  } do
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, CalendarStatusSalixClient)

    {:ok, router} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    Process.put(:calendar_router_agent_id, router.salix_agent_id)

    conn =
      api(
        :get,
        "/v1/cli/meetings/calendar/status?org=#{org.slug}&project=#{project.slug}&connect_id=conn-calendar&limit=7",
        token
      )

    assert conn.status == 200
    data = json_data(conn)
    assert data["mode"] == "meeting_calendar_status"
    assert data["checks"]["gates"] |> hd() |> Map.fetch!("status") == "ok"

    assert data["checks"]["gates"] |> hd() |> get_in(["evidence", "watched_calendars"]) == [
             "Comma Event"
           ]

    assert data["calendar"]["health"] == "ok"
    assert data["calendar"]["summary"]["planned_count"] == 1
    assert [event] = data["calendar"]["events"]

    assert event["title"] ==
             "Agenda https://docs.example.test/brief,Meet:[REDACTED_GOOGLE_MEET_URL]"

    rendered = inspect(data)
    refute rendered =~ "abc-defg-hij"
    refute rendered =~ "PRIVATE_PREPARATION_BASELINE"
    refute rendered =~ "PRIVATE_AUTOJOIN_ERROR"
    refute rendered =~ "agt-private-router"
    refute rendered =~ "agt-private-policy-router"
    refute rendered =~ "PRIVATE_POLICY_GATE_CANARY"
    refute rendered =~ "private-room"

    assert Process.get(:calendar_policy_status_agent_id) == router.salix_agent_id

    assert Process.get(:calendar_status_params) == %{
             "agent_id" => router.salix_agent_id,
             "connect_id" => "conn-calendar",
             "limit" => 7
           }
  end

  test "meeting replay is an authenticated idempotent no-delivery CLI operation", %{
    org: org,
    project: project,
    token: token
  } do
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, MeetingReplaySalixClient)

    body = %{
      "org" => org.slug,
      "project" => project.slug,
      "meeting_id" => "meeting-cli-1",
      "request_id" => "replay-cli-1",
      "run_model" => false
    }

    data = api(:post, "/v1/cli/meetings/replay", token, body) |> json_data()
    assert data["mode"] == "meeting_summary_replay"
    assert data["replay"]["status"] == "ok"
    assert data["replay"]["passed"]
    refute data["replay"]["delivery_writes"]

    assert Process.get(:meeting_replay_request) ==
             {project.salix_group_id, "meeting-cli-1", [run_model: false]}

    Process.delete(:meeting_replay_request)
    replayed = api(:post, "/v1/cli/meetings/replay", token, body) |> json_data()
    assert replayed["replay"]["replayed"]
    assert is_nil(Process.get(:meeting_replay_request))

    unauthenticated = api(:post, "/v1/cli/meetings/replay", nil, body)
    assert unauthenticated.status == 401
  end

  test "meeting model replay requires confirmation at the API boundary", %{
    org: org,
    project: project,
    token: token
  } do
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, MeetingReplaySalixClient)

    body = %{
      "org" => org.slug,
      "project" => project.slug,
      "meeting_id" => "meeting-cli-confirmed",
      "request_id" => "replay-cli-confirmed",
      "run_model" => true
    }

    rejected = api(:post, "/v1/cli/meetings/replay", token, body)
    assert rejected.status == 400

    assert Jason.decode!(rejected.resp_body)["error"]["code"] ==
             "replay_confirmation_required"

    assert is_nil(Process.get(:meeting_replay_request))

    confirmed =
      api(
        :post,
        "/v1/cli/meetings/replay",
        token,
        Map.put(body, "confirm_model_replay", true)
      )
      |> json_data()

    assert confirmed["replay"]["status"] == "ok"

    assert Process.get(:meeting_replay_request) ==
             {project.salix_group_id, "meeting-cli-confirmed", [run_model: true]}
  end

  test "org and project lists are scoped to the current user", %{
    org: org,
    project: project,
    token: token,
    user: user
  } do
    {:ok, other_org} = Orgs.create_org(%{"name" => "Other", "slug" => "other"})

    {:ok, _other_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(other_org.id, %{
        "name" => "Other Project"
      })

    {:ok, _other_membership} = Memberships.put_org_member(other_org.id, user.id, "owner")

    orgs = api(:get, "/v1/cli/orgs", token) |> json_data()
    assert Enum.map(orgs["orgs"], & &1["id"]) == [org.id]

    projects = api(:get, "/v1/cli/projects?org=#{org.slug}", token) |> json_data()
    assert Enum.map(projects["projects"], & &1["id"]) == [project.id]

    hidden = api(:get, "/v1/cli/projects?org=#{other_org.slug}", token)
    assert hidden.status == 403
  end

  test "conversation CLI endpoints expose the dashboard read and trace views", %{
    org: org,
    project: project,
    token: token,
    user: user
  } do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :salix_client,
      ConversationSalixClient
    )

    list =
      api(:get, "/v1/cli/conversations?org=#{org.slug}&project=#{project.slug}&limit=7", token)
      |> json_data()

    assert list["mode"] == "conversations_list"
    assert list["org"]["id"] == org.id
    assert list["project"]["id"] == project.id

    assert [%{"conversation_id" => "task-cli-1", "kind" => "work_session"}] =
             list["conversations"]

    assert Process.get(:conversation_list_limit) == 7

    show =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1?org=#{org.slug}&project=#{project.slug}&message_limit=3",
        token
      )
      |> json_data()

    assert show["mode"] == "conversation_show"
    assert show["conversation"]["conversation_id"] == "task-cli-1"
    assert show["conversation"]["participants"] == show["participants"]
    assert Enum.map(show["participants"], & &1["participant_id"]) == ["delegator", "worker"]
    assert Process.get(:conversation_participants_read) == "task-cli-1"

    assert Enum.map(show["participants"], &get_in(&1, ["payload", "session_id"])) == [
             "router-payload-session",
             "im-task-cli-1"
           ]

    assert Enum.map(show["messages"], & &1["message_id"]) == ["msg-router", "msg-worker"]
    assert Process.get(:conversation_messages_limit) == 3

    messages =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1/messages?org=#{org.slug}&project=#{project.slug}&limit=4",
        token
      )
      |> json_data()

    assert messages["mode"] == "conversation_messages"
    assert Enum.map(messages["messages"], & &1["participant_id"]) == ["delegator", "worker"]
    assert Process.get(:conversation_messages_limit) == 4

    sent =
      api(
        :post,
        "/v1/cli/conversations/task-cli-1/messages",
        token,
        %{
          "org" => org.slug,
          "project" => project.slug,
          "text" => "  run fresh Pi and Codex checks  ",
          "request_id" => "cli-smoke-1"
        }
      )
      |> json_data()

    assert sent["mode"] == "conversation_send"
    assert sent["message"]["message_id"] == "msg-cli-send"

    assert %{
             "actor_type" => "provider_user",
             "user_id" => user_id,
             "participant_id" => "ptp1_2094170633557508096",
             "content" => [%{"type" => "text", "text" => "run fresh Pi and Codex checks"}],
             "metadata" => %{
               "request_id" => "cli-smoke-1",
               "source" => "bridge_for_teams_dashboard"
             }
           } = Process.get(:conversation_send_attrs)

    assert user_id == user.id

    status =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1/participants/worker/status?org=#{org.slug}&project=#{project.slug}",
        token
      )
      |> json_data()

    assert status["mode"] == "conversation_participant_status"
    assert status["participant_id"] == "worker"
    assert status["status"]["activity"]["kind"] == "running"
    assert status["status"]["activity"]["description"] == "handling task"
    assert Process.get(:conversation_status_participant) == "worker"

    trace =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1/trace?org=#{org.slug}&project=#{project.slug}&participant=%20worker%20&limit=5",
        token
      )
      |> json_data()

    assert trace["mode"] == "conversation_trace"
    assert trace["trace_agent_id"] == "agent-worker"
    assert trace["trace_session_id"] == "im-task-cli-1"
    assert trace["trace_participant_id"] == "worker"
    assert trace["trace"]["token"] == "[REDACTED]"

    assert [%{"method" => "turn/completed", "callback_url" => callback_url}] =
             trace["trace"]["events"]

    assert String.starts_with?(callback_url, "https://example.test/callback?")
    assert callback_url =~ "ok=1"
    assert callback_url =~ "token=%5BREDACTED%5D"
    refute callback_url =~ "secret-token"
    assert Process.get(:conversation_trace_limit) == 5
    assert Process.get(:conversation_trace_target) == {"agent-worker", "im-task-cli-1"}

    router_trace =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1/trace?org=#{org.slug}&project=#{project.slug}&participant=delegator&limit=6",
        token
      )
      |> json_data()

    assert router_trace["trace_agent_id"] == "agent-router"
    assert router_trace["trace_session_id"] == "router-payload-session"
    assert router_trace["trace_participant_id"] == "delegator"
    assert router_trace["trace"]["events"] == [%{"method" => "router/notified"}]
    assert Process.get(:conversation_trace_limit) == 6
    assert Process.get(:conversation_trace_target) == {"agent-router", "router-payload-session"}

    delivery =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1/delivery?org=#{org.slug}&project=#{project.slug}&participant=worker&message=msg-worker&limit=8",
        token
      )
      |> json_data()

    assert delivery["mode"] == "conversation_delivery"
    assert delivery["participant_id"] == "worker"
    assert delivery["message_id"] == "msg-worker"
    assert delivery["delivery"]["participant"]["session_id"] == "im-task-cli-1"

    assert [
             %{
               "message_id" => "msg-worker",
               "participant_agent_id" => "agent-worker",
               "participant_payload" => %{"session_id" => "im-task-cli-1"},
               "status" => "delivered",
               "session" => %{"exists" => true, "status" => "ready"}
             }
           ] = delivery["delivery"]["deliveries"]

    assert delivery["delivery"]["deliveries"] |> hd() |> Map.fetch!("source_user_id") ==
             "[REDACTED]"

    assert delivery["delivery"]["deliveries"] |> hd() |> Map.fetch!("from_user_id") ==
             "[REDACTED]"

    assert delivery["delivery"]["deliveries"] |> hd() |> Map.fetch!("sender_user_id") ==
             "[REDACTED]"

    assert delivery["delivery"]["deliveries"] |> hd() |> Map.fetch!("sender_open_id") ==
             "[REDACTED]"

    assert delivery["delivery"]["deliveries"] |> hd() |> Map.fetch!("sender_union_id") ==
             "[REDACTED]"

    assert Process.get(:conversation_delivery_limit) == 8

    assert Process.get(:conversation_delivery_filter) == [
             participant_id: "worker",
             message_id: "msg-worker"
           ]

    redelivery =
      api(:post, "/v1/cli/conversations/task-cli-1/redeliver", token, %{
        "org" => org.slug,
        "project" => project.slug,
        "participant_id" => "worker",
        "message_id" => "msg-router",
        "request_id" => "recover-cli-1"
      })
      |> json_data()

    assert redelivery["redelivery"] == %{
             "conversation_id" => "task-cli-1",
             "participant_id" => "worker",
             "message_id" => "msg-router",
             "request_id" => "recover-cli-1",
             "delivery_status" => "queued"
           }

    assert Process.get(:conversation_redelivery_attrs) == %{
             "participant_id" => "worker",
             "message_id" => "msg-router",
             "request_id" => "recover-cli-1"
           }
  end

  test "conversation CLI endpoints keep project read visibility scoping", %{
    org: org,
    project: project
  } do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :salix_client,
      ConversationSalixClient
    )

    member = user_fixture(email: "conversation-member@example.com")

    {:ok, %{token: member_token, session: member_session}} =
      Sessions.create(member, device: "bft-cli")

    {:ok, _grants} = CLILogin.grant_cli_session_orgs(member_session, [org.id], member.id)
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")

    conn =
      api(
        :get,
        "/v1/cli/conversations?org=#{org.slug}&project=#{project.slug}&limit=7",
        member_token
      )

    assert conn.status == 404

    assert %{"ok" => false, "error" => %{"code" => "project_not_found"}} =
             Jason.decode!(conn.resp_body)
  end

  test "conversation CLI endpoints reject users outside the org before project resolution", %{
    org: org,
    project: project
  } do
    outsider = user_fixture(email: "conversation-outsider@example.com")

    {:ok, %{token: outsider_token, session: outsider_session}} =
      Sessions.create(outsider, device: "bft-cli")

    {:ok, _grants} = CLILogin.grant_cli_session_orgs(outsider_session, [org.id], outsider.id)

    conn =
      api(
        :get,
        "/v1/cli/conversations?org=#{org.slug}&project=#{project.slug}&limit=7",
        outsider_token
      )

    assert conn.status == 403

    assert %{"ok" => false, "error" => %{"code" => "forbidden"}} =
             Jason.decode!(conn.resp_body)
  end

  test "Feishu app upsert is admin-only and redacts submitted secrets", %{
    org: org,
    project: project,
    user: user,
    token: token
  } do
    secret = "super-secret-value"
    request_id = "req-cli-feishu-upsert"

    body = %{
      "org" => org.slug,
      "attrs" => %{
        "display_name" => "CLI App",
        "app_id" => "cli_app",
        "bot_enabled" => true,
        "app_secret" => secret,
        "verification_token" => "verify-secret"
      }
    }

    upsert =
      :post
      |> build_conn("/v1/cli/feishu/apps", Jason.encode!(body))
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("x-request-id", request_id)
      |> DashboardEndpoint.call([])

    assert upsert.status == 200
    refute upsert.resp_body =~ secret
    assert data = json_data(upsert)
    assert data["binding"]["app_id"] == "cli_app"
    assert data["binding"]["bot_enabled"] == true
    assert data["binding"]["app_secret_configured"] == true
    assert data["redaction"]["secrets_printed"] == false

    assert [audit] = Observability.list_audit_logs(org.id, action: "feishu_app_binding.created")
    assert audit.actor_user_id == user.id
    assert audit.actor_label == user.email
    assert audit.request_id == request_id
    assert audit.resource_id == data["binding"]["id"]
    assert audit.metadata["bot_enabled"] == "true"
    refute inspect(audit.metadata) =~ secret

    selected =
      api(:get, "/v1/cli/feishu/apps/selected?org=#{org.slug}&app_id=cli_app", token)
      |> json_data()

    assert selected["selected_app"]["app_id"] == "cli_app"
    assert selected["selected_app"]["binding"]["app_secret_configured"] == true

    setup =
      api(:post, "/v1/cli/feishu/setup", token, %{
        "org" => org.slug,
        "project" => project.slug,
        "app_id" => "cli_app"
      })
      |> json_data()

    assert setup["required_scopes"] == FeishuScopes.required_scope_ids(:bot)
    assert setup["batch_import_payload"] == FeishuScopes.import_payload(:bot)

    assert Enum.map(setup["optional_scopes"], & &1["scope"]) ==
             Enum.map(FeishuScopes.optional_bot_scopes(), & &1.scope)
  end

  test "Feishu app upsert rejects non-admin org members", %{org: org} do
    member = user_fixture(email: "member@example.com")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")

    {:ok, %{token: member_token, session: member_session}} =
      Sessions.create(member, device: "bft-cli")

    {:ok, _grants} = CLILogin.grant_cli_session_orgs(member_session, [org.id], member.id)

    conn =
      api(:post, "/v1/cli/feishu/apps", member_token, %{
        "org" => org.slug,
        "attrs" => %{"app_id" => "member_app", "bot_enabled" => true}
      })

    assert conn.status == 403
    assert %{"ok" => false, "error" => %{"code" => "forbidden"}} = Jason.decode!(conn.resp_body)
  end

  test "SSO checks report Feishu config and current admin login evidence", %{
    user: user,
    org: org,
    token: token
  } do
    {:ok, _sso} =
      Orgs.upsert_sso_connection(org.id, %{
        "provider" => "feishu",
        "client_id" => "cli_app",
        "client_secret" => "super-secret-sso",
        "provider_config" => %{"scope" => "contact:user.employee_id:readonly"}
      })

    %OrgSsoIdentity{}
    |> OrgSsoIdentity.changeset(%{
      org_id: org.id,
      user_id: user.id,
      provider: "feishu",
      provider_subject_type: "user_id",
      provider_subject: "ou_admin",
      display_name: "Admin"
    })
    |> Repo.insert!()

    conn = api(:post, "/v1/cli/sso/checks", token, %{"org" => org.slug})
    refute conn.resp_body =~ "super-secret-sso"

    data = json_data(conn)
    gates = Map.new(data["checks"]["gates"], &{&1["gate_id"], &1})
    assert gates["sso.connection"]["status"] == "ok"
    assert gates["sso.credentials"]["status"] == "ok"
    assert gates["sso.redirect_uri"]["evidence"]["redirect_uri"] =~ "/auth/callback"
    assert gates["sso.authorize_url"]["status"] == "ok"
    assert data["admin_login"]["status"] == "ok"
    assert data["admin_login"]["evidence"]["feishu_sso_identity_seen"] == true
  end

  test "SSO checks of a Lark org report the Lark connection and the admin's Lark sign-in", %{
    user: user,
    org: org,
    token: token
  } do
    {:ok, _sso} =
      Orgs.upsert_sso_connection(org.id, %{
        "provider" => "lark",
        "client_id" => "cli_lark_app",
        "client_secret" => "super-secret-lark"
      })

    conn = api(:post, "/v1/cli/sso/checks", token, %{"org" => org.slug})
    refute conn.resp_body =~ "super-secret-lark"

    data = json_data(conn)
    assert data["checks"]["surface"] == "sso"
    gates = Map.new(data["checks"]["gates"], &{&1["gate_id"], &1})

    assert Enum.map(data["checks"]["gates"], & &1["gate_id"]) ==
             ~w(sso.connection sso.credentials sso.redirect_uri sso.authorize_url)

    assert gates["sso.connection"]["status"] == "ok"
    assert gates["sso.connection"]["evidence"]["connection"]["provider"] == "lark"
    assert gates["sso.credentials"]["label"] == "Lark credentials valid"
    assert gates["sso.credentials"]["status"] == "skipped"
    assert gates["sso.redirect_uri"]["evidence"]["redirect_uri"] =~ "/auth/callback"
    assert gates["sso.authorize_url"]["status"] == "ok"
    assert gates["sso.authorize_url"]["evidence"]["authorize_url_host"] == "lark.test"
    assert data["admin_login"]["status"] == "needs_manual"
    assert data["admin_login"]["evidence"]["lark_sso_identity_seen"] == false

    %OrgSsoIdentity{}
    |> OrgSsoIdentity.changeset(%{
      org_id: org.id,
      user_id: user.id,
      provider: "lark",
      provider_subject_type: "union_id",
      provider_subject: "on_admin"
    })
    |> Repo.insert!()

    conn = api(:post, "/v1/cli/sso/checks", token, %{"org" => org.slug})
    assert json_data(conn)["admin_login"]["status"] == "ok"
  end

  test "runner list exposes heartbeat summary", %{org: org, token: token} do
    {:ok, provisioner} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => "mini-1",
        "name" => "Office Mac mini",
        "status" => "online",
        "last_seen_at" => SystemsClock.utc_now(),
        "version" => "worker-0.1.0",
        "capabilities" => %{
          "component_versions" => %{"salix-connect" => "2026.06"}
        }
      })

    data =
      api(:get, "/v1/orgs/#{org.slug}/runners", token)
      |> json_data()

    assert data["summary"]["ready"] == true
    assert data["summary"]["online"] == 1
    assert data["summary"]["update_available"] == false
    assert data["summary"]["update_available_count"] == 0
    assert data["release"]["error"] == "server_release_unavailable"
    assert data["next_action"] =~ "continue to project device creation"
    [provisioner] = data["runners"]
    assert provisioner["name"] == "Office Mac mini"
    assert provisioner["effective_status"] == "online"
    assert provisioner["version"] == "worker-0.1.0"
    assert provisioner["component_versions"] == "salix-connect=2026.06"
    assert provisioner["update_available"] == false
  end

  defp api(method, path, token, body \\ nil) do
    body = if is_nil(body), do: nil, else: Jason.encode!(body)

    method
    |> build_conn(path, body)
    |> put_req_header("accept", "application/json")
    |> maybe_put_json_content_type(body)
    |> maybe_put_auth(token)
    |> DashboardEndpoint.call([])
  end

  defp dashboard_api(method, path, user, body) do
    method
    |> build_conn(path, Jason.encode!(body))
    |> log_in_user(user)
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> DashboardEndpoint.call([])
  end

  defp maybe_put_json_content_type(conn, nil), do: conn

  defp maybe_put_json_content_type(conn, _body),
    do: put_req_header(conn, "content-type", "application/json")

  defp maybe_put_auth(conn, nil), do: conn
  defp maybe_put_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp json_data(conn) do
    assert conn.status == 200
    assert %{"ok" => true, "data" => data} = Jason.decode!(conn.resp_body)
    data
  end

  defp restore_web_env(key, nil), do: SystemsRuntime.delete_env(:bridge_for_teams_web, key)
  defp restore_web_env(key, value), do: SystemsRuntime.put_env(:bridge_for_teams_web, key, value)

  defp local_platform do
    {os, 0} = System.cmd("uname", ["-s"])
    {arch, 0} = System.cmd("uname", ["-m"])

    os =
      case os |> String.trim() |> String.downcase() do
        "darwin" -> "darwin"
        "linux" -> "linux"
        other -> flunk("unsupported test OS: #{other}")
      end

    arch =
      case String.trim(arch) do
        value when value in ["arm64", "aarch64"] -> "arm64"
        value when value in ["x86_64", "amd64"] -> "amd64"
        other -> flunk("unsupported test arch: #{other}")
      end

    "#{os}-#{arch}"
  end
end
