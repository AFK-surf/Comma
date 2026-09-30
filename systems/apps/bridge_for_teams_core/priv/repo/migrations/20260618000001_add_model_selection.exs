defmodule BridgeForTeams.Repo.Migrations.AddModelSelection do
  use Ecto.Migration

  # Model selection for BridgeForTeams agents. Models are Salix template-catalog
  # entries: orgs constrain which templates their admins may pick
  # (`allowed_template_ids`, empty = no restriction) and set a default
  # (`default_template_id`, nullable). Agents reference the chosen template via
  # `template_id`; Salix resolves model + provider config live from it.
  def change do
    alter table(:organizations) do
      add :allowed_template_ids, {:array, :string}, null: false, default: []
      add :default_template_id, :string
    end

    alter table(:agents) do
      add :template_id, :string
    end
  end
end
