defmodule BridgeForTeams.Repo.Migrations.DropVmEnabledFromProjects do
  @moduledoc """
  Retire `projects.vm_enabled`, the Agent Swarm's Cloud VM switch. #4895
  removed the switch: a swarm's Agents use its Cloud VM while the swarm can
  have one and it is not retired (docs/architecture/DOMAIN_CONCEPTS.md,
  Group). No runtime after that release reads or writes the column; a row
  inserted before this step takes the column's default.

  Before a contract operation selects this step, the operator confirms two
  facts that the release tooling does not check: every running instance of
  the environment is on a release with #4895, and a backup of the table can
  be restored. `down` adds the column again with its default; it does not
  bring back the values.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:projects) do
      remove_if_exists(:vm_enabled)
    end
  end

  def down do
    alter table(:projects) do
      add(:vm_enabled, :boolean, null: false, default: true)
    end
  end
end
