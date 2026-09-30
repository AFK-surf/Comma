defmodule SalixStore.Repo.Migrations.CreateAgentVMMRegistrationObservations do
  use Ecto.Migration

  def change do
    create table(:agent_vmm_registration_observations, primary_key: false) do
      add(
        :registration_id,
        references(:agent_vmm_registrations, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(:gateway_instance_id, :text, null: false)
      add(:connection_epoch, :text, null: false)
      add(:observation_sequence, :bigint, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:received_at, :utc_datetime_usec, null: false)
      add(:disconnected_at, :utc_datetime_usec)
      add(:protocol_version, :text, null: false)
      add(:host_api_version, :text, null: false)
      add(:connector_release, :text)
      add(:supported_features, {:array, :text}, null: false, default: [])
      add(:capacity, :map, null: false, default: %{})
      add(:health_status, :text, null: false)
      add(:health_issue, :text)
      add(:health_message, :text)
      add(:health_components, :map, null: false, default: %{})
      add(:usage, :map, null: false, default: %{})
      add(:inventory_watermark, :bigint, null: false)
      add(:inventory_count, :integer, null: false)
      add(:inventory_observed_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:agent_vmm_registration_observations, :agent_vmm_observation_shape,
        check:
          "observation_sequence > 0 AND inventory_watermark >= 0 AND inventory_count >= 0 AND health_status IN ('healthy','degraded','unavailable') AND char_length(gateway_instance_id) BETWEEN 1 AND 128 AND char_length(connection_epoch) BETWEEN 1 AND 20 AND char_length(protocol_version) BETWEEN 1 AND 32 AND char_length(host_api_version) BETWEEN 1 AND 32 AND (connector_release IS NULL OR char_length(connector_release) <= 128) AND (health_message IS NULL OR char_length(health_message) <= 256) AND cardinality(supported_features) <= 32"
      )
    )
  end
end
