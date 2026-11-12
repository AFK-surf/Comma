defmodule SalixStore.Repo.Migrations.PreserveSlackThreadLeave do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")

    execute("""
    ALTER TABLE slack_router_thread_participations
    DROP CONSTRAINT slack_router_thread_participations_valid_status,
    ADD CONSTRAINT slack_router_thread_participations_valid_status
    CHECK (participation_status IN ('participating', 'not_participating', 'left')) NOT VALID
    """)

    # Only mark_left wrote this exact 30-day negative interval.
    execute("""
    UPDATE slack_router_thread_participations
    SET participation_status = 'left'
    WHERE participation_status = 'not_participating'
      AND expires_at = last_active_at
      AND status_expires_at = last_active_at + interval '30 days'
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout TO '5s'")

    execute("""
    UPDATE slack_router_thread_participations
    SET participation_status = 'not_participating'
    WHERE participation_status = 'left'
    """)

    execute("""
    ALTER TABLE slack_router_thread_participations
    DROP CONSTRAINT slack_router_thread_participations_valid_status,
    ADD CONSTRAINT slack_router_thread_participations_valid_status
    CHECK (participation_status IN ('participating', 'not_participating')) NOT VALID
    """)
  end
end
