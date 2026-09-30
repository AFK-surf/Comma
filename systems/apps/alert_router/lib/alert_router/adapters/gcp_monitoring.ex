defmodule AlertRouter.Adapters.GCPMonitoring do
  @moduledoc """
  Typed adapter for Cloud Monitoring Pub/Sub notification schema 1.2.

  Generated `summary`, documentation, resource labels, and condition text are
  deliberately ignored. Only reviewed policy labels and explicitly allowlisted
  evidence/link fields enter the canonical event. The generated incident URL
  path remains opaque after its HTTPS origin is verified.
  """

  alias AlertRouter.{CanonicalEvent, Catalog}
  alias AlertRouter.Adapters.Helpers

  @spec normalize(map(), keyword()) :: {:ok, CanonicalEvent.t()} | {:error, term()}
  def normalize(payload, opts \\ [])

  def normalize(%{"version" => "1.2", "incident" => incident}, opts)
      when is_map(incident) and is_list(opts) do
    labels = Map.get(incident, "policy_user_labels", %{})

    with {:ok, incident_id} <- Helpers.required_string(incident, "incident_id"),
         {:ok, account} <- Helpers.required_string(incident, "scoping_project_id"),
         {:ok, source_state} <- Helpers.required_string(incident, "state"),
         {:ok, state, recovery_status} <- lifecycle(source_state),
         {:ok, started_at} <- Helpers.from_unix(incident["started_at"]),
         {:ok, ended_at} <- Helpers.optional_unix(incident["ended_at"]),
         {:ok, observed_at} <- observed_at(state, started_at, ended_at),
         {:ok, raw_policy_id} <- Helpers.required_string(labels, "comma_policy_id"),
         {:ok, managed_by} <- Helpers.required_string(labels, "managed_by"),
         {:ok, environment} <- environment(account),
         {:ok, priority} <- normalized_priority(labels["comma_priority"]),
         {:ok, family} <- Helpers.required_string(labels, "comma_domain"),
         {:ok, incident_url} <- reviewed_incident_link(incident["url"], account),
         source_identity <- ["alert-router.v1", "gcp_monitoring", account, incident_id],
         policy_identity <- ["gcp_monitoring", managed_by, raw_policy_id],
         attrs <- %{
           schema_version: 1,
           source: "gcp_monitoring",
           source_account: account,
           source_identity: source_identity,
           policy_identity: policy_identity,
           source_state: source_state,
           state: state,
           recovery_status: recovery_status,
           environment: environment,
           priority: priority,
           team: nil,
           service: Helpers.optional_string(labels, "service"),
           family: family,
           region: Helpers.optional_string(labels, "region"),
           started_at: started_at,
           ended_at: ended_at,
           observed_at: observed_at,
           evidence_values:
             Helpers.compact_string_map([
               {"observed", incident["observed_value"]}
             ]),
           links: %{"incident" => incident_url}
         },
         {:ok, enriched} <- Catalog.enrich(attrs),
         {:ok, event} <- CanonicalEvent.build(enriched) do
      {:ok, event}
    end
  end

  def normalize(%{"version" => version}, _opts), do: {:error, {:unsupported_gcp_schema, version}}
  def normalize(_payload, _opts), do: {:error, :invalid_gcp_payload}

  defp lifecycle("open"), do: {:ok, "firing", "not_applicable"}
  defp lifecycle("closed"), do: {:ok, "resolved", "unknown"}
  defp lifecycle(value), do: {:error, {:invalid_gcp_state, value}}

  defp environment(project) do
    projects = Application.get_env(:alert_router, :gcp_projects, %{})

    case Enum.find(projects, fn {_environment, id} -> is_binary(id) and id == project end) do
      {:staging, _id} -> {:ok, "staging"}
      {:production, _id} -> {:ok, "production"}
      _ -> {:error, {:unknown_gcp_project, project}}
    end
  end

  defp reviewed_incident_link(value, account) when is_binary(value) do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: "console.cloud.google.com",
        port: port,
        userinfo: nil,
        path: path
      } = uri
      when port in [nil, 443] and is_binary(path) and path != "" ->
        {:ok,
         uri
         |> Map.put(:port, nil)
         |> Map.put(:query, URI.encode_query(%{"project" => account}))
         |> Map.put(:fragment, nil)
         |> URI.to_string()}

      _uri ->
        {:error, :invalid_gcp_incident_link}
    end
  end

  defp reviewed_incident_link(_value, _account), do: {:error, :invalid_gcp_incident_link}

  defp normalized_priority(value) when is_binary(value) do
    case String.upcase(value) do
      priority when priority in ["P0", "P1", "P2", "P3"] -> {:ok, priority}
      _priority -> {:error, {:invalid_gcp_priority, value}}
    end
  end

  defp normalized_priority(value), do: {:error, {:invalid_gcp_priority, value}}

  defp observed_at("firing", started_at, _ended_at), do: {:ok, started_at}

  defp observed_at("resolved", _started_at, %DateTime{} = ended_at),
    do: {:ok, ended_at}

  defp observed_at("resolved", _started_at, nil),
    do: {:error, {:missing_field, "ended_at"}}
end
