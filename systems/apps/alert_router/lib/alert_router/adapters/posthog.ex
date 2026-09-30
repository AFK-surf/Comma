defmodule AlertRouter.Adapters.PostHog do
  @moduledoc """
  Comma's versioned envelope for PostHog issue-created/reopened HTTP destinations.

  The project and environment come from server configuration. One source issue
  occurrence is one incident generation; retries retain the original source time.
  This adapter accepts firing facts only and never manufactures recovery.
  """
  alias AlertRouter.{CanonicalEvent, Catalog}
  alias AlertRouter.Adapters.Helpers

  @policy ["posthog", "comma_client_critical_issue"]

  def configuration do
    config = Application.get_env(:alert_router, :posthog_webhook, [])
    project_id = Keyword.get(config, :project_id)
    origin = Keyword.get(config, :origin)
    environment = Keyword.get(config, :environment)

    if is_binary(project_id) and Regex.match?(~r/^[1-9][0-9]{0,15}$/, project_id) and
         origin in ["https://us.posthog.com", "https://eu.posthog.com"] and
         environment in ["staging", "production"] do
      {:ok,
       %{
         project_id: project_id,
         origin: origin,
         environment: environment,
         account: "#{origin}/project/#{project_id}"
       }}
    else
      {:error, :not_configured}
    end
  end

  def normalize(%{"schema_version" => 1, "project_id" => project_id} = payload) do
    with {:ok, config} <- configuration(),
         true <- project_id == config.project_id do
      normalize_issue(payload, config)
    else
      false -> {:error, :unapproved_posthog_project}
      error -> error
    end
  end

  def normalize(_payload), do: {:error, :invalid_posthog_payload}

  defp normalize_issue(%{"event" => action} = payload, config)
       when action in ["issue_created", "issue_reopened"] do
    if payload["severity"] == "critical" and
         payload["error_kind"] in ["react_uncaught", "login_unavailable"] do
      build_event(payload, config)
    else
      {:ok, :ignored}
    end
  end

  defp normalize_issue(_payload, _config), do: {:error, :unsupported_posthog_event}

  defp build_event(payload, config) do
    with {:ok, issue_id} <- Ecto.UUID.cast(payload["issue_id"]),
         {:ok, source_time} <- Helpers.required_string(payload, "occurred_at"),
         {:ok, occurred_at} <- Helpers.parse_iso8601(source_time),
         attrs <- %{
           schema_version: 1,
           source: "posthog",
           source_account: config.account,
           source_identity: [
             "alert-router.v1",
             "posthog",
             config.account,
             issue_id,
             DateTime.to_iso8601(occurred_at)
           ],
           policy_identity:
             if(payload["error_kind"] == "login_unavailable",
               do: ["posthog", "comma_client_login_unavailable"],
               else: @policy
             ),
           source_state: payload["event"],
           state: "firing",
           recovery_status: "not_applicable",
           environment: config.environment,
           started_at: occurred_at,
           observed_at: occurred_at,
           ended_at: nil,
           evidence_values: %{"observed" => payload["error_kind"]},
           links: %{"incident" => "#{config.account}/error_tracking/#{issue_id}"}
         },
         {:ok, enriched} <- Catalog.enrich(attrs),
         {:ok, event} <- CanonicalEvent.build(enriched) do
      {:ok, event}
    else
      :error -> {:error, :invalid_posthog_issue_id}
      error -> error
    end
  end
end
