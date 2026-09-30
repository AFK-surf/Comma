defmodule SalixStore.Repo.Migrations.OwnAgentVMMInstallRevisionInPostgres do
  use Ecto.Migration

  # Model anchor: AgentVMMAdminCommandOrchestration.CompetingOwnerWrite and
  # AgentVMMAdminCommandOrchestration.UnsafeOwnerWrite.

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    CREATE FUNCTION bump_agent_vmm_install_operation_revision()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      NEW.revision := OLD.revision + 1;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER agent_vmm_install_operation_revision
    BEFORE UPDATE ON agent_vmm_install_operations
    FOR EACH ROW
    EXECUTE FUNCTION bump_agent_vmm_install_operation_revision()
    """)
  end

  def down do
    execute("DROP TRIGGER agent_vmm_install_operation_revision ON agent_vmm_install_operations")

    execute("DROP FUNCTION bump_agent_vmm_install_operation_revision()")
  end
end
