defmodule SalixStore.Repo.Migrations.AddScheduleRunsSessionId do
  use Ecto.Migration

  # The occurrence-authority ruling (#871 round-3 escalation, owner
  # 2026-08-15): the run claim freezes its delivery target at insert-once
  # time. The empty string is the EXPLICIT "claimed session-less" sentinel;
  # NULL marks a legacy claim from before this migration, which never froze
  # a target and is dispatched from the sweeper's definition snapshot as it
  # always was (a bounded, pre-deploy population).
  def change do
    alter table(:schedule_runs) do
      add(:session_id, :string)
    end
  end
end
