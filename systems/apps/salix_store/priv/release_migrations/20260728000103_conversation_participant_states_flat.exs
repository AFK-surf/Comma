defmodule SalixStore.Repo.Migrations.ConversationParticipantStatesFlat do
  @moduledoc """
  Exclusive-stage relocation of segmented Conversation participant state.

  Serving reads only `participant_states/<participant_id>.json`, so the release
  controller runs this idempotent cutover at zero replicas before starting the
  candidate runtime.
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    SalixIM.Release.migrate_conversation_participant_states(confirm_no_writers: true)
    :ok
  end
end
