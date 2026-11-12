defmodule Comma.Repo.Migrations.CreateCommaImessageGuidanceReplies do
  use Ecto.Migration

  def change do
    create table(:comma_imessage_guidance_replies, primary_key: false) do
      add(:sender_handle, :text, primary_key: true)
      add(:replied_at, :utc_datetime_usec, null: false)
    end

    create(index(:comma_imessage_guidance_replies, [:replied_at]))
  end
end
