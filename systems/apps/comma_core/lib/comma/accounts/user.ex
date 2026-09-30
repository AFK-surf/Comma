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
          auth_epoch: non_neg_integer(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "comma_users" do
    field(:email, :string, source: :normalized_email)
    field(:name, :string, source: :display_name)
    field(:avatar_id, :string)
    field(:status, :string, default: "active")
    field(:auth_epoch, :integer, default: 0)

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:id, :email, :name, :status, :auth_epoch])
    |> normalize_email()
    |> validate_required([:id, :email, :status])
    |> validate_format(:id, UserId.new_pattern())
    |> validate_length(:email, max: 320)
    |> validate_length(:name, max: 200)
    |> validate_inclusion(:status, ["active", "disabled"])
    |> validate_number(:auth_epoch, greater_than_or_equal_to: 0)
    |> unique_constraint(:email, name: :comma_users_normalized_email_index)
    |> check_constraint(:email, name: :comma_users_email_normalized)
    |> check_constraint(:status, name: :comma_users_status_check)
    |> check_constraint(:auth_epoch, name: :comma_users_auth_epoch_valid)
    |> check_constraint(:id, name: :comma_users_public_id_valid)
  end

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
