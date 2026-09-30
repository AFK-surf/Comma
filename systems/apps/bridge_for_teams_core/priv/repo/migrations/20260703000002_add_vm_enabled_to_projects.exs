defmodule BridgeForTeams.Repo.Migrations.AddVmEnabledToProjects do
  use Ecto.Migration

  # Whether a swarm's agents provision a managed cloud VM. Default true so
  # OAuth-backed tasks (Gmail/Calendar via env.exec.credential_env) work out of
  # the box; provisioning still no-ops safely when no VM provider is configured
  # (tenant or platform default).
  def change do
    alter table(:projects) do
      add :vm_enabled, :boolean, null: false, default: true
    end
  end
end
