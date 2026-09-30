defmodule SalixSignalProto.Test.XEdDSAReference do
  @moduledoc false
  # A direct, variable-time transcription of the deployed XEd25519 signing
  # definition (CRS-03 section 5.2), built on the plain-Elixir curve
  # arithmetic. Tests compare the libsodium signing path with it byte for
  # byte. Never use it with real keys.

  import Bitwise

  alias SalixSignalProto.Crypto.Edwards25519, as: Ed
  alias SalixSignalProto.Crypto.X25519

  # Deployed XEd25519 (CRS-03 section 5.2): A = kB as computed, a = k mod q,
  # the nonce hashes the clamped k, and the sign bit of A goes into bit 7 of
  # byte 63.
  def xeddsa_sign(k, message, z) do
    clamped = X25519.clamp(k)
    k = :binary.decode_unsigned(clamped, :little)
    a_bytes = Ed.encode(Ed.mul(k, Ed.base_point()))
    sign = :binary.decode_unsigned(a_bytes, :little) >>> 255
    a = Integer.mod(k, Ed.q())
    r = scalar(:crypto.hash(:sha512, [<<0xFE>>, :binary.copy(<<0xFF>>, 31), clamped, message, z]))
    r_bytes = Ed.encode(Ed.mul(r, Ed.base_point()))
    h = scalar(:crypto.hash(:sha512, [r_bytes, a_bytes, message]))
    s = Integer.mod(h * a + r, Ed.q())
    r_bytes <> <<s + (sign <<< 255)::little-size(256)>>
  end

  defp scalar(digest), do: digest |> :binary.decode_unsigned(:little) |> Integer.mod(Ed.q())
end
