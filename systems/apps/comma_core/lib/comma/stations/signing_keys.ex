defmodule Comma.Stations.SigningKeys do
  @moduledoc """
  Rotation of the keys that sign member credentials, for the operator of a
  Comma deployment. Salix keeps the keys (`SalixStore.Stations.SigningKeys`);
  each change here is that module's, followed by telling connected stations,
  which learn keys only from their presence socket.

  Routine rotation is `prepublish!/1`, wait for connected stations to receive
  the pending key (`rotation_prepublish_seconds`, default one hour), then
  `activate!/1`. The first key is provisioned on first use.

  `Key` is Comma's own table from before Salix kept the keys. It is only
  read, by the copy to Salix (`Comma.Stations.SalixCopy`).
  """

  alias SalixStore.Stations.Events
  alias SalixStore.Stations.SigningKeys, as: Store

  defmodule Key do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:kid, :string, autogenerate: false}
    schema "comma_station_signing_keys" do
      field(:public_key, :binary)
      field(:private_key_ciphertext, :binary)
      field(:private_key_iv, :binary)
      field(:private_key_tag, :binary)
      field(:status, :string)
      field(:retire_after, :utc_datetime_usec)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defdelegate list(), to: Store

  @doc "Publishes a pending key to stations before it signs."
  def prepublish!(opts \\ []), do: told(Store.prepublish!(opts))

  @doc "Makes the pending key the signer, once stations have had it long enough."
  def activate!(opts \\ []) do
    opts = Keyword.put_new(opts, :prepublish_seconds, prepublish_seconds())
    told(Store.activate!(opts))
  end

  @doc "Replaces a compromised signer at once."
  def rotate_compromised!(opts \\ []), do: told(Store.rotate_compromised!(opts))

  @doc "Removes a retired key."
  def remove!(kid), do: told(Store.remove!(kid))

  defp told(result) do
    Events.keys_changed()
    result
  end

  defp prepublish_seconds do
    SystemsRuntime.get_env(:comma_core, :stations, [])[:rotation_prepublish_seconds] || 3600
  end
end
