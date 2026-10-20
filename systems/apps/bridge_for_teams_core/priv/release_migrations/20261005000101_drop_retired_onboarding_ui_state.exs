defmodule BridgeForTeams.Repo.Migrations.DropRetiredOnboardingUiState do
  @moduledoc """
  Retire the onboarding columns of the removed welcome modal and guided tour.
  The `member_onboarding_states` schema stopped mapping `welcome_seen_at`,
  `collapsed` and `active_step` in #2466; no runtime after that release reads
  or writes them.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:member_onboarding_states) do
      remove(:welcome_seen_at)
      remove(:collapsed)
      remove(:active_step)
    end
  end

  def down do
    alter table(:member_onboarding_states) do
      add(:welcome_seen_at, :utc_datetime_usec)
      add(:collapsed, :boolean, null: false, default: false)
      add(:active_step, :string)
    end
  end
end
