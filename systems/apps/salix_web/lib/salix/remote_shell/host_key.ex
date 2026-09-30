defmodule Salix.RemoteShell.HostKey do
  @moduledoc """
  Pin SSH identity learned at registration over the authenticated CP gateway.
  No ambient known_hosts file, private key, password, or interactive fallback.
  """
  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(key, _hosts, _port, _algorithm, options) do
    opts = Keyword.fetch!(options, :key_cb_private)

    case Keyword.fetch!(opts, :expected) do
      :learn ->
        send(Keyword.fetch!(opts, :owner), {Keyword.fetch!(opts, :ref), key})
        true

      expected ->
        key == expected
    end
  end

  @impl true
  def user_key(_algorithm, _options), do: {:error, :no_private_key}

  @impl true
  def add_host_key(_hosts, _port, _key, _options), do: {:error, :not_pinned}
end
