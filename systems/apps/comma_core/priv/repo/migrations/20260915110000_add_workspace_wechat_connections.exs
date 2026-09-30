defmodule Comma.Repo.Migrations.AddWorkspaceWechatConnections do
  use Ecto.Migration

  def change do
    alter table(:comma_workspaces) do
      add(:wechat_connect_id, :text)
      add(:wechat_pending_connect_id, :text)
    end
  end
end
