defmodule AlertRouter.Repo.Migrations.CreateAlertRouterState do
  use Ecto.Migration

  def up do
    Oban.Migration.up()

    create table(:alert_router_incidents, primary_key: false) do
      add(:incident_key, :string, primary_key: true)
      add(:source, :string, null: false)
      add(:source_account, :string, null: false)
      add(:source_identity, {:array, :string}, null: false)
      add(:policy_identity, {:array, :string}, null: false)
      add(:source_state, :string, null: false)
      add(:state, :string, null: false)
      add(:recovery_status, :string, null: false)
      add(:environment, :string, null: false)
      add(:priority, :string, null: false)
      add(:team, :string, null: false)
      add(:service, :string, null: false)
      add(:family, :string, null: false)
      add(:region, :string)
      add(:summary, :string, null: false)
      add(:impact, :string, null: false)
      add(:latest, :string, null: false)
      add(:owner, :string)
      add(:diagnosis, :string)
      add(:mitigation, :string)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:evidence_values, :map, null: false, default: %{})
      add(:links, :map, null: false, default: %{})
      add(:route_id, :string, null: false)
      add(:route_revision, :integer, null: false, default: 1)
      add(:channel_id, :string, null: false)
      add(:desired_revision, :integer, null: false, default: 1)
      add(:delivered_revision, :integer, null: false, default: 0)
      add(:projection_digest, :binary, null: false)
      add(:slack_root_ts, :string)
      add(:delivery_state, :string, null: false, default: "pending")
      add(:delivery_attempt, :integer, null: false, default: 0)
      add(:delivery_attempt_revision, :integer)
      add(:reconcile_attempt, :integer, null: false, default: 0)
      add(:ambiguous_revision, :integer)
      add(:ambiguous_since, :utc_datetime_usec)
      add(:delivery_lease_token, :uuid)
      add(:delivery_lease_revision, :integer)
      add(:delivery_lease_expires_at, :utc_datetime_usec)
      add(:last_error_class, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:alert_router_incidents, [:state, :environment, :priority]))
    create(index(:alert_router_incidents, [:delivery_state, :updated_at]))

    create(
      constraint(:alert_router_incidents, :alert_router_incidents_state_check,
        check: "state IN ('firing', 'resolved')"
      )
    )

    create(
      constraint(:alert_router_incidents, :alert_router_incidents_recovery_status_check,
        check:
          "(state = 'firing' AND recovery_status = 'not_applicable') OR (state = 'resolved' AND recovery_status IN ('unknown', 'verified'))"
      )
    )

    create(
      constraint(:alert_router_incidents, :alert_router_incidents_revision_check,
        check:
          "desired_revision > 0 AND delivered_revision >= 0 AND delivered_revision <= desired_revision AND delivery_attempt >= 0 AND reconcile_attempt >= 0"
      )
    )

    create(
      constraint(:alert_router_incidents, :alert_router_incidents_delivery_lease_check,
        check:
          "(delivery_lease_token IS NULL AND delivery_lease_revision IS NULL AND delivery_lease_expires_at IS NULL) OR (delivery_lease_token IS NOT NULL AND delivery_lease_revision IS NOT NULL AND delivery_lease_expires_at IS NOT NULL)"
      )
    )

    create(
      constraint(:alert_router_incidents, :alert_router_incidents_delivery_state_check,
        check: "delivery_state IN ('pending', 'posting', 'posted', 'ambiguous', 'failed', 'dlq')"
      )
    )

    create table(:alert_router_events, primary_key: false) do
      add(:event_id, :string, primary_key: true)

      add(
        :incident_key,
        references(:alert_router_incidents,
          column: :incident_key,
          type: :string,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:schema_version, :integer, null: false)
      add(:source_state, :string, null: false)
      add(:state, :string, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:payload_digest, :binary, null: false)
      add(:canonical_payload, :map, null: false)
      add(:disposition, :string, null: false)
      add(:render_revision, :integer)
      add(:timeline_state, :string, null: false, default: "pending")
      add(:slack_reply_ts, :string)
      add(:delivery_attempt, :integer, null: false, default: 0)
      add(:reconcile_attempt, :integer, null: false, default: 0)
      add(:ambiguous_since, :utc_datetime_usec)
      add(:delivery_lease_token, :uuid)
      add(:delivery_lease_expires_at, :utc_datetime_usec)
      add(:last_error_class, :string)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(index(:alert_router_events, [:incident_key, :render_revision]))
    create(index(:alert_router_events, [:timeline_state, :inserted_at]))

    create(
      constraint(:alert_router_events, :alert_router_events_disposition_check,
        check: "disposition IN ('accepted', 'duplicate', 'stale')"
      )
    )

    create(
      constraint(:alert_router_events, :alert_router_events_timeline_state_check,
        check: "timeline_state IN ('pending', 'posting', 'posted', 'ambiguous', 'dlq', 'skipped')"
      )
    )

    create(
      constraint(:alert_router_events, :alert_router_events_delivery_check,
        check:
          "delivery_attempt >= 0 AND reconcile_attempt >= 0 AND ((delivery_lease_token IS NULL AND delivery_lease_expires_at IS NULL) OR (delivery_lease_token IS NOT NULL AND delivery_lease_expires_at IS NOT NULL))"
      )
    )
  end

  def down do
    drop(table(:alert_router_events))
    drop(table(:alert_router_incidents))
    Oban.Migration.down(version: 1)
  end
end
