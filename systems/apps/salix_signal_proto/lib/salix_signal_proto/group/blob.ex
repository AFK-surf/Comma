defmodule SalixSignalProto.Group.Blob do
  @moduledoc """
  Encrypted group attribute blobs (CRS-09a section 9): title, description,
  disappearing timer, avatar and member labels.

  The encryption of plaintext `m` with padding length `n` is
  `c ‖ nonce ‖ 0x00`, where the nonce is the 12-byte squeeze of
  `H(EncryptBlob; r)` and `c` is AES-256-GCM-SIV under the blob key of
  `be32(n) ‖ m ‖ 0^n` with empty associated data.
  """

  alias SalixSignalProto.Crypto.AesGcmSiv
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Group.Sho

  @nonce_label "Signal_ZKGroup_20200424_Random_GroupSecretParams_EncryptBlob"

  @doc """
  Encrypts `plaintext`. Deployed clients use `padding = 0`. `randomness` is
  32 bytes; it is an argument so tests can fix it.
  """
  @spec encrypt(Params.t(), binary(), non_neg_integer(), <<_::256>>) :: binary()
  def encrypt(
        %Params{blob_key: key},
        plaintext,
        padding \\ 0,
        randomness \\ :crypto.strong_rand_bytes(32)
      )
      when is_binary(plaintext) and is_integer(padding) and padding in 0..0xFFFFFFFF and
             byte_size(randomness) == 32 do
    {nonce, _state} = @nonce_label |> Sho.derive(randomness) |> Sho.squeeze(12)
    padded = <<padding::32, plaintext::binary, 0::size(padding * 8)>>
    AesGcmSiv.encrypt(key, nonce, padded) <> nonce <> <<0>>
  end

  @doc """
  Decrypts a blob. The value of the last byte is not checked (deployed
  behavior, CRS-09a section 9 and its open question 4). Returns
  `{:error, :invalid}` for a short input, a failed authentication, or a
  padding length longer than the decrypted text.
  """
  @spec decrypt(Params.t(), binary()) :: {:ok, binary()} | {:error, :invalid}
  def decrypt(%Params{blob_key: key}, blob) when is_binary(blob) and byte_size(blob) >= 29 do
    size = byte_size(blob) - 13
    <<ciphertext::binary-size(^size), nonce::binary-size(12), _last>> = blob

    with {:ok, <<padding::32, rest::binary>>} <- AesGcmSiv.decrypt(key, nonce, ciphertext),
         true <- padding <= byte_size(rest) do
      {:ok, binary_part(rest, 0, byte_size(rest) - padding)}
    else
      _ -> {:error, :invalid}
    end
  end

  def decrypt(%Params{}, _blob), do: {:error, :invalid}
end
