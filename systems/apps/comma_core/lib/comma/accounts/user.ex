defmodule Comma.Accounts.User do
  @moduledoc "Comma-owned product account row."

  use Ecto.Schema

  import Ecto.Changeset

  alias Comma.Accounts.{Email, UserId}

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    inserted_at_source: :inserted_at
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          avatar_id: String.t() | nil,
          status: String.t() | nil,
          locale: String.t() | nil,
          auth_epoch: non_neg_integer(),
          kind: String.t(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "comma_users" do
    field(:email, :string, source: :normalized_email)
    field(:name, :string, source: :display_name)
    field(:avatar_id, :string)
    field(:status, :string, default: "active")
    field(:auth_epoch, :integer, default: 0)
    field(:signup_credit_eligible, :boolean, default: false)
    # Set only by Comma.GuestMode; a guest never becomes a registered User.
    field(:kind, :string, default: "registered")
    field(:guest_pow_id, :string)
    field(:guest_claim_hash, :binary, redact: true)
    field(:guest_claim_expires_at, :utc_datetime_usec)
    field(:guest_imported_into_user_id, :string)
    # The account's app language, shared by every device and server-written text.
    field(:locale, :string)

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:id, :email, :name, :status, :auth_epoch, :locale])
    |> normalize_email()
    |> validate_required([:id, :email, :status])
    |> validate_format(:id, UserId.new_pattern())
    |> validate_length(:email, max: 320)
    |> validate_length(:name, max: 200)
    |> validate_inclusion(:status, ["active", "disabled"])
    |> validate_inclusion(:locale, locales())
    |> validate_number(:auth_epoch, greater_than_or_equal_to: 0)
    |> unique_constraint(:email, name: :comma_users_normalized_email_index)
    |> check_constraint(:email, name: :comma_users_email_normalized)
    |> check_constraint(:status, name: :comma_users_status_check)
    |> check_constraint(:auth_epoch, name: :comma_users_auth_epoch_valid)
    |> check_constraint(:id, name: :comma_users_public_id_valid)
    |> check_constraint(:locale, name: :comma_users_locale_check)
    |> check_constraint(:email, name: :comma_users_kind_valid)
  end

  @doc "App languages, mirrored from `@comma/i18n` `supportedLocales`."
  def locales, do: ~w(en zh-CN)

  @spec new_id() :: String.t()
  def new_id do
    "usr_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end

  defp normalize_email(changeset) do
    case fetch_change(changeset, :email) do
      {:ok, email} ->
        case Email.normalize(email) do
          {:ok, normalized} -> put_change(changeset, :email, normalized)
          {:error, :invalid_email} -> add_error(changeset, :email, "is invalid")
        end

      :error ->
        changeset
    end
  end
end
