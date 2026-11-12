defmodule Comma.Repo.Migrations.AddTaskRequestReportedAt do
  use Ecto.Migration

  # When the owner's Router reported what a request's sender gets. Once only.
  def change do
    alter table(:comma_task_requests) do
      add(:reported_at, :utc_datetime_usec)
    end
  end
end
