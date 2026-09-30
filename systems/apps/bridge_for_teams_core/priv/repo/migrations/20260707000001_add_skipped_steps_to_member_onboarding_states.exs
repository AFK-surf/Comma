defmodule BridgeForTeams.Repo.Migrations.AddSkippedStepsToMemberOnboardingStates do
  use Ecto.Migration

  def change do
    alter table(:member_onboarding_states) do
      # Steps the user chose to skip in the quick-setup checklist/tour. A
      # skipped step counts as done, so completion stays derived-from-data OR
      # explicitly waived — never a third stored "progress" state.
      add :skipped_steps, {:array, :string}, null: false, default: []
    end
  end
end
