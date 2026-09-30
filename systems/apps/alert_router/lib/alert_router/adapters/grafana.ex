defmodule AlertRouter.Adapters.Grafana do
  @moduledoc """
  Typed adapter for Grafana Alerting's default webhook payload.

  A notification group is expanded into one canonical event per alert. The
  rendered `title`, `message`, arbitrary annotations, and arbitrary labels are
  never forwarded.
  """

  alias AlertRouter.{CanonicalEvent, Catalog}
  alias AlertRouter.Adapters.Helpers

  @max_alerts_per_webhook 50

  @spec normalize(map(), DateTime.t()) :: {:ok, [CanonicalEvent.t()]} | {:error, term()}
  def normalize(%{"orgId" => org_id, "alerts" => alerts} = payload, %DateTime{} = received_at)
      when (is_integer(org_id) or is_binary(org_id)) and is_list(alerts) and alerts != [] and
             length(alerts) <= @max_alerts_per_webhook do
    with {:ok, source_origin} <- normalized_origin(payload["externalURL"]),
         {:ok, decimal_org_id} <- decimal_org_id(org_id) do
      alerts
      |> Enum.reduce_while({:ok, []}, fn alert, {:ok, events} ->
        case normalize_alert(alert, source_origin, decimal_org_id, received_at) do
          {:ok, event} -> {:cont, {:ok, [event | events]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, events} -> {:ok, Enum.reverse(events)}
        error -> error
      end
    end
  end

  def normalize(%{"alerts" => alerts}, %DateTime{})
      when is_list(alerts) and length(alerts) > @max_alerts_per_webhook,
      do: {:error, {:too_many_grafana_alerts, @max_alerts_per_webhook}}

  def normalize(_payload, _received_at), do: {:error, :invalid_grafana_payload}

  defp normalize_alert(alert, source_origin, decimal_org_id, _received_at) when is_map(alert) do
    labels = Map.get(alert, "labels", %{})
    annotations = Map.get(alert, "annotations", %{})

    with {:ok, source_state} <- Helpers.required_string(alert, "status"),
         {:ok, state, recovery_status} <- lifecycle(source_state),
         {:ok, fingerprint} <- Helpers.required_string(alert, "fingerprint"),
         {:ok, started_at_raw} <- Helpers.required_string(alert, "startsAt"),
         {:ok, started_at} <- Helpers.parse_iso8601(started_at_raw),
         {:ok, ended_at} <- ended_at(state, alert["endsAt"]),
         {:ok, policy_id} <- Helpers.required_string(annotations, "policy_id"),
         {:ok, environment} <- Helpers.required_string(labels, "environment"),
         {:ok, priority} <- Helpers.required_string(labels, "priority"),
         {:ok, team} <- Helpers.required_string(labels, "team"),
         {:ok, incident_url} <- same_origin_link(alert["generatorURL"], source_origin),
         {:ok, dashboard_url} <- optional_same_origin_link(alert["dashboardURL"], source_origin),
         source_identity <- [
           "alert-router.v1",
           "grafana",
           source_origin,
           decimal_org_id,
           fingerprint,
           DateTime.to_iso8601(started_at)
         ],
         attrs <- %{
           schema_version: 1,
           source: "grafana",
           source_account: source_origin,
           source_identity: source_identity,
           policy_identity: ["grafana", policy_id],
           source_state: source_state,
           state: state,
           recovery_status: recovery_status,
           environment: environment,
           priority: priority,
           team: team,
           service: Helpers.optional_string(labels, "service"),
           family: Helpers.optional_string(labels, "family"),
           region: Helpers.optional_string(labels, "region"),
           started_at: started_at,
           ended_at: ended_at,
           observed_at: ended_at || started_at,
           evidence_values:
             Helpers.compact_string_map([
               {"observed", observed_value(alert["values"])},
               {"threshold", Helpers.optional_string(labels, "threshold")},
               {"duration", Helpers.optional_string(labels, "duration")}
             ]),
           links:
             Helpers.compact_string_map([
               {"incident", incident_url},
               {"dashboard", dashboard_url}
             ])
         },
         {:ok, enriched} <- Catalog.enrich(attrs),
         {:ok, event} <- CanonicalEvent.build(enriched) do
      {:ok, event}
    end
  end

  defp normalize_alert(_alert, _source_origin, _decimal_org_id, _received_at),
    do: {:error, :invalid_grafana_alert}

  defp lifecycle("firing"), do: {:ok, "firing", "not_applicable"}
  defp lifecycle("resolved"), do: {:ok, "resolved", "unknown"}
  defp lifecycle(value), do: {:error, {:invalid_grafana_state, value}}

  defp ended_at("firing", _value), do: {:ok, nil}
  defp ended_at("resolved", value), do: Helpers.parse_iso8601(value)

  defp normalized_origin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        port: port,
        userinfo: nil,
        path: path,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and port in [nil, 443] and path in [nil, "", "/"] ->
        {:ok, "https://#{String.downcase(host)}"}

      _ ->
        {:error, :invalid_grafana_external_url}
    end
  end

  defp normalized_origin(_url), do: {:error, :invalid_grafana_external_url}

  defp decimal_org_id(value) when is_integer(value) and value >= 0,
    do: {:ok, Integer.to_string(value)}

  defp decimal_org_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 ->
        if Integer.to_string(integer) == value,
          do: {:ok, value},
          else: {:error, :invalid_grafana_org_id}

      _ ->
        {:error, :invalid_grafana_org_id}
    end
  end

  defp decimal_org_id(_value), do: {:error, :invalid_grafana_org_id}

  defp same_origin_link(value, source_origin) when is_binary(value) do
    expected_host = URI.parse(source_origin).host

    case URI.parse(value) do
      %URI{scheme: "https", host: ^expected_host, port: port, userinfo: nil} = uri
      when port in [nil, 443] ->
        {:ok,
         uri
         |> Map.put(:port, nil)
         |> Map.put(:query, nil)
         |> Map.put(:fragment, nil)
         |> URI.to_string()}

      _ ->
        {:error, :invalid_grafana_link}
    end
  end

  defp same_origin_link(_value, _source_account), do: {:error, :invalid_grafana_link}

  defp optional_same_origin_link(value, _source_account) when value in [nil, ""], do: {:ok, nil}

  defp optional_same_origin_link(value, source_account),
    do: same_origin_link(value, source_account)

  defp observed_value(values) do
    Enum.find_value(["observed", "reducer", "A"], &value_as_string(values, &1))
  end

  defp value_as_string(values, key) when is_map(values) do
    case values[key] do
      value when is_binary(value) -> value
      value when is_integer(value) or is_float(value) -> to_string(value)
      _ -> nil
    end
  end

  defp value_as_string(_values, _key), do: nil
end
