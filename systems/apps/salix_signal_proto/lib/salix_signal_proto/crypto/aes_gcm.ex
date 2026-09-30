defmodule SalixSignalProto.Crypto.AesGcm do
  @moduledoc """
  AES-GCM authenticated encryption through OTP `:crypto`.

  Keys are 16 or 32 bytes (AES-128 or AES-256). The nonce is 12 bytes and must
  never repeat for one key. The tag is 16 bytes.
  """

  @tag_bytes 16

  @doc "Encrypts `plaintext` and authenticates it with `aad`. Returns `{ciphertext, tag}`."
  @spec encrypt(binary(), <<_::96>>, binary(), binary()) :: {binary(), <<_::128>>}
  def encrypt(key, <<_::binary-size(12)>> = nonce, plaintext, aad)
      when is_binary(plaintext) and is_binary(aad) do
    :crypto.crypto_one_time_aead(cipher(key), key, nonce, plaintext, aad, @tag_bytes, true)
  end

  @doc "Decrypts and authenticates. Returns `{:error, :invalid}` when authentication fails."
  @spec decrypt(binary(), <<_::96>>, binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, :invalid}
  def decrypt(key, <<_::binary-size(12)>> = nonce, ciphertext, tag, aad)
      when is_binary(ciphertext) and is_binary(tag) and is_binary(aad) do
    if byte_size(tag) == @tag_bytes do
      case :crypto.crypto_one_time_aead(cipher(key), key, nonce, ciphertext, aad, tag, false) do
        :error -> {:error, :invalid}
        plaintext -> {:ok, plaintext}
      end
    else
      {:error, :invalid}
    end
  end

  defp cipher(<<_::binary-size(16)>>), do: :aes_128_gcm
  defp cipher(<<_::binary-size(32)>>), do: :aes_256_gcm
end
