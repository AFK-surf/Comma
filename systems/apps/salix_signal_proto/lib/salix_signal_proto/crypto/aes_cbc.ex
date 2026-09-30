defmodule SalixSignalProto.Crypto.AesCbc do
  @moduledoc """
  AES-CBC with PKCS#7 padding through OTP `:crypto`.

  Keys are 16 or 32 bytes; the IV is 16 bytes. CBC is not authenticated.
  Callers must verify a MAC over the ciphertext before they call `decrypt/3`,
  so padding errors never reach an attacker.
  """

  @block 16

  @doc "Pads `plaintext` with PKCS#7 and encrypts it."
  @spec encrypt(binary(), <<_::128>>, binary()) :: binary()
  def encrypt(key, <<_::binary-size(@block)>> = iv, plaintext) when is_binary(plaintext) do
    pad = @block - rem(byte_size(plaintext), @block)
    padded = plaintext <> :binary.copy(<<pad>>, pad)
    :crypto.crypto_one_time(cipher(key), key, iv, padded, true)
  end

  @doc """
  Decrypts and removes PKCS#7 padding. Returns `{:error, :invalid}` for a
  ciphertext that is empty, not a whole number of blocks, or badly padded.
  """
  @spec decrypt(binary(), <<_::128>>, binary()) :: {:ok, binary()} | {:error, :invalid}
  def decrypt(key, <<_::binary-size(@block)>> = iv, ciphertext) when is_binary(ciphertext) do
    size = byte_size(ciphertext)

    if size > 0 and rem(size, @block) == 0 do
      padded = :crypto.crypto_one_time(cipher(key), key, iv, ciphertext, false)
      unpad(padded)
    else
      {:error, :invalid}
    end
  end

  defp unpad(padded) do
    size = byte_size(padded)
    pad = :binary.last(padded)

    if pad in 1..@block//1 and binary_part(padded, size - pad, pad) == :binary.copy(<<pad>>, pad) do
      {:ok, binary_part(padded, 0, size - pad)}
    else
      {:error, :invalid}
    end
  end

  defp cipher(<<_::binary-size(16)>>), do: :aes_128_cbc
  defp cipher(<<_::binary-size(32)>>), do: :aes_256_cbc
end
