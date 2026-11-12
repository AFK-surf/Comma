defmodule Comma.Data.OpenThreadCursor do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "comma_open_thread_cursors" do
    field(:profile_id, :binary_id)
    field(:source_id, :string)
    field(:toolkit, :string)
    field(:read_until, :string)
    field(:updated_at, :utc_datetime_usec)
  end
end
