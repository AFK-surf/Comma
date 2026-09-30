defmodule BridgeForTeamsWeb.CLIControllerTest do
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
               "runtime_kind" => "external"
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
        |> Application.fetch_env!(:bft_cli_artifact_test_root)
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
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    Application.put_env(:bridge_for_teams_core, :salix_client, FeishuTenantAppClient)

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
        "slug" => "other-runner-org-#{System.unique_integer([:positive])}"
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

  test "public bft CLI installer fails honestly when no artifact is configured" do
    previous_base = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_artifact = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    Application.delete_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    Application.delete_env(:bridge_for_teams_web, :bft_cli_artifact_url)

    on_exit(fn ->
      restore_web_env(:bft_cli_artifact_base_url, previous_base)
      restore_web_env(:bft_cli_artifact_url, previous_artifact)
    end)

    conn = api(:get, "/v1/cli/install.sh", nil)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/x-shellscript; charset=utf-8"]
    assert conn.resp_body =~ "bft CLI installer is not configured"
    assert conn.resp_body =~ "exit 1"
  end

  test "public bft CLI installer downloads the configured artifact" do
    previous_base = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_artifact = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    previous_sha = Application.get_env(:bridge_for_teams_web, :bft_cli_sha256)
    previous_public_base_url = Application.get_env(:bridge_for_teams_web, :public_base_url)

    Application.delete_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)

    Application.put_env(
      :bridge_for_teams_web,
      :bft_cli_artifact_url,
      "https://r2.example.test/bft"
    )

    Application.put_env(:bridge_for_teams_web, :bft_cli_sha256, "abc123")
    Application.put_env(:bridge_for_teams_web, :public_base_url, "https://teams.example.test/")

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

  test "public bft CLI installer fails closed when legacy artifact checksum is not configured" do
    previous_base = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_artifact = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    previous_sha = Application.get_env(:bridge_for_teams_web, :bft_cli_sha256)

    Application.delete_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)

    Application.put_env(
      :bridge_for_teams_web,
      :bft_cli_artifact_url,
      "https://r2.example.test/bft"
    )

    Application.delete_env(:bridge_for_teams_web, :bft_cli_sha256)

    on_exit(fn ->
      restore_web_env(:bft_cli_artifact_base_url, previous_base)
      restore_web_env(:bft_cli_artifact_url, previous_artifact)
      restore_web_env(:bft_cli_sha256, previous_sha)
    end)

    conn = api(:get, "/v1/cli/install.sh", nil)

    assert conn.status == 200
    assert conn.resp_body =~ "BFT CLI checksum is not configured on this deployment"
    refute conn.resp_body =~ "skipping sha256 verification"
  end

  test "public bft CLI installer can resolve platform-specific Go artifacts" do
    previous_base = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_release = Application.get_env(:bridge_for_teams_web, :bft_cli_release_id)
    previous_artifact = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    previous_public_base_url = Application.get_env(:bridge_for_teams_web, :public_base_url)

    Application.put_env(
      :bridge_for_teams_web,
      :bft_cli_artifact_base_url,
      "https://r2.example.test/bft-cli"
    )

    Application.put_env(:bridge_for_teams_web, :bft_cli_release_id, "bft-cli-20260623")
    Application.put_env(:bridge_for_teams_web, :public_base_url, "https://teams.example.test/")
    Application.delete_env(:bridge_for_teams_web, :bft_cli_artifact_url)

    on_exit(fn ->
      restore_web_env(:bft_cli_artifact_base_url, previous_base)
      restore_web_env(:bft_cli_release_id, previous_release)
      restore_web_env(:bft_cli_artifact_url, previous_artifact)
      restore_web_env(:public_base_url, previous_public_base_url)
    end)

    conn = api(:get, "/v1/cli/install.sh", nil)

    assert conn.status == 200
    assert conn.resp_body =~ "platform=\"$os-$arch\""

    assert conn.resp_body =~
             "artifact_url=\"https://r2.example.test/bft-cli/releases/bft-cli-20260623/$platform/bft\""

    assert conn.resp_body =~ "checksum_url=\"$artifact_url.sha256\""

    assert conn.resp_body =~
             "curl -fsSL \"$checksum_url\" -o \"$checksum_tmp\" || fail \"BFT CLI checksum not found at $checksum_url\""

    assert conn.resp_body =~ "verify_sha256 \"$expected\" \"$tmp\""
    assert conn.resp_body =~ "sha256sum -c -"
    refute conn.resp_body =~ "skipping sha256 verification"
    assert conn.resp_body =~ ~s('"https://teams.example.test"')
    assert conn.resp_body =~ "bft auth login --url https://teams.example.test --output text"
  end

  test "public bft CLI release metadata exposes configured update target" do
    previous_base = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_release = Application.get_env(:bridge_for_teams_web, :bft_cli_release_id)
    previous_artifact = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    previous_public_base_url = Application.get_env(:bridge_for_teams_web, :public_base_url)

    Application.put_env(
      :bridge_for_teams_web,
      :bft_cli_artifact_base_url,
      "https://r2.example.test/bft-cli"
    )

    Application.put_env(:bridge_for_teams_web, :bft_cli_release_id, "bft-cli-20260624")
    Application.put_env(:bridge_for_teams_web, :public_base_url, "https://teams.example.test/")
    Application.delete_env(:bridge_for_teams_web, :bft_cli_artifact_url)

    on_exit(fn ->
      restore_web_env(:bft_cli_artifact_base_url, previous_base)
      restore_web_env(:bft_cli_release_id, previous_release)
      restore_web_env(:bft_cli_artifact_url, previous_artifact)
      restore_web_env(:public_base_url, previous_public_base_url)
    end)

    conn = api(:get, "/v1/cli/release", nil)

    assert conn.status == 200
    assert %{"ok" => true, "data" => data} = Jason.decode!(conn.resp_body)
    assert data["mode"] == "bft_cli_release"
    assert data["layout"] == "platform"
    assert data["release_id"] == "bft-cli-20260624"

    assert data["metadata_url"] ==
             "https://r2.example.test/bft-cli/releases/bft-cli-20260624/metadata.json"

    assert data["install_url"] == "https://teams.example.test/v1/cli/install.sh"
    assert data["checksum_required"] == true
  end

  test "public bft CLI installer fails closed when platform checksum is missing" do
    previous_base = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_release = Application.get_env(:bridge_for_teams_web, :bft_cli_release_id)
    previous_artifact = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    previous_public_base_url = Application.get_env(:bridge_for_teams_web, :public_base_url)
    previous_test_root = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_test_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "bft-cli-install-missing-checksum-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf(root)
      restore_web_env(:bft_cli_artifact_base_url, previous_base)
      restore_web_env(:bft_cli_release_id, previous_release)
      restore_web_env(:bft_cli_artifact_url, previous_artifact)
      restore_web_env(:public_base_url, previous_public_base_url)
      restore_web_env(:bft_cli_artifact_test_root, previous_test_root)
    end)

    release_id = "bft-cli-install-missing-checksum"
    platform = local_platform()
    artifact_dir = Path.join([root, "bft-cli", "releases", release_id, platform])
    File.mkdir_p!(artifact_dir)

    artifact_path = Path.join(artifact_dir, "bft")
    File.write!(artifact_path, "#!/usr/bin/env sh\nprintf 'installed-bft\\n'\n")
    File.chmod!(artifact_path, 0o755)

    Application.put_env(:bridge_for_teams_web, :bft_cli_artifact_test_root, root)

    %{port: port} =
      TestBandit.start_supervised!(
        plug: ArtifactServer,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    Application.put_env(
      :bridge_for_teams_web,
      :bft_cli_artifact_base_url,
      "http://127.0.0.1:#{port}/bft-cli"
    )

    Application.put_env(:bridge_for_teams_web, :bft_cli_release_id, release_id)
    Application.put_env(:bridge_for_teams_web, :public_base_url, "https://teams.example.test/")
    Application.delete_env(:bridge_for_teams_web, :bft_cli_artifact_url)

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

    assert status != 0
    assert output =~ "BFT CLI checksum not found"
    refute File.exists?(Path.join(install_dir, "bft"))
  end

  test "public bft CLI installer fails closed when platform checksum mismatches" do
    previous_base = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_release = Application.get_env(:bridge_for_teams_web, :bft_cli_release_id)
    previous_artifact = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    previous_public_base_url = Application.get_env(:bridge_for_teams_web, :public_base_url)
    previous_test_root = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_test_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "bft-cli-install-bad-checksum-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf(root)
      restore_web_env(:bft_cli_artifact_base_url, previous_base)
      restore_web_env(:bft_cli_release_id, previous_release)
      restore_web_env(:bft_cli_artifact_url, previous_artifact)
      restore_web_env(:public_base_url, previous_public_base_url)
      restore_web_env(:bft_cli_artifact_test_root, previous_test_root)
    end)

    release_id = "bft-cli-install-bad-checksum"
    platform = local_platform()
    artifact_dir = Path.join([root, "bft-cli", "releases", release_id, platform])
    File.mkdir_p!(artifact_dir)

    artifact_path = Path.join(artifact_dir, "bft")
    File.write!(artifact_path, "#!/usr/bin/env sh\nprintf 'installed-bft\\n'\n")
    File.chmod!(artifact_path, 0o755)
    File.write!(artifact_path <> ".sha256", "#{String.duplicate("0", 64)}  bft\n")

    Application.put_env(:bridge_for_teams_web, :bft_cli_artifact_test_root, root)

    %{port: port} =
      TestBandit.start_supervised!(
        plug: ArtifactServer,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    Application.put_env(
      :bridge_for_teams_web,
      :bft_cli_artifact_base_url,
      "http://127.0.0.1:#{port}/bft-cli"
    )

    Application.put_env(:bridge_for_teams_web, :bft_cli_release_id, release_id)
    Application.put_env(:bridge_for_teams_web, :public_base_url, "https://teams.example.test/")
    Application.delete_env(:bridge_for_teams_web, :bft_cli_artifact_url)

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

    assert status != 0
    assert output =~ "Installing BridgeForTeams bft CLI for #{platform}"
    refute File.exists?(Path.join(install_dir, "bft"))
  end

  test "public bft CLI installer executes against platform-specific artifacts" do
    previous_base = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_base_url)
    previous_release = Application.get_env(:bridge_for_teams_web, :bft_cli_release_id)
    previous_artifact = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_url)
    previous_public_base_url = Application.get_env(:bridge_for_teams_web, :public_base_url)
    previous_test_root = Application.get_env(:bridge_for_teams_web, :bft_cli_artifact_test_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "bft-cli-install-test-#{System.unique_integer([:positive])}"
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

    Application.put_env(:bridge_for_teams_web, :bft_cli_artifact_test_root, root)

    %{port: port} =
      TestBandit.start_supervised!(
        plug: ArtifactServer,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    Application.put_env(
      :bridge_for_teams_web,
      :bft_cli_artifact_base_url,
      "http://127.0.0.1:#{port}/bft-cli"
    )

    Application.put_env(:bridge_for_teams_web, :bft_cli_release_id, release_id)
    Application.put_env(:bridge_for_teams_web, :public_base_url, "https://teams.example.test/")
    Application.delete_env(:bridge_for_teams_web, :bft_cli_artifact_url)

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
      |> dashboard_api("/dashboard/cli/device-authorizations/#{user_code}/approve", user, %{
        "org_ids" => [org.id]
      })
      |> json_data()

    assert approve["authorization"]["status"] == "approved"
    assert approve["authorization"]["client_name"] == "agent laptop"

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
      |> dashboard_api("/dashboard/cli/device-authorizations/#{user_code}/approve", user, %{
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
      |> dashboard_api("/dashboard/cli/device-authorizations/#{user_code}/approve", user, %{
        "org_ids" => [other_org.id]
      })
      |> json_data()

    assert approve["authorization"]["status"] == "approved"

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

  test "dashboard can cancel a CLI device login before token issuance", %{user: user} do
    start =
      :post
      |> api("/v1/cli/auth/device", nil, %{"client_name" => "agent laptop"})
      |> json_data()

    device_code = Map.fetch!(start, "device_code")
    user_code = Map.fetch!(start, "user_code")

    cancel =
      :post
      |> dashboard_api("/dashboard/cli/device-authorizations/#{user_code}/cancel", user, %{})
      |> json_data()

    assert cancel["authorization"]["status"] == "cancelled"

    poll =
      :post
      |> api("/v1/cli/auth/device/poll", nil, %{"device_code" => device_code})
      |> json_data()

    assert poll["status"] == "cancelled"
    refute Map.has_key?(poll, "token")
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
      |> dashboard_api("/dashboard/cli/device-authorizations/#{user_code}", member, %{})

    assert status_conn.status == 403

    approve_conn =
      :post
      |> dashboard_api("/dashboard/cli/device-authorizations/#{user_code}/approve", member, %{})

    assert approve_conn.status == 403

    cancel_conn =
      :post
      |> dashboard_api("/dashboard/cli/device-authorizations/#{user_code}/cancel", member, %{})

    assert cancel_conn.status == 403

    poll =
      :post
      |> api("/v1/cli/auth/device/poll", nil, %{"device_code" => device_code})
      |> json_data()

    assert poll["status"] == "pending"
    refute Map.has_key?(poll, "token")
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
    assert data["create_worker_connect_command"] =~ "bft slack connects create"
    assert data["create_worker_connect_command"] =~ "--inbound-agent <salix-agent-id>"
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
    assert guide_by_field["inbound_agent_id"]["source"] =~ "Optional"
    assert guide_by_field["inbound_agent_id"]["source"] =~ "group router"
  end

  test "meeting calendar status returns configuration evidence and bounded projected events", %{
    org: org,
    project: project,
    token: token
  } do
    Application.put_env(:bridge_for_teams_core, :salix_client, CalendarStatusSalixClient)

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
    Application.put_env(:bridge_for_teams_core, :salix_client, MeetingReplaySalixClient)

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
    Application.put_env(:bridge_for_teams_core, :salix_client, MeetingReplaySalixClient)

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

  test "meeting calendar status consumes the actual Salix autojoin contract", %{
    org: org,
    project: project,
    token: token
  } do
    start_real_calendar_status_store!()
    Application.put_env(:bridge_for_teams_core, :salix_client, ActualCalendarStatusSalixClient)

    {:ok, router} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    Process.put(:calendar_router_agent_id, router.salix_agent_id)

    %{
      meeting_id: meeting_id,
      plan_id: plan_id,
      occurrence_ref: occurrence_ref,
      group: group,
      event: event,
      now: now
    } =
      seed_real_calendar_status!(org, project, router)

    path =
      "/v1/cli/meetings/calendar/status?org=#{org.slug}&project=#{project.slug}&connect_id=conn-calendar&limit=1"

    missing_plan = api(:get, path, token) |> json_data()
    assert missing_plan["calendar"]["health"] == "degraded"
    assert missing_plan["calendar"]["reason"] == "meeting_plan_unavailable"
    assert [missing_plan_event] = missing_plan["calendar"]["events"]
    assert missing_plan_event["autojoin"]["status"] == "not_started"
    assert missing_plan_event["autojoin"]["error_present"] == false

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_meeting_plan(project.salix_group_id, plan_id), %{
               "meeting_plan_id" => plan_id,
               "group_id" => project.salix_group_id,
               "occurrence_ref" => occurrence_ref,
               "conversation_id" => nil,
               "status" => "planned",
               "revision" => 1,
               "updated_at" => now,
               "preparation" => %{}
             })

    planned_without_conversation = api(:get, path, token) |> json_data()
    assert planned_without_conversation["calendar"]["health"] == "unavailable"

    assert planned_without_conversation["calendar"]["reason"] ==
             "calendar_status_invalid_response"

    assert planned_without_conversation["calendar"]["events"] == []

    assert {:ok, _} =
             CasRecord.update(Keys.ctl_meeting_plan(project.salix_group_id, plan_id), fn plan ->
               Map.put(plan, "conversation_id", Ids.new_conversation_id())
             end)

    healthy = api(:get, path, token) |> json_data()
    assert healthy["calendar"]["health"] == "ok"
    assert healthy["calendar"]["reason"] == "eligible_meetings_projected"
    assert [healthy_event] = healthy["calendar"]["events"]

    assert healthy_event["title"] ==
             "Agenda https://docs.example.test/brief,Meet:[REDACTED_GOOGLE_MEET_URL]"

    assert healthy_event["autojoin"] == %{
             "status" => "not_started",
             "start_at" => nil,
             "join_requested_at" => nil,
             "joined_at" => nil,
             "abandoned_at" => nil,
             "error_present" => false
           }

    refute inspect(healthy) =~ "abc-defg-hij"

    checkpoint_real_calendar_event!(
      group,
      Map.put(event, "meet_url", "https://video.example.test/not-google-meet"),
      now + 1
    )

    ineligible_candidate = api(:get, path, token) |> json_data()
    assert ineligible_candidate["calendar"]["health"] == "unavailable"
    assert ineligible_candidate["calendar"]["reason"] == "calendar_status_invalid_response"
    assert ineligible_candidate["calendar"]["events"] == []

    checkpoint_real_calendar_event!(group, event, now + 2)

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :get, Keys.meet_state(meeting_id)})

    store_failure = api(:get, path, token) |> json_data()
    assert store_failure["calendar"]["health"] == "degraded"
    assert store_failure["calendar"]["reason"] == "autojoin_runtime_error"
    assert [store_failure_event] = store_failure["calendar"]["events"]
    assert store_failure_event["autojoin"]["status"] == "unavailable"
    assert store_failure_event["autojoin"]["error_present"] == true
  end

  test "meeting calendar status never drains the reconcile outbox", %{
    org: org,
    project: project,
    token: token
  } do
    Application.put_env(:bridge_for_teams_core, :salix_client, CalendarStatusSalixClient)
    Process.put(:calendar_connects_result, {:error, :not_found})
    Process.delete(:calendar_mutation_calls)

    {:ok, unrelated_org} = Orgs.create_org(%{"name" => "Unrelated", "slug" => "unrelated"})

    {:ok, _unrelated_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        unrelated_org.id,
        %{"name" => "Unrelated Project"}
      )

    before_rows = Repo.all(ReconcileOutbox) |> Enum.sort_by(& &1.id)

    data =
      api(
        :get,
        "/v1/cli/meetings/calendar/status?org=#{org.slug}&project=#{project.slug}&connect_id=conn-calendar",
        token
      )
      |> json_data()

    assert data["calendar"]["health"] == "not_ready"
    assert data["checks"]["gates"] |> hd() |> Map.fetch!("status") == "skipped"
    after_rows = Repo.all(ReconcileOutbox) |> Enum.sort_by(& &1.id)
    assert after_rows == before_rows
    assert Process.get(:calendar_mutation_calls, []) == []
  end

  test "meeting calendar status derives health from one validated raw contract", %{
    org: org,
    project: project,
    token: token
  } do
    Application.put_env(:bridge_for_teams_core, :salix_client, CalendarStatusSalixClient)

    {:ok, router} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    Process.put(:calendar_router_agent_id, router.salix_agent_id)

    base = CalendarStatusSalixClient.healthy_calendar_status(1)

    not_scanned =
      base
      |> Map.put("health", "pending")
      |> Map.put("reason", "projection_not_scanned")
      |> put_in(["projection", "state"], "not_scanned")
      |> put_in(["projection", "calendar_id"], nil)
      |> put_in(["projection", "updated_at"], nil)
      |> put_in(["projection", "age_ms"], nil)
      |> put_in(["projection", "fresh_count"], 0)
      |> put_in(["projection", "recovery_count"], 0)
      |> put_in(["projection", "candidate_count"], 0)
      |> put_in(["projection", "returned_count"], 0)
      |> put_in(["summary", "candidate_count"], 0)
      |> put_in(["summary", "returned_count"], 0)
      |> put_in(["summary", "planned_count"], 0)
      |> Map.put("events", [])

    no_candidates =
      not_scanned
      |> Map.put("health", "ok")
      |> Map.put("reason", "no_eligible_meetings_in_window")
      |> put_in(["projection", "state"], "active")
      |> put_in(["projection", "calendar_id"], "cal-calendar")
      |> put_in(["projection", "updated_at"], 1_786_009_000_000)
      |> put_in(["projection", "age_ms"], 1_000)

    truncated =
      base
      |> put_in(["projection", "fresh_count"], 2)
      |> put_in(["projection", "candidate_count"], 2)
      |> put_in(["projection", "truncated"], true)
      |> put_in(["summary", "candidate_count"], 2)

    plan_error =
      base
      |> put_in(["events", Access.at(0), "plan"], %{"status" => "missing"})
      |> put_in(["summary", "planned_count"], 0)
      |> put_in(["summary", "plan_error_count"], 1)

    candidate_error =
      base
      |> put_in(["events", Access.at(0), "last_error_present"], true)
      |> put_in(["summary", "candidate_error_count"], 1)

    autojoin_error =
      base
      |> put_in(["events", Access.at(0), "autojoin", "status"], "failed")
      |> put_in(["summary", "autojoin_error_count"], 1)

    inconsistent_projection =
      base
      |> Map.put("health", "ok")
      |> Map.put("reason", "no_eligible_meetings_in_window")
      |> put_in(["projection", "fresh_count"], 1)
      |> put_in(["projection", "candidate_count"], 0)
      |> put_in(["projection", "returned_count"], 0)
      |> put_in(["summary", "candidate_count"], 0)
      |> put_in(["summary", "returned_count"], 0)
      |> put_in(["summary", "planned_count"], 0)
      |> Map.put("events", [])

    sparse_event =
      put_in(base, ["events"], [
        %{
          "last_error_present" => false,
          "plan" => %{"status" => "planned"},
          "autojoin" => %{"status" => "not_started"}
        }
      ])

    cases = [
      {"healthy projected event", base, "ok", "eligible_meetings_projected"},
      {"provisioning autojoin lifecycle",
       put_in(base, ["events", Access.at(0), "autojoin", "status"], "provisioning"), "ok",
       "eligible_meetings_projected"},
      {"active autojoin lifecycle",
       put_in(base, ["events", Access.at(0), "autojoin", "status"], "active"), "ok",
       "eligible_meetings_projected"},
      {"processing autojoin lifecycle",
       put_in(base, ["events", Access.at(0), "autojoin", "status"], "processing"), "ok",
       "eligible_meetings_projected"},
      {"healthy without candidates", no_candidates, "ok", "no_eligible_meetings_in_window"},
      {"missing top-level events fails closed", Map.delete(no_candidates, "events"),
       "unavailable", "calendar_status_invalid_response"},
      {"non-list top-level events fails closed", Map.put(no_candidates, "events", %{}),
       "unavailable", "calendar_status_invalid_response"},
      {"worker stopped",
       base
       |> put_in(["runtime", "status"], "not_running")
       |> put_in(["runtime", "running"], false), "degraded", "calendar_worker_not_running"},
      {"worker not configured",
       base
       |> put_in(["runtime", "status"], "not_configured")
       |> put_in(["runtime", "configured"], false)
       |> put_in(["runtime", "running"], false)
       |> put_in(["runtime", "scan_interval_ms"], nil), "degraded",
       "calendar_worker_not_configured"},
      {"first scan pending", not_scanned, "pending", "projection_not_scanned"},
      {"projection unavailable", put_in(base, ["projection", "state"], "unavailable"),
       "unavailable", "calendar_status_invalid_response"},
      {"truncated", truncated, "degraded", "calendar_status_truncated"},
      {"contradictory truncated flag fails closed",
       put_in(base, ["projection", "truncated"], true), "unavailable",
       "calendar_status_invalid_response"},
      {"candidate count without matching kind counts fails closed",
       base
       |> put_in(["projection", "candidate_count"], 2)
       |> put_in(["summary", "candidate_count"], 2), "unavailable",
       "calendar_status_invalid_response"},
      {"missing active freshness field fails closed",
       update_in(base["projection"], &Map.delete(&1, "updated_at")), "unavailable",
       "calendar_status_invalid_response"},
      {"complete active projection with unavailable freshness degrades",
       base
       |> put_in(["projection", "updated_at"], nil)
       |> put_in(["projection", "age_ms"], nil), "degraded", "projection_freshness_invalid"},
      {"valid stale projection",
       base
       |> put_in(["projection", "age_ms"], 360_001)
       |> put_in(["projection", "stale"], true), "degraded", "projection_stale"},
      {"contradictory stale flag fails closed", put_in(base, ["projection", "age_ms"], 360_001),
       "unavailable", "calendar_status_invalid_response"},
      {"summary-only plan error fails closed",
       base
       |> put_in(["summary", "planned_count"], 0)
       |> put_in(["summary", "plan_error_count"], 1), "unavailable",
       "calendar_status_invalid_response"},
      {"matching Plan detail and summary degrade", plan_error, "degraded",
       "meeting_plan_unavailable"},
      {"Plan detail without matching summary fails closed",
       put_in(base, ["events", Access.at(0), "plan"], %{"status" => "missing"}), "unavailable",
       "calendar_status_invalid_response"},
      {"matching candidate detail and summary degrade", candidate_error, "degraded",
       "calendar_candidate_recovery_error"},
      {"summary-only candidate error fails closed",
       put_in(base, ["summary", "candidate_error_count"], 1), "unavailable",
       "calendar_status_invalid_response"},
      {"candidate detail without matching summary fails closed",
       put_in(base, ["events", Access.at(0), "last_error_present"], true), "unavailable",
       "calendar_status_invalid_response"},
      {"matching autojoin detail and summary degrade", autojoin_error, "degraded",
       "autojoin_runtime_error"},
      {"summary-only autojoin error fails closed",
       put_in(base, ["summary", "autojoin_error_count"], 1), "unavailable",
       "calendar_status_invalid_response"},
      {"autojoin detail without matching summary fails closed",
       put_in(base, ["events", Access.at(0), "autojoin", "status"], "failed"), "unavailable",
       "calendar_status_invalid_response"},
      {"canonical unavailable autojoin may omit optional fields",
       base
       |> put_in(["events", Access.at(0), "autojoin"], %{
         "status" => "unavailable",
         "start_at" => nil,
         "join_requested_at" => nil,
         "joined_at" => nil
       })
       |> put_in(["summary", "autojoin_error_count"], 1)
       |> Map.put("health", "degraded")
       |> Map.put("reason", "autojoin_runtime_error"), "degraded", "autojoin_runtime_error"},
      {"unknown autojoin status fails closed",
       put_in(base, ["events", Access.at(0), "autojoin", "status"], "PRIVATE_STATUS"),
       "unavailable", "calendar_status_invalid_response"},
      {"impossible source health pair", Map.put(base, "reason", "calendar_worker_not_running"),
       "unavailable", "calendar_status_invalid_response"},
      {"legal source failure contradicts normalized facts",
       base
       |> Map.put("health", "degraded")
       |> Map.put("reason", "calendar_worker_not_running"), "unavailable",
       "calendar_status_invalid_response"}
    ]

    # Raw DTO violations are rejected before defaults apply, so no events leak through.
    raw_dto_rejections = [
      {"raw DTO projection counts disagree", inconsistent_projection, "unavailable",
       "calendar_status_invalid_response"},
      {"raw DTO event omits required identity and time fields", sparse_event, "unavailable",
       "calendar_status_invalid_response"}
    ]

    raw_dto_rejection_labels = Enum.map(raw_dto_rejections, &elem(&1, 0))

    for {label, status, health, reason} <- cases ++ raw_dto_rejections do
      Process.put(:calendar_status_result, {:ok, status})

      data =
        api(
          :get,
          "/v1/cli/meetings/calendar/status?org=#{org.slug}&project=#{project.slug}&connect_id=conn-calendar&limit=1",
          token
        )
        |> json_data()

      assert data["calendar"]["health"] == health, label
      assert data["calendar"]["reason"] == reason, label
      assert length(data["calendar"]["events"]) <= 1, label

      if label in raw_dto_rejection_labels do
        assert data["calendar"]["events"] == [], label
      end
    end
  end

  test "meeting calendar status classifies connect and policy outages without leaking raw detail",
       %{
         org: org,
         project: project,
         token: token
       } do
    Application.put_env(:bridge_for_teams_core, :salix_client, CalendarStatusSalixClient)

    {:ok, router} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    Process.put(:calendar_router_agent_id, router.salix_agent_id)

    Process.put(
      :calendar_connects_result,
      {:error, {:http, 503, "PRIVATE_CONNECT_CANARY https://meet.google.com/abc-defg-hij"}}
    )

    connect_outage =
      api(
        :get,
        "/v1/cli/meetings/calendar/status?org=#{org.slug}&project=#{project.slug}&connect_id=conn-calendar",
        token
      )
      |> json_data()

    assert connect_outage["calendar"]["health"] == "unavailable"
    assert connect_outage["calendar"]["reason"] == "calendar_backend_unavailable"
    assert connect_outage["checks"]["gates"] |> hd() |> Map.fetch!("status") == "skipped"
    refute inspect(connect_outage) =~ "PRIVATE_CONNECT_CANARY"
    refute inspect(connect_outage) =~ "abc-defg-hij"

    Process.delete(:calendar_connects_result)
    Process.delete(:calendar_status_params)

    Process.put(
      :calendar_policy_status_result,
      {:error,
       {:calendar_enrollment_cache_unavailable,
        {:http, 403, "PRIVATE_POLICY_CANARY https://meet.google.com/def-ghij-klm"}}}
    )

    policy_outage =
      api(
        :get,
        "/v1/cli/meetings/calendar/status?org=#{org.slug}&project=#{project.slug}&connect_id=conn-calendar",
        token
      )
      |> json_data()

    assert policy_outage["calendar"]["health"] == "unavailable"
    assert policy_outage["calendar"]["reason"] == "calendar_backend_unavailable"
    assert policy_outage["checks"]["gates"] |> hd() |> Map.fetch!("status") == "needs_manual"
    assert Process.get(:calendar_status_params) == nil
    refute inspect(policy_outage) =~ "PRIVATE_POLICY_CANARY"
    refute inspect(policy_outage) =~ "def-ghij-klm"
  end

  test "meeting calendar status normalizes raw projection storage failures", %{
    org: org,
    project: project,
    token: token
  } do
    Application.put_env(:bridge_for_teams_core, :salix_client, CalendarStatusSalixClient)

    {:ok, router} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "router",
        "role" => "router"
      })

    Process.put(:calendar_router_agent_id, router.salix_agent_id)

    Process.put(
      :calendar_status_result,
      {:error,
       {:calendar_projection_read,
        {:http, 403, "PRIVATE_BACKEND_CANARY https://meet.google.com/abc-defg-hij"}}}
    )

    data =
      api(
        :get,
        "/v1/cli/meetings/calendar/status?org=#{org.slug}&project=#{project.slug}&connect_id=conn-calendar",
        token
      )
      |> json_data()

    assert data["checks"]["gates"] |> hd() |> Map.fetch!("status") == "ok"
    assert data["calendar"]["health"] == "unavailable"
    assert data["calendar"]["reason"] == "calendar_status_backend_unavailable"
    refute inspect(data) =~ "PRIVATE_BACKEND_CANARY"
    refute inspect(data) =~ "abc-defg-hij"
  end

  test "meeting calendar status rejects an unbounded limit before calling Salix", %{
    org: org,
    project: project,
    token: token
  } do
    Application.put_env(:bridge_for_teams_core, :salix_client, CalendarStatusSalixClient)
    Process.delete(:calendar_status_params)

    conn =
      api(
        :get,
        "/v1/cli/meetings/calendar/status?org=#{org.slug}&project=#{project.slug}&limit=51",
        token
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_limit"
    assert Process.get(:calendar_status_params) == nil
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
    Application.put_env(
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
    Application.put_env(
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

  test "conversation CLI endpoints expose stable error codes and bounded limits", %{
    org: org,
    project: project,
    token: token
  } do
    Application.put_env(
      :bridge_for_teams_core,
      :salix_client,
      ConversationSalixClient
    )

    capped =
      api(:get, "/v1/cli/conversations?org=#{org.slug}&project=#{project.slug}&limit=1000", token)
      |> json_data()

    assert capped["limit"] == 500
    assert Process.get(:conversation_list_limit) == 500

    for path <- [
          "/v1/cli/conversations?org=#{org.slug}&project=#{project.slug}&limit=0",
          "/v1/cli/conversations/task-cli-1/messages?org=#{org.slug}&project=#{project.slug}&limit=abc",
          "/v1/cli/conversations/task-cli-1/trace?org=#{org.slug}&project=#{project.slug}&limit=0",
          "/v1/cli/conversations/task-cli-1/delivery?org=#{org.slug}&project=#{project.slug}&participant=worker&limit=0",
          "/v1/cli/conversations/task-cli-1?org=#{org.slug}&project=#{project.slug}&message_limit=abc"
        ] do
      conn = api(:get, path, token)

      assert conn.status == 400

      assert %{"ok" => false, "error" => %{"code" => "invalid_limit"}} =
               Jason.decode!(conn.resp_body)
    end

    ambiguous_trace_conn =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1/trace?org=#{org.slug}&project=#{project.slug}",
        token
      )

    assert ambiguous_trace_conn.status == 400

    assert %{"ok" => false, "error" => %{"code" => "trace_participant_required"}} =
             Jason.decode!(ambiguous_trace_conn.resp_body)

    missing_delivery_participant_conn =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1/delivery?org=#{org.slug}&project=#{project.slug}",
        token
      )

    assert missing_delivery_participant_conn.status == 400

    assert %{"ok" => false, "error" => %{"code" => "delivery_participant_required"}} =
             Jason.decode!(missing_delivery_participant_conn.resp_body)

    single_trace =
      api(
        :get,
        "/v1/cli/conversations/single-trace/trace?org=#{org.slug}&project=#{project.slug}",
        token
      )
      |> json_data()

    assert single_trace["trace_agent_id"] == "agent-single"
    assert single_trace["trace_session_id"] == "single-session"
    assert single_trace["trace_participant_id"] == "agent"
    assert Process.get(:conversation_trace_target) == {"agent-single", "single-session"}

    unknown_participant_trace_conn =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1/trace?org=#{org.slug}&project=#{project.slug}&participant=missing",
        token
      )

    assert unknown_participant_trace_conn.status == 404

    assert %{"ok" => false, "error" => %{"code" => "trace_session_not_found"}} =
             Jason.decode!(unknown_participant_trace_conn.resp_body)

    for path <- [
          "/v1/cli/conversations/missing-task?org=#{org.slug}&project=#{project.slug}",
          "/v1/cli/conversations/missing-task/messages?org=#{org.slug}&project=#{project.slug}",
          "/v1/cli/conversations/missing-task/participants/worker/status?org=#{org.slug}&project=#{project.slug}",
          "/v1/cli/conversations/missing-task/trace?org=#{org.slug}&project=#{project.slug}",
          "/v1/cli/conversations/missing-task/delivery?org=#{org.slug}&project=#{project.slug}&participant=worker"
        ] do
      conn = api(:get, path, token)

      assert conn.status == 404

      assert %{"ok" => false, "error" => %{"code" => "conversation_not_found"}} =
               Jason.decode!(conn.resp_body)
    end

    missing_participant_status_conn =
      api(
        :get,
        "/v1/cli/conversations/task-cli-1/participants/missing/status?org=#{org.slug}&project=#{project.slug}",
        token
      )

    assert missing_participant_status_conn.status == 404

    assert %{"ok" => false, "error" => %{"code" => "participant_status_not_found"}} =
             Jason.decode!(missing_participant_status_conn.resp_body)

    trace_conn =
      api(
        :get,
        "/v1/cli/conversations/no-trace/trace?org=#{org.slug}&project=#{project.slug}",
        token
      )

    assert trace_conn.status == 404

    assert %{"ok" => false, "error" => %{"code" => "trace_session_not_found"}} =
             Jason.decode!(trace_conn.resp_body)

    missing_runtime_trace_conn =
      api(
        :get,
        "/v1/cli/conversations/trace-gone/trace?org=#{org.slug}&project=#{project.slug}&limit=1000",
        token
      )

    assert missing_runtime_trace_conn.status == 404
    assert Process.get(:conversation_trace_limit) == 500

    assert %{"ok" => false, "error" => %{"code" => "trace_session_not_found"}} =
             Jason.decode!(missing_runtime_trace_conn.resp_body)
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

  test "Feishu app selected smoke stays manual until a bot-ready binding exists", %{
    org: org,
    token: token
  } do
    selected =
      api(:get, "/v1/cli/feishu/apps/selected?org=#{org.slug}&app_id=cli_app", token)
      |> json_data()

    assert selected["selected_app"]["requested_app_id"] == "cli_app"
    assert selected["selected_app"]["app_id"] == nil
    assert selected["selected_app"]["binding"] == nil
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

  test "Feishu app upsert reports existing non-Feishu SSO as a conflict", %{
    org: org,
    token: token
  } do
    {:ok, _oidc} =
      Orgs.upsert_sso_connection(org.id, %{
        "provider" => "generic_oidc",
        "issuer" => "https://accounts.google.com",
        "client_id" => "google-client",
        "client_secret" => "google-secret",
        "allowed_domains" => ["comma.surf"]
      })

    conn =
      api(:post, "/v1/cli/feishu/apps", token, %{
        "org" => org.slug,
        "attrs" => %{
          "app_id" => "cli_google_org",
          "sso_enabled" => true,
          "app_secret" => "feishu-secret"
        }
      })

    assert conn.status == 409
    refute conn.resp_body =~ "feishu-secret"

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "sso_provider_conflict",
               "message" => "Could not save the Feishu app."
             }
           } = Jason.decode!(conn.resp_body)
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

  test "runner list exposes heartbeat summary", %{org: org, token: token} do
    {:ok, provisioner} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => "mini-1",
        "name" => "Office Mac mini",
        "status" => "online",
        "last_seen_at" => DateTime.utc_now(),
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

  defp start_real_calendar_status_store! do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_calendar_autojoin = Application.get_env(:salix_meet, :calendar_autojoin)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_meet, :calendar_autojoin, scan_interval_ms: 120_000)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    worker_started? = is_nil(Process.whereis(SalixMeet.CalendarAutojoin))

    worker_pid =
      if worker_started? do
        {:ok, pid} = Agent.start_link(fn -> :running end, name: SalixMeet.CalendarAutojoin)
        pid
      end

    on_exit(fn ->
      if worker_started? and is_pid(worker_pid) and Process.alive?(worker_pid),
        do: Agent.stop(worker_pid)

      restore_app_env(:salix_store, :s3_backend, previous_backend)
      restore_app_env(:salix_meet, :calendar_autojoin, previous_calendar_autojoin)
    end)
  end

  defp seed_real_calendar_status!(org, project, router) do
    now = System.system_time(:millisecond)
    calendar_id = Ids.new_calendar_id()
    item_id = Ids.new_calendar_item_id()
    plan_id = Ids.new_meeting_plan_id()

    occurrence_ref = %{
      "calendar_id" => calendar_id,
      "instance" => "actual-salix-producer"
    }

    event = %{
      "event_id" => "actual-salix-producer-event",
      "calendar_id" => calendar_id,
      "calendar_item_id" => item_id,
      "occurrence_ref" => occurrence_ref,
      "meeting_plan_id" => plan_id,
      "calendar_revision" => 1,
      "start_ms" => now + 60 * 60 * 1_000,
      "end_ms" => now + 90 * 60 * 1_000,
      "meet_url" => "https://meet.google.com:443/abc-defg-hij",
      "title" =>
        "Agenda https://docs.example.test/brief,Meet:https://meet.google.com:443/abc-defg-hij"
    }

    group = %{
      "tenant_id" => org.salix_tenant_id,
      "group_id" => project.salix_group_id,
      "calendar_id" => calendar_id
    }

    assert {:ok, _} =
             CasRecord.update(Keys.ctl_agent(router.salix_agent_id), fn agent ->
               Map.merge(agent, %{
                 "heartbeat_schedule_id" => "heartbeat-#{router.salix_agent_id}",
                 "router_session_id" => Ids.new_session_id()
               })
             end)

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(project.salix_group_id, "conn-calendar"), %{
               "tenant_id" => org.salix_tenant_id,
               "group_id" => project.salix_group_id,
               "connect_id" => "conn-calendar",
               "provider" => "slack",
               "oauth_completed_at" => 1
             })

    assert {:ok, empty} = CalendarProjection.load(group, now: now - 1)

    assert {:ok, projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(empty, [event], %{}, max_events: 50, now: now)

    assert {:ok, _} = CalendarProjection.checkpoint(projection)

    %{
      meeting_id: CalendarProjection.meeting_id(group, event),
      plan_id: plan_id,
      occurrence_ref: occurrence_ref,
      group: group,
      event: event,
      now: now
    }
  end

  defp checkpoint_real_calendar_event!(group, event, now) do
    assert {:ok, snapshot} = CalendarProjection.load(group, now: now)

    assert {:ok, projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(snapshot, [event], %{}, max_events: 50, now: now)

    assert {:ok, _} = CalendarProjection.checkpoint(projection)
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

  defp restore_web_env(key, nil), do: Application.delete_env(:bridge_for_teams_web, key)
  defp restore_web_env(key, value), do: Application.put_env(:bridge_for_teams_web, key, value)
  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

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
