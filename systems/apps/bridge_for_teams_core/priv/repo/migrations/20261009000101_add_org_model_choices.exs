defmodule BridgeForTeams.Repo.Migrations.AddOrgModelChoices do
  use Ecto.Migration

  # Org model governance stores Salix model choices (`SalixAgent.ModelChoice`
  # values) instead of template ids. `allowed_models` is the list of choices
  # that org admins can give to Agents (empty = every model). The default
  # columns hold the choice that new Routers and Workers get; nil = the
  # platform model of the role. The template columns stay unchanged and are
  # not read; a later release removes them.
  def change do
    alter table(:organizations) do
      add :allowed_models, {:array, :map}, null: false, default: []
      add :default_router_model, :map
      add :default_worker_model, :map
    end
  end
end
