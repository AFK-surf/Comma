defmodule AlertRouter.Data.EventRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:event_id, :string, autogenerate: false}
  schema "alert_router_events" do
    field(:incident_key, :string)
    field(:schema_version, :integer)
    field(:source_state, :string)
    field(:state, :string)
    field(:observed_at, :utc_datetime_usec)
    field(:payload_digest, :binary)
    field(:canonical_payload, :map)
    field(:disposition, :string)
    field(:render_revision, :integer)
    field(:timeline_state, :string, default: "pending")
    field(:slack_reply_ts, :string)
    field(:delivery_attempt, :integer, default: 0)
    field(:reconcile_attempt, :integer, default: 0)
    field(:ambiguous_since, :utc_datetime_usec)
    field(:delivery_lease_token, Ecto.UUID)
    field(:delivery_lease_expires_at, :utc_datetime_usec)
    field(:last_error_class, :string)
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :incident_key,
      :schema_version,
      :source_state,
      :state,
      :observed_at,
      :payload_digest,
      :canonical_payload,
      :disposition,
      :render_revision,
      :timeline_state,
      :slack_reply_ts,
      :delivery_attempt,
      :reconcile_attempt,
      :ambiguous_since,
      :delivery_lease_token,
      :delivery_lease_expires_at,
      :last_error_class
    ])
    |> validate_required([
      :event_id,
      :incident_key,
      :schema_version,
      :source_state,
      :state,
      :observed_at,
      :payload_digest,
      :canonical_payload,
      :disposition,
      :timeline_state
    ])
    |> validate_inclusion(:disposition, ["accepted", "duplicate", "stale"])
    |> validate_inclusion(:timeline_state, [
      "pending",
      "posting",
      "posted",
      "ambiguous",
      "dlq",
      "skipped"
    ])
    |> foreign_key_constraint(:incident_key)
    |> check_constraint(:disposition, name: :alert_router_events_disposition_check)
    |> check_constraint(:timeline_state, name: :alert_router_events_timeline_state_check)
  end

  def timeline_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :timeline_state,
      :slack_reply_ts,
      :delivery_attempt,
      :reconcile_attempt,
      :ambiguous_since,
      :delivery_lease_token,
      :delivery_lease_expires_at,
      :last_error_class
    ])
    |> validate_inclusion(:timeline_state, [
      "pending",
      "posting",
      "posted",
      "ambiguous",
      "dlq",
      "skipped"
    ])
    |> check_constraint(:timeline_state, name: :alert_router_events_timeline_state_check)
    |> check_constraint(:delivery_attempt, name: :alert_router_events_delivery_check)
    |> check_constraint(:delivery_lease_token, name: :alert_router_events_delivery_check)
  end
end
