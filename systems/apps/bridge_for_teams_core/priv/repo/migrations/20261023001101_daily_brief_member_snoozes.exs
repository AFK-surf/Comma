defmodule BridgeForTeams.Repo.Migrations.DailyBriefMemberSnoozes do
  use Ecto.Migration

  # "Tomorrow" on a shared follow-up hides it for the member who pressed it,
  # not for everyone it concerns. And each pass records when the model last
  # saw a follow-up, so a long list is shown to it in turns.
  def up do
    create table(:daily_brief_snoozes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :member_id, references(:daily_brief_members, type: :binary_id, on_delete: :delete_all),
        null: false

      add :followup_id,
          references(:daily_brief_followups, type: :binary_id, on_delete: :delete_all),
          null: false

      add :until, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:daily_brief_snoozes, [:member_id, :followup_id])
    create index(:daily_brief_snoozes, [:followup_id])

    # A snooze lasts a day; the ones still running carry over to the members
    # the follow-up concerns.
    execute """
    INSERT INTO daily_brief_snoozes (id, member_id, followup_id, until, created_at)
    SELECT gen_random_uuid(), m.member_id, f.id, f.snoozed_until, now()
    FROM daily_brief_followups f
    CROSS JOIN LATERAL (
      SELECT f.scope_member_id AS member_id
      UNION SELECT f.owner_member_id
      UNION SELECT f.waiting_on_member_id
    ) m
    WHERE f.snoozed_until > now() AND m.member_id IS NOT NULL
    ON CONFLICT DO NOTHING
    """

    alter table(:daily_brief_followups) do
      remove :snoozed_until
      add :considered_at, :utc_datetime_usec
    end

    create index(:daily_brief_followups, [:project_id, :opened_at],
             where: "scope = 'shared' AND status IN ('open', 'in_progress', 'waiting')",
             name: :daily_brief_followups_shared_open_by_age
           )

    create index(:daily_brief_followups, [:project_id, :considered_at],
             where: "scope = 'shared' AND status IN ('open', 'in_progress', 'waiting')",
             name: :daily_brief_followups_shared_open_by_turn
           )
  end

  def down do
    drop index(:daily_brief_followups, [], name: :daily_brief_followups_shared_open_by_turn)
    drop index(:daily_brief_followups, [], name: :daily_brief_followups_shared_open_by_age)

    alter table(:daily_brief_followups) do
      remove :considered_at
      add :snoozed_until, :utc_datetime_usec
    end

    drop table(:daily_brief_snoozes)
  end
end
