defmodule Comma.Accounts.UserAvatar do
  @moduledoc "Metadata for one immutable user avatar object."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "comma_user_avatars" do
    field(:user_id, :string)
    field(:object_key, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:status, :string)
    field(:upload_token, :string)
    field(:upload_deadline_at, :utc_datetime_usec)
    field(:upload_session_url, :string)

    timestamps()
  end

  def changeset(avatar, attrs) do
    avatar
    |> cast(attrs, [
      :id,
      :user_id,
      :object_key,
      :content_type,
      :byte_size,
      :status,
      :upload_token,
      :upload_deadline_at,
      :upload_session_url
    ])
    |> validate_required([:id, :user_id, :object_key, :content_type, :byte_size, :status])
    |> validate_inclusion(:status, ["pending", "active", "cleanup"])
    |> validate_inclusion(:content_type, ["image/jpeg", "image/png", "image/webp"])
    |> validate_number(:byte_size,
      greater_than: 0,
      less_than_or_equal_to: Comma.ProfileAvatar.max_bytes()
    )
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:object_key)
    |> check_constraint(:status, name: :comma_user_avatars_status_check)
    |> check_constraint(:byte_size, name: :comma_user_avatars_byte_size_valid)
    |> check_constraint(:upload_token, name: :comma_user_avatars_upload_lease_valid)
  end

  def new_id do
    "avt_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
