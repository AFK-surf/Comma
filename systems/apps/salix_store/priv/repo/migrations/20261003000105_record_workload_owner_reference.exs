defmodule SalixStore.Repo.Migrations.RecordWorkloadOwnerReference do
  use Ecto.Migration

  def up do
    alter(table(:compute_workloads), do: add(:owner_ref, :map))

    execute("""
    UPDATE compute_workloads w
    SET owner_ref = jsonb_build_object('kind', 'meeting', 'id', m.meeting_id, 'group_id', m.group_id)
    FROM compute_environments e, meeting_group_projections m
    WHERE w.environment_id = e.id AND w.kind = 'meeting_runtime'
      AND w.id = 'meeting_workload_' || encode(sha256(convert_to(e.tenant_id || ':' || m.meeting_id, 'UTF8')), 'hex')
    """)
  end

  def down do
    alter(table(:compute_workloads), do: remove(:owner_ref))
  end
end
