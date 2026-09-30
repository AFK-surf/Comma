defmodule Comma.Data.TelegramOIDCAttempt do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:state_hash, :string, autogenerate: false}
  schema "comma_telegram_oidc_attempts" do
    field(:workspace_id, :string)
    field(:owner_user_id, :string)
    field(:nonce, :string)
    field(:pkce_verifier, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :state_hash,
      :workspace_id,
      :owner_user_id,
      :nonce,
      :pkce_verifier,
      :expires_at
    ])
    |> validate_required([
      :state_hash,
      :workspace_id,
      :owner_user_id,
      :nonce,
      :pkce_verifier,
      :expires_at
    ])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:owner_user_id)
    |> unique_constraint(:state_hash, name: :comma_telegram_oidc_attempts_pkey)
    |> unique_constraint(:workspace_id)
  end
end
