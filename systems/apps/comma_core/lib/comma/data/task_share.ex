defmodule Comma.Data.TaskShare do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "comma_task_shares" do
    field(:token, :string)
    field(:workspace_id, :string)
    field(:group_id, :string)
    field(:conversation_id, :string)
    field(:created_by, :string)
    field(:through_seq, :integer)
    field(:snapshot, :map, default: %{})
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
