defmodule SalixStore.Repo.Migrations.CreateSlackSemanticCursors do
  use Ecto.Migration

  def change do
    create table(:cursors, prefix: "slack_semantic", primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:workspace_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true, default: "")
      add(:connect_id, :text, primary_key: true, default: "")
      add(:before_ts_us, :bigint, null: false, default: 0)
    end
  end
end
