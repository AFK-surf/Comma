defmodule Comma.Accounts.Identity do
  @moduledoc "Stable external login identity linked to a Comma product account."

  use Ecto.Schema

  import Ecto.Changeset

  alias Comma.Accounts.{Email, User}
  alias Comma.Auth.HostedDomain

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: String.t() | nil,
          provider: String.t() | nil,
          issuer: String.t() | nil,
          subject: String.t() | nil,
          email_snapshot: String.t() | nil,
          email_verified: boolean() | nil,
          hosted_domain: String.t() | nil,
          public_key: binary() | nil,
          label: String.t() | nil,
          disabled_at: DateTime.t() | nil,
          last_authenticated_at: DateTime.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "comma_user_identities" do
    belongs_to(:user, User)
    field(:provider, :string)
    field(:issuer, :string)
    field(:subject, :string)
    field(:email_snapshot, :string)
    field(:email_verified, :boolean)
    field(:hosted_domain, :string)
    field(:public_key, :binary)
    field(:label, :string)
    field(:disabled_at, :utc_datetime_usec)
    field(:last_authenticated_at, :utc_datetime_usec)

    timestamps(inserted_at: :created_at)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :user_id,
      :provider,
      :issuer,
      :subject,
      :email_snapshot,
      :email_verified,
      :hosted_domain,
      :last_authenticated_at,
      :public_key,
      :label,
      :disabled_at
    ])
    |> update_change(:provider, &normalize_token/1)
    |> update_change(:issuer, &trim/1)
    |> update_change(:subject, &trim/1)
    |> normalize_email_snapshot()
    |> normalize_hosted_domain()
    |> validate_required([
      :user_id,
      :provider,
      :issuer,
      :subject,
      :email_snapshot,
      :email_verified,
      :last_authenticated_at
    ])
    |> validate_inclusion(:provider, ["google", "apple", "ssh"])
    |> validate_length(:issuer, min: 1, max: 500)
    |> validate_length(:subject, min: 1, max: 500)
    |> validate_length(:email_snapshot, max: 320)
    |> validate_format(:hosted_domain, HostedDomain.pattern())
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:provider, :issuer, :subject],
      name: :comma_user_identities_provider_subject_unique
    )
    |> unique_constraint([:user_id, :provider],
      name: :comma_user_identities_user_provider_unique
    )
    |> unique_constraint([:user_id, :provider], name: :comma_user_identities_apple_owner_unique)
    |> check_constraint(:provider, name: :comma_user_identities_provider_valid)
    |> check_constraint(:email_snapshot, name: :comma_user_identities_email_normalized)
    |> check_constraint(:hosted_domain, name: :comma_user_identities_hosted_domain_normalized)
  end

  defp normalize_email_snapshot(changeset) do
    case fetch_change(changeset, :email_snapshot) do
      {:ok, email} ->
        case Email.normalize(email) do
          {:ok, normalized} -> put_change(changeset, :email_snapshot, normalized)
          {:error, :invalid_email} -> add_error(changeset, :email_snapshot, "is invalid")
        end

      :error ->
        changeset
    end
  end

  defp normalize_hosted_domain(changeset) do
    update_change(changeset, :hosted_domain, &normalize_token/1)
  end

  defp normalize_token(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_token(value), do: value

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
