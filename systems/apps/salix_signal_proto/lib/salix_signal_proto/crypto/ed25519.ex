defmodule SalixSignalProto.Crypto.Ed25519 do
  @moduledoc """
  Ed25519 signatures (RFC 8032) through OTP `:crypto`.

  A private key is the 32-byte RFC 8032 secret seed. Signing is deterministic.
  Verification follows OpenSSL: it rejects a non-canonical `S` and checks the
  equation without cofactor multiplication.
  """

  @type private_key :: <<_::256>>
  @type public_key :: <<_::256>>
  @type signature :: <<_::512>>

  @doc "Returns a new random private key (secret seed)."
  @spec generate_private_key() :: private_key()
  def generate_private_key, do: :crypto.strong_rand_bytes(32)

  @doc "Returns the public key for a private key."
  @spec public_key(private_key()) :: public_key()
  def public_key(<<_::binary-size(32)>> = private_key) do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519, private_key)
    public_key
  end

  @doc "Signs `message`."
  @spec sign(private_key(), binary()) :: signature()
  def sign(<<_::binary-size(32)>> = private_key, message) when is_binary(message) do
    :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
  end

  @doc "Returns true when `signature` is valid for `message` under `public_key`."
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(<<_::binary-size(32)>> = public_key, message, <<_::binary-size(64)>> = signature)
      when is_binary(message) do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  rescue
    ErlangError -> false
  end

  def verify(public_key, message, signature)
      when is_binary(public_key) and is_binary(message) and is_binary(signature),
      do: false
end
