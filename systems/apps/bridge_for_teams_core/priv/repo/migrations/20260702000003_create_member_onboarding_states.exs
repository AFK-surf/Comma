defmodule BridgeForTeams.Repo.Migrations.CreateMemberOnboardingStates do
  use Ecto.Migration

  def change do
    create table(:member_onboarding_states, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # UI state for the "quick setup" onboarding flow. Step completion is
      # derived from real data (projects / OAuth apps / connections), except
      # `connected_at` which caches the first observed account connection so we
      # never have to scan Salix groups to answer "has this user connected?".
      add :welcome_seen_at, :utc_datetime_usec
      add :dismissed_at, :utc_datetime_usec
      add :celebrated_at, :utc_datetime_usec
      add :connected_at, :utc_datetime_usec
      add :oauth_reminded_at, :utc_datetime_usec
      add :collapsed, :boolean, null: false, default: false
      add :active_step, :string

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:member_onboarding_states, [:org_id, :user_id])
  end
end
