defmodule Comma.Data.DeviceSetupOffer do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "comma_device_setup_offers" do
    field(:workspace_id, :string)
    field(:salix_group_id, :string)
    field(:short_id, :string)
    field(:name, :string)
    field(:model, :string)
    field(:reporter_device_id, :string)
    field(:reporter_user_id, :string)
    field(:request_id, :string)
    field(:status, :string)
    field(:revision, :integer, default: 1)
    field(:device_id, :string)
    field(:message_id, :string)
    field(:expires_at, :utc_datetime_usec)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end
end
