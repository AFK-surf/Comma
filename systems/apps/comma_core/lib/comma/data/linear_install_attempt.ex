defmodule Comma.Data.LinearInstallAttempt do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(link install)

  @primary_key {:state_hash, :string, autogenerate: false}
  schema "comma_linear_install_attempts" do
    field(:workspace_id, :string)
    field(:owner_user_id, :string)
    field(:pkce_verifier, :string)
    field(:environment, :string)
    # `link` authorizes the person (actor=user) to learn their Linear user;
    # `install` then installs Comma into their organization (actor=app) when
    # no Workspace has, carrying the linked user from the link step.
    field(:kind, :string, default: "link")
    field(:linear_organization_id, :string)
    field(:linear_user_id, :string)
    field(:linear_user_name, :string)
    field(:linear_user_email, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)

    timestamps(
      type: :utc_datetime_usec,
      updated_at: false,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :state_hash,
      :workspace_id,
      :owner_user_id,
      :pkce_verifier,
      :environment,
      :kind,
      :linear_organization_id,
      :linear_user_id,
      :linear_user_name,
      :linear_user_email,
      :expires_at
    ])
    |> validate_required([
      :state_hash,
      :workspace_id,
      :owner_user_id,
      :pkce_verifier,
      :kind,
      :expires_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:owner_user_id)
    |> unique_constraint(:state_hash, name: :comma_linear_install_attempts_pkey)
    |> unique_constraint(:workspace_id)
  end
end
