defmodule SalixStore.Repo.Migrations.OwnAgentVMMConnectionOnRegistration do
  use Ecto.Migration

  def change do
    alter table(:agent_vmm_registrations) do
      add(:current_gateway_instance_id, :text)
      add(:current_connection_epoch, :text)
      add(:connected, :boolean, null: false, default: false)
    end

    create(
      index(:compute_commands, [:status, :id],
        name: :compute_commands_in_flight_cursor_index,
        where: "status IN ('admitted', 'executing')"
      )
    )
  end
end
