defmodule BridgeForTeams.Repo.Migrations.AddOrgDefaultRouterTemplate do
  use Ecto.Migration

  # Layered default models: `default_template_id` remains the org Worker
  # default and `default_router_template_id` is the org Router default. Both
  # are published to the Salix tenant `agent_defaults` section; nil defers to
  # the platform default. Existing rows keep their Worker default unchanged.
  def change do
    alter table(:organizations) do
      add :default_router_template_id, :string
    end
  end
end
