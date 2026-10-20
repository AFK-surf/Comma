defmodule BridgeForTeamsWeb.CLIController do
  @moduledoc """
  Authenticated HTTP surface behind the product `bft` terminal wrapper.

  These endpoints accept user-facing org/project refs so the CLI can stay a thin
  client while the server enforces membership, project access, and secret
  redaction.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  import Ecto.Query
  import BridgeForTeamsWeb.ProjectAPIResponse

  alias BridgeForTeams.{
    Auth,
    CLI.Login,
    Conversations,
    FeishuAppBindings,
    FeishuScopes,
    LarkRunChecks,
    LarkScopes,
    Meetings,
    Orgs,
    ProjectIMConnects,
    Projects,
    Repo,
    RunChecks
  }

  alias BridgeForTeams.Schema.{
    FeishuAppBinding,
    Organization,
    OrgSsoConnection,
    OrgSsoIdentity,
    Project
  }

  alias BridgeForTeamsWeb.{LimitParams, ProjectScope}

  def context(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read) do
      send_ok(conn, %{
        "context" => %{
          "org" => public_org(org),
          "project" => public_project(project)
        }
      })
    else
      error -> send_cli_error(conn, error)
    end
  end

  def orgs(conn, _params) do
    orgs =
      conn
      |> current_cli_session()
      |> Login.list_active_cli_session_orgs()
      |> Enum.filter(&(ProjectScope.authorize_org(current_user(conn), &1, "member") == :ok))
      |> Enum.map(&public_org/1)

    send_ok(conn, %{"orgs" => orgs})
  end

  def projects(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member") do
      projects =
        org.id
        |> Projects.list_projects_for_user(current_user(conn).id)
        |> Enum.map(&public_project/1)

      send_ok(conn, %{"org" => public_org(org), "projects" => projects})
    else
      error -> send_cli_error(conn, error)
    end
  end

  def conversations(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, limit} <- read_limit(params, "limit"),
         {:ok, conversations} <- Conversations.list_project_conversations(project, limit: limit) do
      send_ok(conn, %{
        "mode" => "conversations_list",
        "org" => public_org(org),
        "project" => public_project(project),
        "conversations" => conversations,
        "limit" => limit
      })
    else
      error -> send_cli_error(conn, error)
    end
  end

  def conversation(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, message_limit} <- read_limit(params, "message_limit"),
         {:ok, %{conversation: conversation, messages: messages}} <-
           require_conversation_snapshot(project, conversation_id, message_limit) do
      participants = conversation_participants(project, conversation_id)
      conversation = Map.put(conversation, "participants", participants)

      send_ok(conn, %{
        "mode" => "conversation_show",
        "org" => public_org(org),
        "project" => public_project(project),
        "conversation" => conversation,
        "participants" => participants,
        "messages" => messages,
        "message_limit" => message_limit
      })
    else
      error -> send_cli_error(conn, error)
    end
  end

  def conversation_messages(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, limit} <- read_limit(params, "limit"),
         {:ok, messages} <- require_conversation_messages(project, conversation_id, limit) do
      send_ok(conn, %{
        "mode" => "conversation_messages",
        "org" => public_org(org),
        "project" => public_project(project),
        "conversation_id" => conversation_id,
        "messages" => messages,
        "limit" => limit
      })
    else
      error -> send_cli_error(conn, error)
    end
  end

  def conversation_send(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :write),
         {:ok, _conversation} <- require_conversation(project, conversation_id),
         {:ok, text} <- require_conversation_message(params["text"]),
         {:ok, request_id} <- require_conversation_send_request(params["request_id"]),
         {:ok, result} <-
           Conversations.send_project_conversation_message(project, conversation_id, text,
             actor_user_id: current_user(conn).id,
             request_id: request_id
           ) do
      send_ok(conn, %{
        "mode" => "conversation_send",
        "org" => public_org(org),
        "project" => public_project(project),
        "conversation_id" => conversation_id,
        "message" => result
      })
    else
      {:error, :conversation_message_required} ->
        send_error(
          conn,
          400,
          "conversation_message_required",
          "Pass a non-empty message of at most 32,000 bytes.",
          %{}
        )

      {:error, :conversation_send_request_required} ->
        send_error(
          conn,
          400,
          "conversation_send_request_required",
          "Pass a stable opaque request id.",
          %{}
        )

      error ->
        send_cli_error(conn, error)
    end
  end

  def conversation_participant_status(
        conn,
        %{"conversation_id" => conversation_id, "participant_id" => participant_id} = params
      ) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, _conversation} <- require_conversation(project, conversation_id),
         {:ok, participant_id} <- require_status_participant(participant_id),
         {:ok, status} <-
           Conversations.project_conversation_participant_status(
             project,
             conversation_id,
             participant_id
           ) do
      send_ok(conn, %{
        "mode" => "conversation_participant_status",
        "org" => public_org(org),
        "project" => public_project(project),
        "conversation_id" => conversation_id,
        "participant_id" => participant_id,
        "status" => status
      })
    else
      {:error, :status_participant_required} ->
        send_error(
          conn,
          400,
          "status_participant_required",
          "Pass a conversation participant id to inspect participant status.",
          %{}
        )

      {:error, :not_found} ->
        send_error(
          conn,
          404,
          "participant_status_not_found",
          "Conversation participant status not found.",
          %{}
        )

      error ->
        send_cli_error(conn, error)
    end
  end

  def conversation_trace(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, limit} <- read_limit(params, "limit"),
         {:ok, conversation} <- require_conversation(project, conversation_id),
         {:ok, participants} <-
           Conversations.list_project_conversation_participants(project, conversation_id),
         {:ok,
          %{
            agent_id: agent_id,
            session_id: session_id,
            participant_id: trace_participant_id
          }} <-
           Conversations.debug_trace_target(Map.put(conversation, "participants", participants),
             participant_id: trim(params["participant"])
           ),
         {:ok, trace} <- Conversations.get_session_trace(agent_id, session_id, limit: limit) do
      conversation = Map.put(conversation, "participants", participants)

      send_ok(conn, %{
        "mode" => "conversation_trace",
        "org" => public_org(org),
        "project" => public_project(project),
        "conversation" => conversation,
        "trace_agent_id" => agent_id,
        "trace_session_id" => session_id,
        "trace_participant_id" => trace_participant_id,
        "trace" => trace,
        "limit" => limit
      })
    else
      {:error, :trace_participant_required} ->
        send_error(
          conn,
          400,
          "trace_participant_required",
          "Pass a conversation participant id to select the trace session.",
          %{}
        )

      {:error, reason} when reason in [:missing_trace_session, :not_found] ->
        send_error(
          conn,
          404,
          "trace_session_not_found",
          "Conversation trace session not found.",
          %{}
        )

      error ->
        send_cli_error(conn, error)
    end
  end

  def conversation_delivery(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, limit} <- read_limit(params, "limit"),
         {:ok, _conversation} <- require_conversation(project, conversation_id),
         {:ok, participant_id} <- require_delivery_participant(params["participant"]),
         {:ok, status} <-
           Conversations.project_conversation_delivery_status(project, conversation_id,
             participant_id: participant_id,
             message_id: params["message"],
             limit: limit
           ) do
      send_ok(conn, %{
        "mode" => "conversation_delivery",
        "org" => public_org(org),
        "project" => public_project(project),
        "conversation_id" => conversation_id,
        "participant_id" => participant_id,
        "message_id" => params["message"],
        "delivery" => status,
        "limit" => limit
      })
    else
      {:error, :delivery_participant_required} ->
        send_error(
          conn,
          400,
          "delivery_participant_required",
          "Pass a conversation participant id to inspect participant delivery status.",
          %{}
        )

      error ->
        send_cli_error(conn, error)
    end
  end

  def conversation_redeliver(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :write),
         {:ok, _conversation} <- require_conversation(project, conversation_id),
         {:ok, result} <-
           Conversations.redeliver_message(
             project,
             conversation_id,
             Map.take(params, ~w(participant_id message_id request_id))
           ) do
      send_ok(conn, %{"redelivery" => result})
    else
      {:error, {:bad_request, message}} ->
        send_error(conn, 400, "invalid_conversation_redelivery", message, %{})

      error ->
        send_cli_error(conn, error)
    end
  end

  def upsert_feishu_app(conn, %{"attrs" => attrs} = params) when is_map(attrs) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "admin") do
      case FeishuAppBindings.upsert_binding(org.id, attrs, request_audit_opts(conn)) do
        {:ok, %FeishuAppBinding{} = binding} ->
          send_ok(conn, %{
            "org" => public_org(org),
            "binding" => public_binding(binding),
            "redaction" => %{
              "credential_input" => "request_body",
              "secrets_printed" => false
            }
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          send_error(conn, 400, "invalid_feishu_app", "Could not save the Feishu app.", %{
            "errors" => changeset_errors(changeset)
          })

        {:error, reason} ->
          send_backend_error(conn, reason, "Could not save the Feishu app.")
      end
    else
      error -> send_cli_error(conn, error)
    end
  end

  def upsert_feishu_app(conn, _params) do
    send_error(conn, 400, "missing_attrs", "Pass a Feishu app attrs object.", %{})
  end

  def selected_feishu_app(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "admin"),
         {:ok, selected} <- select_feishu_app(org, params, false) do
      send_ok(conn, %{"org" => public_org(org), "selected_app" => public_selected_app(selected)})
    else
      error -> send_cli_error(conn, error)
    end
  end

  def feishu_setup(conn, params) do
    do_feishu_setup(conn, params, truthy?(params["ensure_connect"]))
  end

  def feishu_connect(conn, params) do
    do_feishu_setup(conn, params, true)
  end

  @doc "Connects a Lark app to a project, or refreshes the credentials of a connected one."
  def lark_connect(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "admin"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :write),
         {:ok, attrs} <- lark_credentials(params) do
      case ProjectIMConnects.create_project_connect(org.id, project.id, "lark", attrs) do
        {:ok, connect} ->
          send_ok(conn, %{
            "mode" => "lark_connect",
            "org" => public_org(org),
            "project" => public_project(project),
            "action" => connect["action"] || "created",
            "connect" => public_connect(connect),
            "callback_url" => sanitize_url(connect["webhook_url"]),
            "manual_checklist" => lark_manual_checklist()
          })

        {:error, reason} ->
          send_backend_error(conn, reason, "Could not connect the Lark app.")
      end
    else
      error -> send_cli_error(conn, error)
    end
  end

  @doc "The Lark apps of a project."
  def lark_status(conn, params) do
    with {:ok, org} <- require_org(params),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read) do
      case ProjectIMConnects.list_project_connects(org.id, project.id, "lark") do
        {:ok, connects} ->
          send_ok(conn, %{
            "mode" => "lark_status",
            "org" => public_org(org),
            "project" => public_project(project),
            "connects" =>
              Enum.map(connects, fn connect ->
                connect
                |> public_connect()
                |> Map.put("callback_url", sanitize_url(connect["webhook_url"]))
              end),
            "manual_checklist" => lark_manual_checklist()
          })

        {:error, reason} ->
          send_backend_error(conn, reason, "Could not read the Lark apps.")
      end
    else
      error -> send_cli_error(conn, error)
    end
  end

  @doc "Runs the checks of one Lark connect of a project."
  def lark_checks(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, checks} <- LarkRunChecks.run_bot(org, project, connect_id: params["connect_id"]) do
      send_ok(conn, %{
        "mode" => "lark_checks",
        "org" => public_org(org),
        "project" => public_project(project),
        "checks" => RunChecks.to_json_map(checks)
      })
    else
      {:error, :connect_not_found} ->
        send_error(conn, 404, "connect_not_found", "Lark connect not found.", %{})

      {:error, reason} ->
        send_backend_error(conn, reason, "Could not run Lark checks.")

      error ->
        send_cli_error(conn, error)
    end
  end

  @doc "The scopes a Lark app needs, as the JSON of the Lark Developer Console's batch import."
  def lark_scopes(conn, _params) do
    send_ok(conn, %{
      "mode" => "lark_scopes",
      "required_scopes" => LarkScopes.required_scope_ids(),
      "batch_import_payload" => LarkScopes.import_payload(),
      "import_path" => "Lark Developer Console → Permissions & Scopes → batch import"
    })
  end

  defp lark_credentials(params) do
    attrs =
      Map.new(~w(app_id app_secret verification_token encrypt_key), &{&1, trim(params[&1])})

    missing = Enum.filter(~w(app_id app_secret), &(attrs[&1] == ""))

    cond do
      missing != [] ->
        error(400, "missing_lark_credentials", "Pass the Lark app's App ID and App Secret.", %{
          "fields" => missing
        })

      attrs["verification_token"] == "" and attrs["encrypt_key"] == "" ->
        error(
          400,
          "missing_lark_credentials",
          "Pass the Verification Token or the Encrypt Key of the Lark app's event subscription.",
          %{"fields" => ["verification_token"]}
        )

      true ->
        {:ok, attrs}
    end
  end

  defp lark_manual_checklist do
    [
      "In the Lark Developer Console, add the Bot capability to the app.",
      "Under Events & Callbacks, choose \"Send events to developer's server\" and save the callback URL as the request URL.",
      "Subscribe to the events im.message.receive_v1 and im.message.recalled_v1.",
      "Under Permissions & Scopes, batch-import the JSON that bft lark scopes prints. It has im:message.group_msg, so that people can go on in a thread without mentioning the bot, and every message of a group is recorded.",
      "Create a version of the app and publish it; scopes and events take effect with the published version.",
      "Add the bot to a group and mention it, or write to it in a private chat.",
      "Run bft lark checks to verify the request URL and the route."
    ]
  end

  @doc "Connects a QQ bot to a project, or refreshes the credentials of a connected one."
  def qq_connect(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "admin"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :write),
         {:ok, attrs} <- qq_credentials(params) do
      case ProjectIMConnects.create_project_connect(org.id, project.id, "qq", attrs) do
        {:ok, connect} ->
          send_ok(conn, %{
            "mode" => "qq_connect",
            "org" => public_org(org),
            "project" => public_project(project),
            "action" => connect["action"] || "created",
            "connect" => public_connect(connect),
            "callback_url" => sanitize_url(connect["webhook_url"]),
            "manual_checklist" => qq_manual_checklist()
          })

        {:error, reason} ->
          send_backend_error(conn, reason, "Could not connect the QQ bot.")
      end
    else
      error -> send_cli_error(conn, error)
    end
  end

  @doc "The QQ bots of a project."
  def qq_status(conn, params) do
    with {:ok, org} <- require_org(params),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read) do
      case ProjectIMConnects.list_project_connects(org.id, project.id, "qq") do
        {:ok, connects} ->
          send_ok(conn, %{
            "mode" => "qq_status",
            "org" => public_org(org),
            "project" => public_project(project),
            "connects" =>
              Enum.map(connects, fn connect ->
                connect
                |> public_connect()
                |> Map.put("callback_url", sanitize_url(connect["webhook_url"]))
              end),
            "manual_checklist" => qq_manual_checklist()
          })

        {:error, reason} ->
          send_backend_error(conn, reason, "Could not read the QQ bots.")
      end
    else
      error -> send_cli_error(conn, error)
    end
  end

  @doc """
  Replaces the shortcuts of a QQ bot's command menu. `app_id` names the bot
  when the project has more than one.
  """
  def qq_menu(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "admin"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :write),
         {:ok, items} <- qq_menu_items(params["items"]),
         {:ok, connects} <- ProjectIMConnects.list_project_connects(org.id, project.id, "qq"),
         {:ok, connect} <- qq_menu_connect(connects, trim(params["app_id"])) do
      case ProjectIMConnects.update_project_qq_command_menu(
             org.id,
             project.id,
             connect["connect_id"],
             items
           ) do
        {:ok, connect} ->
          send_ok(conn, %{
            "mode" => "qq_menu",
            "org" => public_org(org),
            "project" => public_project(project),
            "connect" => public_connect(connect)
          })

        {:error, {:invalid_menu, message}} ->
          send_cli_error(conn, error(400, "invalid_qq_menu", message))

        {:error, reason} ->
          send_backend_error(conn, reason, "Could not update the QQ bot's command menu.")
      end
    else
      error -> send_cli_error(conn, error)
    end
  end

  defp qq_menu_items(items) when is_list(items), do: {:ok, items}
  defp qq_menu_items(_items), do: error(400, "invalid_qq_menu", "Pass the menu items as a list.")

  defp qq_menu_connect([connect], ""), do: {:ok, connect}

  defp qq_menu_connect([], _app_id),
    do: error(404, "qq_bot_not_found", "This project has no QQ bot. Run bft qq connect first.")

  defp qq_menu_connect(_connects, ""),
    do: error(400, "qq_app_id_required", "This project has more than one QQ bot. Pass --app-id.")

  defp qq_menu_connect(connects, app_id) do
    case Enum.find(connects, &(trim(&1["app_id"]) == app_id)) do
      nil -> error(404, "qq_bot_not_found", "This project has no QQ bot with that AppID.")
      connect -> {:ok, connect}
    end
  end

  defp qq_credentials(params) do
    attrs = %{"app_id" => trim(params["app_id"]), "app_secret" => trim(params["app_secret"])}

    case Enum.filter(~w(app_id app_secret), &(attrs[&1] == "")) do
      [] ->
        {:ok, attrs}

      missing ->
        error(400, "missing_qq_credentials", "Pass the QQ bot's AppID and AppSecret.", %{
          "fields" => missing
        })
    end
  end

  defp qq_manual_checklist do
    [
      "In the QQ bot console, choose Webhook as the event delivery method and save the callback URL.",
      "Subscribe to the private chat, group, interaction and group member events.",
      "If the console has an IP allowlist, add this deployment's egress addresses.",
      "Add the bot to a group and mention it, or write to it in a private chat.",
      "For messages later than 5 minutes after a mention, a group admin turns on \"机器人主动在群聊内发言\" in the bot's settings in that group.",
      "To record the whole group conversation, a group admin sets \"机器人可获取的群聊消息范围\" to \"获取群内全部消息\"."
    ]
  end

  def feishu_checks(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, checks} <- RunChecks.run_bot(org, project, connect_id: params["connect_id"]) do
      send_ok(conn, %{
        "mode" => "feishu_checks",
        "org" => public_org(org),
        "project" => public_project(project),
        "checks" => RunChecks.to_json_map(checks)
      })
    else
      {:error, :connect_not_found} ->
        send_error(conn, 404, "connect_not_found", "Feishu connect not found.", %{})

      {:error, reason} ->
        send_backend_error(conn, reason, "Could not run Feishu checks.")

      error ->
        send_cli_error(conn, error)
    end
  end

  def sso_checks(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "admin") do
      sso_connection = Orgs.get_sso_connection(org.id)
      redirect_uri = dashboard_redirect_uri(conn)
      now = SystemsClock.utc_now()

      case sso_connection do
        %OrgSsoConnection{provider: "lark"} ->
          send_ok(conn, %{
            "mode" => "sso_checks",
            "org" => public_org(org),
            "checks" => build_lark_sso_checks(org, sso_connection, redirect_uri),
            "admin_login" => lark_admin_login_gate(org, current_user(conn))
          })

        _ ->
          send_ok(conn, %{
            "mode" => "sso_checks",
            "org" => public_org(org),
            "checks" => build_sso_checks(org, sso_connection, redirect_uri, now),
            "admin_login" => feishu_admin_login_gate(org, current_user(conn))
          })
      end
    else
      error -> send_cli_error(conn, error)
    end
  end

  def slack_setup(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, manifest} <-
           ProjectIMConnects.slack_manifest(params["app_name"] || project.name || "Bridge") do
      app_manifest = manifest["manifest"] || %{}
      bot_scopes = get_in(app_manifest, ["oauth_config", "scopes", "bot"]) || []

      send_ok(conn, %{
        "mode" => "slack_setup",
        "org" => public_org(org),
        "project" => public_project(project),
        "manifest" => app_manifest,
        "redirect_url" => manifest["redirect_url"],
        "events_url" => manifest["events_url"],
        "interactions_url" => manifest["interactions_url"],
        "required_scopes" => bot_scopes,
        "slack_apps_url" => "https://api.slack.com/apps",
        "credential_guide" => slack_credential_guide(),
        "create_connect_command" => slack_create_connect_command(org, project),
        "create_task_connect_command" => slack_create_task_connect_command(org, project),
        "manual_checklist" => [
          "Create or update the Slack app from the manifest.",
          "Confirm Interactivity is enabled with the manifest's request URL.",
          "Install the app into the Slack workspace.",
          "Invite the bot to private target channels; after installation, it automatically joins newly created public channels and can join an existing public channel on request."
        ]
      })
    else
      {:error, reason} -> send_backend_error(conn, reason, "Could not prepare Slack setup.")
      error -> send_cli_error(conn, error)
    end
  end

  def meeting_calendar_status(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :read),
         {:ok, limit} <- read_calendar_status_limit(params),
         {:ok, result} <-
           RunChecks.run_slack_calendar_status(org, project,
             connect_id: params["connect_id"],
             limit: limit
           ) do
      send_ok(conn, %{
        "mode" => "meeting_calendar_status",
        "org" => public_org(org),
        "project" => public_project(project),
        "checks" => RunChecks.to_json_map(result.checks),
        "calendar" => result.calendar
      })
    else
      {:error, :connect_not_found} ->
        send_error(conn, 404, "connect_not_found", "Slack connect not found.", %{})

      {:error, :invalid_calendar_status_query} ->
        send_error(conn, 400, "invalid_limit", "Limit must be between 1 and 50.", %{})

      {:error, reason} ->
        send_backend_error(conn, reason, "Could not read meeting calendar status.")

      error ->
        send_cli_error(conn, error)
    end
  end

  def meeting_summary_replay(conn, params) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "admin"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :write),
         {:ok, meeting_id} <- required_replay_param(params, "meeting_id"),
         {:ok, request_id} <- required_replay_param(params, "request_id"),
         {:ok, run_model} <- replay_boolean(params["run_model"]),
         :ok <- replay_confirmation(run_model, params["confirm_model_replay"]),
         {:ok, replay} <-
           Meetings.replay_summary(
             org,
             project,
             current_user(conn),
             meeting_id,
             request_id,
             run_model: run_model
           ) do
      send_ok(conn, %{
        "mode" => "meeting_summary_replay",
        "org" => public_org(org),
        "project" => public_project(project),
        "replay" => replay
      })
    else
      {:error, :online_replay_disabled} ->
        send_error(conn, 403, "online_replay_disabled", "Online meeting replay is disabled.", %{})

      {:error, :meeting_not_found} ->
        send_error(conn, 404, "meeting_not_found", "Meeting not found in this project.", %{})

      {:error, :meeting_not_terminal} ->
        send_error(conn, 409, "meeting_not_terminal", "Meeting is not terminal yet.", %{})

      {:error, :replay_request_conflict} ->
        send_error(
          conn,
          409,
          "replay_request_conflict",
          "The request id is already bound to a different replay.",
          %{}
        )

      {:error, :invalid_replay_request} ->
        send_error(
          conn,
          400,
          "invalid_replay_request",
          "Meeting and request ids are invalid.",
          %{}
        )

      {:error, :replay_confirmation_required} ->
        send_error(
          conn,
          400,
          "replay_confirmation_required",
          "Explicit confirmation is required for model replay.",
          %{}
        )

      {:error, :replay_confirmation_without_model} ->
        send_error(
          conn,
          400,
          "replay_confirmation_without_model",
          "Model replay confirmation requires run_model=true.",
          %{}
        )

      {:error, reason} ->
        send_backend_error(conn, reason, "Could not replay meeting summary.")

      error ->
        send_cli_error(conn, error)
    end
  end

  defp required_replay_param(params, key) do
    case params[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :invalid_replay_request}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, :invalid_replay_request}
    end
  end

  defp replay_boolean(true), do: {:ok, true}
  defp replay_boolean(false), do: {:ok, false}
  defp replay_boolean(nil), do: {:ok, false}
  defp replay_boolean(_other), do: {:error, :invalid_replay_request}

  defp replay_confirmation(true, true), do: :ok
  defp replay_confirmation(true, _other), do: {:error, :replay_confirmation_required}
  defp replay_confirmation(false, value) when value in [nil, false], do: :ok
  defp replay_confirmation(false, _other), do: {:error, :replay_confirmation_without_model}

  defp slack_credential_guide do
    [
      %{
        "field" => "app_id",
        "flag" => "--app-id",
        "source" => "Slack app -> Basic Information -> App Credentials -> App ID"
      },
      %{
        "field" => "client_id",
        "flag" => "--client-id",
        "source" => "Slack app -> Basic Information -> App Credentials -> Client ID"
      },
      %{
        "field" => "client_secret",
        "flag" => "--client-secret-env",
        "source" => "Slack app -> Basic Information -> App Credentials -> Client Secret"
      },
      %{
        "field" => "signing_secret",
        "flag" => "--signing-secret-env",
        "source" => "Slack app -> Basic Information -> App Credentials -> Signing Secret"
      },
      %{
        "field" => "inbound_tasks",
        "flag" => "--tasks",
        "source" =>
          "Optional. Bind the connection to Tasks instead of the Router: each new Slack thread becomes a Task. Give {\"model\": <model choice>} to run that model, or {} for the project's default Task model. Omit to bind the project's Router."
      }
    ]
  end

  defp slack_create_connect_command(org, project) do
    "bft slack connects create --org #{cli_ref(org.slug, org.id)} --project #{cli_ref(project.slug, project.id)} --app-id <app-id> --client-id <client-id> --client-secret-env BFT_SLACK_CLIENT_SECRET --signing-secret-env BFT_SLACK_SIGNING_SECRET --confirm-mutating"
  end

  defp slack_create_task_connect_command(org, project) do
    slack_create_connect_command(org, project) <> " --tasks"
  end

  defp cli_ref(value, fallback) do
    case value do
      value when is_binary(value) and value != "" -> value
      _ -> fallback
    end
  end

  defp do_feishu_setup(conn, params, ensure_connect?) do
    with {:ok, org} <- require_org(params),
         :ok <- authorize_org(conn, org, "admin"),
         {:ok, project} <- require_project(conn, org, params),
         :ok <- authorize_project(conn, project, :write),
         {:ok, selected} <- select_feishu_app(org, params, ensure_connect?),
         {:ok, setup} <-
           maybe_ensure_feishu_connect(org, project, selected, params, ensure_connect?) do
      send_ok(
        conn,
        Map.merge(setup, %{
          "mode" => "feishu_setup",
          "org" => public_org(org),
          "project" => public_project(project),
          "selected_app" => public_selected_app(selected),
          "required_scopes" => FeishuScopes.required_scope_ids(:bot),
          "batch_import_payload" => FeishuScopes.import_payload(:bot),
          "optional_scopes" => FeishuScopes.optional_bot_scopes(),
          "event_subscriptions" => ["im.message.receive_v1", "im.message.recalled_v1"],
          "manual_checklist" => feishu_manual_checklist(),
          "limitations" => [
            "One bot-enabled Feishu app can be connected to one Agent Swarm until multi-route support lands.",
            "Resubmitting the same app_id routes through a resync/update path; backend errors are surfaced instead of silently dropping credential changes."
          ]
        })
      )
    else
      {:error, reason} -> send_backend_error(conn, reason, "Could not prepare Feishu setup.")
      error -> send_cli_error(conn, error)
    end
  end

  defp require_org(params) do
    ProjectScope.require_org(params["org"], missing_message: "Pass --org <org-id-or-slug>.")
  end

  defp require_project(conn, org, params) do
    ProjectScope.require_project(current_user(conn), org, params["project"],
      missing_message: "Pass --project <project-id-or-slug>."
    )
  end

  defp authorize_org(conn, %Organization{} = org, min_role) do
    ProjectScope.authorize_org_for_conn(conn, org, min_role)
  end

  defp authorize_project(conn, %Project{} = project, action) do
    ProjectScope.authorize_project(current_user(conn), project, action)
  end

  defp read_limit(params, key, default \\ 100) do
    case LimitParams.read(params, key, default) do
      {:ok, limit} ->
        {:ok, limit}

      {:error, :invalid_limit} ->
        error(400, "invalid_limit", "Limit must be a positive integer.")
    end
  end

  defp read_calendar_status_limit(params) do
    case read_limit(params, "limit", 20) do
      {:ok, limit} when limit <= 50 -> {:ok, limit}
      {:ok, _limit} -> {:error, :invalid_calendar_status_query}
      error -> error
    end
  end

  defp require_delivery_participant(value) do
    case trim(value) do
      "" -> {:error, :delivery_participant_required}
      participant_id -> {:ok, participant_id}
    end
  end

  defp require_status_participant(value) do
    case trim(value) do
      "" -> {:error, :status_participant_required}
      participant_id -> {:ok, participant_id}
    end
  end

  defp require_conversation_message(value) when is_binary(value) do
    text = String.trim(value)

    if text != "" and byte_size(text) <= 32_000,
      do: {:ok, text},
      else: {:error, :conversation_message_required}
  end

  defp require_conversation_message(_value), do: {:error, :conversation_message_required}

  defp require_conversation_send_request(value) when is_binary(value) do
    request_id = String.trim(value)

    if byte_size(request_id) in 1..160,
      do: {:ok, request_id},
      else: {:error, :conversation_send_request_required}
  end

  defp require_conversation_send_request(_value),
    do: {:error, :conversation_send_request_required}

  defp require_conversation(project, conversation_id) do
    case Conversations.get_project_conversation(project, conversation_id) do
      {:ok, conversation} ->
        {:ok, conversation}

      {:error, :not_found} ->
        error(404, "conversation_not_found", "Conversation not found.")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_conversation_snapshot(project, conversation_id, limit) do
    case Conversations.get_project_conversation_with_messages(project, conversation_id,
           limit: limit
         ) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, :not_found} ->
        error(404, "conversation_not_found", "Conversation not found.")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_conversation_messages(project, conversation_id, limit) do
    case Conversations.list_project_conversation_messages(project, conversation_id, limit: limit) do
      {:ok, messages} ->
        {:ok, messages}

      {:error, :not_found} ->
        error(404, "conversation_not_found", "Conversation not found.")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp conversation_participants(project, conversation_id) do
    case Conversations.list_project_conversation_participants(project, conversation_id) do
      {:ok, participants} -> participants
      {:error, _reason} -> []
    end
  end

  defp current_user(conn), do: Map.fetch!(conn.assigns, :current_user)
  defp current_cli_session(conn), do: Map.fetch!(conn.assigns, :current_cli_session)

  defp request_audit_opts(conn) do
    user = current_user(conn)

    [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: request_id(conn)
    ]
  end

  defp actor_label(user) do
    cond do
      present?(Map.get(user, :email)) -> String.trim(user.email)
      present?(Map.get(user, :name)) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [request_id | _] when is_binary(request_id) and request_id != "" ->
        request_id

      _ ->
        case Logger.metadata()[:request_id] do
          request_id when is_binary(request_id) and request_id != "" -> request_id
          _ -> SystemsRuntime.Proc.uuid()
        end
    end
  end

  defp select_feishu_app(%Organization{} = org, params, ensure_connect?) do
    app_id = params["app_id"]
    bot_bindings = org.id |> FeishuAppBindings.list_bindings() |> Enum.filter(&bot_binding?/1)

    cond do
      present?(app_id) ->
        binding = Enum.find(bot_bindings, &(&1.app_id == app_id))

        if binding do
          {:ok, %{source: "app_id", app_id: binding.app_id, binding: binding}}
        else
          if ensure_connect? do
            error(
              400,
              "missing_feishu_app",
              "No bot-enabled Feishu app binding is available for this app_id."
            )
          else
            {:ok, %{source: "app_id", app_id: nil, requested_app_id: app_id, binding: nil}}
          end
        end

      bot_bindings != [] ->
        [binding | _] = bot_bindings
        {:ok, %{source: "binding", app_id: binding.app_id, binding: binding}}

      ensure_connect? ->
        error(400, "missing_feishu_app", "No bot-enabled Feishu app binding is available.")

      true ->
        {:ok, %{source: "none", app_id: nil, binding: nil}}
    end
  end

  defp bot_binding?(%FeishuAppBinding{} = binding),
    do: binding.bot_enabled and binding.app_secret_configured

  defp maybe_ensure_feishu_connect(org, project, selected, params, ensure_connect?) do
    with {:ok, connects} <- ProjectIMConnects.list_project_connects(org.id, project.id, "feishu") do
      existing = preferred_connect(connects, selected.app_id)

      cond do
        ensure_connect? and present?(selected.app_id) ->
          attrs =
            %{"app_id" => selected.app_id}
            |> put_present("app_name", params["app_name"] || selected_app_name(selected))

          case ProjectIMConnects.create_project_connect(org.id, project.id, "feishu", attrs) do
            {:ok, connect} ->
              {:ok, connect_payload(connect, connect["action"] || "ensured", connects)}

            {:error, reason} ->
              {:error, reason}
          end

        existing ->
          {:ok, connect_payload(existing, "existing", connects)}

        true ->
          {:ok,
           %{
             "action" => "preview",
             "connect" => nil,
             "callback_url" => nil,
             "next_action" => "Run with --ensure-connect after the org Feishu app is saved."
           }}
      end
    end
  end

  defp connect_payload(connect, action, connects) do
    %{
      "action" => action,
      "connect" => public_connect(connect),
      "callback_url" => sanitize_url(connect["webhook_url"]),
      "all_connects" => Enum.map(connects, &public_connect/1)
    }
  end

  defp selected_app_name(%{binding: %FeishuAppBinding{} = binding}),
    do: binding.display_name || binding.app_id

  defp selected_app_name(%{app_id: app_id}), do: app_id

  defp preferred_connect(connects, nil),
    do: Enum.find(connects, &active_connect?/1) || List.first(connects)

  defp preferred_connect(connects, app_id) do
    Enum.find(connects, &(active_connect?(&1) and &1["app_id"] == app_id)) ||
      Enum.find(connects, &(&1["app_id"] == app_id))
  end

  defp active_connect?(connect), do: is_nil(connect["disabled_at"])

  defp feishu_manual_checklist do
    [
      "Create or select the org Feishu custom app.",
      "Enable group bot (IM) on the org Feishu app binding.",
      "Create or resync the Agent Swarm Feishu connect to generate the callback URL.",
      "Paste the callback URL into Feishu Events & Callbacks.",
      "Subscribe to im.message.receive_v1 and im.message.recalled_v1.",
      "Batch-import the required bot scopes, publish/install the app version, and add the bot to the target group.",
      "Run bft feishu checks --json and then test a real @Bridge message."
    ]
  end

  defp build_sso_checks(org, sso_connection, redirect_uri, now) do
    %{
      "surface" => "sso",
      "connect_ref" => org.id,
      "ran_at" => DateTime.to_iso8601(now),
      "gates" => [
        sso_connection_gate(sso_connection),
        sso_credentials_gate(sso_connection),
        %{
          "gate_id" => "sso.redirect_uri",
          "label" => "Feishu redirect URI generated",
          "status" => "ok",
          "next_action" => "Register this redirect URI in the Feishu app SSO settings.",
          "evidence" => %{"redirect_uri" => redirect_uri}
        },
        sso_authorize_url_gate(org, redirect_uri)
      ]
    }
  end

  defp sso_connection_gate(nil) do
    %{
      "gate_id" => "sso.connection",
      "label" => "Feishu SSO connection exists",
      "status" => "needs_manual",
      "next_action" => "Configure Feishu SSO on the BFT org settings page."
    }
  end

  defp sso_connection_gate(%OrgSsoConnection{provider: "feishu"} = connection) do
    %{
      "gate_id" => "sso.connection",
      "label" => "Feishu SSO connection exists",
      "status" => "ok",
      "next_action" => "Feishu SSO connection is saved.",
      "evidence" => %{"connection" => public_sso_connection(connection)}
    }
  end

  defp sso_connection_gate(%OrgSsoConnection{} = connection) do
    %{
      "gate_id" => "sso.connection",
      "label" => "Feishu SSO connection exists",
      "status" => "fail",
      "next_action" => "Replace the current SSO provider with Feishu for this onboarding flow.",
      "evidence" => %{"provider" => connection.provider}
    }
  end

  defp sso_credentials_gate(%OrgSsoConnection{provider: "feishu"} = connection) do
    configured? = present?(connection.client_id) and present?(connection.client_secret)

    %{
      "gate_id" => "sso.credentials",
      "label" => "Feishu SSO credentials present",
      "status" => if(configured?, do: "ok", else: "needs_manual"),
      "next_action" =>
        if configured? do
          "Client ID and App Secret are present; continue with redirect and login smoke."
        else
          "Save the Feishu App ID and App Secret in BFT org SSO settings."
        end,
      "evidence" => %{
        "client_id" => connection.client_id,
        "client_secret_configured" => present?(connection.client_secret)
      }
    }
  end

  defp sso_credentials_gate(_connection) do
    %{
      "gate_id" => "sso.credentials",
      "label" => "Feishu SSO credentials present",
      "status" => "needs_manual",
      "next_action" => "Save a Feishu SSO connection before checking credentials."
    }
  end

  defp sso_authorize_url_gate(org, redirect_uri) do
    case Auth.authorize_url(org.id, redirect_uri: redirect_uri) do
      {:ok, %{url: url}} ->
        uri = URI.parse(url)

        %{
          "gate_id" => "sso.authorize_url",
          "label" => "Feishu authorization URL can be generated",
          "status" => "ok",
          "next_action" =>
            "Open the BFT login page for this org and complete the Feishu SSO browser flow.",
          "evidence" => %{
            "authorize_url_host" => uri.host,
            "authorize_url_generated" => true
          }
        }

      {:error, reason} ->
        %{
          "gate_id" => "sso.authorize_url",
          "label" => "Feishu authorization URL can be generated",
          "status" =>
            if(reason in [:no_sso_connection, :missing_client_id, :missing_client_secret],
              do: "needs_manual",
              else: "fail"
            ),
          "next_action" => sso_authorize_url_next_action(reason),
          "evidence" => %{"reason" => safe_reason(reason)}
        }
    end
  end

  defp sso_authorize_url_next_action(:no_sso_connection),
    do: "Configure Feishu SSO on the BFT org settings page."

  defp sso_authorize_url_next_action(:missing_client_id),
    do: "Save the Feishu App ID in BFT org SSO settings."

  defp sso_authorize_url_next_action(:missing_client_secret),
    do: "Save the Feishu App Secret in BFT org SSO settings."

  defp sso_authorize_url_next_action(_reason),
    do: "Could not generate a Feishu authorization URL; inspect the SSO connection."

  defp feishu_admin_login_gate(org, user) do
    sso_identity? =
      Repo.exists?(
        from(i in OrgSsoIdentity,
          where: i.org_id == ^org.id and i.user_id == ^user.id and i.provider == "feishu"
        )
      )

    %{
      "gate_id" => "sso.admin_login",
      "label" => "Current admin has signed in with Feishu SSO",
      "classification" => if(sso_identity?, do: "automatic", else: "assisted"),
      "status" => if(sso_identity?, do: "ok", else: "needs_manual"),
      "reason_class" => if(sso_identity?, do: nil, else: "sso_login_not_observed"),
      "required" => true,
      "next_action" =>
        if sso_identity? do
          "This CLI session belongs to an admin user with a Feishu SSO identity."
        else
          "Sign out, sign in through Feishu SSO as an org admin, generate a fresh BFT CLI login command, then rerun this step."
        end,
      "evidence" => %{"user_id" => user.id, "feishu_sso_identity_seen" => sso_identity?},
      "redacted" => true
    }
  end

  # ---- sign-in with Lark ----

  # The gates of `LarkRunChecks.run_sso/2`, then the two the CLI adds for every
  # provider: the saved connection and the authorization URL.
  defp build_lark_sso_checks(org, %OrgSsoConnection{} = connection, redirect_uri) do
    {:ok, checks} = LarkRunChecks.run_sso(org, redirect_uri: redirect_uri)
    checks = RunChecks.to_json_map(checks)

    connection_gate = %{
      "gate_id" => "sso.connection",
      "label" => "Lark SSO connection exists",
      "status" => "ok",
      "next_action" => "Lark SSO connection is saved.",
      "evidence" => %{"connection" => public_sso_connection(connection)}
    }

    Map.put(
      checks,
      "gates",
      [connection_gate] ++ checks["gates"] ++ [lark_sso_authorize_url_gate(org, redirect_uri)]
    )
  end

  defp lark_sso_authorize_url_gate(org, redirect_uri) do
    gate = %{
      "gate_id" => "sso.authorize_url",
      "label" => "Lark authorization URL can be generated"
    }

    case Auth.authorize_url(org.id, redirect_uri: redirect_uri) do
      {:ok, %{url: url}} ->
        Map.merge(gate, %{
          "status" => "ok",
          "next_action" =>
            "Open the BFT login page for this org and complete the Lark sign-in in a browser.",
          "evidence" => %{
            "authorize_url_host" => URI.parse(url).host,
            "authorize_url_generated" => true
          }
        })

      {:error, reason} ->
        Map.merge(gate, %{
          "status" => "fail",
          "next_action" =>
            "Could not generate a Lark authorization URL; inspect the SSO connection.",
          "evidence" => %{"reason" => safe_reason(reason)}
        })
    end
  end

  defp lark_admin_login_gate(org, user) do
    seen? =
      Repo.exists?(
        from(i in OrgSsoIdentity,
          where: i.org_id == ^org.id and i.user_id == ^user.id and i.provider == "lark"
        )
      )

    %{
      "gate_id" => "sso.admin_login",
      "label" => "Current admin has signed in with Lark",
      "classification" => if(seen?, do: "automatic", else: "assisted"),
      "status" => if(seen?, do: "ok", else: "needs_manual"),
      "reason_class" => if(seen?, do: nil, else: "sso_login_not_observed"),
      "required" => true,
      "next_action" =>
        if seen? do
          "This CLI session belongs to an admin user with a Lark identity."
        else
          "Sign out, sign in with Lark as an org admin, generate a fresh BFT CLI login command, then rerun this step."
        end,
      "evidence" => %{"user_id" => user.id, "lark_sso_identity_seen" => seen?},
      "redacted" => true
    }
  end

  defp public_sso_connection(%OrgSsoConnection{} = connection) do
    %{
      "id" => connection.id,
      "provider" => connection.provider,
      "client_id" => connection.client_id,
      "client_secret_configured" => present?(connection.client_secret),
      "provider_config" =>
        Map.take(connection.provider_config || %{}, [
          "scope",
          "tenant_key",
          "provisioning_policy"
        ]),
      "last_verified_at" => connection.last_verified_at,
      "last_error_code" => connection.last_error_code
    }
  end

  defp dashboard_redirect_uri(conn),
    do:
      conn |> dashboard_base_url() |> String.trim_trailing("/") |> then(&(&1 <> "/auth/callback"))

  defp dashboard_base_url(_conn) do
    case SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url) do
      base when is_binary(base) and base != "" ->
        base

      _ ->
        dashboard_endpoint_base_url()
    end
  end

  defp dashboard_endpoint_base_url do
    endpoint_config =
      SystemsRuntime.get_env(
        :bridge_for_teams_web,
        BridgeForTeamsWeb.DashboardEndpoint,
        []
      )

    url_config = Keyword.get(endpoint_config, :url, [])
    http_config = Keyword.get(endpoint_config, :http, [])

    scheme = Keyword.get(url_config, :scheme, "http")
    host = Keyword.get(url_config, :host, "localhost")
    port = Keyword.get(url_config, :port) || Keyword.get(http_config, :port)

    port_suffix =
      case {scheme, port} do
        {"http", port} when port in [nil, 80] -> ""
        {"https", port} when port in [nil, 443] -> ""
        {_scheme, nil} -> ""
        {_scheme, port} -> ":#{port}"
      end

    "#{scheme}://#{host}#{port_suffix}"
  end

  defp public_binding(nil), do: nil

  defp public_binding(%FeishuAppBinding{} = binding) do
    %{
      "id" => binding.id,
      "app_id" => binding.app_id,
      "display_name" => binding.display_name,
      "sso_enabled" => binding.sso_enabled,
      "bot_enabled" => binding.bot_enabled,
      "app_secret_configured" => binding.app_secret_configured,
      "verification_token_configured" => binding.verification_token_configured,
      "encrypt_key_configured" => binding.encrypt_key_configured
    }
  end

  defp public_selected_app(%{source: source, app_id: app_id, binding: binding} = selected) do
    %{
      "source" => source,
      "app_id" => app_id,
      "requested_app_id" => Map.get(selected, :requested_app_id),
      "binding" => public_binding(binding)
    }
  end

  defp error(status, code, message, details \\ %{}), do: {:error, status, code, message, details}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(safe_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false
end
