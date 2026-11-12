defmodule Comma.Data.LineDMLink do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:workspace_id, :string, autogenerate: false}
  schema "comma_line_dm_links" do
    field(:owner_user_id, :string)
    field(:line_user_id, :string)
    field(:line_display_name, :string)
    field(:connect_id, :string)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:workspace_id, :owner_user_id, :line_user_id, :line_display_name, :connect_id])
    |> update_change(:line_user_id, &String.trim/1)
    |> validate_required([:workspace_id, :owner_user_id, :line_user_id, :connect_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:owner_user_id)
    |> unique_constraint(:workspace_id, name: :comma_line_dm_links_pkey)
    |> unique_constraint(:line_user_id)
  end
end
