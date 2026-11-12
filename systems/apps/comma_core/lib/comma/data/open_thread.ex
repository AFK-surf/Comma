defmodule Comma.Data.OpenThread do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "comma_open_threads" do
    field(:profile_id, :binary_id)
    field(:source_id, :string)
    field(:toolkit, :string)
    field(:thread_key, :string)
    field(:kind, :string)
    field(:status, :string)
    field(:summary, :string)
    field(:quote, :string, default: "")
    field(:counterpart, :string)
    field(:url, :string)
    field(:due_on, :date)
    field(:evidence_at, :utc_datetime_usec)
    field(:first_seen_at, :utc_datetime_usec)
    field(:changed_at, :utc_datetime_usec)
    field(:corrected_at, :utc_datetime_usec)
    field(:checked_ts, :string)
    field(:tracked_at, :utc_datetime_usec)
  end
end
