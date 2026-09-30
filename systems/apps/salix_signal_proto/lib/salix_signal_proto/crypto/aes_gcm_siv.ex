defmodule SalixSignalProto.Crypto.AesGcmSiv do
  @moduledoc """
  AES-256-GCM-SIV (RFC 8452) with a 12-byte nonce and a 16-byte tag.

  OTP `:crypto` has no GCM-SIV on the OpenSSL 3.0 builds that CI and local
  development use, so this module builds it from AES-256 block encryption in
  `:crypto` (ECB, one call per message) and POLYVAL in plain Elixir.

  Users: group attribute blobs (CRS-09a section 9) and sealed sender v2
  (CRS-06 section 8). The ciphertext is the encrypted text followed by the
  tag, as both sections use it.

  POLYVAL runs on integers and is not constant time. Its key and inputs are
  message keys and plaintexts; callers in this application only use it for
  short messages in a server process, where the timing difference does not
  reach a remote peer. A decryption compares tags in constant time.
  """

  import Bitwise

  alias SalixSignalProto.Crypto.Hmac

  @block 16
  # POLYVAL field polynomial x^128 + x^127 + x^126 + x^121 + 1, as an integer
  # whose bit i is the coefficient of x^i.
  @poly 1 <<< 128 ||| 1 <<< 127 ||| 1 <<< 126 ||| 1 <<< 121 ||| 1
  @mask128 (1 <<< 128) - 1

  @doc "Encrypts `plaintext`; returns the ciphertext with the 16-byte tag appended."
  @spec encrypt(<<_::256>>, <<_::96>>, binary(), binary()) :: binary()
  def encrypt(<<_::binary-size(32)>> = key, <<_::binary-size(12)>> = nonce, plaintext, aad \\ "")
      when is_binary(plaintext) and is_binary(aad) do
    {auth_key, enc_key} = derive_keys(key, nonce)
    tag = tag(auth_key, enc_key, nonce, plaintext, aad)
    ctr(enc_key, tag, plaintext) <> tag
  end

  @doc """
  Decrypts `ciphertext` (encrypted text then tag). Returns `{:error, :invalid}`
  when the input is shorter than a tag or the tag does not match.
  """
  @spec decrypt(<<_::256>>, <<_::96>>, binary(), binary()) :: {:ok, binary()} | {:error, :invalid}
  def decrypt(<<_::binary-size(32)>> = key, <<_::binary-size(12)>> = nonce, ciphertext, aad \\ "")
      when is_binary(ciphertext) and is_binary(aad) do
    size = byte_size(ciphertext) - @block

    if size >= 0 do
      <<body::binary-size(^size), tag::binary-size(@block)>> = ciphertext
      {auth_key, enc_key} = derive_keys(key, nonce)
      plaintext = ctr(enc_key, tag, body)

      if Hmac.equal?(tag(auth_key, enc_key, nonce, plaintext, aad), tag),
        do: {:ok, plaintext},
        else: {:error, :invalid}
    else
      {:error, :invalid}
    end
  end

  # RFC 8452 section 4: six AES blocks of le32(i) || nonce; the first 8 bytes
  # of blocks 0-1 are the POLYVAL key, of blocks 2-5 the AES-256 key.
  defp derive_keys(key, nonce) do
    blocks = aes(key, for(i <- 0..5, into: <<>>, do: <<i::little-32, nonce::binary>>))

    halves =
      for <<half::binary-size(8), _::binary-size(8) <- blocks>>, do: half

    [a0, a1 | enc] = halves
    {a0 <> a1, IO.iodata_to_binary(enc)}
  end

  defp tag(auth_key, enc_key, nonce, plaintext, aad) do
    length_block = <<bit_size(aad)::little-64, bit_size(plaintext)::little-64>>
    input = [pad(aad), pad(plaintext), length_block]
    s = polyval(:binary.decode_unsigned(auth_key, :little), IO.iodata_to_binary(input))
    <<first::binary-size(12), rest::binary-size(4)>> = <<s::little-128>>
    <<b0::binary-size(3), last>> = rest
    masked = :crypto.exor(first, nonce) <> b0 <> <<band(last, 0x7F)>>
    aes(enc_key, masked)
  end

  # Counter mode: the counter block is the tag with its top bit set; the
  # first 32 bits count up little-endian, modulo 2^32.
  defp ctr(_enc_key, _tag, <<>>), do: <<>>

  defp ctr(enc_key, tag, text) do
    <<counter::little-32, fixed::binary-size(11), top>> = tag
    top = bor(top, 0x80)
    blocks = div(byte_size(text) + @block - 1, @block)

    counters =
      for i <- 0..(blocks - 1)//1,
          into: <<>>,
          do: <<band(counter + i, 0xFFFFFFFF)::little-32, fixed::binary, top>>

    keystream = aes(enc_key, counters)
    :crypto.exor(text, binary_part(keystream, 0, byte_size(text)))
  end

  defp aes(key, blocks), do: :crypto.crypto_one_time(:aes_256_ecb, key, blocks, true)

  defp pad(bytes) do
    case rem(byte_size(bytes), @block) do
      0 -> bytes
      r -> bytes <> <<0::size((@block - r) * 8)>>
    end
  end

  # POLYVAL(H, X_1..X_s) (RFC 8452 section 3) over little-endian 16-byte blocks.
  defp polyval(h, input) do
    for <<block::little-128 <- input>>, reduce: 0 do
      s -> dot(bxor(s, block), h)
    end
  end

  # dot(a, b) = a * b * x^-128 in GF(2^128) modulo the POLYVAL polynomial.
  defp dot(a, b) do
    product = clmul(a, b, 0, 0)
    div_x128(product, 128) |> band(@mask128)
  end

  defp clmul(_a, 0, _shift, acc), do: acc

  defp clmul(a, b, shift, acc) do
    acc = if band(b, 1) == 1, do: bxor(acc, a <<< shift), else: acc
    clmul(a, b >>> 1, shift + 1, acc)
  end

  # Divides by x^n modulo the polynomial: the polynomial has constant term 1,
  # so adding it clears bit 0 before each shift.
  defp div_x128(value, 0), do: value

  defp div_x128(value, n) do
    value = if band(value, 1) == 1, do: bxor(value, @poly), else: value
    div_x128(value >>> 1, n - 1)
  end
end
