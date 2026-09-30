defmodule BridgeForTeams.RunChecks do
  @moduledoc """
  Shared Run checks contract for BridgeForTeams integration onboarding.

  The dashboard and CLI both consume this module so the visibility surface stays
  honest and serializable: live checks may return `:ok`/`:fail`, missing backend
  probes return `:skipped`, and Feishu-console-only work returns
  `:needs_manual`.
  """

  alias BridgeForTeams.{
    Agents,
    FeishuScopes,
    Orgs,
    ProjectIMConnects,
    Projects
  }

  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.RunChecks.{CalendarStatusContract, GateContract}
  alias BridgeForTeams.Schema.{Agent, Organization, Project}

  @sso_gate_ids ~w(sso.credentials sso.redirect_uri)
  @bot_gate_ids ~w(bot.credentials bot.callback bot.chat_access bot.calendar bot.first_message bot.manual)
  @statuses ~w(ok fail needs_manual skipped)a

  @doc "Canonical SSO gate IDs in display order."
  def sso_gate_ids, do: @sso_gate_ids

  @doc "Canonical bot gate IDs in display order."
  def bot_gate_ids, do: @bot_gate_ids

  @doc "Run the Feishu SSO checks for an org."
  @spec run_sso(Ecto.UUID.t() | Organization.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_sso(org_or_id, opts \\ []) do
    with {:ok, %Organization{} = org} <- fetch_org(org_or_id) do
      redirect_uri = opts |> Keyword.get(:redirect_uri) |> trim()
      sso = Orgs.get_sso_connection(org.id)

      {:ok,
       %{
         surface: "sso",
         org_ref: org.id,
         project_ref: nil,
         connect_ref: org.id,
         ran_at: ran_at(opts),
         gates: [
           sso_credentials_gate(sso),
           sso_redirect_uri_gate(redirect_uri)
         ]
       }}
    end
  end

  @doc "Run the Feishu bot / IM checks for an org project."
  @spec run_bot(Ecto.UUID.t() | Organization.t(), Ecto.UUID.t() | Project.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_bot(org_or_id, project_or_id, opts \\ []) do
    with {:ok, %Organization{} = org} <- fetch_org(org_or_id),
         {:ok, %Project{} = project} <- fetch_project(project_or_id),
         :ok <- ensure_project_in_org(project, org) do
      {connects, list_error} = list_connects(org, project, "feishu")
      requested_connect_id = opts |> Keyword.get(:connect_id) |> trim()
      connect = preferred_connect(connects, requested_connect_id)

      if requested_connect_id != "" and is_nil(list_error) and is_nil(connect) do
        {:error, :connect_not_found}
      else
        {:ok,
         %{
           surface: "bot",
           org_ref: org.id,
           project_ref: project.id,
           connect_ref: connect && connect["connect_id"],
           ran_at: ran_at(opts),
           gates: [
             bot_credentials_gate(connect, list_error),
             bot_callback_gate(connect, list_error),
             bot_chat_access_gate(project, connect, list_error),
             bot_calendar_gate(project, connect, list_error),
             bot_first_message_gate(connect, list_error),
             bot_manual_gate(org)
           ]
         }}
      end
    end
  end

  @doc "Run the optional Slack Google Calendar auto-join check for an org project."
  @spec run_slack_calendar(
          Ecto.UUID.t() | Organization.t(),
          Ecto.UUID.t() | Project.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def run_slack_calendar(org_or_id, project_or_id, opts \\ []) do
    with {:ok, %Organization{} = org} <- fetch_org(org_or_id),
         {:ok, %Project{} = project} <- fetch_project(project_or_id),
         :ok <- ensure_project_in_org(project, org) do
      policy_probe = Keyword.get(opts, :calendar_policy_probe, :meeting_calendar_policy)
      {connects, list_error} = list_connects(org, project, "slack", policy_probe)
      requested_connect_id = opts |> Keyword.get(:connect_id) |> trim()
      connect = preferred_connect(connects, requested_connect_id)

      if requested_connect_id != "" and is_nil(list_error) and is_nil(connect) do
        {:error, :connect_not_found}
      else
        {:ok,
         %{
           surface: "slack_calendar",
           org_ref: org.id,
           project_ref: project.id,
           connect_ref: connect && connect["connect_id"],
           ran_at: ran_at(opts),
           gates: [
             project
             |> meeting_calendar_gate(connect, list_error, "slack", policy_probe)
             |> Map.put(:required, true)
           ]
         }}
      end
    end
  end

  @doc "Run the Slack calendar gate and read its bounded durable meeting projection."
  @spec run_slack_calendar_status(
          Ecto.UUID.t() | Organization.t(),
          Ecto.UUID.t() | Project.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def run_slack_calendar_status(org_or_id, project_or_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    with true <- is_integer(limit) and limit in 1..50,
         {:ok, checks} <-
           run_slack_calendar(
             org_or_id,
             project_or_id,
             Keyword.put(opts, :calendar_policy_probe, :meeting_calendar_policy_status)
           ) do
      gate = List.first(checks.gates) || %{}
      client = client()

      calendar =
        cond do
          gate[:status] != :ok ->
            unavailable_calendar_status(
              diagnostic_gate_health(gate[:reason_class]),
              diagnostic_gate_reason(gate[:reason_class]),
              limit
            )

          not function_exported?(client, :meeting_calendar_status, 1) ->
            unavailable_calendar_status("unavailable", "backend_missing", limit)

          true ->
            case client.meeting_calendar_status(%{
                   "agent_id" => gate[:diagnostic_agent_id],
                   "connect_id" => checks.connect_ref,
                   "limit" => limit
                 }) do
              {:ok, status} when is_map(status) ->
                CalendarStatusContract.normalize(status, limit)

              {:error, reason} ->
                {health, public_reason} = calendar_status_error(reason)

                unavailable_calendar_status(
                  health,
                  public_reason,
                  limit
                )

              _other ->
                unavailable_calendar_status(
                  "unavailable",
                  "calendar_status_invalid_response",
                  limit
                )
            end
        end

      {:ok, %{checks: checks, calendar: calendar}}
    else
      false -> {:error, :invalid_calendar_status_query}
      {:error, _} = error -> error
    end
  end

  @doc "Return a JSON-compatible, redacted map for CLI/API consumers."
  @spec to_json_map(map()) :: map()
  def to_json_map(%{} = result) do
    GateContract.normalize_result(%{
      "surface" => result[:surface],
      "org_ref" => result[:org_ref],
      "project_ref" => result[:project_ref],
      "connect_ref" => result[:connect_ref],
      "ran_at" => serialize_time(result[:ran_at]),
      "gates" => Enum.map(result[:gates] || [], &gate_to_json/1)
    })
  end

  @doc "Encode a Run checks result as JSON."
  @spec encode_json!(map(), keyword()) :: String.t()
  def encode_json!(%{} = result, opts \\ [pretty: true]) do
    result
    |> to_json_map()
    |> Jason.encode!(opts)
  end

  defp sso_credentials_gate(%{provider: "feishu"} = sso) do
    configured? = present?(sso.client_id) and present?(sso.client_secret)

    if configured? do
      gate(%{
        gate_id: "sso.credentials",
        label: "Feishu credentials valid",
        status: :skipped,
        reason_class: :on_demand_verifier_missing,
        next_action:
          "On-demand credential verification is not wired yet; saving does not prove the App Secret.",
        evidence: %{
          "sso_connection_id" => sso.id,
          "provider" => sso.provider,
          "client_id_configured" => true,
          "client_secret_configured" => true
        }
      })
    else
      gate(%{
        gate_id: "sso.credentials",
        label: "Feishu credentials valid",
        status: :fail,
        reason_class: :credentials_not_configured,
        next_action: "Save a Feishu SSO connection with Client ID and Client secret.",
        evidence: %{
          "sso_connection_id" => sso.id,
          "provider" => sso.provider,
          "client_id_configured" => present?(sso.client_id),
          "client_secret_configured" => present?(sso.client_secret)
        }
      })
    end
  end

  defp sso_credentials_gate(_sso) do
    gate(%{
      gate_id: "sso.credentials",
      label: "Feishu credentials valid",
      status: :skipped,
      reason_class: :not_configured,
      next_action: "Save a Feishu SSO connection before running credential checks.",
      evidence: %{"configured" => false}
    })
  end

  defp sso_redirect_uri_gate(""), do: sso_redirect_uri_missing_gate()

  defp sso_redirect_uri_gate(redirect_uri) do
    gate(%{
      gate_id: "sso.redirect_uri",
      label: "Redirect URI is generated",
      status: :ok,
      reason_class: :generated,
      next_action: "Register #{redirect_uri} in the Feishu app's redirect settings.",
      evidence: %{"redirect_uri" => redirect_uri}
    })
  end

  defp sso_redirect_uri_missing_gate do
    gate(%{
      gate_id: "sso.redirect_uri",
      label: "Redirect URI is generated",
      status: :skipped,
      reason_class: :missing_redirect_uri,
      next_action: "Pass a public dashboard redirect URI before sharing SSO setup evidence.",
      evidence: %{}
    })
  end

  defp bot_credentials_gate(_connect, list_error) when not is_nil(list_error) do
    gate(%{
      gate_id: "bot.credentials",
      label: "App ID + Secret valid (tenant token)",
      status: :skipped,
      reason_class: list_error,
      next_action: "Could not load Feishu connects. Re-run checks after Salix is available.",
      evidence: %{"list_error" => reason_to_string(list_error)}
    })
  end

  defp bot_credentials_gate(nil, _list_error) do
    gate(%{
      gate_id: "bot.credentials",
      label: "App ID + Secret valid (tenant token)",
      status: :skipped,
      reason_class: :not_connected,
      next_action: "Create a Feishu connect first, then re-run checks.",
      evidence: %{"configured" => false}
    })
  end

  defp bot_credentials_gate(connect, _list_error) do
    required_configured? =
      truthy?(connect["app_secret_configured"]) and
        truthy?(connect["verification_token_configured"])

    if required_configured? do
      gate(%{
        gate_id: "bot.credentials",
        label: "App ID + Secret valid (tenant token)",
        status: :skipped,
        reason_class: :validated_on_save,
        next_action:
          "Validated when the connect was created; on-demand re-check is not wired yet.",
        evidence: credential_evidence(connect)
      })
    else
      gate(%{
        gate_id: "bot.credentials",
        label: "App ID + Secret valid (tenant token)",
        status: :fail,
        reason_class: :secrets_not_configured,
        next_action: "Configure the Feishu App Secret and Verification Token for this app.",
        evidence: credential_evidence(connect)
      })
    end
  end

  defp bot_callback_gate(_connect, list_error) when not is_nil(list_error) do
    gate(%{
      gate_id: "bot.callback",
      label: "Callback reachable + URL verification",
      status: :skipped,
      reason_class: list_error,
      next_action: "Could not load Feishu connects. Re-run checks after Salix is available.",
      evidence: %{"list_error" => reason_to_string(list_error)}
    })
  end

  defp bot_callback_gate(nil, _list_error) do
    gate(%{
      gate_id: "bot.callback",
      label: "Callback reachable + URL verification",
      status: :skipped,
      reason_class: :not_connected,
      next_action: "Create a Feishu connect first, then re-run checks.",
      evidence: %{}
    })
  end

  defp bot_callback_gate(connect, _list_error) do
    base = %{
      gate_id: "bot.callback",
      label: "Callback reachable + URL verification"
    }

    client = client()

    if function_exported?(client, :feishu_callback_preflight_for_connect, 1) do
      case client.feishu_callback_preflight_for_connect(%{"connect_id" => connect["connect_id"]}) do
        {:ok, evidence} ->
          gate(
            Map.merge(base, %{
              status: :ok,
              reason_class: :url_verification_passed,
              next_action: "Callback reachable and URL verification passed.",
              evidence: callback_evidence(connect, evidence)
            })
          )

        {:error, reason} ->
          gate(
            Map.merge(base, %{
              status: callback_status(reason),
              reason_class: reason,
              next_action: callback_next_action(reason),
              evidence: callback_evidence(connect, %{"failure" => reason_to_string(reason)})
            })
          )

        other ->
          gate(
            Map.merge(base, %{
              status: :fail,
              reason_class: :unexpected_response,
              next_action: "Callback verification returned an unexpected response.",
              evidence: callback_evidence(connect, %{"response" => inspect(other)})
            })
          )
      end
    else
      gate(
        Map.merge(base, %{
          status: :skipped,
          reason_class: :backend_missing,
          next_action: "Callback preflight backend is not wired yet.",
          evidence: callback_evidence(connect, %{})
        })
      )
    end
  end

  defp bot_chat_access_gate(_project, _connect, list_error) when not is_nil(list_error) do
    gate(%{
      gate_id: "bot.chat_access",
      label: "Bot chat access + Agent Swarm route",
      status: :skipped,
      reason_class: list_error,
      next_action: "Could not load Feishu connects. Re-run checks after Salix is available.",
      evidence: %{"list_error" => reason_to_string(list_error)}
    })
  end

  defp bot_chat_access_gate(_project, nil, _list_error) do
    gate(%{
      gate_id: "bot.chat_access",
      label: "Bot chat access + Agent Swarm route",
      status: :skipped,
      reason_class: :not_connected,
      next_action: "Create a Feishu connect first, then re-run checks.",
      evidence: %{}
    })
  end

  defp bot_chat_access_gate(project, connect, _list_error) do
    route = route_state(project, connect)
    identity = bot_identity(connect)
    status = chat_access_status(route, identity)
    reason_class = chat_access_reason(route, identity, status)

    gate(%{
      gate_id: "bot.chat_access",
      label: "Bot chat access + Agent Swarm route",
      status: status,
      reason_class: reason_class,
      next_action: chat_access_next_action(route, identity, status),
      evidence: chat_access_evidence(project, connect, route, identity)
    })
  end

  defp bot_calendar_gate(project, connect, list_error),
    do: meeting_calendar_gate(project, connect, list_error, "feishu")

  defp meeting_calendar_gate(project, connect, list_error, provider),
    do: meeting_calendar_gate(project, connect, list_error, provider, :meeting_calendar_policy)

  defp meeting_calendar_gate(_project, _connect, list_error, provider, policy_probe)
       when not is_nil(list_error) do
    diagnostic? = policy_probe == :meeting_calendar_policy_status

    gate(%{
      gate_id: "bot.calendar",
      label: calendar_gate_label(provider),
      required: false,
      status: :skipped,
      reason_class:
        if(diagnostic?, do: diagnostic_connect_reason_class(list_error), else: list_error),
      next_action:
        "Could not load #{provider_name(provider)} connects. Re-run checks after Salix is available.",
      evidence: if(diagnostic?, do: %{}, else: %{"list_error" => reason_to_string(list_error)})
    })
  end

  defp meeting_calendar_gate(_project, nil, _list_error, provider, _policy_probe) do
    gate(%{
      gate_id: "bot.calendar",
      label: calendar_gate_label(provider),
      required: false,
      status: :skipped,
      reason_class: :not_connected,
      next_action: calendar_not_connected_next_action(provider),
      evidence: %{}
    })
  end

  defp meeting_calendar_gate(project, connect, _list_error, provider, policy_probe) do
    route = route_state(project, connect)
    client = client()

    cond do
      route.status != :ready ->
        diagnostic? = policy_probe == :meeting_calendar_policy_status
        route_unavailable? = diagnostic? and unavailable_reason?(route.route_error)

        gate(%{
          gate_id: "bot.calendar",
          label: calendar_gate_label(provider),
          required: false,
          status: :skipped,
          reason_class:
            if(route_unavailable?,
              do: :calendar_backend_unavailable,
              else: :router_not_configured
            ),
          next_action: "Make the Agent Swarm Router ready, then re-run checks.",
          evidence: %{
            "connect_id" => connect["connect_id"],
            "route_status" => route.status
          }
        })

      policy_probe not in [:meeting_calendar_policy, :meeting_calendar_policy_status] or
          not function_exported?(client, policy_probe, 1) ->
        gate(%{
          gate_id: "bot.calendar",
          label: calendar_gate_label(provider),
          required: false,
          status: :skipped,
          reason_class: :backend_missing,
          next_action: "Calendar policy verification is not available on this Salix runtime.",
          evidence: %{"connect_id" => connect["connect_id"]}
        })

      true ->
        calendar_policy_gate(
          apply(client, policy_probe, [
            %{
              "agent_id" => route.router_agent_id,
              "connect_id" => connect["connect_id"]
            }
          ]),
          connect,
          route,
          provider,
          policy_probe
        )
    end
  end

  defp calendar_policy_gate({:ok, evidence}, connect, route, provider, policy_probe)
       when is_map(evidence) do
    evidence =
      if policy_probe == :meeting_calendar_policy_status,
        do: diagnostic_calendar_policy_evidence(evidence),
        else: evidence

    %{
      gate_id: "bot.calendar",
      label: calendar_gate_label(provider),
      required: false,
      status: :ok,
      reason_class: :active,
      next_action: calendar_active_next_action(provider),
      evidence:
        Map.merge(evidence, %{
          "connect_id" => connect["connect_id"],
          "route_status" => route.status
        })
    }
    |> gate()
    |> Map.put(:diagnostic_agent_id, route.router_agent_id)
  end

  defp calendar_policy_gate({:error, reason}, connect, route, provider, policy_probe) do
    failure =
      if policy_probe == :meeting_calendar_policy_status,
        do: diagnostic_calendar_policy_failure(reason, provider),
        else: calendar_policy_failure(reason, provider)

    gate(%{
      gate_id: "bot.calendar",
      label: calendar_gate_label(provider),
      required: false,
      status: failure.status,
      reason_class: failure.reason_class,
      next_action: failure.next_action,
      evidence:
        Map.merge(failure.evidence, %{
          "connect_id" => connect["connect_id"],
          "route_status" => route.status
        })
    })
  end

  defp calendar_policy_gate(other, connect, route, provider, policy_probe),
    do:
      calendar_policy_gate(
        {:error, {:unexpected_calendar_policy_response, other}},
        connect,
        route,
        provider,
        policy_probe
      )

  defp diagnostic_calendar_policy_failure(:calendar_policy_not_configured, provider),
    do: calendar_policy_failure(:calendar_policy_not_configured, provider)

  defp diagnostic_calendar_policy_failure(:calendar_enrollment_pending, _provider) do
    %{
      status: :needs_manual,
      reason_class: :calendar_enrollment_pending,
      next_action:
        "Calendar enrollment has not completed yet. Wait for the bounded background worker and re-run status.",
      evidence: %{}
    }
  end

  defp diagnostic_calendar_policy_failure(:calendar_policy_group_conflict, provider),
    do: calendar_policy_failure(:calendar_policy_group_conflict, provider)

  defp diagnostic_calendar_policy_failure(:calendar_policy_agent_group_missing, provider),
    do: calendar_policy_failure(:calendar_policy_agent_group_missing, provider)

  defp diagnostic_calendar_policy_failure(reason, _provider) do
    if unavailable_reason?(reason) do
      %{
        status: :needs_manual,
        reason_class: :calendar_backend_unavailable,
        next_action: "Calendar diagnostics are temporarily unavailable. Re-run status shortly.",
        evidence: %{}
      }
    else
      %{
        status: :fail,
        reason_class: diagnostic_calendar_reason_class(reason),
        next_action:
          "Verify the configured connect, explicit calendar selectors, and completed calendar enrollment.",
        evidence: %{}
      }
    end
  end

  defp diagnostic_calendar_policy_evidence(evidence) do
    Map.take(evidence, [
      "calendar_ids",
      "channel",
      "channel_id",
      "connect_id",
      "connected_account_ids",
      "meeting_calendar_id",
      "mode",
      "readiness",
      "resolved_at_ms",
      "watched_calendars"
    ])
  end

  defp diagnostic_calendar_reason_class(:calendar_policy_not_owned),
    do: :calendar_policy_not_owned

  defp diagnostic_calendar_reason_class(:calendar_enrollment_connect_not_found),
    do: :calendar_enrollment_connect_not_found

  defp diagnostic_calendar_reason_class(:calendar_enrollment_invalid),
    do: :calendar_enrollment_invalid

  defp diagnostic_calendar_reason_class(_reason), do: :calendar_policy_invalid

  defp diagnostic_connect_reason_class(reason) do
    if unavailable_reason?(reason),
      do: :calendar_backend_unavailable,
      else: :connect_lookup_failed
  end

  defp diagnostic_gate_health(reason_class)
       when reason_class in [:backend_missing, :calendar_backend_unavailable],
       do: "unavailable"

  defp diagnostic_gate_health(_reason_class), do: "not_ready"

  defp diagnostic_gate_reason(reason_class) when is_atom(reason_class),
    do: Atom.to_string(reason_class)

  defp diagnostic_gate_reason(_reason_class), do: "calendar_status_not_ready"

  defp calendar_status_error(reason)
       when reason in [
              :not_found,
              :calendar_policy_agent_group_missing,
              :invalid_calendar_status_query,
              :invalid_calendar_projection_status_query
            ],
       do: {"not_ready", "calendar_status_not_ready"}

  defp calendar_status_error(_reason),
    do: {"unavailable", "calendar_status_backend_unavailable"}

  defp unavailable_reason?(reason)
       when reason in [:transient, :timeout, :unavailable, :source_operation_timeout],
       do: true

  defp unavailable_reason?({:calendar_enrollment_cache_unavailable, _reason}), do: true
  defp unavailable_reason?({:calendar_enrollment_connect_lookup, _reason}), do: true
  defp unavailable_reason?({:transport, _reason}), do: true

  defp unavailable_reason?({tag, status})
       when tag in [:http, :google_calendar_http] and is_integer(status),
       do: transient_http_status?(status)

  defp unavailable_reason?({tag, status, _body})
       when tag in [:http, :google_calendar_http] and is_integer(status),
       do: transient_http_status?(status)

  defp unavailable_reason?({tag, reason})
       when tag in [
              :calendar_enrollment_account,
              :calendar_enrollment_list,
              :calendar_enrollment_connect,
              :calendar_enrollment_connect_lookup,
              :calendar_projection_read
            ],
       do: unavailable_reason?(reason)

  defp unavailable_reason?(_reason), do: false

  defp unavailable_calendar_status(health, reason, limit) do
    %{
      "health" => health,
      "reason" => reason,
      "window_hours" => 24,
      "projection" => %{
        "state" => "unavailable",
        "candidate_count" => 0,
        "returned_count" => 0,
        "limit" => limit,
        "truncated" => false
      },
      "summary" => %{
        "candidate_count" => 0,
        "returned_count" => 0,
        "planned_count" => 0,
        "plan_error_count" => 0,
        "candidate_error_count" => 0,
        "autojoin_error_count" => 0
      },
      "events" => []
    }
  end

  defp calendar_policy_failure(:calendar_policy_not_configured, "slack") do
    %{
      status: :skipped,
      reason_class: :calendar_policy_not_configured,
      next_action:
        "Meeting auto-join is optional. To enable it, configure this connect in meetings.calendar_autojoin with a Slack channel and explicit watched calendars.",
      evidence: %{}
    }
  end

  defp calendar_policy_failure(:calendar_policy_not_configured, _provider) do
    %{
      status: :skipped,
      reason_class: :calendar_policy_not_configured,
      next_action:
        "Calendar event creation remains available through the Agent Swarm's ACTIVE Google Calendar connection. To also notify this Feishu group at or shortly after event start, configure this connect in meetings.calendar_autojoin with mode=notify, a target chat, and explicit watched calendars.",
      evidence: %{}
    }
  end

  defp calendar_policy_failure(
         {:calendar_source_maintenance, {:calendar_source_bootstrap_pending, next_retry_at}},
         _provider
       ),
       do: calendar_bootstrap_pending(next_retry_at)

  defp calendar_policy_failure({:calendar_source_bootstrap_pending, next_retry_at}, _provider),
    do: calendar_bootstrap_pending(next_retry_at)

  defp calendar_policy_failure({:calendar_source_maintenance, reason}, _provider) do
    if transient_calendar_policy_reason?(reason),
      do: calendar_transient_pending(reason, :calendar_source_maintenance_retrying),
      else: calendar_source_maintenance_failed(reason)
  end

  defp calendar_policy_failure(:calendar_enrollment_no_active_account, _provider) do
    %{
      status: :fail,
      reason_class: :calendar_enrollment_no_active_account,
      next_action:
        "Connect an ACTIVE Google Calendar account owned by this Agent Swarm, then re-run checks.",
      evidence: %{}
    }
  end

  defp calendar_policy_failure({:calendar_not_found, calendar}, "slack") do
    %{
      status: :fail,
      reason_class: :calendar_not_found,
      next_action:
        "No Google Calendar matched the configured value. Use the exact shared calendar name or stable calendar ID in meetings.calendar_autojoin.calendars, then re-run checks.",
      evidence: %{"configured_calendar" => calendar}
    }
  end

  defp calendar_policy_failure({:calendar_not_found, calendar}, _provider) do
    %{
      status: :fail,
      reason_class: :calendar_not_found,
      next_action:
        "No Google Calendar matched the configured value. Use the exact shared calendar name or stable calendar ID in meetings.calendar_autojoin.calendars; keep create_calendar equal to one of those entries, then re-run checks.",
      evidence: %{"configured_calendar" => calendar}
    }
  end

  defp calendar_policy_failure({:calendar_ambiguous, calendar}, "slack") do
    %{
      status: :fail,
      reason_class: :calendar_ambiguous,
      next_action:
        "More than one Google Calendar matched the configured value. Replace it with the stable calendar ID in meetings.calendar_autojoin.calendars, then re-run checks.",
      evidence: %{"configured_calendar" => calendar}
    }
  end

  defp calendar_policy_failure({:calendar_ambiguous, calendar}, _provider) do
    %{
      status: :fail,
      reason_class: :calendar_ambiguous,
      next_action:
        "More than one Google Calendar matched the configured value. Replace it with the stable calendar ID in meetings.calendar_autojoin.calendars and, when it is the creation target, in create_calendar too; then re-run checks.",
      evidence: %{"configured_calendar" => calendar}
    }
  end

  defp calendar_policy_failure(:calendar_policy_agent_group_missing, _provider) do
    %{
      status: :skipped,
      reason_class: :calendar_policy_agent_group_missing,
      next_action:
        "The Router Agent has no Salix group. Repair the Agent Swarm route, then re-run checks.",
      evidence: %{}
    }
  end

  defp calendar_policy_failure(:calendar_policy_group_conflict, _provider) do
    %{
      status: :fail,
      reason_class: :calendar_policy_group_conflict,
      next_action:
        "More than one meeting-calendar target is configured for this Agent Swarm. Keep exactly one Slack or Feishu connect entry for the group, then re-run checks.",
      evidence: %{}
    }
  end

  defp calendar_policy_failure(reason, provider) do
    if transient_calendar_policy_reason?(reason) do
      calendar_transient_pending(reason, :calendar_enrollment_retrying)
    else
      calendar_permanent_failure(reason, provider)
    end
  end

  defp calendar_gate_label("slack"), do: "Google Calendar meeting auto-join"
  defp calendar_gate_label(_provider), do: "Google Calendar meeting notifications"

  defp calendar_not_connected_next_action("slack"),
    do: "Create a Slack connect before configuring meeting auto-join."

  defp calendar_not_connected_next_action(_provider),
    do: "Create a Feishu connect before configuring meeting notifications."

  defp calendar_active_next_action("slack"),
    do:
      "Google Calendar is ACTIVE; matching events are eligible for automatic meeting join from the configured Slack channel."

  defp calendar_active_next_action(_provider),
    do:
      "Google Calendar is ACTIVE; meetings notify the configured Feishu group on the first worker tick at or shortly after start."

  defp provider_name("slack"), do: "Slack"
  defp provider_name(_provider), do: "Feishu"

  defp calendar_bootstrap_pending(next_retry_at) do
    %{
      status: :needs_manual,
      reason_class: :calendar_initial_sync_pending,
      next_action:
        "Initial calendar sync has not completed yet. The retry becomes eligible at the time below; the bounded worker cadence determines when it runs. Re-run checks after that attempt.",
      evidence: %{"next_retry_at" => calendar_retry_time(next_retry_at)}
    }
  end

  defp calendar_transient_pending(reason, reason_class) do
    %{
      status: :needs_manual,
      reason_class: reason_class,
      next_action:
        "Calendar enrollment is temporarily unavailable. Initial-source retries become eligible after 60 seconds; repair of a previously active source follows six hours plus source jitter. The bounded worker cadence determines when an eligible retry runs.",
      evidence: %{"retryable_failure" => reason_to_string(reason)}
    }
  end

  defp calendar_source_maintenance_failed(reason) do
    %{
      status: :fail,
      reason_class: :calendar_source_maintenance_failed,
      next_action:
        "Calendar source maintenance requires correction. Verify the Google Calendar authorization and selected calendar still exist, reconnect or correct them as needed, then re-run checks.",
      evidence: %{"maintenance_failure" => reason_to_string(reason)}
    }
  end

  defp calendar_permanent_failure(reason, "slack") do
    %{
      status: :fail,
      reason_class: reason,
      next_action:
        "Verify the selected shared calendars, target Slack channel and bot membership, and Google Calendar authorization.",
      evidence: %{"failure" => reason_to_string(reason)}
    }
  end

  defp calendar_permanent_failure(reason, _provider) do
    %{
      status: :fail,
      reason_class: reason,
      next_action:
        "Verify the selected shared calendar, create_calendar, target Feishu chat, and Google Calendar authorization.",
      evidence: %{"failure" => reason_to_string(reason)}
    }
  end

  defp transient_calendar_policy_reason?(reason)
       when reason in [
              :transient,
              :timeout,
              :unavailable,
              :source_operation_timeout,
              :calendar_source_refresh_unsettled
            ],
       do: true

  defp transient_calendar_policy_reason?(
         {:calendar_enrollment_connect_lookup, {:ambiguous, _reason}}
       ),
       do: true

  defp transient_calendar_policy_reason?({:google_calendar_rate_limited, status, _reasons})
       when status in [403, 429],
       do: true

  defp transient_calendar_policy_reason?({:transport, _reason}), do: true

  defp transient_calendar_policy_reason?({tag, reason})
       when tag in [
              :calendar_enrollment_account,
              :calendar_enrollment_list,
              :calendar_enrollment_connect,
              :calendar_enrollment_connect_lookup,
              :channel_resolve
            ],
       do: transient_calendar_policy_reason?(reason)

  defp transient_calendar_policy_reason?({tag, status})
       when tag in [:http, :google_calendar_http] and is_integer(status),
       do: transient_http_status?(status)

  defp transient_calendar_policy_reason?({tag, status, _body})
       when tag in [:http, :google_calendar_http] and is_integer(status),
       do: transient_http_status?(status)

  defp transient_calendar_policy_reason?(_reason), do: false

  defp transient_http_status?(status), do: status in [408, 425, 429] or status >= 500

  defp calendar_retry_time(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> value
    end
  end

  defp calendar_retry_time(value), do: value

  defp bot_first_message_gate(_connect, list_error) when not is_nil(list_error) do
    gate(%{
      gate_id: "bot.first_message",
      label: "First message round-trips (@Bridge -> reply)",
      status: :skipped,
      reason_class: list_error,
      next_action: "Could not load Feishu connects. Re-run checks after Salix is available.",
      evidence: %{"list_error" => reason_to_string(list_error)}
    })
  end

  defp bot_first_message_gate(nil, _list_error) do
    gate(%{
      gate_id: "bot.first_message",
      label: "First message round-trips (@Bridge -> reply)",
      status: :skipped,
      reason_class: :not_connected,
      next_action: "Create a Feishu connect before sending a first-message smoke.",
      evidence: %{"auto_run" => false}
    })
  end

  defp bot_first_message_gate(connect, _list_error) do
    gate(%{
      gate_id: "bot.first_message",
      label: "First message round-trips (@Bridge -> reply)",
      status: :needs_manual,
      reason_class: :explicit_admin_action_required,
      next_action:
        "Use the explicit test-message action, or send a real @Bridge message in the target Feishu group and watch for a reply.",
      evidence: %{
        "connect_id" => connect["connect_id"],
        "auto_run" => false,
        "side_effects" => "billable_llm_wake"
      }
    })
  end

  defp bot_manual_gate(org) do
    scopes = FeishuScopes.required_scope_ids(:bot)

    gate(%{
      gate_id: "bot.manual",
      label: "Feishu console steps completed",
      status: :needs_manual,
      reason_class: :feishu_console_steps_required,
      next_action:
        "In Feishu: Permissions & Scopes → Batch import/export scopes → Import JSON, import the Bot scope JSON, subscribe to receive-message events, publish/install the new app version, add the bot to the target group, and confirm new members may view history. External or confidential chats may still block attachment downloads.",
      evidence: %{
        "settings_path" => "/orgs/#{org.slug}/settings/feishu",
        "required_scopes" => scopes,
        "capability_checks" => [
          %{
            "id" => "history_access",
            "required_scopes" => ["im:message:readonly", "im:message.group_msg"],
            "failure_hints" => [
              "permission missing or the permission-bearing app version is not published/installed",
              "bot is not a member of the target chat",
              "new members are not allowed to view earlier chat history"
            ]
          },
          %{
            "id" => "message_resources",
            "failure_hints" => [
              "external chat policy blocks this resource",
              "confidential/restricted mode blocks resource download",
              "resource is deleted or exceeds Feishu's 100 MB limit"
            ]
          },
          %{
            "id" => "message_mutation_reactions_and_pins",
            "required_scopes" => [
              "im:message:update",
              "im:message:recall",
              "im:message.reactions:read",
              "im:message.reactions:write_only",
              "im:message.pins:read",
              "im:message.pins:write_only"
            ],
            "failure_hints" => [
              "permission-bearing app version is not published/installed",
              "message edit/recall only applies to messages authored by this bot",
              "chat policy only allows owners or administrators to Pin"
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
              "permission-bearing app version is not published/installed",
              "the app's Contacts & organization data scope excludes the requested user or department",
              "directory results are partial because only explicitly authorized roots are visible"
            ]
          }
        ]
      }
    })
  end

  defp chat_access_status(%{status: :disabled}, _identity), do: :fail
  defp chat_access_status(%{status: :missing_router}, _identity), do: :fail
  defp chat_access_status(%{status: :unknown}, _identity), do: :skipped
  defp chat_access_status(_route, %{status: :fail}), do: :fail
  defp chat_access_status(_route, %{status: :skipped}), do: :skipped
  defp chat_access_status(%{status: :ready}, %{status: :ok}), do: :skipped
  defp chat_access_status(_route, _identity), do: :skipped

  defp chat_access_reason(%{status: :disabled}, _identity, _status), do: :connect_inactive

  defp chat_access_reason(%{status: :missing_router}, _identity, _status),
    do: :router_not_configured

  defp chat_access_reason(%{status: :unknown, route_error: reason}, _identity, _status),
    do: reason

  defp chat_access_reason(_route, %{status: status, reason_class: reason}, _status)
       when status in [:fail, :skipped],
       do: reason

  defp chat_access_reason(%{status: :ready}, %{status: :ok}, :skipped),
    do: :chat_probe_missing

  defp chat_access_reason(_route, _identity, _status), do: :not_verified

  defp chat_access_next_action(%{status: :disabled}, _identity, _status),
    do: "Enable this Feishu connect before sending the first group message."

  defp chat_access_next_action(%{status: :missing_router}, _identity, _status),
    do:
      "The Agent Swarm router is not ready. Retry checks shortly; if this persists, contact support."

  defp chat_access_next_action(%{status: :unknown}, _identity, _status),
    do: "Could not verify the Salix route/router state. Retry checks shortly."

  defp chat_access_next_action(
         _route,
         %{status: :fail, reason_class: :bot_identity_missing},
         _status
       ),
       do:
         "Salix has not resolved the Feishu bot open_id yet. Re-save or resync the org Feishu app binding before testing group messages."

  defp chat_access_next_action(_route, %{status: :skipped, reason_class: reason}, _status)
       when reason in [:unavailable, :timeout],
       do: "Salix is unavailable right now. Re-run checks shortly."

  defp chat_access_next_action(_route, %{status: :skipped}, _status),
    do: "Bot identity could not be verified yet. Re-run checks after the runtime is ready."

  defp chat_access_next_action(%{status: :ready}, %{status: :ok}, :skipped),
    do:
      "Route and bot identity are ready; chat/member probing needs a runtime call that is not wired yet."

  defp chat_access_next_action(_route, _identity, _status),
    do: "Re-run checks after the Feishu connect and route are ready."

  defp chat_access_evidence(project, connect, route, identity) do
    %{
      "project_id" => project.id,
      "salix_group_id" => project.salix_group_id,
      "connect_id" => connect["connect_id"],
      "connect_status" => connect["status"],
      "route_status" => route.status,
      "router_agent_id" => route.router_agent_id,
      "router_agent_name" => route.router_agent && route.router_agent.salix["name"],
      "bot_identity_status" => identity.status,
      "bot_identity_reason" => identity.reason_class,
      "bot_identity_evidence" => identity.evidence || %{},
      "chat_probe" => "not_wired"
    }
  end

  defp bot_identity(connect) do
    client = client()

    cond do
      not function_exported?(client, :feishu_bot_identity, 1) ->
        %{status: :skipped, reason_class: :backend_missing, evidence: %{}}

      true ->
        case client.feishu_bot_identity(%{"connect_id" => connect["connect_id"]}) do
          {:ok, evidence} ->
            %{status: :ok, reason_class: :resolved, evidence: evidence}

          {:error, reason} ->
            %{
              status: bot_identity_status(reason),
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
    end
  end

  defp bot_identity_status(reason)
       when reason in [:connect_not_found, :connect_inactive, :unavailable, :timeout],
       do: :skipped

  defp bot_identity_status(_reason), do: :fail

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
    do: "Configure the Feishu Verification Token and Encrypt Key if encryption is enabled."

  defp callback_next_action(reason) when reason in [:connect_not_found, :connect_inactive],
    do: "This connect is not active; re-create or re-enable it, then re-run checks."

  defp callback_next_action(:token_mismatch),
    do: "Verification Token mismatch: synchronize the Feishu console token with this connect."

  defp callback_next_action(:encrypted_unsupported),
    do:
      "Encrypted callback verification failed. Re-publish the app and re-run; if it persists, temporarily disable Feishu event encryption."

  defp callback_next_action(:decrypt_signature),
    do: "Signature verification failed: check the Verification Token and Encrypt Key."

  defp callback_next_action(:callback_unreachable),
    do: "The callback URL is unreachable. Check the public endpoint and tunnel."

  defp callback_next_action(reason) when reason in [:unavailable, :timeout],
    do: "Salix is unavailable right now. Re-run checks shortly."

  defp callback_next_action(_reason),
    do: "Callback verification failed. Inspect the Feishu app callback configuration."

  defp callback_evidence(connect, evidence) do
    %{
      "connect_id" => connect["connect_id"],
      "app_id" => connect["app_id"],
      "webhook_url" => safe_webhook_url(connect),
      "verification_token_configured" => truthy?(connect["verification_token_configured"]),
      "encrypt_key_configured" => truthy?(connect["encrypt_key_configured"]),
      "encrypted_callback" =>
        truthy?(connect["encrypt_key_configured"]) or evidence["challenge_mode"] == "encrypted",
      "preflight" => evidence
    }
  end

  defp credential_evidence(connect) do
    %{
      "connect_id" => connect["connect_id"],
      "app_id" => connect["app_id"],
      "app_secret_configured" => truthy?(connect["app_secret_configured"]),
      "verification_token_configured" => truthy?(connect["verification_token_configured"]),
      "encrypt_key_configured" => truthy?(connect["encrypt_key_configured"]),
      "updated_at" => connect["updated_at"]
    }
  end

  defp route_state(_project, %{"disabled_at" => disabled_at})
       when not is_nil(disabled_at) and disabled_at != "" do
    %{
      status: :disabled,
      router_agent_id: nil,
      router_agent: nil,
      route_error: nil
    }
  end

  defp route_state(project, _connect) do
    case read_current_router_agent_id(project) do
      {:ok, router_agent_id} ->
        router_agent =
          Enum.find(Agents.list_agents(project.id), &router_agent?(&1, router_agent_id))

        status = if router_agent, do: :ready, else: :missing_router

        %{
          status: status,
          router_agent_id: router_agent_id,
          router_agent: router_agent,
          route_error: nil
        }

      {:unsupported, reason} ->
        %{status: :unknown, router_agent_id: nil, router_agent: nil, route_error: reason}

      {:error, reason} ->
        %{status: :unknown, router_agent_id: nil, router_agent: nil, route_error: reason}
    end
  end

  defp read_current_router_agent_id(project) do
    client = client()

    if function_exported?(client, :get_group, 1) do
      case client.get_group(project.salix_group_id) do
        {:ok, group} -> {:ok, group["router_agent_id"]}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      {:unsupported, :get_group_unavailable}
    end
  end

  defp router_agent?(_agent, nil), do: false
  defp router_agent?(_agent, ""), do: false

  defp router_agent?(%Agent{} = agent, router_agent_id),
    do: agent.salix_agent_id == router_agent_id

  defp list_connects(org, project, provider),
    do: list_connects(org, project, provider, :meeting_calendar_policy)

  defp list_connects(org, project, provider, :meeting_calendar_policy_status) do
    case ProjectIMConnects.list_project_connects_read_only(org.id, project.id, provider) do
      {:ok, connects} when is_list(connects) -> {connects, nil}
      {:ok, _other} -> {[], :unexpected_connects_response}
      {:error, reason} -> {[], reason}
    end
  end

  defp list_connects(org, project, provider, _policy_probe) do
    case ProjectIMConnects.list_project_connects(org.id, project.id, provider) do
      {:ok, connects} when is_list(connects) -> {connects, nil}
      {:ok, _other} -> {[], :unexpected_connects_response}
      {:error, reason} -> {[], reason}
    end
  end

  defp preferred_connect(connects, "") do
    Enum.find(connects, &blank?(&1["disabled_at"])) || List.first(connects)
  end

  defp preferred_connect(connects, connect_id),
    do: Enum.find(connects, &(&1["connect_id"] == connect_id))

  defp safe_webhook_url(%{"webhook_url" => url} = connect) when is_binary(url) and url != "" do
    app_id = connect["app_id"]
    uri = URI.parse(url)
    existing_query = URI.decode_query(uri.query || "")
    query = maybe_put_query(%{}, "app_id", app_id || existing_query["app_id"])

    %{uri | query: if(query == %{}, do: nil, else: URI.encode_query(query))}
    |> URI.to_string()
  rescue
    _ -> nil
  end

  defp safe_webhook_url(_connect), do: nil

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, _key, ""), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp gate(attrs) do
    status = Map.fetch!(attrs, :status)

    if status not in @statuses do
      raise ArgumentError, "unknown Run checks status #{inspect(status)}"
    end

    attrs
    |> Map.put_new(:required, true)
    |> Map.put_new(:evidence, %{})
    |> Map.put(:evidence, redact_evidence(attrs[:evidence] || %{}))
    |> Map.put(:redacted, true)
  end

  defp gate_to_json(gate) do
    %{
      "gate_id" => gate[:gate_id],
      "label" => gate[:label],
      "status" => atom_to_string(gate[:status]),
      "reason_class" => atom_to_string(gate[:reason_class]),
      "next_action" => gate[:next_action],
      "required" => gate[:required] != false,
      "evidence" => redact_evidence(gate[:evidence] || %{}),
      "redacted" => gate[:redacted] != false
    }
  end

  defp redact_evidence(%{} = map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key) do
        {to_string(key), "[REDACTED]"}
      else
        {to_string(key), redact_evidence(value)}
      end
    end)
  end

  defp redact_evidence(list) when is_list(list), do: Enum.map(list, &redact_evidence/1)

  defp redact_evidence(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> redact_evidence()

  defp redact_evidence(value) when is_atom(value), do: Atom.to_string(value)
  defp redact_evidence(value) when is_binary(value), do: redact_string(value)
  defp redact_evidence(value), do: value

  defp redact_string(value) do
    cond do
      String.contains?(value, ["app_secret=", "verification_token=", "encrypt_key="]) ->
        value
        |> URI.parse()
        |> redact_url()

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
  rescue
    _ -> "[REDACTED]"
  end

  defp redact_url(%URI{} = uri) do
    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Enum.reject(fn {key, _value} -> secret_key?(key) end)
      |> Map.new()

    %{uri | query: if(query == %{}, do: nil, else: URI.encode_query(query))}
    |> URI.to_string()
  end

  defp secret_key?(key) do
    key = key |> to_string() |> String.downcase()

    cond do
      String.ends_with?(key, "_configured") ->
        false

      key in ["app_id", "connect_id", "group_id", "project_id", "settings_path"] ->
        false

      String.contains?(key, [
        "secret",
        "token",
        "encrypt_key",
        "authorization",
        "password",
        "raw_payload",
        "payload",
        "body",
        "message",
        "content",
        "open_id",
        "union_id",
        "user_id",
        "tenant_access",
        "user_access",
        "access_token"
      ]) ->
        true

      true ->
        false
    end
  end

  defp fetch_org(%Organization{} = org), do: {:ok, org}
  defp fetch_org(id), do: Orgs.get_org(id)

  defp fetch_project(%Project{} = project), do: {:ok, project}
  defp fetch_project(id), do: Projects.get_project(id)

  defp ensure_project_in_org(%Project{org_id: org_id}, %Organization{id: org_id}), do: :ok
  defp ensure_project_in_org(_project, _org), do: {:error, :not_found}

  defp ran_at(opts), do: Keyword.get_lazy(opts, :ran_at, &DateTime.utc_now/0)

  defp serialize_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_time(other), do: other

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value) when is_binary(value), do: value
  defp atom_to_string(value), do: inspect(value)

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)

  defp present?(value), do: not blank?(value)
  defp blank?(value), do: trim(value) == ""

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_value), do: false

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()

  defp client, do: Client.impl()
end
