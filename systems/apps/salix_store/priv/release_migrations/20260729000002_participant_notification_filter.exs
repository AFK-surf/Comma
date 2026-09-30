defmodule SalixStore.Repo.Migrations.ParticipantNotificationFilter do
  @moduledoc """
  Exclusive-stage replacement of participant `wake_on_message` with the
  canonical `notification_filter`.

  The release controller runs this idempotent cutover at zero replicas before
  starting the candidate runtime.
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    SalixIM.Release.migrate_participant_notification_filters(confirm_no_writers: true)
    :ok
  end
end
