defmodule SalixStore.Repo.Migrations.WorkflowRouterNotificationFilter do
  @moduledoc """
  Online compatibility marker for historical Workflow Router notification
  filters.

  The candidate runtime converges the exact legacy Router participant through
  its ConversationParticipantActor before message-delivery selection. The
  database step therefore records availability of that rolling-compatible
  behavior and performs no deployment-wide S3 scan or writer cutover.
  """

  use Ecto.Migration

  def up, do: :ok
end
