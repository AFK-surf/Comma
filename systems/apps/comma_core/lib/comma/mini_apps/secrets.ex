defmodule Comma.MiniApps.Secrets do
  @moduledoc """
  Owner-entered backend secrets of a Mini App. Comma keeps each value sealed
  on the app row so it can set it again on each new Version script; the
  value never returns to a client, the coding agent or the frontend.

  Sealing follows `SalixAgent.DeviceSecrets`: AES-256-GCM under the
  deployment credential root (`SalixStore.Crypto.derived_key/1`, purpose
  `mini-app-secret-v1`), with the app ID and name as AAD, so a value copied to
  another app or name does not decrypt. The root protects a stolen database;
  application compromise is outside this boundary.
  """

  alias SalixStore.Crypto

  @purpose "mini-app-secret-v1"
  @max_value_bytes 4_096
  @name ~r/\A[A-Z][A-Z0-9_]{0,63}\z/

  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  def valid_value?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= @max_value_bytes

  def seal(app_id, name, value) do
    with {:ok, key} <- Crypto.derived_key(@purpose) do
      iv = SystemsRuntime.Proc.random_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, aad(app_id, name), true)

      {:ok, "v1." <> Base.url_encode64(iv <> tag <> ciphertext, padding: false)}
    end
  end

  def unseal(app_id, name, "v1." <> encoded) do
    with {:ok, key} <- Crypto.derived_key(@purpose),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         value when is_binary(value) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             aad(app_id, name),
             tag,
             false
           ) do
      {:ok, value}
    else
      _ -> {:error, :secret_unavailable}
    end
  end

  def unseal(_app_id, _name, _sealed), do: {:error, :secret_unavailable}

  @doc "Every sealed secret of an app, opened: `{:ok, %{name => value}}`."
  def unseal_all(app_id, sealed) when is_map(sealed) do
    Enum.reduce_while(sealed, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case unseal(app_id, name, value) do
        {:ok, plain} -> {:cont, {:ok, Map.put(acc, name, plain)}}
        error -> {:halt, error}
      end
    end)
  end

  defp aad(app_id, name), do: "mini-app-secret-v1:" <> app_id <> ":" <> name
end

defmodule Comma.MiniApps.Viewer do
  @moduledoc """
  Pairwise viewer IDs: what an app sees of a Comma User. The ID is
  `base64url(hmac_sha256(viewer_key, user_id <> ":" <> app_id))`, cut to 22
  characters, so two apps see different IDs for one User and an app cannot
  recover the User ID. Nothing stores the mapping.
  """

  def id(user_id, app_id) when is_binary(user_id) and is_binary(app_id) do
    with {:ok, key} <- Comma.MiniApps.Config.viewer_key() do
      {:ok,
       :crypto.mac(:hmac, :sha256, key, user_id <> ":" <> app_id)
       |> Base.url_encode64(padding: false)
       |> binary_part(0, 22)}
    end
  end
end
