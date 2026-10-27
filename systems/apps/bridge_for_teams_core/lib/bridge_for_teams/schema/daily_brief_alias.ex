defmodule BridgeForTeams.Schema.DailyBriefAlias do
  @moduledoc "A name, handle, or project term that marks a message as being about a member."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    updated_at: false,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "daily_brief_aliases" do
    field :member_id, :binary_id
    field :term, :string
    field :kind, :string
    timestamps()
  end

  def changeset(alias_row, attrs) do
    alias_row
    |> cast(attrs, [:member_id, :term, :kind])
    |> update_change(:term, &String.trim/1)
    |> validate_required([:member_id, :term, :kind])
    |> validate_length(:term, max: 128)
    |> validate_inclusion(:kind, ~w(name handle project))
    |> unique_constraint([:member_id, :term], name: :daily_brief_aliases_member_term)
  end

  @type t :: %__MODULE__{}
end
