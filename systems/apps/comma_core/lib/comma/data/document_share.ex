defmodule Comma.Data.DocumentShare do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "comma_document_shares" do
    field(:token, :string)
    field(:workspace_id, :string)
    field(:group_id, :string)
    field(:conversation_id, :string)
    field(:created_by, :string)
    field(:file_name, :string)
    field(:message_id, :string)
    field(:block_index, :integer)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end
end
