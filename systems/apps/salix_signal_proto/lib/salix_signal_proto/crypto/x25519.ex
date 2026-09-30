defmodule SalixSignalProto.Crypto.X25519 do
  @moduledoc """
  X25519 Diffie-Hellman (RFC 7748) through OTP `:crypto`.

  Keys are 32-byte binaries. X25519 clamps a private key when it uses it, so
  `clamp/1` does not change any public key or shared secret. The serialized
  private key is the clamped value (CRS-03 section 3.1), so
  `generate_private_key/0` and `keypair/1` return clamped keys. Public keys are
  raw Montgomery u-coordinates; the `0x05` type byte of the wire form
  (CRS-03 section 3.2) belongs to the key codec, not to this module. The top
  bit of u is ignored, as RFC 7748 section 5 requires.
  """

  import Bitwise

  @key_bytes 32

  @type private_key :: <<_::256>>
  @type public_key :: <<_::256>>

  @doc "Returns a new random private key, clamped."
  @spec generate_private_key() :: private_key()
  def generate_private_key, do: clamp(:crypto.strong_rand_bytes(@key_bytes))

  @doc "Returns the public key `X25519(private_key, 9)`."
  @spec public_key(private_key()) :: public_key()
  def public_key(<<_::binary-size(@key_bytes)>> = private_key) do
    {public_key, _private_key} = :crypto.generate_key(:eddh, :x25519, private_key)
    public_key
  end

  @doc """
  Returns `{public_key, clamped_private_key}` for `private_key` (new and random
  by default).
  """
  @spec keypair(private_key()) :: {public_key(), private_key()}
  def keypair(private_key \\ generate_private_key()) do
    {public_key(private_key), clamp(private_key)}
  end

  @doc """
  Computes the shared secret `X25519(private_key, public_key)`.

  Returns `{:error, :invalid_public_key}` when `public_key` is not 32 bytes or
  when the result is the all-zero value, which a public key of small order
  produces (RFC 7748 section 6.1).
  """
  @spec dh(private_key(), binary()) :: {:ok, <<_::256>>} | {:error, :invalid_public_key}
  def dh(
        <<_::binary-size(@key_bytes)>> = private_key,
        <<_::binary-size(@key_bytes)>> = public_key
      ) do
    {:ok, :crypto.compute_key(:eddh, public_key, private_key, :x25519)}
  rescue
    # OpenSSL refuses to derive an all-zero shared secret.
    ErlangError -> {:error, :invalid_public_key}
  end

  def dh(<<_::binary-size(@key_bytes)>>, public_key) when is_binary(public_key),
    do: {:error, :invalid_public_key}

  @doc "Applies X25519 scalar clamping (RFC 7748 section 5) to a private key."
  @spec clamp(private_key()) :: private_key()
  def clamp(<<first, middle::binary-size(30), last>>) do
    <<band(first, 248), middle::binary, bor(band(last, 127), 64)>>
  end
end
