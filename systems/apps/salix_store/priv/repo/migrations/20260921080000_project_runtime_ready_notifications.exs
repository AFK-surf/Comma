defmodule SalixStore.Repo.Migrations.ProjectRuntimeReadyNotifications do
  use Ecto.Migration

  def change do
    alter table(:device_runtime_locators) do
      add(:ready_until_ms, :bigint)
    end

    create(
      index(:device_runtime_locators, [:tenant_id, :group_id, :device_id],
        where: "ready_until_ms IS NOT NULL"
      )
    )

    create(
      index(:device_runtime_locators, [:group_id, :device_runtime_id],
        where: "ready_until_ms IS NOT NULL"
      )
    )

    alter table(:session_work_candidates) do
      add(:group_id, :text)
      add(:device_runtime_id, :text)
    end

    create(
      index(:session_work_candidates, [:group_id, :device_runtime_id],
        where: "runtime_kind = 'external' AND reasons @> ARRAY['runtime_wait']::text[]"
      )
    )

    create(
      index(:session_work_candidates, [:agent_id, :runtime_kind, :session_id, :candidate_token],
        name: :session_work_candidates_ready_eager_cursor_idx,
        where:
          "due_at_ms IS NULL AND (NOT reasons @> ARRAY['runtime_wait']::text[] OR NOT reasons <@ ARRAY['external_callback_tool_call','capability_deadline','wait_deadline','llm_retry','runtime_wait']::text[])"
      )
    )

    alter table(:session_work_backfill_expected_candidates) do
      add(:device_runtime_id, :text)
    end
  end
end
