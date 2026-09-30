defmodule Comma.Data.MemberSourceState do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "comma_member_source_states" do
    field(:profile_id, :binary_id)
    field(:source_id, :string)
    field(:toolkit, :string)
    field(:app, :string, default: "")
    field(:subject, :map)
    field(:bound, :map)
    field(:failure, :map)
    field(:trigger_id, :string)
    field(:current_keys, {:array, :string}, default: [])
    field(:attempted_at, :utc_datetime_usec)
    field(:collected_at, :utc_datetime_usec)
    field(:baseline_at, :utc_datetime_usec)
  end
end
