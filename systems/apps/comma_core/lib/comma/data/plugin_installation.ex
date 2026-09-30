defmodule Comma.Data.PluginInstallation do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "comma_plugin_installations" do
    field(:workspace_id, :string, primary_key: true)
    field(:plugin_id, :string, primary_key: true)
    field(:connected_observed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
