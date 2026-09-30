defmodule SalixSignalProto.Attachment do
  @moduledoc """
  Attachment encryption, padding and integrity checks (CRS-10 sections 6, 7
  and 10).

  A sender pads the plaintext to a size bucket, encrypts it with
  AES-256-CBC, and appends an HMAC-SHA256:

      blob   = IV (16) || AES-256-CBC(aes_key, IV, padded) || HMAC(mac_key, IV || C) (32)
      digest = SHA-256(blob)

  The 64 attachment keys are `aes_key (32) || mac_key (32)`. The keys, the
  unpadded size and the digest travel in the attachment pointer
  (`SalixSignalProto.Attachment.Pointer`).

  A receiver checks the MAC and the digest before it decrypts, then keeps
  the first `size` bytes of the plaintext (section 6.4).
  """

  alias SalixSignalProto.Crypto.{AesCbc, Hkdf, Hmac}

  @type keys :: <<_::512>>

  @iv_bytes 16
  @mac_bytes 32
  @min_padded 541

  @doc "64 new random attachment keys (CRS-10 section 6.1)."
  @spec generate_keys() :: keys()
  def generate_keys, do: :crypto.strong_rand_bytes(64)

  @doc "A new random 16-byte IV."
  @spec generate_iv() :: <<_::128>>
  def generate_iv, do: :crypto.strong_rand_bytes(@iv_bytes)

  @doc """
  The padded plaintext size for an attachment of `size` bytes:
  `max(541, floor(1.05 ^ k))` for the smallest integer `k` with
  `1.05 ^ k >= size` (CRS-10 section 7). Computed exactly with integers.
  """
  @spec padded_size(non_neg_integer()) :: pos_integer()
  def padded_size(size) when is_integer(size) and size >= 0 do
    k = smallest_exponent(size)
    max(@min_padded, div(pow(21, k), pow(20, k)))
  end

  @doc """
  The encrypted blob size for a plaintext of `size` bytes; this is the
  `uploadLength` of the upload form request (CRS-10 section 6.3).
  """
  @spec blob_size(non_neg_integer()) :: pos_integer()
  def blob_size(size), do: @iv_bytes + (div(padded_size(size), 16) + 1) * 16 + @mac_bytes

  @doc """
  Pads and encrypts `plaintext`. Returns the blob, its SHA-256 digest and
  the unpadded size.
  """
  @spec encrypt(binary(), keys(), <<_::128>>) ::
          %{blob: binary(), digest: <<_::256>>, size: non_neg_integer()}
  def encrypt(plaintext, <<aes_key::binary-size(32), mac_key::binary-size(32)>>, iv)
      when is_binary(plaintext) and byte_size(iv) == @iv_bytes do
    size = byte_size(plaintext)
    padded = plaintext <> :binary.copy(<<0>>, padded_size(size) - size)
    ciphertext = AesCbc.encrypt(aes_key, iv, padded)
    body = iv <> ciphertext
    blob = body <> Hmac.sha256(mac_key, body)
    %{blob: blob, digest: :crypto.hash(:sha256, blob), size: size}
  end

  @doc """
  Verifies and decrypts a blob (CRS-10 section 6.4).

  `digest` is the pointer's 32-byte digest. Message attachments require it;
  pass `:none` only for sticker images, which are checked with the MAC alone
  (section 10). `size` is the pointer's unpadded size.

  Errors: `:too_short` (48 bytes or fewer), `:bad_mac`, `:bad_digest`,
  `:bad_padding` (the CBC padding does not decode) and `:bad_size` (the
  plaintext is shorter than `size`).
  """
  @spec decrypt(binary(), keys(), <<_::256>> | :none, non_neg_integer()) ::
          {:ok, binary()}
          | {:error, :too_short | :bad_mac | :bad_digest | :bad_padding | :bad_size}
  def decrypt(blob, <<aes_key::binary-size(32), mac_key::binary-size(32)>>, digest, size)
      when is_binary(blob) and is_integer(size) and size >= 0 do
    total = byte_size(blob)

    with :ok <- check(total > @iv_bytes + @mac_bytes, :too_short),
         body = binary_part(blob, 0, total - @mac_bytes),
         mac = binary_part(blob, total - @mac_bytes, @mac_bytes),
         :ok <- check(Hmac.equal?(Hmac.sha256(mac_key, body), mac), :bad_mac),
         :ok <- check_digest(blob, digest),
         <<iv::binary-size(@iv_bytes), ciphertext::binary>> = body,
         {:ok, padded} <- cbc_decrypt(aes_key, iv, ciphertext),
         :ok <- check(byte_size(padded) >= size, :bad_size) do
      {:ok, binary_part(padded, 0, size)}
    end
  end

  @doc """
  The keys of a sticker image, derived from the 32-byte pack key:
  `HKDF-SHA256(pack_key, no salt, "Sticker Pack", 64)` (CRS-10 section 10).
  """
  @spec sticker_keys(<<_::256>>) :: keys()
  def sticker_keys(<<_::binary-size(32)>> = pack_key),
    do: Hkdf.derive(pack_key, "", "Sticker Pack", 64)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp check_digest(_blob, :none), do: :ok

  defp check_digest(blob, digest) when is_binary(digest),
    do: check(Hmac.equal?(:crypto.hash(:sha256, blob), digest), :bad_digest)

  defp cbc_decrypt(aes_key, iv, ciphertext) do
    case AesCbc.decrypt(aes_key, iv, ciphertext) do
      {:ok, padded} -> {:ok, padded}
      {:error, :invalid} -> {:error, :bad_padding}
    end
  end

  # The smallest k >= 0 with 21^k >= size * 20^k, that is 1.05^k >= size.
  # A floating-point estimate starts the search; exact integer comparisons
  # settle it.
  defp smallest_exponent(size) when size <= 1, do: 0

  defp smallest_exponent(size) do
    estimate = max(0, ceil(:math.log(size) / :math.log(1.05)) - 2)
    estimate |> step_up(size) |> step_down(size)
  end

  defp reaches?(k, size), do: pow(21, k) >= size * pow(20, k)

  defp step_up(k, size), do: if(reaches?(k, size), do: k, else: step_up(k + 1, size))

  defp step_down(0, _size), do: 0
  defp step_down(k, size), do: if(reaches?(k - 1, size), do: step_down(k - 1, size), else: k)

  defp pow(base, exponent), do: Integer.pow(base, exponent)
end
