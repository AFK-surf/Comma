defmodule BridgeForTeamsWeb.DashboardSettings do
  @cli_session_limit 50
  @feishu_app_limit 50
  @route_project_limit 50
  @waiting_member_limit 20

  @moduledoc """
  Builds the Settings page payloads and applies settings writes for
  `DashboardAPIController`.

  Settings are an owner/admin surface. The controller answers other members
  with 403 and records a denied audit entry for a refused write; the functions
  here assume an authorized caller. Every write returns the refreshed section,
  so the client does not need a second read.

  Reads use a fixed number of database queries:

    * General lists the caller's newest #{@cli_session_limit} BFT CLI sessions.
    * Integrations lists up to #{@feishu_app_limit} Feishu apps, up to
      #{@route_project_limit} Agent Swarms and up to #{@waiting_member_limit}
      members waiting for an OAuth app.
      It asks Salix for the Feishu bot routes of those Agent Swarms (one call
      each) only when a bot-enabled Feishu app exists, so the Salix calls have
      the same bound. A `*_truncated` flag marks a list that hit its limit.
      The route lookup stops at the first unavailable or timed-out Salix call
      and has a time budget (see
      `BridgeForTeams.ProjectIMConnects.list_connects_for_projects/2`): a
      degraded Salix adds at most about 18 s to the read, or to a Feishu
      write, which returns the refreshed section, and gives
      `routes_status: "unavailable"`.

  Secrets are write-only. Responses carry `*_configured` flags, never secret
  values.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{
    FeishuAppBindings,
    FeishuScopes,
    LarkRunChecks,
    Models,
    Observability,
    Onboarding,
    OrgComposioSettings,
    OrgOAuthApps,
    OrgSignalNumber,
    Orgs,
    ProjectIMConnects,
    Projects,
    RunChecks
  }

  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeamsWeb.{I18n, MacMiniRelease}
  alias BridgeForTeamsWeb.Dashboard.CoreComponents

  @org_fields ~w(name slug icon default_locale)
  @sso_fields ~w(provider issuer client_id client_secret allowed_domains default_role)
  @sso_providers ~w(generic_oidc feishu lark)
  @sso_roles ~w(admin member)
  @feishu_provisioning_policies ~w(jit existing_identity)
  @feishu_default_scope "contact:user.base:readonly"
  @feishu_app_fields ~w(app_id display_name app_secret verification_token encrypt_key
                        sso_enabled bot_enabled)

  # Brand names and developer-console URLs (where an admin creates an OAuth
  # app) for the providers Salix supports. Unknown providers fall back to a
  # capitalized label and no console link.
  @oauth_provider_info %{
    "feishu" => {"Feishu", "https://open.feishu.cn/app"},
    "github" => {"GitHub", "https://github.com/settings/applications/new"},
    "google" => {"Google", "https://console.cloud.google.com/apis/credentials"},
    "lark" => {"Lark", "https://open.larksuite.com/app"},
    "linear" => {"Linear", "https://linear.app/settings/api/applications/new"},
    "notion" => {"Notion", "https://www.notion.so/my-integrations"},
    "slack" => {"Slack", "https://api.slack.com/apps"},
    "x" => {"X", "https://console.x.com"}
  }
  @oauth_app_name "Comma Bridge for Teams"
  @linear_oauth_app_create_url "https://linear.app/settings/api/applications/new"
  @slack_app_create_url "https://api.slack.com/apps"
  @github_app_create_url "https://github.com/settings/apps/new"

  # ---- General ----

  @doc "The General page: the org profile and the caller's BFT CLI access."
  def general(org, user) do
    %{
      "organization" => %{
        "name" => org.name,
        "slug" => org.slug,
        "icon" => org.icon,
        "default_locale" => org.default_locale
      },
      "locale_options" =>
        Enum.map(I18n.options(), fn {label, value} -> %{"value" => value, "label" => label} end),
      "cli" => cli(user)
    }
  end

  @doc "Update the org profile. Only the profile fields are written."
  def update_general(org, user, params) do
    attrs = Map.take(params, @org_fields)

    case Orgs.update_org(org, attrs, audit_opts(user)) do
      {:ok, org} ->
        {:ok, general(org, user)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, 422, "invalid_organization", gettext("Couldn't update organization."),
         %{"fields" => field_errors(changeset)}}

      {:error, _reason} ->
        write_failed(gettext("Couldn't update organization."))
    end
  end

  @doc "Revoke one of the caller's BFT CLI sessions. Unknown sessions are a no-op."
  def revoke_cli_session(user, session_id) do
    case Ecto.UUID.cast(session_id) do
      {:ok, session_id} ->
        :ok = CLILogin.revoke_cli_session_for_user(user, session_id)
        {:ok, cli(user)}

      :error ->
        {:error, 404, "cli_session_not_found", gettext("BFT CLI session not found."), %{}}
    end
  end

  defp cli(user) do
    api_base_url = MacMiniRelease.api_base_url()
    sessions = CLILogin.list_cli_sessions(user, limit: @cli_session_limit + 1)

    %{
      "api_base_url" => api_base_url,
      "config_path" => "~/.bridge-for-teams/cli.json",
      "install_command" => "curl -fsSL #{shell_quote(api_base_url <> "/v1/cli/install.sh")} | sh",
      "login_command" =>
        "bft auth login --url #{shell_quote(api_base_url)} --output text\n" <>
          "bft onboarding smoke --step cli-login",
      "sessions" => sessions |> Enum.take(@cli_session_limit) |> Enum.map(&public_cli_session/1),
      "sessions_truncated" => length(sessions) > @cli_session_limit
    }
  end

  defp public_cli_session(session) do
    %{
      "id" => session.id,
      "client_name" => session.client_name,
      "device" => session.device,
      "created_at" => session.created_at,
      "last_seen_at" => session.last_seen_at,
      "expires_at" => session.expires_at
    }
  end

  defp shell_quote(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    ~s("#{escaped}")
  end

  # ---- AI models ----

  # One save takes at most this many allowed choices (the catalog has fewer),
  # and asks Salix to check at most this many that are neither stored nor
  # plain catalog choices.
  @max_allowed_models 500
  @max_salix_checks 20
  @default_fields %{
    "router" => "default_router_model",
    "task" => "default_task_model"
  }

  @doc """
  The AI models page: the catalog choices, the org's allowed list, the
  default Router model and the org default Task model (the Task model of a
  swarm without its own), and the platform model that each follows.

  Each option says what serves it for the org (`served_by`): `"subscription"`
  (with its `plans`), `"api_key"`, `"platform"`, or nil when none of the org's
  accounts does. Pay-per-use is a choice of its own: a model that Provider API
  keys serve is offered with `allow_paid` true, its `key_sources` naming those
  keys, beside the plain choice when a subscription serves it too (whose
  `key_sources` then say it is also available pay-per-use). `catalog` also
  holds allowed and default choices that the catalog does not name, and the
  models a custom endpoint lists. `servable_status` is `"unavailable"` when
  what serves each model could not be read.
  """
  def models(org), do: models(org, Models.catalog())

  defp models(org, catalog_result) do
    {servable_status, served} =
      case Models.servable(org) do
        {:ok, served} -> {"ok", served}
        {:error, _reason} -> {"unavailable", %{}}
      end

    {status, catalog} =
      case catalog_result do
        {:ok, catalog} -> {"ok", offered_choices(catalog, served)}
        {:error, _reason} -> {"unavailable", []}
      end

    allowed = Enum.map(org.allowed_models || [], &Models.option(&1, catalog))
    router = default_option(org.default_router_model, catalog)
    task = default_option(org.default_task_model, catalog)
    offered = if allowed == [], do: catalog, else: allowed
    platform = Models.platform_defaults()
    source = &sourced(&1, served)

    %{
      "catalog_status" => status,
      "servable_status" => servable_status,
      "catalog" =>
        (catalog ++ allowed ++ Enum.reject([router, task], &is_nil/1))
        |> Enum.uniq_by(& &1["key"])
        |> Enum.map(source),
      "allowed_models" => Enum.map(allowed, source),
      "default_router_model" => router && source.(router),
      "default_task_model" => task && source.(task),
      "default_options" => %{
        "router" => offered |> with_current(router) |> Enum.map(source),
        "task" => offered |> with_current(task) |> Enum.map(source)
      },
      "platform_defaults" => %{
        "router" => platform["router"],
        "task" => platform["worker"]
      }
    }
  end

  # The plain choice of each catalog model that a subscription serves or
  # nothing serves, and the pay-per-use choice of each model a key serves,
  # then the pay-per-use choices of the models a custom endpoint lists.
  defp offered_choices(catalog, served) do
    names = MapSet.new(catalog, & &1["choice"]["model"])

    listed =
      for {id, model} <- served, not MapSet.member?(names, id) do
        choice = Models.normalize(%{"kind" => "catalog", "model" => id})

        %{"key" => Models.key(choice), "choice" => choice, "label" => model["label"]}
        |> Map.put("vendor", model["vendor"])
      end
      |> Enum.sort_by(& &1["label"])

    Enum.flat_map(catalog ++ listed, fn option ->
      case served[option["choice"]["model"]] do
        %{"served_by" => "api_key"} -> [paid(option)]
        %{"key_sources" => [_ | _]} -> [option, paid(option)]
        _subscription_or_none -> [option]
      end
    end)
  end

  defp paid(option) do
    choice = Map.put(option["choice"], "allow_paid", true)
    %{option | "choice" => choice, "key" => Models.key(choice)}
  end

  defp sourced(option, served) do
    {served_by, plans, key_sources} =
      case option["choice"] do
        %{"kind" => "catalog", "model" => id, "allow_paid" => true} ->
          case served[id] do
            %{"key_sources" => [_ | _] = sources} -> {"api_key", [], sources}
            _none -> {nil, [], []}
          end

        %{"kind" => "catalog", "model" => id} ->
          case served[id] do
            %{"served_by" => "subscription"} = model ->
              {"subscription", model["plans"], model["key_sources"]}

            _none ->
              {nil, [], []}
          end

        %{"kind" => "platform"} ->
          {"platform", [], []}

        _other ->
          {nil, [], []}
      end

    Map.merge(option, %{"served_by" => served_by, "plans" => plans, "key_sources" => key_sources})
  end

  defp default_option(nil, _catalog), do: nil
  defp default_option(choice, catalog), do: Models.option(choice, catalog)

  defp with_current(options, nil), do: options

  defp with_current(options, current) do
    if Enum.any?(options, &(&1["key"] == current["key"])),
      do: options,
      else: options ++ [current]
  end

  @doc """
  Save the allowed models, the default Router model and the org default Task
  model, each a model choice
  (`BridgeForTeams.Models`). An absent field keeps its current value; `[]`
  allows every model and `null` follows the platform model. Salix checks each
  choice; an allowed choice that Salix refuses (for example a retired model)
  is dropped, so a list of only retired models allows every model.
  """
  def update_models(org, user, params) do
    catalog_result = Models.catalog()

    with {:ok, allowed} <- allowed_models(params, org, catalog_result),
         {:ok, router} <- default_model(params, org, "router", catalog_result),
         {:ok, task} <- default_model(params, org, "task", catalog_result),
         :ok <- ensure_defaults_allowed(org, user, allowed, router, task) do
      attrs = %{
        "allowed_models" => allowed,
        "default_router_model" => router,
        "default_task_model" => task
      }

      case Orgs.update_org(org, attrs, audit_opts(user)) do
        {:ok, org} ->
          {:ok, models(org, catalog_result)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, 422, "invalid_model_settings", gettext("Couldn't save the model settings."),
           %{"fields" => field_errors(changeset)}}

        {:error, _reason} ->
          write_failed(gettext("Couldn't save the model settings."))
      end
    end
  end

  defp allowed_models(params, org, catalog_result) do
    case Map.fetch(params, "allowed_models") do
      :error ->
        {:ok, org.allowed_models || []}

      {:ok, choices} when is_list(choices) and length(choices) <= @max_allowed_models ->
        if Enum.all?(choices, &is_map/1),
          do:
            choices
            |> Enum.map(&Models.normalize/1)
            |> Enum.uniq()
            |> choose_allowed(org, catalog_result),
          else: invalid_model_settings()

      {:ok, _other} ->
        invalid_model_settings()
    end
  end

  # A choice kept from the stored list needs no new check.
  defp choose_allowed(choices, org, catalog_result) do
    stored = org.allowed_models || []

    salix_checks =
      Enum.count(choices, &(&1 not in stored and not Models.in_catalog?(&1, catalog_result)))

    if salix_checks > @max_salix_checks,
      do: invalid_model_settings(),
      else: choose_each(choices, stored, org, catalog_result)
  end

  defp choose_each(choices, stored, org, catalog_result) do
    Enum.reduce_while(choices, {:ok, []}, fn choice, {:ok, acc} ->
      result =
        if choice in stored, do: {:ok, choice}, else: Models.choose(org, choice, catalog_result)

      case result do
        {:ok, value} ->
          {:cont, {:ok, [value | acc]}}

        {:error, reason} when reason in [:unavailable, :timeout] ->
          {:halt, write_failed(gettext("Couldn't save the model settings."))}

        {:error, _refused} ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp default_model(params, org, role, catalog_result) do
    field = @default_fields[role]
    current = Map.fetch!(org, String.to_existing_atom(field))

    case Map.fetch(params, field) do
      :error ->
        {:ok, current}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, choice} when is_map(choice) ->
        if Models.normalize(choice) == current,
          do: {:ok, current},
          else: choose_default(org, field, choice, catalog_result)

      {:ok, _other} ->
        invalid_model_settings()
    end
  end

  defp choose_default(org, field, choice, catalog_result) do
    case Models.choose(org, choice, catalog_result) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} when reason in [:unavailable, :timeout] ->
        write_failed(gettext("Couldn't save the model settings."))

      {:error, _refused} ->
        {:error, 422, "invalid_model_settings", gettext("Couldn't save the model settings."),
         %{"fields" => %{field => [gettext("Choose a model from the list.")]}}}
    end
  end

  defp invalid_model_settings,
    do: {:error, 422, "invalid_model_settings", gettext("Couldn't save the model settings."), %{}}

  defp ensure_defaults_allowed(org, user, allowed, router, task) do
    disallowed =
      for {field, default} <- [
            {"default_router_model", router},
            {"default_task_model", task}
          ],
          default && allowed != [] && default not in allowed,
          do: field

    if disallowed == [] do
      :ok
    else
      _ =
        Observability.record_validation_event(%{
          org_id: org.id,
          actor_user_id: user.id,
          surface: "models",
          resource_type: "model_settings",
          resource_id: org.id,
          resource_label: org.name,
          status: "fail",
          reason_class: "default_model_not_allowed",
          evidence: %{
            "allowed_model_count" => length(allowed),
            "field_errors" => Map.new(disallowed, &{&1, ["must be one of the allowed models"]})
          }
        })

      {:error, 422, "default_model_not_allowed",
       gettext("The default model must be one of the allowed models."), %{"fields" => disallowed}}
    end
  end

  # ---- Single sign-on ----

  @doc "The Single sign-on page: the connection and the Feishu app it reuses."
  def sso(org) do
    %{
      "connection" => org.id |> Orgs.get_sso_connection() |> public_sso(),
      "feishu_app" => org.id |> FeishuAppBindings.latest_sso_binding() |> public_sso_app(),
      "redirect_uri" => redirect_uri(),
      "providers" => @sso_providers,
      "roles" => @sso_roles,
      "provisioning_policies" => @feishu_provisioning_policies,
      "default_feishu_scope" => @feishu_default_scope
    }
  end

  @doc """
  Save the SSO connection. A Feishu connection takes its App ID from the
  Feishu app enabled for sign-in; its secret stays the one that app saved.
  A Lark connection holds the App ID (`client_id`) and App Secret
  (`client_secret`) of its own Lark app. A blank `client_secret` keeps the
  stored secret while the provider stays the same.
  """
  def update_sso(org, user, params) do
    with {:ok, attrs} <- sso_attrs(org, params) do
      case Orgs.upsert_sso_connection(org.id, attrs, audit_opts(user)) do
        {:ok, _sso} ->
          {:ok, sso(org)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, 422, "invalid_sso_connection", gettext("Couldn't save the SSO connection."),
           %{"fields" => field_errors(changeset)}}

        {:error, _reason} ->
          write_failed(gettext("Couldn't save the SSO connection."))
      end
    end
  end

  defp sso_attrs(org, params) do
    attrs =
      case params["provider_config"] do
        %{} = config ->
          params
          |> Map.take(@sso_fields)
          |> Map.put("provider_config", Map.take(config, ~w(scope provisioning_policy)))

        _ ->
          Map.take(params, @sso_fields)
      end

    if attrs["provider"] == "feishu" do
      case FeishuAppBindings.latest_sso_binding(org.id) do
        %{app_id: app_id} when is_binary(app_id) ->
          {:ok, Map.put(attrs, "client_id", app_id)}

        _ ->
          {:error, 422, "feishu_app_required",
           gettext("No Feishu app is enabled for sign-in yet."), %{}}
      end
    else
      {:ok, attrs}
    end
  end

  @doc """
  Run the SSO checks and record them in Operations. A failed recording still
  returns the checks, with `recorded: false`.
  """
  def run_sso_checks(org, user) do
    case run_provider_sso_checks(org) do
      {:ok, checks} ->
        recorded? =
          match?(
            {:ok, _check},
            Observability.record_run_checks_activity(checks, ran_by_user_id: user.id)
          )

        {:ok,
         %{
           "checks" => RunChecks.to_json_map(checks),
           "recorded" => recorded?,
           "warning" =>
             if(recorded?,
               do: nil,
               else: gettext("Checks ran, but Operations could not record them.")
             )
         }}

      {:error, _reason} ->
        {:error, 500, "checks_failed", gettext("Could not run SSO checks."), %{}}
    end
  end

  # Lark sign-in has its own checks; every other provider keeps the shared ones.
  defp run_provider_sso_checks(org) do
    case Orgs.get_sso_connection(org.id) do
      %{provider: "lark"} -> LarkRunChecks.run_sso(org.id, redirect_uri: redirect_uri())
      _ -> RunChecks.run_sso(org.id, redirect_uri: redirect_uri())
    end
  end

  defp public_sso(nil), do: nil

  defp public_sso(sso) do
    config = sso.provider_config || %{}

    %{
      "provider" => sso.provider,
      "issuer" => sso.issuer,
      "client_id" => sso.client_id,
      "client_secret_configured" => present?(sso.client_secret),
      "allowed_domains" => sso.allowed_domains || [],
      "default_role" => sso.default_role || "member",
      "provider_config" => %{
        "scope" => config["scope"],
        "provisioning_policy" => config["provisioning_policy"] || "jit"
      },
      "last_verified_at" => sso.last_verified_at
    }
  end

  defp public_sso_app(nil), do: nil

  defp public_sso_app(binding) do
    %{
      "id" => binding.id,
      "app_id" => binding.app_id,
      "display_name" => binding.display_name,
      "app_secret_configured" => binding.app_secret_configured
    }
  end

  # ---- Integrations ----

  @doc "The Integrations page: every section in one bounded payload."
  def integrations(org) do
    %{
      "oauth" => oauth(org),
      "composio" => composio(org),
      "signal" => signal(org),
      "feishu" => feishu(org)
    }
  end

  @doc "Save an OAuth provider app. A blank `client_secret` keeps the stored one."
  def save_oauth_app(org, user, provider, params) do
    attrs = Map.take(params, ~w(client_id client_secret))

    case OrgOAuthApps.upsert_org_oauth_app(org.id, provider, attrs, audit_opts(user)) do
      {:ok, _app} ->
        Onboarding.invalidate_oauth_cache(org.id)
        {:ok, oauth(org)}

      {:error, {:bad_request, message}} when is_binary(message) ->
        {:error, 422, "invalid_oauth_app", message, %{}}

      {:error, reason} ->
        runtime_error(
          reason,
          gettext("Couldn't save the OAuth app (%{reason}).", reason: describe_error(reason))
        )
    end
  end

  @doc "Remove an OAuth provider app."
  def delete_oauth_app(org, user, provider) do
    case OrgOAuthApps.delete_org_oauth_app(org.id, provider, audit_opts(user)) do
      {:ok, _result} ->
        Onboarding.invalidate_oauth_cache(org.id)
        {:ok, oauth(org)}

      {:error, reason} ->
        runtime_error(
          reason,
          gettext("Couldn't remove the OAuth app (%{reason}).", reason: describe_error(reason))
        )
    end
  end

  @doc "Save the Composio settings. A blank `api_key` keeps the stored key."
  def save_composio(org, user, params) do
    attrs = Map.take(params, ~w(api_key base_url enabled))

    case OrgComposioSettings.upsert_org_composio_settings(org.id, attrs, audit_opts(user)) do
      {:ok, _view} ->
        {:ok, composio(org)}

      {:error, {:bad_request, message}} when is_binary(message) ->
        {:error, 422, "invalid_composio_settings", message, %{}}

      {:error, reason} ->
        runtime_error(
          reason,
          gettext("Couldn't save the Composio settings (%{reason}).",
            reason: describe_error(reason)
          )
        )
    end
  end

  @doc "Remove the Composio settings."
  def delete_composio(org, user) do
    case OrgComposioSettings.delete_org_composio_settings(org.id, audit_opts(user)) do
      {:ok, _result} ->
        {:ok, composio(org)}

      {:error, reason} ->
        runtime_error(
          reason,
          gettext("Couldn't remove the Composio settings (%{reason}).",
            reason: describe_error(reason)
          )
        )
    end
  end

  @doc "Set the org's own Signal number; a blank number returns to the platform number."
  def save_signal(org, user, params) do
    number = if is_binary(params["number"]), do: params["number"], else: ""

    case OrgSignalNumber.put(org.id, number, audit_opts(user)) do
      {:ok, _view} -> {:ok, signal(org)}
      {:error, reason} -> signal_error(reason)
    end
  end

  @doc """
  Create (`id` nil) or update a Feishu app. Saving an app with an existing
  App ID updates that app. Secrets are write-only; a blank one keeps the
  stored value.
  """
  def save_feishu_app(org, user, id, params) do
    attrs = Map.take(params, @feishu_app_fields)

    with {:ok, attrs} <- put_feishu_app_id(attrs, id) do
      case FeishuAppBindings.upsert_binding(org.id, attrs, audit_opts(user)) do
        {:ok, _binding} -> {:ok, feishu(org)}
        {:error, reason} -> feishu_app_error(reason)
      end
    end
  end

  defp put_feishu_app_id(attrs, nil), do: {:ok, attrs}

  defp put_feishu_app_id(attrs, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, Map.put(attrs, "id", id)}
      :error -> feishu_app_not_found()
    end
  end

  @doc "Delete a Feishu app and disconnect the SSO and bot secrets it owns."
  def delete_feishu_app(org, user, id) do
    with {:ok, id} <- cast_feishu_app_id(id) do
      case FeishuAppBindings.delete_binding(org.id, id, audit_opts(user)) do
        {:ok, _binding} ->
          {:ok, feishu(org)}

        {:error, :not_found} ->
          feishu_app_not_found()

        {:error, reason} ->
          runtime_error(
            reason,
            gettext("Couldn't remove the Feishu app (%{reason}).", reason: describe_error(reason))
          )
      end
    end
  end

  defp cast_feishu_app_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> feishu_app_not_found()
    end
  end

  defp feishu_app_not_found,
    do: {:error, 404, "feishu_app_not_found", gettext("Feishu app not found."), %{}}

  # The OAuth section. The setup link and console label stay server-owned
  # because they embed this deployment's callback URLs.
  defp oauth(org) do
    {status, apps} =
      case OrgOAuthApps.list_org_oauth_apps(org.id) do
        {:ok, apps} -> {"ok", apps}
        {:error, _reason} -> {"unavailable", []}
      end

    waiting = Onboarding.pending_oauth_reminders(org.id, limit: @waiting_member_limit + 1)

    %{
      "status" => status,
      "apps" => Enum.map(apps, &public_oauth_app/1),
      "waiting_members" => %{
        "names" =>
          waiting
          |> Enum.take(@waiting_member_limit)
          |> Enum.map(fn %{user: user} -> user.name || user.email || user.id end),
        "truncated" => length(waiting) > @waiting_member_limit
      }
    }
  end

  defp public_oauth_app(app) do
    provider = to_string(app["provider"])

    %{
      "provider" => provider,
      "label" => provider_label(provider),
      "client_id" => app["client_id"],
      "client_secret_configured" => app["client_secret_configured"] == true,
      "source" => app["source"],
      "configured" =>
        app["client_secret_configured"] == true or (app["client_id"] || "") != "" or
          app["source"] == "default",
      "setup_href" => provider_setup_url(provider),
      "setup_config" => setup_config(provider)
    }
  end

  defp setup_config("x"),
    do: %{
      "app_name" => @oauth_app_name,
      "callback_url" => salix_oauth_callback_url("x"),
      "website_url" => MacMiniRelease.api_base_url()
    }

  # A Lark app is the swarm's Lark bot app: the admin adds the redirect URL
  # under Security Settings and enters its App ID and App Secret here.
  defp setup_config("lark"), do: %{"callback_url" => salix_oauth_callback_url("lark")}

  # A Feishu app is the organization's Feishu app, set up the same way.
  defp setup_config("feishu"), do: %{"callback_url" => salix_oauth_callback_url("feishu")}

  defp setup_config(_provider), do: nil

  defp composio(org) do
    case OrgComposioSettings.get_org_composio_settings(org.id) do
      {:ok, view} ->
        %{
          "status" => "ok",
          "enabled" => view["enabled"] == true,
          "api_key_configured" => view["api_key_configured"] == true,
          "base_url" => view["base_url"],
          "source" => view["source"]
        }

      {:error, _reason} ->
        %{
          "status" => "unavailable",
          "enabled" => false,
          "api_key_configured" => false,
          "base_url" => nil,
          "source" => nil
        }
    end
  end

  defp signal(org) do
    case OrgSignalNumber.get(org.id) do
      {:ok, view} ->
        %{
          "status" => "ok",
          "override_e164" => get_in(view, ["override", "e164"]),
          "platform_e164" => get_in(view, ["platform", "e164"]),
          "effective_e164" => get_in(view, ["effective", "e164"])
        }

      {:error, _reason} ->
        %{
          "status" => "unavailable",
          "override_e164" => nil,
          "platform_e164" => nil,
          "effective_e164" => nil
        }
    end
  end

  defp feishu(org) do
    apps = FeishuAppBindings.list_bindings(org.id, limit: @feishu_app_limit + 1)
    projects = Projects.list_projects(org.id, limit: @route_project_limit + 1)
    shown_apps = Enum.take(apps, @feishu_app_limit)
    shown_projects = Enum.take(projects, @route_project_limit)

    {routes, routes_status} =
      if Enum.any?(shown_apps, & &1.bot_enabled) do
        {pairs, error} = ProjectIMConnects.list_connects_for_projects(shown_projects, "feishu")
        {routes_by_app(org, pairs), if(error, do: "unavailable", else: "ok")}
      else
        {%{}, "skipped"}
      end

    %{
      "apps" => Enum.map(shown_apps, &public_feishu_app(&1, routes)),
      "apps_truncated" => length(apps) > @feishu_app_limit,
      "routes_status" => routes_status,
      "projects_shown" => length(shown_projects),
      "projects_truncated" => length(projects) > @route_project_limit,
      "redirect_uri" => redirect_uri(),
      "scope_cards" =>
        Enum.map(FeishuScopes.import_cards(), fn card ->
          %{
            "id" => card.id,
            "title" => card.title,
            "description" => card.description,
            "json" => card.json,
            "required_scopes" => card.required_scopes
          }
        end),
      "optional_scopes" =>
        Enum.map(FeishuScopes.optional_bot_scopes(), fn scope ->
          %{"scope" => scope.scope, "label" => scope.label, "note" => scope.note}
        end)
    }
  end

  defp routes_by_app(org, pairs) do
    pairs
    |> Enum.reject(fn {_project, connect} -> trim(connect["app_id"]) == "" end)
    |> Enum.group_by(
      fn {_project, connect} -> connect["app_id"] end,
      fn {project, connect} ->
        %{
          "project_id" => project.id,
          "project_name" => project.name,
          "salix_group_id" => project.salix_group_id,
          "connect_id" => connect["connect_id"],
          "disabled" => not is_nil(connect["disabled_at"]),
          "href" => "/orgs/#{org.slug}/projects/#{project.id}/connections?provider=feishu"
        }
      end
    )
  end

  defp public_feishu_app(binding, routes) do
    %{
      "id" => binding.id,
      "app_id" => binding.app_id,
      "display_name" => binding.display_name,
      "sso_enabled" => binding.sso_enabled,
      "bot_enabled" => binding.bot_enabled,
      "app_secret_configured" => binding.app_secret_configured,
      "verification_token_configured" => binding.verification_token_configured,
      "encrypt_key_configured" => binding.encrypt_key_configured,
      "routes" => if(binding.bot_enabled, do: Map.get(routes, binding.app_id, []), else: [])
    }
  end

  defp feishu_app_error({:missing_bot_secret, :app_secret}),
    do:
      {:error, 422, "feishu_bot_secret_required",
       gettext(
         "Could not enable the Feishu bot. Enter the App Secret, or first enable SSO for this same Feishu App ID so the bot can reuse that secret."
       ), %{}}

  defp feishu_app_error(:bot_app_already_enabled),
    do:
      {:error, 409, "feishu_bot_app_already_enabled",
       gettext(
         "Only one Feishu app can be enabled for the group bot right now. Disable the existing bot app before enabling another."
       ), %{}}

  defp feishu_app_error(:app_id_immutable),
    do:
      {:error, 422, "feishu_app_id_immutable",
       gettext(
         "App ID cannot be changed for an existing Feishu app. Delete it and add a new app instead."
       ), %{}}

  defp feishu_app_error(:not_found), do: feishu_app_not_found()

  defp feishu_app_error(%Ecto.Changeset{} = changeset),
    do:
      {:error, 422, "invalid_feishu_app",
       gettext("Could not save the Feishu app. Check the App ID and secret."),
       %{"fields" => field_errors(changeset)}}

  defp feishu_app_error(_reason),
    do:
      {:error, 500, "write_failed",
       gettext("Could not save the Feishu app. Check the App ID and secret."), %{}}

  defp signal_error({:bad_request, message}) when is_binary(message),
    do: {:error, 422, "invalid_signal_number", message, %{}}

  defp signal_error(:signal_account_not_found),
    do:
      {:error, 422, "signal_account_not_found",
       gettext("This number is not registered for Signal on this server."), %{}}

  defp signal_error(:signal_account_scope),
    do:
      {:error, 422, "signal_account_scope",
       gettext("This number belongs to another organization."), %{}}

  defp signal_error(:signal_account_inactive),
    do: {:error, 422, "signal_account_inactive", gettext("This number is not active."), %{}}

  defp signal_error(reason),
    do:
      runtime_error(
        reason,
        gettext("Couldn't save the Signal number (%{reason}).", reason: describe_error(reason))
      )

  defp provider_label(provider) do
    case Map.get(@oauth_provider_info, provider) do
      {label, _console_url} -> label
      nil -> String.capitalize(provider)
    end
  end

  defp provider_setup_url("github"), do: github_app_create_url()
  defp provider_setup_url("linear"), do: linear_oauth_app_create_url()
  defp provider_setup_url("slack"), do: slack_app_create_url()

  defp provider_setup_url(provider) do
    case Map.get(@oauth_provider_info, provider) do
      {_label, console_url} -> console_url
      nil -> nil
    end
  end

  defp linear_oauth_app_create_url do
    query =
      URI.encode_query(%{
        "developer.name" => "Comma",
        "display.description" => "Connect Linear to Comma Bridge for Teams agents.",
        "distribution" => "private",
        "oauth.client_name" => @oauth_app_name,
        "oauth.client_uri" => MacMiniRelease.api_base_url(),
        "oauth.grant_types" => "authorization_code",
        "oauth.redirect_uris" => salix_oauth_callback_url("linear")
      })

    @linear_oauth_app_create_url <> "?" <> query
  end

  defp slack_app_create_url do
    manifest = %{
      "display_information" => %{
        "background_color" => "#1D1C1D",
        "description" => "Connect Slack to Comma Bridge for Teams.",
        "name" => @oauth_app_name
      },
      "oauth_config" => %{
        "redirect_urls" => [salix_oauth_callback_url("slack")],
        "scopes" => %{"user" => ["users:read"]}
      },
      "settings" => %{
        "org_deploy_enabled" => false,
        "socket_mode_enabled" => false,
        "token_rotation_enabled" => false
      }
    }

    @slack_app_create_url <>
      "?" <> URI.encode_query(%{"manifest_json" => Jason.encode!(manifest), "new_app" => "1"})
  end

  defp github_app_create_url do
    query =
      URI.encode_query([
        {"name", @oauth_app_name},
        {"description", "Connect OAuth providers to Comma Bridge for Teams agents."},
        {"url", MacMiniRelease.api_base_url()},
        {"callback_urls[]", salix_oauth_callback_url("github")},
        {"request_oauth_on_install", "true"},
        {"public", "false"},
        {"webhook_active", "false"}
      ])

    @github_app_create_url <> "?" <> query
  end

  defp salix_oauth_callback_url(provider),
    do: salix_public_base_url() <> "/v1/oauth/#{provider}/callback"

  defp salix_public_base_url do
    case SystemsRuntime.get_env(:salix_web, :public_base_url) do
      base when is_binary(base) and base != "" -> String.trim_trailing(base, "/")
      _ -> "http://127.0.0.1:#{SystemsRuntime.get_env(:salix_web, :port, 4000)}"
    end
  end

  # ---- shared ----

  @doc """
  Record a settings write refused for a caller who cannot manage settings,
  then return the 403 error.
  """
  def deny(org, user, action) do
    _ =
      Observability.record_write_attempt(%{
        org_id: org.id,
        actor_user_id: user.id,
        actor_label: actor_label(user),
        action: action,
        resource_type: "organization_settings",
        resource_id: org.id,
        resource_label: org.name,
        result: "denied",
        reason: :forbidden,
        request_id: SystemsRuntime.Proc.uuid(),
        surface: "settings",
        metadata: %{}
      })

    forbidden()
  end

  @doc "The 403 error for a caller who cannot manage settings."
  def forbidden,
    do: {:error, 403, "forbidden", gettext("Only organization admins can manage settings."), %{}}

  # The SSO redirect URI an admin registers in the Feishu app or the Lark app.
  defp redirect_uri, do: MacMiniRelease.api_base_url() <> "/auth/callback"

  defp runtime_error(reason, message) when reason in [:unavailable, :timeout],
    do: {:error, 503, "runtime_unavailable", message, %{}}

  defp runtime_error(_reason, message), do: write_failed(message)

  defp write_failed(message), do: {:error, 500, "write_failed", message, %{}}

  defp describe_error(:unavailable), do: "runtime unavailable"
  defp describe_error(:timeout), do: "runtime timed out"
  defp describe_error(reason), do: inspect(reason)

  defp field_errors(changeset),
    do: Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)

  defp audit_opts(user),
    do: [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: SystemsRuntime.Proc.uuid()
    ]

  defp actor_label(user) do
    cond do
      present?(user.email) -> user.email
      present?(user.name) -> user.name
      true -> user.id
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
