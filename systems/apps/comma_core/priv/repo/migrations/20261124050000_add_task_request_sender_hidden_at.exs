defmodule Comma.Repo.Migrations.AddTaskRequestSenderHiddenAt do
  use Ecto.Migration

  # When the sender hid a decided request from their own lists. The recipient's
  # Task and rate-limit accounting stay untouched.
  def change do
    alter table(:comma_task_requests) do
      add(:sender_hidden_at, :utc_datetime_usec)
    end
  end
end
