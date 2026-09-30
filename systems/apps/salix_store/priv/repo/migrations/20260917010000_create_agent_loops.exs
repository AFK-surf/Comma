defmodule SalixStore.Repo.Migrations.CreateAgentLoops do
  use Ecto.Migration

  # Background Loops (docs/salix/task-dynamic-workflow.md, "Background loops").
  # One row per Loop definition owned by an Agent: the workspace path and
  # hash of its compiled eBPF object (the bytes live once, in the Agent's
  # VFS), its config, the capability grants, the notification target Session, the
  # lifecycle status and the guest checkpoint. The current incarnation
  # columns are the runtime fence: a spinfoam host call whose object does not
  # carry the row's `incarnation` is stale and is refused.
  #
  # `agent_loop_acks` records processed-event acknowledgements the guest
  # made through `loop.ack`. It is bounded by retention, not a delivery log.
  def change do
    create table(:agent_loops, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:agent_id, :text, null: false)
      add(:session_id, :text, null: false)
      add(:name, :text)
      add(:elf_sha256, :text, null: false)
      add(:elf_path, :text, null: false)
      add(:config, :map, null: false, default: %{})
      add(:capabilities, :map, null: false, default: %{})
      add(:status, :text, null: false, default: "active")
      add(:paused_by, :text)
      add(:failure, :text)
      add(:exit_code, :bigint)
      add(:checkpoint, :map)
      add(:incarnation, :bigint, null: false, default: 0)
      add(:incarnation_node, :text)
      add(:incarnation_session, :text)
      add(:object_id, :text)
      add(:notify_window_start_ms, :bigint)
      add(:notify_window_count, :integer, null: false, default: 0)
      add(:notify_limited_since_ms, :bigint)
      add(:restart_window_start_ms, :bigint)
      add(:restart_count, :integer, null: false, default: 0)
      add(:ifc, :map, null: false, default: %{})
      add(:created_at, :bigint, null: false)
      add(:updated_at, :bigint, null: false)
      add(:last_notified_at, :bigint)
    end

    create(index(:agent_loops, [:agent_id]))
    create(index(:agent_loops, [:group_id]))

    create table(:agent_loop_acks, primary_key: false) do
      add(:loop_id, :text, primary_key: true)
      add(:event_id, :text, primary_key: true)
      add(:acked_at, :bigint, null: false)
    end

    create(index(:agent_loop_acks, [:acked_at]))
  end
end
