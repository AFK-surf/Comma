defmodule CommaSSH.KeyCallback do
  @moduledoc "OTP verifies signatures. This adapter hands off only the successful connection's key."
  @behaviour :ssh_server_key_api
  @impl true
  def host_key(:"ssh-ed25519", options), do: {:ok, options[:key_cb_private][:host_key]}
  def host_key(_, _), do: {:error, :unsupported}
  @impl true
  def is_auth_key(key, ~c"comma", _options) do
    blob = :ssh_message.ssh2_pubkey_encode(key)

    if byte_size(blob) <= 16_384 do
      # Both OTP callbacks run in the connection process. Probes may overwrite
      # this value; the final signed request overwrites it again before success.
      Process.put({__MODULE__, :candidate}, blob)
      true
    else
      false
    end
  end

  def is_auth_key(_, _, _), do: false

  def connected(~c"comma", peer, ~c"publickey") do
    case Process.delete({__MODULE__, :candidate}) do
      blob when is_binary(blob) -> CommaSSH.Connections.authenticated(blob, peer)
      _ -> exit(:missing_authenticated_key)
    end
  end

  def connected(_, _, _), do: exit(:unsupported_authentication)
end
