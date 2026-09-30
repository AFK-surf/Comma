defmodule Comma.Data.PluginInstallAttempt do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "comma_plugin_install_attempts" do
    field(:workspace_id, :string, primary_key: true)
    field(:plugin_id, :string, primary_key: true)
    field(:generation, :integer, default: 0)
    field(:authorization_state, :string)
    field(:provider_state, :string)
    field(:operation_kind, :string)
    field(:initiator_user_id, :string)
    field(:operation_data, :map)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
