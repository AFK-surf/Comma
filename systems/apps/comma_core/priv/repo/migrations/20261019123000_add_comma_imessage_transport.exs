defmodule Comma.Repo.Migrations.AddCommaIMessageTransport do
  use Ecto.Migration

  # Comma iMessage gets a second transport (Photon shared lines). Existing
  # rows keep the relay transport. A Photon attempt names the handle that
  # must answer it and the line it was assigned.
  def change do
    alter table(:comma_imessage_dm_links) do
      add(:transport, :string, null: false, default: "relay")
      add(:assignment_id, :string)
    end

    alter table(:comma_imessage_dm_claim_codes) do
      add(:transport, :string, null: false, default: "relay")
      add(:sender_handle, :string)
      add(:line_handle, :string)
      add(:assignment_id, :string)
    end
  end
end
