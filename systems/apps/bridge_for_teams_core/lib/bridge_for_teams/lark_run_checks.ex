defmodule BridgeForTeams.LarkRunChecks do
  @moduledoc """
  Run checks for a Lark connect of an Agent Swarm.

  A Lark connect holds its app's own credentials, so the checks read one
  connect of the project and no org-level app. The result has the shape of
  `BridgeForTeams.RunChecks` with the surface `lark_bot` and the same gate
  IDs: `bot.credentials`, `bot.callback`, `bot.chat_access`, `bot.calendar`,
  `bot.first_message` and `bot.manual`. Serialize it with
  `BridgeForTeams.RunChecks.to_json_map/1`.

  A gate is `:ok` or `:fail` only after a live probe. A probe that did not
  run is `:skipped`, and work in the Lark Developer Console is
  `:needs_manual`.

  `run_sso/2` runs the checks for sign-in with Lark. They read the
  organization's SSO connection and no Lark connect. The surface is `sso` and
  the gates are `sso.credentials` and `sso.redirect_uri`.
  """

  alias BridgeForTeams.{Agents, LarkScopes, Orgs, ProjectIMConnects, Projects}
  alias BridgeForTeams.RunChecks.CalendarStatusContract
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Agent, Organization, Project}

  @statuses ~w(ok fail needs_manual skipped)a

  @doc """
  Runs the checks for one Lark connect of a project: the connect
  `opts[:connect_id]`, or the first enabled one.
  """
  @spec run_bot(Ecto.UUID.t() | Organization.t(), Ecto.UUID.t() | Project.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_bot(org_or_id, project_or_id, opts \\ []) do
    with {:ok, %Organization{} = org} <- fetch_org(org_or_id),
         {:ok, %Project{} = project} <- fetch_project(project_or_id),
         :ok <- ensure_project_in_org(project, org) do
      {connects, list_error} = list_connects(org, project)
      requested_connect_id = opts |> Keyword.get(:connect_id) |> trim()
      connect = preferred_connect(connects, requested_connect_id)

      if requested_connect_id != "" and is_nil(list_error) and is_nil(connect) do
        {:error, :connect_not_found}
      else
        {:ok,
         %{
           surface: "lark_bot",
           org_ref: org.id,
           project_ref: project.id,
           connect_ref: connect && connect["connect_id"],
           ran_at:
             Keyword.get_lazy(opts, :ran_at, fn ->
               SystemsClock.timestamp(:utc_datetime_usec)
             end),
           gates: gates(org, project, connect, list_error)
         }}
      end
    end
  end

  @doc """
  Runs the checks for sign-in with Lark. `opts[:redirect_uri]` is the address
  the Lark app must list.
  """
  @spec run_sso(Ecto.UUID.t() | Organization.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_sso(org_or_id, opts \\ []) do
    with {:ok, %Organization{} = org} <- fetch_org(org_or_id) do
      {:ok,
       %{
         surface: "sso",
         org_ref: org.id,
         project_ref: nil,
         connect_ref: org.id,
         ran_at:
           Keyword.get_lazy(opts, :ran_at, fn ->
             SystemsClock.timestamp(:utc_datetime_usec)
           end),
         gates: [
           sso_credentials_gate(Orgs.get_sso_connection(org.id)),
           sso_redirect_uri_gate(opts |> Keyword.get(:redirect_uri) |> trim())
         ]
       }}
    end
  end

  # ---- sso.credentials ----

  # No request to Lark proves the App Secret here; only a sign-in does. The
  # gate fails on a missing value and is skipped otherwise.
  defp sso_credentials_gate(%{provider: "lark"} = sso) do
    id? = trim(sso.client_id) != ""
    secret? = trim(sso.client_secret) != ""

    evidence = %{
      "sso_connection_id" => sso.id,
      "provider" => "lark",
      "client_id_configured" => id?,
      "client_secret_configured" => secret?
    }

    if id? and secret? do
      gate(%{
        gate_id: "sso.credentials",
        label: "Lark credentials valid",
        status: :skipped,
        reason_class: :on_demand_verifier_missing,
        next_action:
          "The check does not ask Lark. Sign in with a test account in a new browser session to prove the App Secret.",
        evidence: evidence
      })
    else
      gate(%{
        gate_id: "sso.credentials",
        label: "Lark credentials valid",
        status: :fail,
        reason_class: :credentials_not_configured,
        next_action: "Save the App ID and App Secret of the Lark app on the Single sign-on page.",
        evidence: evidence
      })
    end
  end

  defp sso_credentials_gate(_sso) do
    gate(%{
      gate_id: "sso.credentials",
      label: "Lark credentials valid",
      status: :skipped,
      reason_class: :not_configured,
      next_action: "Save a Lark SSO connection before running credential checks.",
      evidence: %{"configured" => false}
    })
  end

  # ---- sso.redirect_uri ----

  defp sso_redirect_uri_gate("") do
    gate(%{
      gate_id: "sso.redirect_uri",
      label: "Redirect URI is generated",
      status: :skipped,
      reason_class: :missing_redirect_uri,
      next_action: "Pass a public dashboard redirect URI before sharing SSO setup evidence.",
      evidence: %{}
    })
  end

  defp sso_redirect_uri_gate(redirect_uri) do
    gate(%{
      gate_id: "sso.redirect_uri",
      label: "Redirect URI is generated",
      status: :ok,
      reason_class: :generated,
      next_action:
        "Add #{redirect_uri} to the redirect URLs in the Security Settings of the Lark app.",
      evidence: %{"redirect_uri" => redirect_uri}
    })
  end

  defp gates(_org, _project, _connect, list_error) when not is_nil(list_error) do
    for {gate_id, label, required} <- gate_heads() do
      gate(%{
        gate_id: gate_id,
        label: label,
        required: required,
        status: :skipped,
        reason_class: list_error,
        next_action: "Could not load Lark connects. Re-run checks after Salix is available.",
        evidence: %{"list_error" => reason_to_string(list_error)}
      })
    end
  end

  defp gates(_org, _project, nil, _list_error) do
    for {gate_id, label, required} <- gate_heads() do
      gate(%{
        gate_id: gate_id,
        label: label,
        required: required,
        status: :skipped,
        reason_class: :not_connected,
        next_action: "Connect a Lark app first, then re-run checks.",
        evidence: %{}
      })
    end
  end

  defp gates(org, project, connect, _list_error) do
    [
      credentials_gate(connect),
      callback_gate(connect),
      chat_access_gate(project, connect),
      calendar_gate(project, connect),
      first_message_gate(connect),
      manual_gate(org, project)
    ]
  end

  defp gate_heads do
    [
      {"bot.credentials", "App ID + Secret valid (tenant token)", true},
      {"bot.callback", "Callback reachable + URL verification", true},
      {"bot.chat_access", "Bot chat access + Agent Swarm route", true},
      {"bot.calendar", "Google Calendar meeting notifications", false},
      {"bot.first_message", "First message round-trips (@bot -> reply)", true},
      {"bot.manual", "Lark Developer Console steps completed", true}
    ]
  end

  defp head(gate_id) do
    {^gate_id, label, required} = List.keyfind(gate_heads(), gate_id, 0)
    %{gate_id: gate_id, label: label, required: required}
  end

  # ---- bot.credentials ----

  # Lark signs events with the Verification Token or the Encrypt Key, so one
  # of the two is enough.
  defp credentials_gate(connect) do
    configured? =
      truthy?(connect["app_secret_configured"]) and
        (truthy?(connect["verification_token_configured"]) or
           truthy?(connect["encrypt_key_configured"]))

    evidence = %{
      "connect_id" => connect["connect_id"],
      "app_id" => connect["app_id"],
      "app_secret_configured" => truthy?(connect["app_secret_configured"]),
      "verification_token_configured" => truthy?(connect["verification_token_configured"]),
      "encrypt_key_configured" => truthy?(connect["encrypt_key_configured"]),
      "updated_at" => connect["updated_at"]
    }

    if configured? do
      gate(
        Map.merge(head("bot.credentials"), %{
          status: :skipped,
          reason_class: :validated_on_save,
          next_action:
            "Lark accepted the App ID and App Secret when the app was connected; this check does not ask Lark again.",
          evidence: evidence
        })
      )
    else
      gate(
        Map.merge(head("bot.credentials"), %{
          status: :fail,
          reason_class: :secrets_not_configured,
          next_action:
            "Connect the Lark app again with its App Secret and its Verification Token or Encrypt Key.",
          evidence: evidence
        })
      )
    end
  end

  # ---- bot.callback ----

  defp callback_gate(connect) do
    client = client()

    {status, reason_class, next_action, preflight} =
      if function_exported?(client, :lark_callback_preflight_for_connect, 1) do
        case client.lark_callback_preflight_for_connect(%{"connect_id" => connect["connect_id"]}) do
          {:ok, evidence} ->
            {:ok, :url_verification_passed, "Callback reachable and URL verification passed.",
             evidence}

          {:error, reason} ->
            {callback_status(reason), reason, callback_next_action(reason),
             %{"failure" => reason_to_string(reason)}}

          other ->
            {:fail, :unexpected_response,
             "Callback verification returned an unexpected response.",
             %{"response" => inspect(other)}}
        end
      else
        {:skipped, :backend_missing,
         "Callback verification is not available on this Salix runtime.", %{}}
      end

    gate(
      Map.merge(head("bot.callback"), %{
        status: status,
        reason_class: reason_class,
        next_action: next_action,
        evidence: %{
          "connect_id" => connect["connect_id"],
          "app_id" => connect["app_id"],
          "webhook_url" => safe_webhook_url(connect),
          "verification_token_configured" => truthy?(connect["verification_token_configured"]),
          "encrypt_key_configured" => truthy?(connect["encrypt_key_configured"]),
          "encrypted_callback" => truthy?(connect["encrypt_key_configured"]),
          "preflight" => preflight
        }
      })
    )
  end

  defp callback_status(reason)
       when reason in [
              :connect_not_found,
              :connect_inactive,
              :secrets_not_configured,
              :unavailable,
              :timeout
            ],
       do: :skipped

  defp callback_status(_reason), do: :fail

  defp callback_next_action(:secrets_not_configured),
    do: "Connect the Lark app again with its Verification Token or its Encrypt Key."

  defp callback_next_action(reason) when reason in [:connect_not_found, :connect_inactive],
    do: "This connect is not active; enable it or connect the app again, then re-run checks."

  defp callback_next_action(:token_mismatch),
    do:
      "Verification Token mismatch: connect the app again with the token of its Events & Callbacks page."

  defp callback_next_action(:decrypt_signature),
    do:
      "The request URL refused the signed callback. Connect the app again with the Encrypt Key of its Events & Callbacks page."

  defp callback_next_action(:callback_unreachable),
    do: "The request URL is unreachable. Check the public endpoint and tunnel."

  defp callback_next_action(reason) when reason in [:unavailable, :timeout],
    do: "Salix is unavailable right now. Re-run checks shortly."

  defp callback_next_action(_reason),
    do:
      "Callback verification failed. Check that the request URL of this connect reaches this deployment."

  # ---- bot.chat_access ----

  defp chat_access_gate(project, connect) do
    route = route_state(project, connect)
    identity = bot_identity(connect)
    {status, reason_class, next_action} = chat_access(route, identity)

    gate(
      Map.merge(head("bot.chat_access"), %{
        status: status,
        reason_class: reason_class,
        next_action: next_action,
        evidence: %{
          "project_id" => project.id,
          "salix_group_id" => project.salix_group_id,
          "connect_id" => connect["connect_id"],
          "connect_status" => connect["status"],
          "route_status" => route.status,
          "router_agent_id" => route.router_agent_id,
          "router_agent_name" => route.router_agent && route.router_agent.salix["name"],
          "bot_identity_status" => identity.status,
          "bot_identity_reason" => identity.reason_class,
          "bot_identity_evidence" => identity.evidence,
          "chat_probe" => "not_wired"
        }
      })
    )
  end

  defp chat_access(%{status: :disabled}, _identity),
    do:
      {:fail, :connect_inactive,
       "Enable this Lark connect before sending the first group message."}

  defp chat_access(%{status: :missing_router}, _identity),
    do:
      {:fail, :router_not_configured,
       "The Agent Swarm router is not ready. Retry checks shortly; if this persists, contact support."}

  defp chat_access(%{status: :unknown, route_error: reason}, _identity),
    do: {:skipped, reason, "Could not verify the Salix route/router state. Retry checks shortly."}

  defp chat_access(_route, %{status: :fail, reason_class: :bot_identity_missing}),
    do:
      {:fail, :bot_identity_missing,
       "Salix has no open_id for the Lark bot. Connect the app again so that Salix reads the bot's identity from Lark."}

  defp chat_access(_route, %{status: :fail, reason_class: reason}),
    do: {:fail, reason, "Re-run checks after the Lark connect and route are ready."}

  defp chat_access(_route, %{status: :skipped, reason_class: reason})
       when reason in [:unavailable, :timeout],
       do: {:skipped, reason, "Salix is unavailable right now. Re-run checks shortly."}

  defp chat_access(_route, %{status: :skipped, reason_class: reason}),
    do:
      {:skipped, reason,
       "Bot identity could not be verified yet. Re-run checks after the runtime is ready."}

  defp chat_access(_route, _identity),
    do:
      {:skipped, :chat_probe_missing,
       "Route and bot identity are ready; chat/member probing needs a runtime call that is not wired yet."}

  defp bot_identity(connect) do
    client = client()

    if function_exported?(client, :lark_bot_identity, 1) do
      case client.lark_bot_identity(%{"connect_id" => connect["connect_id"]}) do
        {:ok, evidence} ->
          %{status: :ok, reason_class: :resolved, evidence: evidence}

        {:error, reason}
        when reason in [:connect_not_found, :connect_inactive, :unavailable, :timeout] ->
          %{
            status: :skipped,
            reason_class: reason,
            evidence: %{"failure" => reason_to_string(reason)}
          }

        {:error, reason} ->
          %{
            status: :fail,
            reason_class: reason,
            evidence: %{"failure" => reason_to_string(reason)}
          }

        other ->
          %{
            status: :fail,
            reason_class: :unexpected_response,
            evidence: %{"response" => inspect(other)}
          }
      end
    else
      %{status: :skipped, reason_class: :backend_missing, evidence: %{}}
    end
  end

  # ---- bot.calendar ----

  # Optional. A Lark connect in meetings.calendar_autojoin has the notify mode.
  defp calendar_gate(project, connect) do
    route = route_state(project, connect)
    client = client()

    {status, reason_class, next_action, evidence} =
      cond do
        route.status != :ready ->
          {:skipped, :router_not_configured,
           "Make the Agent Swarm Router ready, then re-run checks.", %{}}

        not function_exported?(client, :meeting_calendar_policy, 1) ->
          {:skipped, :backend_missing,
           "Calendar policy verification is not available on this Salix runtime.", %{}}

        true ->
          case client.meeting_calendar_policy(%{
                 "agent_id" => route.router_agent_id,
                 "connect_id" => connect["connect_id"]
               }) do
            {:ok, evidence} when is_map(evidence) ->
              {:ok, :active,
               "Google Calendar is ACTIVE; meetings notify the configured Lark chat on the first worker tick at or shortly after start.",
               evidence}

            {:error, reason} ->
              calendar_failure(reason)

            other ->
              calendar_failure({:unexpected_calendar_policy_response, other})
          end
      end

    gate(
      Map.merge(head("bot.calendar"), %{
        status: status,
        reason_class: reason_class,
        next_action: next_action,
        evidence:
          Map.merge(evidence, %{
            "connect_id" => connect["connect_id"],
            "route_status" => route.status
          })
      })
    )
  end

  defp calendar_failure(:calendar_policy_not_configured),
    do:
      {:skipped, :calendar_policy_not_configured,
       "Calendar event creation remains available through the Agent Swarm's ACTIVE Google Calendar connection. To also notify a Lark chat at or shortly after event start, configure this connect in meetings.calendar_autojoin with mode=notify, a target chat, and explicit watched calendars.",
       %{}}

  defp calendar_failure(
         {:calendar_source_maintenance, {:calendar_source_bootstrap_pending, next_retry_at}}
       ),
       do: calendar_failure({:calendar_source_bootstrap_pending, next_retry_at})

  defp calendar_failure({:calendar_source_bootstrap_pending, next_retry_at}),
    do:
      {:needs_manual, :calendar_initial_sync_pending,
       "Initial calendar sync has not completed yet. The retry becomes eligible at the time below; the bounded worker cadence determines when it runs. Re-run checks after that attempt.",
       %{"next_retry_at" => calendar_retry_time(next_retry_at)}}

  defp calendar_failure({:calendar_source_maintenance, reason}) do
    if transient_calendar_reason?(reason) do
      calendar_retrying(reason, :calendar_source_maintenance_retrying)
    else
      {:fail, :calendar_source_maintenance_failed,
       "Calendar source maintenance requires correction. Verify the Google Calendar authorization and selected calendar still exist, reconnect or correct them as needed, then re-run checks.",
       %{"maintenance_failure" => reason_to_string(reason)}}
    end
  end

  defp calendar_failure(:calendar_enrollment_no_active_account),
    do:
      {:fail, :calendar_enrollment_no_active_account,
       "Connect an ACTIVE Google Calendar account owned by this Agent Swarm, then re-run checks.",
       %{}}

  defp calendar_failure({:calendar_not_found, calendar}),
    do:
      {:fail, :calendar_not_found,
       "No Google Calendar matched the configured value. Use the exact shared calendar name or stable calendar ID in meetings.calendar_autojoin.calendars; keep create_calendar equal to one of those entries, then re-run checks.",
       %{"configured_calendar" => calendar}}

  defp calendar_failure({:calendar_ambiguous, calendar}),
    do:
      {:fail, :calendar_ambiguous,
       "More than one Google Calendar matched the configured value. Replace it with the stable calendar ID in meetings.calendar_autojoin.calendars and, when it is the creation target, in create_calendar too; then re-run checks.",
       %{"configured_calendar" => calendar}}

  defp calendar_failure(:calendar_policy_agent_group_missing),
    do:
      {:skipped, :calendar_policy_agent_group_missing,
       "The Router Agent has no Salix group. Repair the Agent Swarm route, then re-run checks.",
       %{}}

  defp calendar_failure(:calendar_policy_group_conflict),
    do:
      {:fail, :calendar_policy_group_conflict,
       "More than one meeting-calendar target is configured for this Agent Swarm. Keep exactly one connect entry for the group, then re-run checks.",
       %{}}

  defp calendar_failure(reason) do
    if transient_calendar_reason?(reason) do
      calendar_retrying(reason, :calendar_enrollment_retrying)
    else
      {:fail, reason,
       "Verify the selected shared calendar, create_calendar, target Lark chat, and Google Calendar authorization.",
       %{"failure" => reason_to_string(reason)}}
    end
  end

  defp calendar_retrying(reason, reason_class),
    do:
      {:needs_manual, reason_class,
       "Calendar enrollment is temporarily unavailable. Initial-source retries become eligible after 60 seconds; repair of a previously active source follows six hours plus source jitter. The bounded worker cadence determines when an eligible retry runs.",
       %{"retryable_failure" => reason_to_string(reason)}}

  defp transient_calendar_reason?(reason)
       when reason in [
              :transient,
              :timeout,
              :unavailable,
              :source_operation_timeout,
              :calendar_source_refresh_unsettled
            ],
       do: true

  defp transient_calendar_reason?({:calendar_enrollment_connect_lookup, {:ambiguous, _reason}}),
    do: true

  defp transient_calendar_reason?({:google_calendar_rate_limited, status, _reasons})
       when status in [403, 429],
       do: true

  defp transient_calendar_reason?({:transport, _reason}), do: true

  defp transient_calendar_reason?({tag, reason})
       when tag in [
              :calendar_enrollment_account,
              :calendar_enrollment_list,
              :calendar_enrollment_connect,
              :calendar_enrollment_connect_lookup,
              :channel_resolve
            ],
       do: transient_calendar_reason?(reason)

  defp transient_calendar_reason?({tag, status})
       when tag in [:http, :google_calendar_http] and is_integer(status),
       do: transient_http_status?(status)

  defp transient_calendar_reason?({tag, status, _body})
       when tag in [:http, :google_calendar_http] and is_integer(status),
       do: transient_http_status?(status)

  defp transient_calendar_reason?(_reason), do: false

  defp transient_http_status?(status), do: status in [408, 425, 429] or status >= 500

  defp calendar_retry_time(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> value
    end
  end

  defp calendar_retry_time(value), do: value

  # ---- bot.first_message ----

  # A real message wakes the Router's model, so the checks never send one.
  defp first_message_gate(connect) do
    gate(
      Map.merge(head("bot.first_message"), %{
        status: :needs_manual,
        reason_class: :explicit_admin_action_required,
        next_action:
          "Mention the bot in a Lark group it is in, or write to it in a private chat, and watch for a reply.",
        evidence: %{
          "connect_id" => connect["connect_id"],
          "auto_run" => false,
          "side_effects" => "billable_llm_wake"
        }
      })
    )
  end

  # ---- bot.manual ----

  defp manual_gate(org, project) do
    gate(
      Map.merge(head("bot.manual"), %{
        status: :needs_manual,
        reason_class: :lark_console_steps_required,
        next_action:
          "In the Lark Developer Console: Permissions & Scopes → batch import, import the scope JSON of the Connections page or of bft lark scopes. On Events & Callbacks save the request URL, subscribe to im.message.receive_v1 and im.message.recalled_v1, and under Callbacks subscribe to card.action.trigger. Create a version of the app and publish it, then add the bot to the target group.",
        evidence: %{
          "settings_path" => "/orgs/#{org.slug}/projects/#{project.id}/connections?provider=lark",
          "required_scopes" => LarkScopes.required_scope_ids(),
          "capability_checks" => [
            %{
              "id" => "group_history",
              "required_scopes" => ["im:message.group_msg"],
              "failure_hints" => [
                "permission missing or the permission-bearing app version is not published",
                "without this scope Lark delivers only messages that mention the bot",
                "bot is not a member of the target chat"
              ]
            },
            %{
              "id" => "message_resources",
              "required_scopes" => ["im:resource"],
              "failure_hints" => [
                "the file does not belong to the message it is read from",
                "the chat's policy blocks the download of this file"
              ]
            },
            %{
              "id" => "directory_access",
              "required_scopes" => [
                "contact:contact.base:readonly",
                "contact:user.base:readonly",
                "contact:department.base:readonly"
              ],
              "failure_hints" => [
                "permission-bearing app version is not published",
                "the app's Contacts & organization data scope excludes the requested user or department"
              ]
            },
            %{
              "id" => "cloud_documents",
              "required_scopes" => LarkScopes.document_scope_ids(),
              "failure_hints" => [
                "permission-bearing app version is not published",
                "the document is not shared with the app or with a chat that includes the bot",
                "only Docx documents and Docx pages of a wiki are supported",
                "a Minutes recording is still being processed or is not shared with the bot"
              ]
            }
          ]
        }
      })
    )
  end

  # ---- route ----

  defp route_state(_project, %{"disabled_at" => disabled_at})
       when not is_nil(disabled_at) and disabled_at != "" do
    %{status: :disabled, router_agent_id: nil, router_agent: nil, route_error: nil}
  end

  defp route_state(project, _connect) do
    case current_router_agent_id(project) do
      {:ok, router_agent_id} ->
        router_agent =
          Enum.find(Agents.list_agents(project.id), &router_agent?(&1, router_agent_id))

        %{
          status: if(router_agent, do: :ready, else: :missing_router),
          router_agent_id: router_agent_id,
          router_agent: router_agent,
          route_error: nil
        }

      {:error, reason} ->
        %{status: :unknown, router_agent_id: nil, router_agent: nil, route_error: reason}
    end
  end

  defp current_router_agent_id(project) do
    client = client()

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

  defp router_agent?(%Agent{} = agent, router_agent_id)
       when is_binary(router_agent_id) and router_agent_id != "",
       do: agent.salix_agent_id == router_agent_id

  defp router_agent?(_agent, _router_agent_id), do: false

  # ---- connects ----

  defp list_connects(org, project) do
    case ProjectIMConnects.list_project_connects(org.id, project.id, "lark") do
      {:ok, connects} when is_list(connects) -> {connects, nil}
      {:ok, _other} -> {[], :unexpected_connects_response}
      {:error, reason} -> {[], reason}
    end
  end

  defp preferred_connect(connects, ""),
    do: Enum.find(connects, &(trim(&1["disabled_at"]) == "")) || List.first(connects)

  defp preferred_connect(connects, connect_id),
    do: Enum.find(connects, &(&1["connect_id"] == connect_id))

  # The request URL with only its `app_id` query parameter.
  defp safe_webhook_url(%{"webhook_url" => url} = connect) when is_binary(url) and url != "" do
    uri = URI.parse(url)
    app_id = trim(connect["app_id"])
    app_id = if app_id == "", do: URI.decode_query(uri.query || "")["app_id"], else: app_id

    URI.to_string(%{uri | query: app_id && URI.encode_query(%{"app_id" => app_id})})
  rescue
    _invalid -> nil
  end

  defp safe_webhook_url(_connect), do: nil

  # ---- gate ----

  defp gate(attrs) do
    status = Map.fetch!(attrs, :status)

    if status not in @statuses do
      raise ArgumentError, "unknown Run checks status #{inspect(status)}"
    end

    attrs
    |> Map.put_new(:required, true)
    |> Map.put(:evidence, redact_evidence(attrs[:evidence] || %{}))
    |> Map.put(:redacted, true)
  end

  # A gate is recorded as it is built, so its evidence is redacted here.
  defp redact_evidence(%{} = map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key),
        do: {to_string(key), "[REDACTED]"},
        else: {to_string(key), redact_evidence(value)}
    end)
  end

  defp redact_evidence(list) when is_list(list), do: Enum.map(list, &redact_evidence/1)

  defp redact_evidence(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> redact_evidence()

  defp redact_evidence(value) when is_boolean(value) or is_nil(value), do: value
  defp redact_evidence(value) when is_atom(value), do: Atom.to_string(value)
  defp redact_evidence(value) when is_binary(value), do: redact_string(value)
  defp redact_evidence(value), do: value

  defp redact_string(value) do
    cond do
      Regex.match?(
        ~r/(app_secret|verification_token|encrypt_key|client_secret|access_token|raw_payload|message_body)/i,
        value
      ) ->
        "[REDACTED]"

      Regex.match?(~r/bearer\s+[a-z0-9._-]+/i, value) ->
        "[REDACTED]"

      true ->
        CalendarStatusContract.redact_meet_urls(value)
    end
  end

  defp secret_key?(key) do
    key = key |> to_string() |> String.downcase()

    cond do
      String.ends_with?(key, "_configured") ->
        false

      key in ["app_id", "connect_id", "group_id", "project_id", "settings_path"] ->
        false

      true ->
        String.contains?(key, [
          "secret",
          "token",
          "encrypt_key",
          "authorization",
          "password",
          "payload",
          "body",
          "message",
          "content",
          "open_id",
          "union_id",
          "user_id",
          "tenant_access",
          "user_access"
        ])
    end
  end

  # ---- values ----

  defp fetch_org(%Organization{} = org), do: {:ok, org}
  defp fetch_org(id), do: Orgs.get_org(id)

  defp fetch_project(%Project{} = project), do: {:ok, project}
  defp fetch_project(id), do: Projects.get_project(id)

  defp ensure_project_in_org(%Project{org_id: org_id}, %Organization{id: org_id}), do: :ok
  defp ensure_project_in_org(_project, _org), do: {:error, :not_found}

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_value), do: false

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()

  defp client, do: Client.impl()
end
