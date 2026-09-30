defmodule Comma.Data.MemberSourceItem do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "comma_member_source_items" do
    field(:profile_id, :binary_id)
    field(:source_id, :string)
    field(:toolkit, :string)
    field(:item_key, :string)
    field(:url, :string)
    field(:app, :string, default: "")
    field(:title, :string, default: "")
    field(:excerpt, :string, default: "")
    field(:context, :map)
    field(:prompt_context, :string, default: "")
    field(:relationship, :string)
    field(:recipient, :string)
    field(:facts, :map, default: %{})
    field(:provider_ids, :map, default: %{})
    field(:fingerprint, :string)
    field(:baseline, :boolean, default: false)
    field(:attention, :map)
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:changed_at, :utc_datetime_usec)
  end
end
