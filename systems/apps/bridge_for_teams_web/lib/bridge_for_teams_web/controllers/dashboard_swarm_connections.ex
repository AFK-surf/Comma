defmodule BridgeForTeamsWeb.DashboardSwarmConnections do
  @moduledoc """
  Builds the Agent Swarm Connections page payload and applies its writes for
  `DashboardAPIController`: the messaging channels (Feishu and Slack connects
  with their Run checks, and Signal chats), the third-party accounts
  (managed OAuth and Composio toolkits), and the Tailscale network.

  The page is one read with a fixed number of database queries and Salix
  calls, whatever the number of connects, agents or accounts: the caller's
  organization role, the organization's bot-enabled Feishu app, the router
  agent and the org's model choices (a Slack connection delivers to the
  Router, or makes each new thread a Task that runs a chosen model or the
  swarm's default Task model), and one Salix call each for the IM
  connects, the Slack manifest, the group, Signal, the OAuth platforms, the
  OAuth accounts, the Composio accounts and the Tailscale network.
  Each section has its own `status` (`ok`, `preparing` or `unavailable`), so
  one runtime failure does not hide the others.

  Feishu and Slack Run checks record their result for the Health page's
  Delivery signal. A failed recording still returns the checks, with a
  warning.

  Showing at least one connected OAuth account marks the caller's onboarding
  connect step done, as the LiveView page did.

  Every swarm member reads the page; every write is for swarm admins. A
  refused write records a denied audit entry, as the LiveView page did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{
    Agents,
    FeishuAppBindings,
    Models,
    LarkRunChecks,
    LarkScopes,
    Memberships,
    Observability,
    Onboarding,
    ProjectComposioConnections,
    ProjectIMConnects,
    ProjectOAuthConnections,
    ProjectSignal,
    ProjectTailnet,
    ProviderScopes,
    RunChecks,
    UserOnboardings
  }

  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Agent

  @signal_binding_limit 100
  @app_name_limit 100
  @slack_create_app_base "https://api.slack.com/apps"
  @slack_fields ~w(app_name app_id client_id client_secret signing_secret inbound_agent_id inbound_tasks)

  # ---- Reads ----

  @doc "The page: messaging (Feishu, Slack, QQ), Signal, OAuth accounts and Composio toolkits."
  def page(org, user, project, role) do
    org_role =
      case Memberships.org_role(org.id, user.id) do
        {:ok, org_role} -> org_role
        _other -> nil
      end

    {:ok,
     %{
       "project" => public_project(project, role),
       "org_admin" => org_role in ~w(owner admin),
       "messaging" => messaging(org, project),
       "signal" => signal(org, project),
       "accounts" => accounts(org, user, project),
       "composio" => composio(org, project),
       "tailnet" => tailnet(org, project, role)
     }}
  end

  @doc "The Slack App Manifest for `app_name`; nil when Salix cannot build it."
  def slack_manifest(params) do
    name = String.slice(text(params["app_name"]) || "", 0, @app_name_limit)
    {:ok, %{"manifest" => manifest(name)}}
  end

  defp messaging(org, project) do
    case ProjectIMConnects.list_project_connects(org.id, project.id, nil) do
      {:ok, connects} ->
        router_id = router_agent_id(project)
        router = router_agent(project, router_id)
        feishu = Enum.filter(connects, &(&1["provider"] == "feishu"))
        slack = Enum.filter(connects, &(&1["provider"] == "slack"))
        qq = Enum.filter(connects, &(&1["provider"] == "qq"))
        lark = Enum.filter(connects, &(&1["provider"] == "lark"))

        %{
          "status" => "ok",
          "feishu" => feishu(org, feishu, router),
          "slack" => slack(org, project, slack, router, router_id),
          "qq" => qq(qq, router),
          "lark" => lark(lark, router)
        }

      {:error, reason} ->
        %{
          "status" => section_status(reason),
          "feishu" => nil,
          "slack" => nil,
          "qq" => nil,
          "lark" => nil
        }
    end
  end

  # The org's bot-enabled, secret-configured Feishu app (an org has at most
  # one). Salix sources the bot secret from its tenant store, so a connect
  # names only the app.
  defp feishu(org, connects, router) do
    apps =
      case FeishuAppBindings.latest_bot_binding(org.id) do
        %{app_secret_configured: true} = app -> [app]
        _none -> []
      end

    %{
      "apps" => Enum.map(apps, &%{"app_id" => &1.app_id, "name" => &1.display_name || &1.app_id}),
      "connects" => Enum.map(connects, &feishu_connect/1),
      "route" => feishu_route(connects, router)
    }
  end

  defp feishu_connect(connect) do
    %{
      "connect_id" => connect["connect_id"],
      "status" => connect["status"] || "configured",
      "disabled" => not is_nil(connect["disabled_at"]),
      "app_id" => connect["app_id"],
      "webhook_url" => display_webhook_url(connect),
      "app_secret_configured" => connect["app_secret_configured"] == true,
      "verification_token_configured" => connect["verification_token_configured"] == true,
      "encrypt_key_configured" => connect["encrypt_key_configured"] == true,
      "updated_at" => iso_timestamp(connect["updated_at"])
    }
  end

  # Whether a Feishu group message reaches this swarm: an active connect and
  # the group's router. A runtime failure reads as unknown, never as missing.
  defp feishu_route(connects, router) do
    connect = Enum.find(connects, &is_nil(&1["disabled_at"])) || List.first(connects)

    {router, error} =
      case {connect, router} do
        {nil, _router} -> {nil, nil}
        {_connect, {:ok, agent}} -> {agent, nil}
        {_connect, {:error, reason}} -> {nil, reason}
      end

    status =
      cond do
        is_nil(connect) -> "not_connected"
        connect["disabled_at"] -> "disabled"
        error -> "unknown"
        is_nil(router) -> "missing_router"
        true -> "ready"
      end

    %{
      "status" => status,
      "connect_id" => connect && connect["connect_id"],
      "router" => router && (router.salix["name"] || router.salix_agent_id)
    }
  end

  # The swarm's QQ bots. Each connect holds its own bot credentials; the page
  # shows the callback address to save in the QQ bot console.
  defp qq(connects, router) do
    %{
      "connects" =>
        Enum.map(connects, fn connect ->
          %{
            "connect_id" => connect["connect_id"],
            "status" => connect["status"] || "configured",
            "disabled" => not is_nil(connect["disabled_at"]),
            "app_id" => connect["app_id"],
            "bot_name" => text(connect["bot_username"]),
            "webhook_url" => display_webhook_url(connect),
            "app_secret_configured" => connect["app_secret_configured"] == true,
            # The shortcuts of the bot's command menu, and whether QQ took the
            # menu in private chats and in groups.
            "command_menu" => List.wrap(connect["command_menu"]),
            "command_menu_sync" =>
              if(is_map(connect["command_menu_sync"]),
                do: connect["command_menu_sync"],
                else: %{}
              ),
            "updated_at" => iso_timestamp(connect["updated_at"])
          }
        end),
      "route" => feishu_route(connects, router)
    }
  end

  # The swarm's Lark apps. Each connect holds its own app credentials; the
  # page shows the request URL to save in the Lark Developer Console.
  defp lark(connects, router) do
    %{
      "connects" =>
        Enum.map(connects, fn connect ->
          %{
            "connect_id" => connect["connect_id"],
            "status" => connect["status"] || "configured",
            "disabled" => not is_nil(connect["disabled_at"]),
            "app_id" => connect["app_id"],
            "app_name" => text(connect["app_name"]),
            "webhook_url" => display_webhook_url(connect),
            "app_secret_configured" => connect["app_secret_configured"] == true,
            "verification_token_configured" => connect["verification_token_configured"] == true,
            "encrypt_key_configured" => connect["encrypt_key_configured"] == true,
            "updated_at" => iso_timestamp(connect["updated_at"])
          }
        end),
      "route" => feishu_route(connects, router),
      # The JSON for the batch import of the Lark Developer Console.
      "scope_json" => LarkScopes.import_json()
    }
  end

  # A connection delivers to the Router, or binds each new Slack thread to a
  # Task (`inbound_tasks`) that runs the model it names or, without one, the
  # swarm's default Task model. Workers are retired: a connection still bound
  # to one shows it, and the create form offers the Router and Tasks only.
  defp slack(org, project, connects, router, router_id) do
    app_name = default_slack_app_name(project)
    agents = if match?({:ok, %Agent{}}, router), do: [elem(router, 1)], else: []
    offered = org_models(org)

    %{
      "app_name" => app_name,
      "manifest" => manifest(app_name),
      "inbound_agents" => inbound_agents(agents),
      "inbound_agents_truncated" => false,
      "default_inbound_agent_id" =>
        case router_id do
          {:ok, id} -> id
          _error -> nil
        end,
      "task_models" => task_model_options(offered),
      "connects" => Enum.map(connects, &slack_connect(&1, agents, offered))
    }
  end

  defp slack_connect(connect, agents, offered) do
    %{
      "connect_id" => connect["connect_id"],
      "installed" => (connect["oauth_completed_at"] || 0) > 0,
      "disabled" => not is_nil(connect["disabled_at"]),
      "workspace" => text(connect["workspace_name"]) || text(connect["workspace_id"]),
      "inbound" => if(is_map(connect["inbound_tasks"]), do: "tasks", else: "agent"),
      "inbound_agent" => inbound_label(connect, agents, offered),
      "install_url" => web_url(connect["oauth_url"]),
      "client_secret_configured" => connect["client_secret_configured"] == true,
      "signing_secret_configured" => connect["signing_secret_configured"] == true,
      "updated_at" => iso_timestamp(connect["updated_at"])
    }
  end

  defp inbound_label(%{"inbound_tasks" => %{} = tasks}, _agents, offered) do
    case tasks["model"] do
      %{} = model ->
        gettext("Tasks · %{model}", model: Models.option(model, offered)["label"])

      _default ->
        gettext("Tasks · default Task model")
    end
  end

  defp inbound_label(connect, agents, _offered),
    do: agent_label(connect["inbound_agent_id"], agents)

  # The models a connection bound to Tasks may run: the swarm's default Task
  # model (key ""), then the org's offered choices.
  defp task_model_options(offered) do
    [
      %{"key" => "", "choice" => nil, "label" => gettext("Default Task model")}
      | Enum.map(offered, &Map.take(&1, ~w(key choice label)))
    ]
  end

  defp org_models(org) do
    case Models.allowed(org, Models.catalog()) do
      {:ok, options} -> options
      {:error, _reason} -> []
    end
  end

  defp inbound_agents(agents) do
    for agent <- agents,
        agent.role == "router",
        Agent.active?(agent),
        present?(agent.salix_agent_id),
        do: %{"id" => agent.salix_agent_id, "label" => agent_name(agent)}
  end

  defp agent_label(nil, _agents), do: nil

  defp agent_label(id, agents) do
    case Enum.find(agents, &(&1.salix_agent_id == id)) do
      nil -> id
      agent -> agent_name(agent)
    end
  end

  defp agent_name(agent) do
    [agent.salix["name"] || agent.salix_agent_id, agent.role]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp router_agent(project, {:ok, id}), do: Agents.get_project_agent(project.id, id)
  defp router_agent(_project, error), do: error

  # The group's current router (`router_agent_id` is an agent's
  # `salix_agent_id`).
  defp router_agent_id(project) do
    client = Client.impl()

    if function_exported?(client, :get_group, 1) do
      case client.get_group(project.salix_group_id) do
        {:ok, group} -> {:ok, group["router_agent_id"]}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      {:error, :get_group_unavailable}
    end
  end

  # The Slack bot's name defaults to the swarm's name, so it is recognizable
  # in the workspace without typing.
  defp default_slack_app_name(project) do
    case text(project.name) do
      nil -> "Comma"
      name -> name
    end
  end

  # Slack pre-fills "Create New App → From a manifest" from `manifest_json`.
  defp manifest(app_name) do
    case ProjectIMConnects.slack_manifest(app_name) do
      {:ok, %{"manifest" => manifest} = payload} ->
        %{
          "json" => Jason.encode!(manifest, pretty: true),
          "create_url" =>
            @slack_create_app_base <>
              "?" <> URI.encode_query(new_app: "1", manifest_json: Jason.encode!(manifest)),
          "redirect_url" => payload["redirect_url"],
          "events_url" => payload["events_url"],
          "interactions_url" => payload["interactions_url"]
        }

      _other ->
        nil
    end
  end

  # The webhook address to paste into Feishu: only its `app_id` query stays,
  # so no credential in the stored address is shown.
  defp display_webhook_url(%{"webhook_url" => url} = connect) when is_binary(url) and url != "" do
    uri = URI.parse(url)
    app_id = text(connect["app_id"]) || URI.decode_query(uri.query || "")["app_id"]
    query = if app_id, do: URI.encode_query(%{"app_id" => app_id})
    URI.to_string(%{uri | query: query})
  rescue
    _malformed -> nil
  end

  defp display_webhook_url(_connect), do: nil

  # The project's Signal chats (docs/messaging-voice.md); a runtime failure,
  # or a Salix client without Signal, makes only this section unavailable.
  defp signal(org, project) do
    case ProjectSignal.status(org, project) do
      {:ok, %{} = status} ->
        bindings = List.wrap(status["bindings"])

        %{
          "status" => "ok",
          "number" => get_in(status, ["account", "e164"]),
          "bindings" =>
            bindings |> Enum.take(@signal_binding_limit) |> Enum.map(&signal_binding/1),
          "bindings_truncated" => length(bindings) > @signal_binding_limit
        }

      _error ->
        %{
          "status" => "unavailable",
          "number" => nil,
          "bindings" => [],
          "bindings_truncated" => false
        }
    end
  end

  # Only swarm admins see the login link: whoever opens it adds the swarm's
  # node to their tailnet.
  defp tailnet(org, project, role) do
    case ProjectTailnet.status(org, project) do
      {:ok, %{} = status} ->
        status
        |> Map.take(
          ~w(enabled state approved login_url tailnet node_name login_name node_tags addresses key_expiry error settings updated_at)
        )
        |> Map.put("status", "ok")
        |> then(&if(role == "admin", do: &1, else: Map.delete(&1, "login_url")))

      _error ->
        %{"status" => "unavailable"}
    end
  end

  defp signal_binding(binding) do
    %{
      "binding_id" => binding["binding_id"],
      "display_name" => text(binding["display_name"]),
      "kind" => if(binding["kind"] == "group", do: "group", else: "person"),
      "number" => binding["number"]
    }
  end

  defp accounts(org, user, project) do
    available = ProjectOAuthConnections.list_available_providers(org.id)
    connections = ProjectOAuthConnections.list_connections(org.id, project.id)

    case {available, connections} do
      {{:ok, providers}, {:ok, connections}} ->
        if connections != [], do: :ok = Onboarding.observe_connected(org.id, user.id)

        %{
          "status" => "ok",
          "connections" => Enum.map(connections, &oauth_connection/1),
          "providers" =>
            Enum.map(providers, fn app ->
              %{
                "provider" => app["provider"],
                "ready" => ProjectOAuthConnections.provider_authorization_ready?(app)
              }
            end)
        }

      {available, connections} ->
        reason =
          Enum.find_value([connections, available], :unavailable, fn
            {:error, reason} -> reason
            _ok -> nil
          end)

        %{"status" => section_status(reason), "connections" => [], "providers" => []}
    end
  end

  defp oauth_connection(connection) do
    %{
      "binding_id" => connection["binding_id"],
      "provider" => connection["provider"],
      "alias" => text(connection["alias"]),
      "account" =>
        text(connection["provider_account_name"]) || text(connection["provider_account_id"]),
      "scopes" => Enum.filter(List.wrap(connection["scopes"]), &is_binary/1),
      "status" => connection["status"] || "active",
      "enabled" => Map.get(connection, "enabled", true) != false
    }
  end

  # Composio readiness is org-wide (one API key), so it degrades on its own.
  defp composio(org, project) do
    {configured, connections, status} =
      if ProjectComposioConnections.configured?(org.id) do
        case ProjectComposioConnections.list_connections(org.id, project.id) do
          {:ok, connections} -> {true, connections, "ok"}
          {:error, :not_configured} -> {false, [], "ok"}
          {:error, _reason} -> {true, [], "unavailable"}
        end
      else
        {false, [], "ok"}
      end

    %{
      "status" => status,
      "configured" => configured,
      "toolkits" =>
        Enum.map(ProjectComposioConnections.toolkits(), fn toolkit ->
          account =
            Enum.find(connections, fn account ->
              ProjectComposioConnections.connection_toolkit(account) == toolkit and
                ProjectComposioConnections.connection_active?(account)
            end)

          %{"toolkit" => toolkit, "account_id" => account && text(account["id"])}
        end)
    }
  end

  # ---- Writes: messaging ----

  @doc "Connect an org Feishu app to this swarm; the secrets stay in Salix."
  def create_feishu(org, user, project, role, params) do
    with :ok <- authorize_im(org, user, project, role, "integration.feishu.created") do
      app_id = text(params["app_id"])
      binding = app_id && FeishuAppBindings.get_binding_for_app(org.id, app_id)
      fallback = (binding && (binding.display_name || binding.app_id)) || "Bridge"
      attrs = %{"app_id" => app_id, "app_name" => text(params["app_name"]) || fallback}

      case ProjectIMConnects.create_project_connect(
             org.id,
             project.id,
             "feishu",
             attrs,
             audit_opts(user)
           ) do
        # A resubmitted app refreshes the existing connect; say which happened.
        {:ok, %{"action" => "resynced"}} ->
          {:ok,
           %{
             "notice" =>
               gettext(
                 "Reused the existing Feishu connect and refreshed its credentials from the org app."
               )
           }}

        {:ok, _connect} ->
          {:ok, %{"notice" => gettext("Feishu webhook connect ready.")}}

        {:error, reason} ->
          im_error(reason)
      end
    end
  end

  @doc """
  Connect a Lark app's bot to this swarm with the app's App ID, App Secret and
  the Verification Token or Encrypt Key of its event subscription.
  """
  def create_lark(org, user, project, role, params) do
    with :ok <- authorize_im(org, user, project, role, "integration.lark.created") do
      attrs =
        Map.new(~w(app_id app_secret verification_token encrypt_key), &{&1, text(params[&1])})

      cond do
        is_nil(attrs["verification_token"]) and is_nil(attrs["encrypt_key"]) ->
          {:error, 422, "missing_credentials",
           gettext(
             "Enter the Verification Token or the Encrypt Key of the Lark app. Lark signs events with them."
           ), %{"fields" => ["verification_token"]}}

        true ->
          case ProjectIMConnects.create_project_connect(
                 org.id,
                 project.id,
                 "lark",
                 attrs,
                 audit_opts(user)
               ) do
            {:ok, %{"action" => "resynced"}} ->
              {:ok, %{"notice" => gettext("Updated the Lark app's credentials.")}}

            {:ok, _connect} ->
              {:ok,
               %{
                 "notice" =>
                   gettext(
                     "Lark app connected. Save the request URL in the Lark Developer Console."
                   )
               }}

            {:error, :provider_app_in_use} ->
              {:error, 409, "provider_app_in_use",
               gettext(
                 "This Lark app is already connected to another Agent Swarm. One Lark app serves one Agent Swarm; delete the existing connect or use a different app."
               ), %{}}

            {:error, :connect_rejected} ->
              {:error, 422, "connect_rejected",
               gettext(
                 "Lark rejected these credentials. Check the App ID and App Secret, and that the app has the Bot capability and a published version."
               ), %{}}

            {:error, reason} ->
              im_error(reason)
          end
      end
    end
  end

  @doc "Connect a QQ bot to this swarm with the bot's AppID and AppSecret."
  def create_qq(org, user, project, role, params) do
    with :ok <- authorize_im(org, user, project, role, "integration.qq.created") do
      attrs = %{"app_id" => text(params["app_id"]), "app_secret" => text(params["app_secret"])}

      case ProjectIMConnects.create_project_connect(
             org.id,
             project.id,
             "qq",
             attrs,
             audit_opts(user)
           ) do
        {:ok, %{"action" => "resynced"}} ->
          {:ok, %{"notice" => gettext("Updated the QQ bot's credentials.")}}

        {:ok, _connect} ->
          {:ok,
           %{
             "notice" =>
               gettext("QQ bot connected. Save the callback address in the QQ bot console.")
           }}

        {:error, :provider_app_in_use} ->
          {:error, 409, "provider_app_in_use",
           gettext(
             "This QQ bot is already connected to another Agent Swarm. One QQ bot serves one Agent Swarm; delete the existing connect or use a different bot."
           ), %{}}

        {:error, :connect_rejected} ->
          {:error, 422, "connect_rejected",
           gettext("QQ rejected these credentials. Check the AppID and AppSecret and retry."),
           %{}}

        {:error, reason} ->
          im_error(reason)
      end
    end
  end

  @doc "Replace the shortcuts of a QQ bot's command menu; QQ gets the new menu at once."
  def update_qq_menu(org, user, project, role, connect_id, params) do
    with :ok <-
           authorize_im(org, user, project, role, "integration.qq.updated", %{
             "connect_id_configured" => present?(connect_id)
           }),
         {:ok, items} <- menu_items(params["items"]) do
      case ProjectIMConnects.update_project_qq_command_menu(
             org.id,
             project.id,
             connect_id,
             items,
             audit_opts(user)
           ) do
        {:ok, connect} ->
          {:ok, %{"notice" => qq_menu_notice(connect["command_menu_sync"])}}

        {:error, {:invalid_menu, message}} ->
          {:error, 422, "invalid_menu", message, %{}}

        {:error, reason} ->
          im_error(reason)
      end
    end
  end

  defp menu_items(items) when is_list(items), do: {:ok, items}

  defp menu_items(_items),
    do: {:error, 422, "invalid_menu", gettext("Send the menu items as a list."), %{}}

  # The bot's owner can have made a panel of their own in the QQ bot console;
  # that one stays, and this menu does not show in its place.
  defp qq_menu_notice(%{} = sync) do
    if "owner_panel" in Map.values(sync),
      do:
        gettext(
          "Menu saved. The bot has a command panel made in the QQ bot console, which QQ keeps showing. Delete that panel there to show this menu."
        ),
      else: gettext("Menu saved and sent to QQ.")
  end

  defp qq_menu_notice(_sync), do: gettext("Menu saved.")

  @doc "Create a Slack connect from the app the admin created from the manifest."
  def create_slack(org, user, project, role, params) do
    with :ok <- authorize_im(org, user, project, role, "integration.slack.created") do
      attrs = Map.take(params, @slack_fields)

      case ProjectIMConnects.create_project_connect(
             org.id,
             project.id,
             "slack",
             attrs,
             audit_opts(user)
           ) do
        {:ok, _connect} ->
          {:ok,
           %{
             "notice" =>
               gettext("Slack connect created. Open the install URL to finish the OAuth install.")
           }}

        {:error, reason} ->
          im_error(reason)
      end
    end
  end

  @doc "Turn a Feishu, Slack or QQ connect on or off; the request names the wanted state."
  def set_im_enabled(org, user, project, role, connect_id, params) do
    enabled = params["enabled"]
    name = if enabled == true, do: "enabled", else: "disabled"

    with :ok <-
           authorize_im(org, user, project, role, "integration.connect.#{name}", %{
             "connect_id_configured" => present?(connect_id)
           }),
         :ok <- boolean(enabled) do
      change =
        if enabled,
          do: &ProjectIMConnects.enable_project_connect/4,
          else: &ProjectIMConnects.disable_project_connect/4

      case change.(org.id, project.id, connect_id, audit_opts(user)) do
        {:ok, _connect} ->
          {:ok,
           %{
             "notice" =>
               if(enabled, do: gettext("Connect enabled."), else: gettext("Connect disabled."))
           }}

        {:error, reason} ->
          im_error(reason)
      end
    end
  end

  @doc "Delete a connect, which releases its provider app."
  def delete_im(org, user, project, role, connect_id) do
    with :ok <-
           authorize_im(org, user, project, role, "integration.connect.deleted", %{
             "connect_id_configured" => present?(connect_id)
           }) do
      case ProjectIMConnects.delete_project_connect(
             org.id,
             project.id,
             connect_id,
             audit_opts(user)
           ) do
        {:ok, _result} -> {:ok, %{"notice" => gettext("Connect deleted.")}}
        {:error, reason} -> im_error(reason)
      end
    end
  end

  @doc "Run the Feishu bot checks and record them for Health."
  def run_feishu_checks(org, user, project, role) do
    with :ok <-
           authorize_im(org, user, project, role, "integration.feishu.checks_run", %{
             "operation" => "run_checks"
           }) do
      case RunChecks.run_bot(org.id, project.id) do
        {:ok, checks} -> {:ok, recorded(checks, user)}
        {:error, _reason} -> checks_failed(gettext("Could not run Feishu checks."))
      end
    end
  end

  @doc "Run one Lark connect's checks and record them for Health."
  def run_lark_checks(org, user, project, role, connect_id) do
    with :ok <-
           authorize_im(org, user, project, role, "integration.lark.checks_run", %{
             "operation" => "run_checks",
             "connect_id_configured" => present?(connect_id)
           }) do
      case LarkRunChecks.run_bot(org.id, project.id, connect_id: connect_id) do
        {:ok, checks} -> {:ok, recorded(checks, user)}
        {:error, :connect_not_found} -> im_error(:connect_not_found)
        {:error, _reason} -> checks_failed(gettext("Could not run Lark checks."))
      end
    end
  end

  @doc "Run one Slack connect's calendar checks and record them for Health."
  def run_slack_checks(org, user, project, role, connect_id) do
    with :ok <-
           authorize_im(org, user, project, role, "integration.slack.calendar_checks_run", %{
             "operation" => "run_calendar_checks",
             "connect_id_configured" => present?(connect_id)
           }) do
      case RunChecks.run_slack_calendar(org.id, project.id, connect_id: connect_id) do
        {:ok, checks} -> {:ok, recorded(checks, user)}
        {:error, :connect_not_found} -> im_error(:connect_not_found)
        {:error, _reason} -> checks_failed(gettext("Could not run Slack calendar checks."))
      end
    end
  end

  defp recorded(checks, user) do
    recorded? =
      match?(
        {:ok, _check},
        Observability.record_run_checks_activity(checks, ran_by_user_id: user.id)
      )

    %{
      "checks" => RunChecks.to_json_map(checks),
      "recorded" => recorded?,
      "warning" =>
        if(recorded?, do: nil, else: gettext("Checks ran, but Operations could not record them."))
    }
  end

  defp checks_failed(message), do: {:error, 503, "checks_failed", message, %{}}

  @doc "A one-time Signal code; it appears only in this answer."
  def create_signal_claim(org, user, project, role) do
    with :ok <- authorize_signal(org, user, project, role, "project_signal.claim_started") do
      case ProjectSignal.start_claim(org, project, user.id) do
        {:ok, %{"claim" => %{} = claim}} ->
          {:ok, %{"claim" => %{"number" => claim["number"], "command" => claim["command"]}}}

        {:error, :not_configured} ->
          {:error, 409, "signal_not_configured",
           gettext("Signal has no number on this server yet."), %{}}

        _error ->
          {:error, 503, "write_failed", gettext("Couldn't create a Signal code."), %{}}
      end
    end
  end

  @doc "Disconnect one Signal chat; a call in progress ends."
  def remove_signal_binding(org, user, project, role, binding_id) do
    with :ok <- authorize_signal(org, user, project, role, "project_signal.binding_removed") do
      case ProjectSignal.remove_binding(org, project, binding_id) do
        {:ok, _status} ->
          {:ok, %{"notice" => gettext("Signal chat disconnected.")}}

        {:error, :not_found} ->
          {:error, 404, "signal_chat_not_found",
           gettext("That Signal chat is no longer connected."), %{}}

        {:error, _reason} ->
          {:error, 503, "write_failed", gettext("Couldn't disconnect the Signal chat."), %{}}
      end
    end
  end

  # ---- Writes: Tailscale ----

  @doc """
  Connect the swarm to the organization's tailnet, or change its settings.
  The result carries the tailnet status, with the login link while the node
  waits for a tailnet admin.
  """
  def connect_tailnet(org, user, project, role, params) do
    attrs = Map.take(params, ~w(tags accept_routes expected_tailnet))

    with :ok <- authorize_tailnet(org, user, project, role, "project_tailnet.connected") do
      case ProjectTailnet.connect(org, project, attrs, user.id) do
        {:ok, status} ->
          tailnet_written(org, user, project, "project_tailnet.connected")
          {:ok, %{"tailnet" => tailnet_view(status)}}

        {:error, reason}
        when reason in [:invalid_tags, :invalid_accept_routes, :invalid_expected_tailnet] ->
          {:error, 422, Atom.to_string(reason),
           gettext(
             "Use tags like tag:name (at most 8) and a tailnet name of at most 253 characters."
           ), %{}}

        {:error, _reason} ->
          {:error, 503, "write_failed", gettext("Couldn't save the Tailscale settings."), %{}}
      end
    end
  end

  @doc "Disconnect the swarm from its tailnet; its node logs out."
  def disconnect_tailnet(org, user, project, role) do
    with :ok <- authorize_tailnet(org, user, project, role, "project_tailnet.disconnected") do
      case ProjectTailnet.disconnect(org, project, user.id) do
        {:ok, status} ->
          tailnet_written(org, user, project, "project_tailnet.disconnected")

          {:ok,
           %{"tailnet" => tailnet_view(status), "notice" => gettext("Tailscale disconnected.")}}

        {:error, _reason} ->
          {:error, 503, "write_failed", gettext("Couldn't disconnect Tailscale."), %{}}
      end
    end
  end

  defp tailnet_view(status),
    do:
      status
      |> Map.take(
        ~w(enabled state approved login_url tailnet node_name login_name node_tags addresses key_expiry error settings updated_at)
      )
      |> Map.put("status", "ok")

  defp authorize_tailnet(org, user, project, role, action) do
    authorize(
      role,
      fn -> denied(org, user, project, action, "project_tailnet", "tailnet", %{}) end,
      gettext("Only Agent Swarm admins can manage Tailscale.")
    )
  end

  defp tailnet_written(org, user, project, action) do
    Observability.record_write_attempt(%{
      org_id: org.id,
      actor_user_id: user.id,
      actor_label: actor_label(user),
      action: action,
      resource_type: "project_tailnet",
      resource_label: project.name,
      result: "ok",
      request_id: SystemsRuntime.Proc.uuid(),
      surface: "tailnet",
      metadata: %{"project_id" => project.id, "salix_group_id" => project.salix_group_id}
    })
  end

  # ---- Writes: accounts ----

  @doc """
  Start connecting a managed-OAuth account after the reader confirmed it.
  `base_url` is the dashboard origin the provider returns the browser to.
  """
  def connect_account(org, user, project, role, params, base_url) do
    provider = text(params["provider"])

    with :ok <-
           authorize(
             role,
             fn ->
               denied(
                 org,
                 user,
                 project,
                 "project_oauth_connection.authorization_started",
                 "project_oauth_connection",
                 "oauth",
                 %{"provider_configured" => not is_nil(provider)}
               )
             end,
             gettext("Only Agent Swarm admins can connect accounts.")
           ) do
      attrs = %{
        "alias" => text(params["alias"]),
        "redirect_after" => return_to(base_url, org, project),
        "scopes" => ProviderScopes.scopes(provider, capabilities(user))
      }

      org.id
      |> ProjectOAuthConnections.start_connection(project.id, provider, attrs, audit_opts(user))
      |> started(&oauth_error/1)
    end
  end

  @doc "Turn a connected account on or off without deleting it."
  def set_account_enabled(org, user, project, role, binding_id, params) do
    enabled = params["enabled"]
    name = if enabled == true, do: "enabled", else: "disabled"

    with :ok <- authorize_account(org, user, project, role, name, binding_id),
         :ok <- boolean(enabled) do
      change =
        if enabled,
          do: &ProjectOAuthConnections.enable_connection/4,
          else: &ProjectOAuthConnections.disable_connection/4

      case change.(org.id, project.id, binding_id, audit_opts(user)) do
        {:ok, _binding} ->
          {:ok,
           %{
             "notice" =>
               if(enabled, do: gettext("Account enabled."), else: gettext("Account disabled."))
           }}

        {:error, reason} ->
          oauth_error(reason)
      end
    end
  end

  @doc "Disconnect an account; agents lose access to it."
  def delete_account(org, user, project, role, binding_id) do
    with :ok <- authorize_account(org, user, project, role, "deleted", binding_id) do
      case ProjectOAuthConnections.delete_connection(
             org.id,
             project.id,
             binding_id,
             audit_opts(user)
           ) do
        {:ok, _result} -> {:ok, %{"notice" => gettext("Account disconnected.")}}
        {:error, reason} -> oauth_error(reason)
      end
    end
  end

  @doc "Start connecting a Composio toolkit after the reader confirmed it."
  def connect_composio(org, user, project, role, toolkit, base_url) do
    with :ok <-
           authorize(
             role,
             fn ->
               denied(
                 org,
                 user,
                 project,
                 "project_composio_connection.authorization_started",
                 "composio_connection",
                 "composio",
                 %{"toolkit_configured" => present?(toolkit)}
               )
             end,
             gettext("Only Agent Swarm admins can connect accounts.")
           ) do
      org.id
      |> ProjectComposioConnections.start_connection(
        project.id,
        toolkit,
        %{"callback_url" => return_to(base_url, org, project)},
        audit_opts(user)
      )
      |> started(&composio_error/1)
    end
  end

  @doc "Disconnect a Composio account."
  def delete_composio(org, user, project, role, account_id) do
    with :ok <-
           authorize(
             role,
             fn ->
               denied(
                 org,
                 user,
                 project,
                 "project_composio_connection.deleted",
                 "composio_connection",
                 "composio",
                 %{"account_id_configured" => present?(account_id)}
               )
             end,
             gettext("Only Agent Swarm admins can manage connected accounts.")
           ) do
      case ProjectComposioConnections.delete_connection(
             org.id,
             project.id,
             account_id,
             audit_opts(user)
           ) do
        {:ok, _result} -> {:ok, %{"notice" => gettext("Account disconnected.")}}
        {:error, reason} -> composio_error(reason)
      end
    end
  end

  defp started({:ok, %{"authorization_url" => url}}, _error) when is_binary(url) and url != "",
    do: {:ok, %{"redirect_url" => url}}

  defp started({:ok, %{"redirect_url" => url}}, _error) when is_binary(url) and url != "",
    do: {:ok, %{"redirect_url" => url}}

  defp started({:ok, _payload}, error), do: error.(:no_redirect_url)
  defp started({:error, reason}, error), do: error.(reason)

  # The provider returns the browser to this page.
  defp return_to(base_url, org, project),
    do: "#{base_url}/orgs/#{org.slug}/projects/#{project.id}/connections"

  # The connecting user's granted capabilities (first-run onboarding); a user
  # who skipped onboarding has none and gets the provider defaults.
  defp capabilities(user) do
    case UserOnboardings.ensure_onboarding(user.id) do
      {:ok, onboarding} -> onboarding.capabilities || %{}
      _error -> %{}
    end
  end

  # ---- Authorization ----

  defp authorize("admin", _record, _message), do: :ok

  defp authorize(_role, record, message) do
    _ = record.()
    {:error, 403, "forbidden", message, %{}}
  end

  defp authorize_im(org, user, project, role, action, metadata \\ %{}) do
    authorize(
      role,
      fn ->
        denied(org, user, project, action, "project_im_connect", "integration", metadata)
      end,
      gettext("Only Agent Swarm admins can manage integrations.")
    )
  end

  defp authorize_signal(org, user, project, role, action) do
    authorize(
      role,
      fn -> denied(org, user, project, action, "project_signal", "signal", %{}) end,
      gettext("Only project admins can do this.")
    )
  end

  defp authorize_account(org, user, project, role, name, binding_id) do
    authorize(
      role,
      fn ->
        denied(
          org,
          user,
          project,
          "project_oauth_connection.#{name}",
          "project_oauth_connection",
          "oauth",
          %{"binding_id_configured" => present?(binding_id)}
        )
      end,
      gettext("Only Agent Swarm admins can manage connected accounts.")
    )
  end

  defp denied(org, user, project, action, resource_type, surface, metadata) do
    Observability.record_write_attempt(%{
      org_id: org.id,
      actor_user_id: user.id,
      actor_label: actor_label(user),
      action: action,
      resource_type: resource_type,
      resource_label: project.name,
      result: "denied",
      reason: :forbidden,
      request_id: SystemsRuntime.Proc.uuid(),
      surface: surface,
      metadata:
        Map.merge(
          %{
            "project_id" => project.id,
            "salix_group_id" => project.salix_group_id,
            "surface" => surface
          },
          metadata
        )
    })
  end

  defp boolean(value) when is_boolean(value), do: :ok

  defp boolean(_value),
    do: {:error, 422, "invalid_enablement", gettext("Choose on or off."), %{}}

  # ---- Errors ----

  defp section_status(:group_not_ready), do: "preparing"
  defp section_status(_reason), do: "unavailable"

  defp im_error(:group_not_ready),
    do:
      {:error, 409, "group_not_ready", gettext("Agent Swarm is still preparing. Retry shortly."),
       %{}}

  defp im_error(:unsupported_provider),
    do: {:error, 422, "unsupported_provider", gettext("That IM provider is not supported."), %{}}

  defp im_error(:connect_not_found),
    do: {:error, 404, "connect_not_found", gettext("That connect no longer exists."), %{}}

  defp im_error({:missing_credentials, fields}),
    do:
      {:error, 422, "missing_credentials",
       gettext("Connect is missing required fields: %{fields}.", fields: Enum.join(fields, ", ")),
       %{"fields" => fields}}

  defp im_error(:feishu_app_mismatch),
    do:
      {:error, 422, "feishu_app_mismatch",
       gettext(
         "The organization's Feishu bot app is a different app now. Reload the page and choose it again."
       ), %{}}

  defp im_error(:feishu_app_secret_missing),
    do:
      {:error, 422, "feishu_app_secret_missing",
       gettext(
         "The organization's Feishu app has no app secret. An organization admin must add it in organization settings."
       ), %{}}

  defp im_error(:workers_retired) do
    message =
      gettext(
        "Workers are retired. Deliver to the Router, or make each new thread a Task that runs a model."
      )

    {:error, 410, "workers_retired", message, %{"fields" => %{"inbound_agent_id" => [message]}}}
  end

  defp im_error(:model_not_allowed) do
    message = gettext("Choose a model this organization allows.")
    {:error, 422, "model_not_allowed", message, %{"fields" => %{"inbound_tasks" => [message]}}}
  end

  defp im_error(:invalid_inbound_agent) do
    message = gettext("Choose the Router of this Agent Swarm, or Tasks.")

    {:error, 422, "invalid_inbound_agent", message,
     %{"fields" => %{"inbound_agent_id" => [message]}}}
  end

  defp im_error(:connect_rejected),
    do:
      {:error, 422, "connect_rejected",
       gettext("The provider rejected the connect setup. Check the app credentials and retry."),
       %{}}

  defp im_error(:provider_app_in_use),
    do:
      {:error, 409, "provider_app_in_use",
       gettext(
         "This Feishu app is already connected to another Agent Swarm. Current limitation: one Feishu app can serve one Agent Swarm; delete the existing connect or use a different app."
       ), %{}}

  defp im_error(:unavailable),
    do: {:error, 503, "runtime_unavailable", gettext("Salix is unavailable. Retry shortly."), %{}}

  defp im_error(:timeout),
    do: {:error, 503, "runtime_unavailable", gettext("Salix timed out. Retry shortly."), %{}}

  defp im_error(_reason),
    do: {:error, 503, "write_failed", gettext("Could not update the IM connect."), %{}}

  defp oauth_error(:group_not_ready),
    do:
      {:error, 409, "group_not_ready", gettext("The runtime is not ready yet. Retry shortly."),
       %{}}

  defp oauth_error(reason) when reason in [:provider_not_configured, :not_configured],
    do:
      {:error, 422, "provider_not_configured",
       gettext("That platform isn't configured for your organization yet."), %{}}

  defp oauth_error({:precondition_failed, _detail}), do: oauth_error(:provider_not_configured)

  defp oauth_error(:not_found),
    do: {:error, 404, "account_not_found", gettext("That account is no longer connected."), %{}}

  defp oauth_error({:bad_request, _detail}),
    do:
      {:error, 422, "connection_rejected",
       gettext("The platform rejected the authorization request."), %{}}

  defp oauth_error(reason) when reason in [:unavailable, :timeout],
    do:
      {:error, 503, "runtime_unavailable",
       gettext("Salix is unavailable right now. Retry shortly."), %{}}

  defp oauth_error(_reason),
    do:
      {:error, 503, "write_failed", gettext("Could not connect the account. Please try again."),
       %{}}

  defp composio_error(:group_not_ready), do: oauth_error(:group_not_ready)

  defp composio_error(:not_configured),
    do:
      {:error, 422, "composio_not_configured",
       gettext("Composio isn't configured for your organization yet."), %{}}

  defp composio_error(:no_redirect_url),
    do:
      {:error, 503, "write_failed", gettext("Could not start the connection. Please try again."),
       %{}}

  defp composio_error(:google_admin_custom_oauth_required),
    do:
      {:error, 422, "custom_oauth_required",
       gettext(
         "Configure a Google Admin OAuth app in Composio with Directory group read scopes before connecting."
       ), %{}}

  defp composio_error({:bad_request, _detail}),
    do:
      {:error, 422, "connection_rejected",
       gettext("The platform rejected the connection request."), %{}}

  defp composio_error(reason), do: oauth_error(reason)

  # ---- Helpers ----

  defp public_project(project, role),
    do: %{"id" => project.id, "name" => project.name, "role" => role}

  defp audit_opts(user),
    do: [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: SystemsRuntime.Proc.uuid()
    ]

  defp actor_label(user), do: text(user.email) || text(user.name) || user.id

  # An address the browser may open: http(s) only.
  defp web_url(value) do
    with url when is_binary(url) <- text(value),
         %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(url) do
      url
    else
      _other -> nil
    end
  end

  # Salix reports times in unix seconds or milliseconds.
  defp iso_timestamp(value) when is_integer(value) do
    unit = if value > 99_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _invalid -> nil
    end
  end

  defp iso_timestamp(_value), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
