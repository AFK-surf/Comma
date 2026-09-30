defmodule BridgeForTeams.SourcedContext.Crypto do
  @moduledoc "Authenticated encryption for sourced-context plaintext at rest."

  @aad_prefix "comma.sourced-context.v1\0"
  @version "v1."

  @spec seal(binary(), binary()) :: {:ok, String.t()} | {:error, term()}
  def seal(plaintext, aad) when is_binary(plaintext) and is_binary(aad) do
    with {:ok, key} <- encryption_key() do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          iv,
          plaintext,
          @aad_prefix <> aad,
          16,
          true
        )

      {:ok, @version <> Base.url_encode64(iv <> tag <> ciphertext, padding: false)}
    end
  end

  def seal(_plaintext, _aad), do: {:error, :invalid_sourced_context_plaintext}

  @spec unseal(String.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def unseal(@version <> encoded, aad) when is_binary(aad) do
    with {:ok, key} <- encryption_key(),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             @aad_prefix <> aad,
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _invalid -> {:error, :invalid_sourced_context_ciphertext}
    end
  end

  def unseal(_ciphertext, _aad), do: {:error, :invalid_sourced_context_ciphertext}

  @spec available?() :: boolean()
  def available?, do: match?({:ok, _key}, encryption_key())

  defp encryption_key do
    case Application.get_env(:bridge_for_teams_core, :sourced_context_encryption_key) do
      value when is_binary(value) ->
        case Base.decode64(value) do
          {:ok, key} when byte_size(key) == 32 -> {:ok, key}
          _invalid -> {:error, :sourced_context_encryption_unavailable}
        end

      _missing ->
        {:error, :sourced_context_encryption_unavailable}
    end
  end
end
