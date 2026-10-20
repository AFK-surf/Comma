defmodule BridgeForTeams.Repo.Migrations.ConvertOrgTemplateModels do
  use Ecto.Migration
  @disable_ddl_transaction true

  # Each Organization's template-based model settings become model choices
  # (`BridgeForTeams.Migrations.OrgModelChoices`). It reads the Salix template
  # records and the Custom Profiles that Salix migration 20261009210001 made,
  # so the release manifest runs it after that migration.
  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case BridgeForTeams.Migrations.OrgModelChoices.run(
           repo(),
           &SalixAgent.Migrations.OrgModelChoices.choice/3
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Organization model choice migration failed: #{inspect(reason)}"
    end
  end

  def down, do: :ok
end
