defmodule SalixStore.Repo.Migrations.RetireTaskGraphs do
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    SalixIM.Release.retire_task_graphs(confirm_no_writers: true)
    :ok
  end
end
