defmodule BridgeForTeams.Repo.Migrations.CreateDepartmentsAndSearchGrants do
  use Ecto.Migration

  def change do
    create table(:departments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create constraint(:departments, :departments_name_valid,
             check: "btrim(name) <> '' AND char_length(name) <= 80"
           )

    create unique_index(:departments, [:org_id, "lower(name)"],
             name: :departments_org_id_lower_name_index
           )

    create index(:departments, [:org_id, :position, :created_at])

    alter table(:projects) do
      add :department_id, references(:departments, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:projects, [:org_id, :department_id])

    create table(:search_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_kind, :string, null: false
      add :subject_id, :binary_id, null: false
      add :target_kind, :string, null: false
      add :target_id, :binary_id, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create constraint(:search_grants, :search_grants_kinds_valid,
             check:
               "subject_kind IN ('department', 'project') AND target_kind IN ('department', 'project')"
           )

    create unique_index(
             :search_grants,
             [:org_id, :subject_kind, :subject_id, :target_kind, :target_id],
             name: :search_grants_unique_rule_index
           )

    create index(:search_grants, [:org_id, :subject_kind, :subject_id])
    create index(:search_grants, [:org_id, :target_kind, :target_id])
  end
end
