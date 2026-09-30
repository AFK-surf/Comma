defmodule SalixIM.SlackCommandSync do
  @moduledoc """
  Explicit admin-triggered reconciliation of one App manifest.
  One attempt, no polling. Interrupted attempts remain pending and can be retried.
  Non-command manifest fields come from Slack, never from our generated template.
  """
  alias SalixIM.{ProviderConnects, SlackCommands}
  alias SalixIM.Provider.Slack.API
  alias SalixStore.SlackCommandControl

  def configure_credential(tenant_id, refresh_token, profile \\ "default") do
    if SlackCommandControl.valid_profile?(profile) and is_binary(refresh_token) and
         byte_size(refresh_token) <= 4096 and
         String.starts_with?(refresh_token, "xoxe-") do
      SlackCommandControl.exclusive(fn ->
        # Rotation validates the supplied credential and returns its lifetime.
        case call(nil, "tooling.tokens.rotate", refresh_token: refresh_token) do
          {:ok, value} -> store_rotation(tenant_id, value, profile)
          error -> error
        end
      end)
    else
      {:error, :invalid_configuration_token}
    end
  end

  def credential_configured?(tenant_id, profile \\ "default") do
    case SlackCommandControl.profiles(tenant_id) do
      {:ok, profiles} -> profile in profiles
      _ -> false
    end
  end

  def sync(connect) do
    started = System.monotonic_time()
    result = do_sync(connect)

    outcome =
      case result do
        {:ok, %{"status" => status}} when status in ["synced", "reauthorization_required"] -> "ok"
        _ -> "error"
      end

    :telemetry.execute(
      [:salix, :slack_command_sync, :stop],
      %{duration: System.monotonic_time() - started},
      %{outcome: outcome}
    )

    result
  end

  # Operator question: are admin-triggered Slack syncs failing or becoming slow?
  def metrics do
    [
      Telemetry.Metrics.counter("salix.slack_command_sync.count",
        event_name: [:salix, :slack_command_sync, :stop],
        tags: [:outcome]
      ),
      Telemetry.Metrics.distribution("salix.slack_command_sync.duration",
        event_name: [:salix, :slack_command_sync, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:outcome],
        reporter_options: [buckets: [100, 500, 1000, 5000, 15000, 60000]]
      )
    ]
  end

  defp do_sync(connect) do
    result =
      with {:ok, url} <- callback_url(),
           {:ok, credential} <-
             token(
               connect["tenant_id"],
               SlackCommands.state(connect)["credential_profile"] || "default"
             ),
           {:ok, exported} <-
             call(credential["token"], "apps.manifest.export", app_id: connect["app_id"]),
           {:ok, manifest} <- merged_manifest(exported["manifest"], connect, url),
           {:ok, validated} <-
             call(credential["token"], "apps.manifest.validate",
               app_id: connect["app_id"],
               manifest: Jason.encode!(manifest)
             ),
           true <- validated["errors"] in [nil, []] do
        if comparable_manifest(exported["manifest"]) == comparable_manifest(manifest) do
          {:ok, false}
        else
          publish(connect, credential["token"], exported["manifest"], manifest)
        end
      else
        false -> {:error, :invalid_manifest}
        error -> error
      end

    case result do
      {:ok, permissions_updated} ->
        required =
          permissions_updated or
            (SlackCommands.state(connect)["authorization_required"] == true and
               not commands_granted?(connect))

        finish(connect, %{
          "status" => if(required, do: "reauthorization_required", else: "synced"),
          "error" => nil,
          "failure_stage" => nil,
          "failure_outcome" => nil,
          "authorization_required" => required,
          "synced_at" => System.system_time(:second),
          "managed_names" => Enum.map(SlackCommands.list(connect), & &1["command"])
        })

      {:error, {:sync_failure, stage, outcome, reason}} ->
        finish_failure(connect, stage, outcome, reason)

      {:error, reason} ->
        finish_failure(connect, "prepare", "not_sent", reason)
    end
  end

  defp commands_granted?(connect),
    do:
      connect["granted_bot_scopes_generation"] == connect["connect_generation"] and
        "commands" in (connect["granted_bot_scopes"] || [])

  defp publish(_connect, _token, old, new) when old == new, do: {:ok, false}

  defp publish(connect, token, old, manifest) do
    # Retain possible published names before sending. If Slack accepts the write
    # but its response is lost, a later delete can still remove those names.
    names = Enum.map(SlackCommands.list(connect), & &1["command"])

    with {:ok, _} <-
           SlackCommands.update(
             connect["group_id"],
             connect["connect_id"],
             connect["app_id"],
             fn state ->
               state
               |> Map.put(
                 "managed_names",
                 Enum.uniq(
                   Enum.filter(state["managed_names"] || [], fn name ->
                     Enum.any?(
                       get_in(old, ["features", "slash_commands"]) || [],
                       &(&1["command"] == name)
                     )
                   end) ++ names
                 )
               )
               |> Map.put(
                 "authorization_required",
                 state["authorization_required"] == true or
                   ("commands" not in (get_in(old, ["oauth_config", "scopes", "bot"]) || []) and
                      "commands" in (get_in(manifest, ["oauth_config", "scopes", "bot"]) || []))
               )
             end
           ) do
      with {:ok, response} <-
             call(
               token,
               "apps.manifest.update",
               [app_id: connect["app_id"], manifest: Jason.encode!(manifest)],
               "update"
             ),
           {:ok, verified} <-
             call(token, "apps.manifest.export", [app_id: connect["app_id"]], "verify"),
           true <- same_commands?(verified["manifest"], manifest) do
        {:ok, response["permissions_updated"] == true}
      else
        false -> {:error, {:sync_failure, "verify", "unknown", :manifest_verification_failed}}
        error -> error
      end
    end
  end

  defp comparable_manifest(manifest) do
    features = manifest["features"] || %{}

    Map.put(
      manifest,
      "features",
      Map.put(features, "slash_commands", normalize_commands(features["slash_commands"]))
    )
  end

  defp same_commands?(actual, expected) when is_map(actual) do
    normalize_commands(get_in(actual, ["features", "slash_commands"])) ==
      normalize_commands(get_in(expected, ["features", "slash_commands"]))
  end

  defp same_commands?(_, _), do: false

  defp normalize_commands(commands) do
    (commands || [])
    |> Enum.map(&Map.merge(%{"should_escape" => false, "usage_hint" => ""}, &1))
    |> Enum.sort_by(& &1["command"])
  end

  @doc false
  def merged_manifest(manifest, connect, url) when is_map(manifest) do
    entries = SlackCommands.list(connect)

    desired =
      entries
      |> Enum.filter(& &1["enabled"])
      |> Enum.map(fn entry ->
        entry
        |> Map.take(~w(command description usage_hint))
        |> Map.merge(%{"url" => url, "should_escape" => false})
      end)

    names =
      Enum.uniq(
        (SlackCommands.state(connect)["managed_names"] || []) ++
          Enum.map(entries, & &1["command"])
      )

    features = manifest["features"] || %{}
    remote = features["slash_commands"] || []
    # Adding an existing name explicitly adopts it only if it already targets
    # this deployment. Never hijack a command sent to another handler.
    conflict = Enum.any?(remote, &(&1["command"] in names and &1["url"] != url))
    commands = Enum.reject(remote, &(&1["command"] in names)) ++ desired

    cond do
      conflict ->
        {:error, :command_name_conflict}

      length(commands) > 50 ->
        {:error, :too_many_commands}

      true ->
        updated = Map.put(manifest, "features", Map.put(features, "slash_commands", commands))
        {:ok, if(desired == [], do: updated, else: add_commands_scope(updated))}
    end
  end

  def merged_manifest(_, _, _), do: {:error, :invalid_manifest}

  defp add_commands_scope(manifest) do
    oauth = manifest["oauth_config"] || %{}
    scopes = oauth["scopes"] || %{}
    bot = scopes["bot"] || []

    Map.put(
      manifest,
      "oauth_config",
      Map.put(oauth, "scopes", Map.put(scopes, "bot", Enum.uniq(bot ++ ["commands"])))
    )
  end

  def callback_url do
    url = ProviderConnects.public_base_url() <> "/v1/im/slack/commands"

    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, :https_callback_required}
    end
  end

  defp token(tenant_id, profile) do
    with {:ok, credential} <- SlackCommandControl.credential(tenant_id, profile) do
      if is_integer(credential["exp"]) and credential["exp"] > System.system_time(:second) + 300 do
        {:ok, credential}
      else
        with {:ok, rotated} <-
               call(nil, "tooling.tokens.rotate", refresh_token: credential["refresh_token"]),
             :ok <- store_rotation(tenant_id, rotated, profile) do
          {:ok, rotated}
        end
      end
    end
  end

  defp store_rotation(tenant_id, value, profile) do
    if is_binary(value["token"]) and is_binary(value["refresh_token"]) and
         is_integer(value["exp"]) do
      SlackCommandControl.put_credential(
        tenant_id,
        Map.take(value, ~w(token refresh_token exp team_id user_id)),
        profile
      )
    else
      {:error, :invalid_configuration_token}
    end
  end

  defp finish_failure(connect, stage, outcome, reason) do
    # Store only bounded classifications and safe text, never Slack response bodies.
    finish(connect, %{
      "status" => "failed",
      "failure_stage" => stage,
      "failure_outcome" => outcome,
      "error" => error_text(reason)
    })
  end

  defp finish(connect, attributes) do
    with {:ok, saved} <-
           SlackCommands.update(
             connect["group_id"],
             connect["connect_id"],
             connect["app_id"],
             fn state -> Map.merge(state, attributes) end
           ) do
      {:ok, SlackCommands.state(saved)}
    end
  end

  # Reuse the existing Slack adapter (Req, timeouts, response/error handling).
  # No second protocol stack or extra dependency is necessary.
  defp call(token, method, fields, stage \\ "prepare") do
    {:ok, API.request_form(token, method, fields, timeout_ms: 2_000, pool_retries: 0)}
  rescue
    error in API.Error ->
      reason =
        cond do
          is_integer(error.retry_after) ->
            {:rate_limited, min(max(error.retry_after, 1), 3600)}

          error.message in ~w(invalid_auth token_expired token_revoked invalid_refresh_token not_authed) ->
            :invalid_configuration_token

          error.message in ~w(no_permission access_denied app_not_found app_not_eligible missing_scope not_allowed_token_type) ->
            :configuration_access_denied

          error.message == "invalid_manifest" ->
            :invalid_manifest

          true ->
            :slack_unavailable
        end

      # Slack documents partial success for internal_error and fatal_error.
      # Unknown provider errors stay uncertain instead of implying no write occurred.
      rejected =
        reason in [:invalid_configuration_token, :configuration_access_denied, :invalid_manifest] or
          match?({:rate_limited, _}, reason) or
          error.status in [400, 401, 403, 404, 405, 413, 415, 422, 429]

      request_failure(stage, reason, rejected)

    _ ->
      request_failure(stage, :slack_unavailable, false)
  end

  defp request_failure("prepare", reason, _), do: {:error, reason}

  defp request_failure(stage, reason, rejected) do
    # A rejected read after an accepted write cannot establish the write's result.
    outcome = if stage == "update" and rejected, do: "rejected", else: "unknown"
    {:error, {:sync_failure, stage, outcome, reason}}
  end

  def error_text({:rate_limited, seconds}),
    do: "Slack rate limit. Retry after #{seconds} seconds."

  def error_text(reason) do
    case reason do
      :command_templates_changed ->
        "Templates changed. Reload the page before saving or copying."

      :command_template_conflict ->
        "This App already has that command. Edit or delete its existing alias first."

      :command_template_missing ->
        "Template no longer exists. Reload the page."

      :command_admin_busy ->
        "Another command update is active. Retry shortly."

      :command_configuration_changed ->
        "Configuration changed. Reload before saving."

      :command_app_changed ->
        "The Slack App binding changed. Reload this page."

      :invalid_credential_profile ->
        "Use a lowercase credential profile name. Limit: 50 profiles per tenant."

      :invalid_commands ->
        "Use unique lowercase /commands, descriptions, and nonempty prompts. Limit: 50 commands."

      :configuration_credentials_missing ->
        "Configure a Slack configuration refresh token."

      :configuration_credentials_unavailable ->
        "Cannot read configuration credentials. Check the credential key."

      :credential_sealer_unavailable ->
        "The deployment credential key is unavailable."

      :invalid_configuration_token ->
        "Replace the configuration refresh token. Slack may have consumed an earlier rotation."

      :configuration_access_denied ->
        "The configuration account cannot manage this App. Check its permissions."

      :command_name_conflict ->
        "A matching Slack command targets another handler. Resolve the conflict in Slack."

      :too_many_commands ->
        "The App would exceed Slack's 50-command limit."

      :https_callback_required ->
        "Configure an HTTPS public base URL before synchronization."

      :invalid_manifest ->
        "Slack rejected the manifest. Check the App configuration."

      :manifest_verification_failed ->
        "Slack did not confirm the expected command list. Retry synchronization."

      _ ->
        "The operation failed. Configuration may already be saved. Reload and retry."
    end
  end
end
