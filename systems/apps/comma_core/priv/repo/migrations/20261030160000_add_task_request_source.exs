defmodule Comma.Repo.Migrations.AddTaskRequestSource do
  use Ecto.Migration

  # The chat message a request was asked in through a Comma for Teams Router:
  # that Router's Group, the provider and the message's reply coordinates.
  # When the request's Task has a result, that Router replies there with it.
  def change do
    alter table(:comma_task_requests) do
      add(:source, :map)
    end
  end
end
