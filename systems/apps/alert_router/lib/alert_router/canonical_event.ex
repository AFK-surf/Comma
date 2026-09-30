defmodule AlertRouter.CanonicalEvent do
  @moduledoc """
  Versioned, source-neutral alert lifecycle event accepted by the router.

  Only fields in this struct may cross the source adapter boundary. Raw source
  summaries, annotations, labels, queries, tenant data, and credentials never
  enter the durable/rendered payload. Reviewed adapters may admit only the
  bounded operational references and stable error class named in the evidence
  allowlist.
  """

  @enforce_keys [
    :schema_version,
    :event_id,
    :incident_key,
    :source,
    :source_account,
    :source_identity,
    :policy_identity,
    :source_state,
    :state,
    :recovery_status,
    :environment,
    :priority,
    :team,
    :service,
    :family,
    :started_at,
    :observed_at,
    :evidence_values,
    :links,
    :summary,
    :impact,
    :latest
  ]
  defstruct @enforce_keys ++ [:ended_at, :region]

  @sources ~w(gcp_monitoring grafana github_actions posthog salix_runtime)
  @states ~w(firing resolved)
  @recovery_statuses ~w(not_applicable unknown verified)
  @environments ~w(staging production)
  @priorities ~w(P0 P1 P2 P3)
  @evidence_keys ~w(
    observed
    threshold
    duration
    delta
    sample_count
    cluster
    tenant
    agent_group
    agent
    session
    trigger_error
    execution
    dispatch
  )
  @operational_reference_keys ~w(cluster tenant agent_group agent session execution dispatch)
  @link_keys ~w(incident dashboard runbook)
  @string_limits %{
    event_id: 255,
    incident_key: 255,
    source: 32,
    source_account: 255,
    source_state: 64,
    state: 16,
    environment: 32,
    priority: 8,
    team: 64,
    service: 64,
    family: 64,
    summary: 100,
    impact: 240,
    latest: 240
  }
  @optional_string_limits %{region: 64}

  @type t :: %__MODULE__{}

  @projection_fields [
    :state,
    :recovery_status,
    :environment,
    :priority,
    :team,
    :service,
    :family,
    :region,
    :summary,
    :impact,
    :latest,
    :evidence_values,
    :links
  ]

  @doc "Derives the canonical generation/event hashes before validating the event."
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(attrs) when is_map(attrs) do
    attrs = atomize_known(attrs)

    with {:ok, source_identity} <- fetch_identity(attrs, :source_identity),
         {:ok, observed_at} <- fetch_datetime(attrs, :observed_at) do
      attrs
      |> Map.put(:incident_key, incident_key(source_identity))
      |> Map.put(:event_id, event_id(attrs, observed_at))
      |> new()
    end
  end

  def build(_attrs), do: {:error, :canonical_event_must_be_a_map}

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs = atomize_known(attrs)

    with :ok <- require_fields(attrs, @enforce_keys),
         :ok <- equal(attrs.schema_version, 1, :schema_version),
         :ok <- one_of(attrs.source, @sources, :source),
         :ok <- one_of(attrs.state, @states, :state),
         :ok <- one_of(attrs.recovery_status, @recovery_statuses, :recovery_status),
         :ok <- valid_recovery(attrs.state, attrs.recovery_status),
         :ok <- valid_identities(attrs),
         :ok <- one_of(attrs.environment, @environments, :environment),
         :ok <- one_of(attrs.priority, @priorities, :priority),
         :ok <- bounded_strings(attrs, @string_limits),
         :ok <- optional_bounded_strings(attrs, @optional_string_limits),
         :ok <- datetime(attrs.started_at, :started_at),
         :ok <- optional_datetime(attrs[:ended_at], :ended_at),
         :ok <- datetime(attrs.observed_at, :observed_at),
         :ok <- resolved_has_end(attrs),
         :ok <- exact_identity_hashes(attrs),
         :ok <-
           allowlisted_string_map(attrs.evidence_values, @evidence_keys, :evidence_values, 160),
         :ok <- stable_operational_references(attrs.evidence_values),
         :ok <- stable_error_class(attrs.evidence_values),
         :ok <- validated_links(attrs.links) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def new(_attrs), do: {:error, :canonical_event_must_be_a_map}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event), do: Map.from_struct(event)

  @spec digest(t() | map()) :: binary()
  def digest(%__MODULE__{} = event), do: event |> to_map() |> digest()

  def digest(map) when is_map(map) do
    map
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
  end

  @spec projection_digest(t() | map()) :: binary()
  def projection_digest(%__MODULE__{} = event), do: event |> to_map() |> projection_digest()

  def projection_digest(map) when is_map(map) do
    map
    |> atomize_known()
    |> Map.take(@projection_fields)
    |> digest()
  end

  @doc "Returns the stable key for one validated source incident generation tuple."
  @spec incident_key([String.t()]) :: String.t()
  def incident_key(source_identity) when is_list(source_identity) do
    "ar1_" <> hash_canonical_array(source_identity)
  end

  @doc "Returns the stable id for one canonical source transition projection."
  @spec event_id(map(), DateTime.t()) :: String.t()
  def event_id(attrs, %DateTime{} = observed_at) when is_map(attrs) do
    source_identity = Map.fetch!(attrs, :source_identity)
    source_state = Map.fetch!(attrs, :source_state)
    projection = attrs |> projection_digest() |> Base.url_encode64(padding: false)

    transition_tuple = [
      "alert-router-event.v1",
      source_identity,
      source_state,
      DateTime.to_iso8601(observed_at),
      projection
    ]

    "are1_" <> hash_canonical_array(transition_tuple)
  end

  defp atomize_known(attrs) do
    fields = MapSet.new(__struct__() |> Map.from_struct() |> Map.keys())

    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        if MapSet.member?(fields, key), do: Map.put(acc, key, value), else: acc

      {key, value}, acc when is_binary(key) ->
        case Enum.find(fields, &(Atom.to_string(&1) == key)) do
          nil -> acc
          field -> Map.put(acc, field, value)
        end
    end)
  end

  defp require_fields(attrs, keys) do
    case Enum.find(keys, &is_nil(Map.get(attrs, &1))) do
      nil -> :ok
      key -> {:error, {:missing_field, key}}
    end
  end

  defp equal(value, value, _field), do: :ok
  defp equal(_value, expected, field), do: {:error, {:invalid_field, field, expected}}

  defp one_of(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else: {:error, {:invalid_field, field, value}}
  end

  defp bounded_strings(attrs, limits) do
    case Enum.find_value(limits, &invalid_string(attrs, &1, false)) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp optional_bounded_strings(attrs, limits) do
    case Enum.find_value(limits, &invalid_string(attrs, &1, true)) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp invalid_string(attrs, {field, max_bytes}, optional?) do
    case Map.get(attrs, field) do
      nil when optional? ->
        nil

      value when is_binary(value) and byte_size(value) <= max_bytes ->
        if String.trim(value) == "", do: {:invalid_string, field}, else: nil

      value when is_binary(value) ->
        {:string_too_long, field, max_bytes}

      _value ->
        {:invalid_string, field}
    end
  end

  defp datetime(%DateTime{}, _field), do: :ok
  defp datetime(value, field), do: {:error, {:invalid_datetime, field, value}}
  defp optional_datetime(nil, _field), do: :ok
  defp optional_datetime(value, field), do: datetime(value, field)

  defp fetch_identity(attrs, field) do
    case Map.get(attrs, field) do
      value when is_list(value) -> {:ok, value}
      _value -> {:error, {:missing_field, field}}
    end
  end

  defp fetch_datetime(attrs, field) do
    case Map.get(attrs, field) do
      %DateTime{} = value -> {:ok, value}
      value -> {:error, {:invalid_datetime, field, value}}
    end
  end

  defp valid_recovery("firing", "not_applicable"), do: :ok
  defp valid_recovery("resolved", status) when status in ["unknown", "verified"], do: :ok

  defp valid_recovery(state, status),
    do: {:error, {:invalid_recovery_status, state, status}}

  defp valid_identities(%{
         source: "gcp_monitoring",
         source_account: account,
         source_identity: ["alert-router.v1", "gcp_monitoring", account, incident_id],
         policy_identity: ["gcp_monitoring", managed_by, policy_id]
       })
       when is_binary(incident_id) and is_binary(managed_by) and is_binary(policy_id) do
    bounded_identity_strings([
      "alert-router.v1",
      "gcp_monitoring",
      account,
      incident_id,
      managed_by,
      policy_id
    ])
  end

  defp valid_identities(%{
         source: "grafana",
         source_account: origin,
         source_identity: [
           "alert-router.v1",
           "grafana",
           origin,
           org_id,
           fingerprint,
           starts_at
         ],
         policy_identity: ["grafana", policy_id]
       })
       when is_binary(org_id) and is_binary(fingerprint) and is_binary(starts_at) and
              is_binary(policy_id) do
    with :ok <- bounded_identity_strings([origin, org_id, fingerprint, starts_at, policy_id]),
         true <- Regex.match?(~r/^(0|[1-9][0-9]*)$/, org_id),
         {:ok, _datetime, 0} <- DateTime.from_iso8601(starts_at),
         %URI{scheme: "https", host: host, port: port, path: nil, query: nil, fragment: nil} <-
           URI.parse(origin),
         true <- port in [nil, 443] and is_binary(host) and host == String.downcase(host) do
      :ok
    else
      _ -> {:error, {:invalid_identity, :source_identity}}
    end
  end

  defp valid_identities(%{
         source: "github_actions",
         source_account: account,
         source_identity: [
           "alert-router.v1",
           "github_actions",
           account,
           workflow_name,
           run_id,
           run_attempt
         ],
         policy_identity: ["github_actions", account, policy_id]
       })
       when is_binary(workflow_name) and is_binary(run_id) and is_binary(run_attempt) and
              is_binary(policy_id) do
    with :ok <-
           bounded_identity_strings([account, workflow_name, run_id, run_attempt, policy_id]),
         true <- Regex.match?(~r/^[1-9][0-9]*$/, run_id),
         true <- Regex.match?(~r/^[1-9][0-9]*$/, run_attempt) do
      :ok
    else
      _ -> {:error, {:invalid_identity, :source_identity}}
    end
  end

  defp valid_identities(%{
         source: "posthog",
         source_account: account,
         source_identity: ["alert-router.v1", "posthog", account, issue_id, occurred_at],
         policy_identity: ["posthog", policy]
       })
       when policy in ["comma_client_critical_issue", "comma_client_login_unavailable"] do
    with :ok <- bounded_identity_strings([account, issue_id, occurred_at]),
         {:ok, _id} <- Ecto.UUID.cast(issue_id),
         {:ok, _time, 0} <- DateTime.from_iso8601(occurred_at) do
      :ok
    else
      _ -> {:error, {:invalid_identity, :source_identity}}
    end
  end

  defp valid_identities(%{
         source: "salix_runtime",
         source_account: environment,
         source_identity: [
           "alert-router.v1",
           "salix_runtime",
           environment,
           tenant,
           agent,
           session,
           dispatch,
           execution,
           episode
         ],
         policy_identity: ["salix_runtime", "external_execution"]
       }) do
    bounded_identity_strings([environment, tenant, agent, session, dispatch, execution, episode])
  end

  defp valid_identities(_attrs), do: {:error, {:invalid_identity, :source_identity}}

  defp bounded_identity_strings(values) do
    if Enum.all?(values, fn value ->
         is_binary(value) and value != "" and byte_size(value) <= 255
       end) do
      :ok
    else
      {:error, {:invalid_identity, :identity_member}}
    end
  end

  defp exact_identity_hashes(attrs) do
    expected_incident_key = incident_key(attrs.source_identity)
    expected_event_id = event_id(attrs, attrs.observed_at)

    cond do
      attrs.incident_key != expected_incident_key ->
        {:error, {:identity_hash_mismatch, :incident_key}}

      attrs.event_id != expected_event_id ->
        {:error, {:identity_hash_mismatch, :event_id}}

      true ->
        :ok
    end
  end

  defp resolved_has_end(%{state: "resolved", ended_at: %DateTime{}}), do: :ok
  defp resolved_has_end(%{state: "resolved"}), do: {:error, {:missing_field, :ended_at}}
  defp resolved_has_end(_attrs), do: :ok

  defp allowlisted_string_map(map, allowed, field, max_bytes) when is_map(map) do
    unknown = Map.keys(map) -- allowed

    cond do
      unknown != [] ->
        {:error, {:unknown_fields, field, Enum.sort(unknown)}}

      Enum.any?(map, fn {key, value} ->
        not is_binary(key) or not is_binary(value) or byte_size(value) > max_bytes
      end) ->
        {:error, {:invalid_map_value, field}}

      true ->
        :ok
    end
  end

  defp allowlisted_string_map(_map, _allowed, field, _max_bytes),
    do: {:error, {:invalid_map, field}}

  defp stable_error_class(%{"trigger_error" => value}) do
    if byte_size(value) <= 64 and String.match?(value, ~r/^[a-z][a-z0-9_]*$/) do
      :ok
    else
      {:error, {:invalid_evidence_value, "trigger_error"}}
    end
  end

  defp stable_error_class(_evidence_values), do: :ok

  defp stable_operational_references(evidence_values) do
    case Enum.find(@operational_reference_keys, fn key ->
           case evidence_values[key] do
             nil -> false
             value -> not String.match?(value, ~r/^[A-Za-z0-9][A-Za-z0-9._:@\/-]*$/)
           end
         end) do
      nil -> :ok
      key -> {:error, {:invalid_evidence_value, key}}
    end
  end

  defp validated_links(links) do
    with :ok <- allowlisted_string_map(links, @link_keys, :links, 2_048) do
      case Enum.find(links, fn {_key, value} -> not safe_https_url?(value) end) do
        nil -> :ok
        {key, _value} -> {:error, {:invalid_url, key}}
      end
    end
  end

  defp safe_https_url?(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil}
      when is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp canonical_json(%DateTime{} = value), do: value |> DateTime.to_iso8601() |> Jason.encode!()

  defp canonical_json(map) when is_map(map) do
    encoded =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> canonical_json(value)
      end)

    "{" <> encoded <> "}"
  end

  defp canonical_json(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp hash_canonical_array(value) when is_list(value) do
    value
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
