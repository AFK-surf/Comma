defmodule SalixStore.Repo.Migrations.TaskConversationStatus do
  @moduledoc """
  Exclusive-stage materialization of the legacy Task display projection as the
  authoritative Conversation status.

  The release controller runs this idempotent cutover at zero replicas before
  starting the candidate runtime.
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    SalixIM.Release.migrate_task_statuses(confirm_no_writers: true)
    :ok
  end
end
