defmodule SalixStore.Repo.Migrations.RemoveAgentVMMObservationMetadata do
  use Ecto.Migration

  def up do
    drop(constraint(:agent_vmm_registration_observations, :agent_vmm_observation_shape))

    alter table(:agent_vmm_registration_observations) do
      remove(:protocol_version)
      remove(:host_api_version)
      remove(:connector_release)
      remove(:supported_features)
    end

    create(
      constraint(:agent_vmm_registration_observations, :agent_vmm_observation_shape,
        check:
          "observation_sequence > 0 AND inventory_watermark >= 0 AND health_status IN ('healthy','degraded','unavailable') AND char_length(gateway_instance_id) BETWEEN 1 AND 128 AND char_length(connection_epoch) BETWEEN 1 AND 20 AND (health_message IS NULL OR char_length(health_message) <= 256)"
      )
    )
  end

  def down, do: raise("Removed Agent VMM observation metadata requires forward repair")
end
