defmodule Comma.Data.IMessageDMClaimCode do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:code, :string, autogenerate: false}
  schema "comma_imessage_dm_claim_codes" do
    field(:workspace_id, :string)
    field(:owner_user_id, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:code, :workspace_id, :owner_user_id, :expires_at])
    |> validate_required([:code, :workspace_id, :owner_user_id, :expires_at])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:owner_user_id)
    |> unique_constraint(:code, name: :comma_imessage_dm_claim_codes_pkey)
    |> unique_constraint(:workspace_id)
  end
end
