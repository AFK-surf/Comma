defmodule BridgeForTeams.Repo.Migrations.AddAllDepartmentsSearchGrant do
  use Ecto.Migration

  def up do
    drop constraint(:search_grants, :search_grants_kinds_valid)

    create constraint(:search_grants, :search_grants_kinds_valid,
             check:
               "subject_kind IN ('department', 'project') AND ((target_kind IN ('department', 'project')) OR (target_kind = 'all_departments' AND target_id = org_id))"
           )
  end

  def down do
    execute "DELETE FROM search_grants WHERE target_kind = 'all_departments'"
    drop constraint(:search_grants, :search_grants_kinds_valid)

    create constraint(:search_grants, :search_grants_kinds_valid,
             check:
               "subject_kind IN ('department', 'project') AND target_kind IN ('department', 'project')"
           )
  end
end
