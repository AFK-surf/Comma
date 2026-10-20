defmodule Comma.Repo.Migrations.WidenIMessageReceiverCursor do
  use Ecto.Migration

  # Photon stores a bounded overlap and pending burst IDs here, not one event ID.
  # Preserve the cursor and the relay's existing values when widening the column.
  def up do
    alter table(:comma_imessage_relay_cursors) do
      modify(:event_id, :text)
    end
  end

  def down do
    raise "Keep the text cursor column on application rollback. Shrinking it can lose receiver progress."
  end
end
