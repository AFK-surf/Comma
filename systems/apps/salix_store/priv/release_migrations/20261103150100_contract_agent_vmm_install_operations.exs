defmodule SalixStore.Repo.Migrations.ContractAgentVMMInstallOperations do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("DROP TRIGGER agent_vmm_install_operation_retired ON agent_vmm_install_operations")
    execute("DROP FUNCTION reject_retired_agent_vmm_install_write()")
    execute("DROP TRIGGER agent_vmm_install_operation_revision ON agent_vmm_install_operations")
    execute("DROP FUNCTION bump_agent_vmm_install_operation_revision()")
    drop(table(:agent_vmm_install_operations))

    execute(
      "ALTER TABLE agent_vmm_registrations DROP CONSTRAINT agent_vmm_registration_enrollment_retired"
    )

    alter table(:agent_vmm_registrations) do
      remove(:enrollment_token_hash)
    end
  end

  def down do
    raise "single Registration contract requires forward repair"
  end
end
