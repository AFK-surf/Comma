defmodule SalixSignalProto.Crypto.XEdDSA do
  @moduledoc """
  XEd25519 signatures as deployed, over X25519 key pairs.

  `sign/3` and `verify/3` implement XEd25519 as deployed (CRS-03 section 5).
  It is the XEdDSA scheme of the public specification
  (https://signal.org/docs/specifications/xeddsa/, revision 1) with one
  change that affects the signature bytes: the private scalar is not negated
  to force the Edwards sign bit to 0. Instead, `A = kB` is used as computed
  and its sign bit b travels in bit 7 of byte 63 of the signature.

  No deployed protocol step uses VXEdDSA (CRS-03 section 5.4), so Comma does not
  implement it (CRS-03, Comma decision D1).

  A private key is an X25519 private key (`SalixSignalProto.Crypto.X25519`).
  Signing clamps it as X25519 does. A public key is the raw 32-byte Montgomery
  u-coordinate, without the `0x05` type byte of the wire form.

  Signing runs in the libsodium NIF in constant time. `random` is the 64-byte
  secret random input Z; the caller must pass fresh random bytes for every
  signature and never reuse them. It is an argument only so that tests can
  inject it.

  Verification uses public data only. XEd25519 verification applies the
  CRS-03 section 5.3 checks in Elixir and then checks the cofactorless
  equation with the OTP `:crypto` Ed25519 verifier against the converted
  public key. That verifier requires `s < q`, so `s` is reduced modulo q
  first; `sB` is unchanged because B has order q.
  """

  import Bitwise

  alias SalixSignalProto.Crypto.Edwards25519
  alias SalixSignalProto.Crypto.Native

  @scalar_limit 1 <<< 253
  @low_255 (1 <<< 255) - 1

  @type private_key :: <<_::256>>
  @type public_key :: <<_::256>>
  @type signature :: <<_::512>>

  @doc "Signs `message` with deployed XEd25519 (CRS-03 section 5.2)."
  @spec sign(private_key(), binary(), <<_::512>>) :: signature()
  def sign(private_key, message, random \\ :crypto.strong_rand_bytes(64))

  def sign(<<_::binary-size(32)>> = private_key, message, <<_::binary-size(64)>> = random)
      when is_binary(message) do
    case Native.xeddsa_sign(private_key, message, random) do
      # Only a zero nonce fails, with probability about 2^-252.
      :error -> raise RuntimeError, "XEd25519 signing produced a zero nonce"
      signature -> signature
    end
  end

  @doc """
  Verifies a deployed XEd25519 signature (CRS-03 section 5.3). Returns false
  for inputs of the wrong size.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(
        <<u_bytes::binary-size(32)>>,
        message,
        <<r::binary-size(32), s_bytes::binary-size(32)>>
      )
      when is_binary(message) do
    s_field = :binary.decode_unsigned(s_bytes, :little)
    sign = s_field >>> 255
    s = band(s_field, @low_255)
    # Bit 255 of u is ignored.
    u = band(:binary.decode_unsigned(u_bytes, :little), @low_255)
    p = Edwards25519.p()

    with true <- s < @scalar_limit,
         true <- rem(u + 1, p) != 0,
         y = Edwards25519.u_to_y(u),
         # RFC 8032 decoding rejects x = 0 with sign bit 1. Only y = -1
         # (u = 0 mod p) has x = 0 here.
         true <- not (y == p - 1 and sign == 1) do
      # y < p, so this is a canonical encoding. The Ed25519 verifier rejects
      # it when no point has this y-coordinate.
      a = <<y + (sign <<< 255)::little-size(256)>>
      reduced_s = <<rem(s, Edwards25519.q())::little-size(256)>>
      ed25519_verify(a, message, r <> reduced_s)
    else
      _ -> false
    end
  end

  def verify(public_key, message, signature)
      when is_binary(public_key) and is_binary(message) and is_binary(signature),
      do: false

  defp ed25519_verify(public_key, message, signature) do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  rescue
    ErlangError -> false
  end
end
