defmodule BridgeForTeams.Repo.Migrations.AddCreatedByUserIdToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:projects, [:org_id, :created_by_user_id])
  end
end
