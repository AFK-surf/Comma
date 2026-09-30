defmodule AlertRouter.Data.Incident do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:incident_key, :string, autogenerate: false}
  schema "alert_router_incidents" do
    field(:source, :string)
    field(:source_account, :string)
    field(:source_identity, {:array, :string})
    field(:policy_identity, {:array, :string})
    field(:source_state, :string)
    field(:state, :string)
    field(:recovery_status, :string)
    field(:environment, :string)
    field(:priority, :string)
    field(:team, :string)
    field(:service, :string)
    field(:family, :string)
    field(:region, :string)
    field(:summary, :string)
    field(:impact, :string)
    field(:latest, :string)
    field(:owner, :string)
    field(:handling_revision, :integer, default: 0)
    field(:feedback, :map, default: %{})
    field(:diagnosis, :string)
    field(:mitigation, :string)
    field(:progress, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:observed_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:evidence_values, :map, default: %{})
    field(:links, :map, default: %{})
    field(:route_id, :string)
    field(:route_revision, :integer, default: 1)
    field(:channel_id, :string)
    field(:desired_revision, :integer, default: 1)
    field(:delivered_revision, :integer, default: 0)
    field(:projection_digest, :binary)
    field(:slack_root_ts, :string)
    field(:slack_root_revision, :integer)
    field(:delivery_state, :string, default: "pending")
    field(:delivery_attempt, :integer, default: 0)
    field(:delivery_attempt_revision, :integer)
    field(:reconcile_attempt, :integer, default: 0)
    field(:ambiguous_revision, :integer)
    field(:ambiguous_since, :utc_datetime_usec)
    field(:delivery_lease_token, Ecto.UUID)
    field(:delivery_lease_revision, :integer)
    field(:delivery_lease_expires_at, :utc_datetime_usec)
    field(:last_error_class, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @event_fields [
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
    :region,
    :summary,
    :impact,
    :latest,
    :started_at,
    :ended_at,
    :observed_at,
    :last_seen_at,
    :evidence_values,
    :links,
    :route_id,
    :route_revision,
    :channel_id,
    :desired_revision,
    :projection_digest
  ]

  def create_changeset(incident, attrs) do
    incident
    |> cast(attrs, @event_fields)
    |> validate_required(@event_fields -- [:region, :ended_at])
    |> validate_inclusion(:state, ["firing", "resolved"])
    |> validate_inclusion(:recovery_status, ["not_applicable", "unknown", "verified"])
    |> validate_number(:desired_revision, greater_than: 0)
    |> check_constraint(:state, name: :alert_router_incidents_state_check)
    |> check_constraint(:recovery_status,
      name: :alert_router_incidents_recovery_status_check
    )
    |> check_constraint(:desired_revision, name: :alert_router_incidents_revision_check)
  end

  def advance_changeset(incident, attrs) do
    incident
    |> cast(
      attrs,
      @event_fields -- [:incident_key, :source, :source_account, :source_identity]
    )
    |> validate_required([
      :policy_identity,
      :source_state,
      :state,
      :recovery_status,
      :environment,
      :priority,
      :team,
      :service,
      :family,
      :summary,
      :impact,
      :latest,
      :started_at,
      :observed_at,
      :last_seen_at,
      :route_id,
      :route_revision,
      :channel_id,
      :desired_revision,
      :projection_digest
    ])
    |> validate_inclusion(:state, ["firing", "resolved"])
    |> validate_inclusion(:recovery_status, ["not_applicable", "unknown", "verified"])
    |> check_constraint(:state, name: :alert_router_incidents_state_check)
    |> check_constraint(:recovery_status,
      name: :alert_router_incidents_recovery_status_check
    )
    |> check_constraint(:desired_revision, name: :alert_router_incidents_revision_check)
  end

  def delivery_changeset(incident, attrs) do
    incident
    |> cast(attrs, [
      :delivered_revision,
      :slack_root_ts,
      :slack_root_revision,
      :delivery_state,
      :delivery_attempt,
      :delivery_attempt_revision,
      :reconcile_attempt,
      :ambiguous_revision,
      :ambiguous_since,
      :delivery_lease_token,
      :delivery_lease_revision,
      :delivery_lease_expires_at,
      :last_error_class
    ])
    |> validate_inclusion(:delivery_state, [
      "pending",
      "posting",
      "posted",
      "ambiguous",
      "failed",
      "dlq"
    ])
    |> check_constraint(:delivered_revision, name: :alert_router_incidents_revision_check)
    |> check_constraint(:delivery_attempt, name: :alert_router_incidents_revision_check)
    |> check_constraint(:delivery_lease_token, name: :alert_router_incidents_delivery_lease_check)
    |> check_constraint(:delivery_state, name: :alert_router_incidents_delivery_state_check)
  end
end
