defmodule SalixSignalProto.Crypto.Edwards25519 do
  @moduledoc """
  Twisted Edwards Curve25519 arithmetic for public data only.

  This module implements the curve parameters, point encoding, `convert_mont`
  and `u_to_y` of the XEdDSA specification
  (https://signal.org/docs/specifications/xeddsa/, sections 2 and 5) with
  plain integer arithmetic. It is **variable time**. Use it only on public
  values, such as signature verification inputs. Secret-dependent operations
  are in the libsodium NIF.

  Points are extended coordinates `{x, y, z, t}` with `x = X/Z`, `y = Y/Z` and
  `x * y = T/Z`. The curve is `-x^2 + y^2 = 1 + d x^2 y^2` over `p = 2^255 - 19`.
  """

  import Bitwise

  @p (1 <<< 255) - 19
  @q (1 <<< 252) + 27_742_317_777_372_353_535_851_937_790_883_648_493
  # d = -121665 / 121666 (mod p) and sqrt(-1) = 2^((p - 1) / 4) (mod p).
  @d Integer.mod(
       -121_665 * :binary.decode_unsigned(:crypto.mod_pow(121_666, @p - 2, @p)),
       @p
     )
  @sqrt_m1 :binary.decode_unsigned(:crypto.mod_pow(2, div(@p - 1, 4), @p))

  @typedoc "A point in extended coordinates."
  @type point :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc "The field prime p."
  def p, do: @p

  @doc "The order q of the base point."
  def q, do: @q

  @doc "The identity point I = (0, 1)."
  @spec identity() :: point()
  def identity, do: {0, 1, 1, 0}

  @doc "The base point B = convert_mont(9)."
  @spec base_point() :: point()
  def base_point do
    {:ok, point} = convert_mont(9)
    point
  end

  @doc """
  convert_mont (spec section 2.3): masks u to 255 bits, maps it to a twisted
  Edwards y-coordinate and chooses sign bit 0. Returns `:error` when the
  result is not on the curve.
  """
  @spec convert_mont(non_neg_integer()) :: {:ok, point()} | :error
  def convert_mont(u) when is_integer(u) and u >= 0 do
    from_y(u_to_y(band(u, (1 <<< 255) - 1)), 0)
  end

  @doc "The Curve25519 birational map y = (u - 1) * inv(u + 1) (mod p)."
  @spec u_to_y(integer()) :: non_neg_integer()
  def u_to_y(u), do: mod(mod(u - 1) * inv(u + 1))

  @doc """
  Returns the point with y-coordinate `y` (reduced modulo p) and x sign bit
  `sign`, or `:error` when no point has that y-coordinate. When x is 0 the
  sign bit selects nothing and the point with x = 0 is returned.
  """
  @spec from_y(non_neg_integer(), 0 | 1) :: {:ok, point()} | :error
  def from_y(y, sign) when sign in [0, 1] do
    y = mod(y)
    y2 = y * y
    # x^2 = (y^2 - 1) / (d y^2 + 1)
    case sqrt(mod(mod(y2 - 1) * inv(mod(@d * y2 + 1)))) do
      {:ok, x} ->
        x = if x != 0 and band(x, 1) != sign, do: @p - x, else: x
        {:ok, {x, y, 1, mod(x * y)}}

      :error ->
        :error
    end
  end

  @doc """
  Decodes a 32-byte point encoding (spec section 2.4): the low 255 bits are
  y, the top bit is the sign of x. Returns `:error` when the point is not on
  the curve. A y-coordinate at or above p is read modulo p.
  """
  @spec decode(binary()) :: {:ok, point()} | :error
  def decode(<<_::binary-size(32)>> = bytes) do
    value = :binary.decode_unsigned(bytes, :little)
    from_y(band(value, (1 <<< 255) - 1), value >>> 255)
  end

  def decode(bytes) when is_binary(bytes), do: :error

  @doc "Encodes a point as 32 bytes: y little-endian with the sign of x in bit 255."
  @spec encode(point()) :: <<_::256>>
  def encode({x, y, z, _t}) do
    z_inv = inv(z)
    x = mod(x * z_inv)
    y = mod(y * z_inv)
    <<y + (band(x, 1) <<< 255)::little-size(256)>>
  end

  @doc "Point addition (complete for this curve)."
  @spec add(point(), point()) :: point()
  def add({x1, y1, z1, t1}, {x2, y2, z2, t2}) do
    a = mod((y1 - x1) * (y2 - x2))
    b = mod((y1 + x1) * (y2 + x2))
    c = mod(t1 * 2 * @d * t2)
    dd = mod(z1 * 2 * z2)
    e = b - a
    f = dd - c
    g = dd + c
    h = b + a
    {mod(e * f), mod(g * h), mod(f * g), mod(e * h)}
  end

  @doc "Scalar multiplication by a non-negative integer (not reduced first)."
  @spec mul(non_neg_integer(), point()) :: point()
  def mul(0, _point), do: identity()

  def mul(scalar, point) when is_integer(scalar) and scalar > 0 do
    scalar
    |> Integer.digits(2)
    |> Enum.reduce(identity(), fn bit, acc ->
      doubled = add(acc, acc)
      if bit == 1, do: add(doubled, point), else: doubled
    end)
  end

  @doc "Returns true when the point is the identity."
  @spec identity?(point()) :: boolean()
  def identity?({x, y, z, _t}), do: mod(x) == 0 and mod(y - z) == 0

  # Field arithmetic modulo p.

  defp mod(a), do: Integer.mod(a, @p)

  # inv(0) = 0, as the spec defines it.
  defp inv(a), do: pow(mod(a), @p - 2)

  defp pow(base, exponent) do
    case mod(base) do
      0 -> 0
      b -> :crypto.mod_pow(b, exponent, @p) |> :binary.decode_unsigned()
    end
  end

  defp sqrt(a) do
    candidate = pow(a, div(@p + 3, 8))

    cond do
      mod(candidate * candidate - a) == 0 -> {:ok, candidate}
      mod(candidate * candidate + a) == 0 -> {:ok, mod(candidate * @sqrt_m1)}
      true -> :error
    end
  end
end
