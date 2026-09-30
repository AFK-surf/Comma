defmodule SalixSignalProto.Group.Elligator do
  @moduledoc """
  The single ristretto255 Elligator map `MAP` of RFC 9496 section 4.3.4 and
  its non-negative preimages (CRS-09a sections 1 and 8.4).

  `map/1` runs in the libsodium NIF. libsodium exposes only the one-way map
  on 64 bytes, `MAP(b[0..32]) + MAP(b[32..64])`. `MAP` of 32 zero bytes is
  the identity (the Elligator step for `t = 0` lands on a non-square and
  returns `(0, 1)`; CRS-09a section 8.4 states it for the all-zero profile
  key), so `MAP(b)` is the one-way map of `b || 0^32`.

  `preimages/1` implements the informative method of CRS-09a section 8.4 in
  plain Elixir field arithmetic. It is **variable time**. It runs only when
  Comma decrypts a group member's service ID or profile key from group state,
  which the storage service and every group member already hold in
  encrypted form. See the module notes in `SalixSignalProto.Group.Uid`.
  """

  alias SalixSignalProto.Crypto.Ristretto255
  alias SalixSignalProto.Group.Elligator.Field

  @doc "`MAP(b)`: bit 255 of `b` is ignored and the value is reduced modulo p."
  @spec map(<<_::256>>) :: Ristretto255.element()
  def map(<<_::binary-size(32)>> = bytes),
    do: Ristretto255.from_uniform_bytes(bytes <> <<0::256>>)

  @doc """
  The eight slot values of CRS-09a section 8.4 for the element `point`, in
  slot order. Each value is 32 little-endian bytes or `nil` for an empty slot.
  Returns `:error` when `point` is not a valid encoding.
  """
  @spec preimages(binary()) :: {:ok, [<<_::256>> | nil]} | :error
  def preimages(point) do
    with {:ok, {x, y, z, _t}} <- decode(point) do
      {:ok, point |> jacobi_points(x, y, z) |> Enum.flat_map(&dual/1) |> Enum.map(&slot/1)}
    end
  end

  # --- field constants (RFC 9496 section 4.1 and CRS-09a section 8.4) ---
  # Computed at compile time from their definitions.

  @d Field.d()
  @sqrt_m1 Field.sqrt_m1()
  @invsqrt_a_minus_d Field.invsqrt(Field.mod(-1 - @d))
  @c1 Field.mod(-2 * @invsqrt_a_minus_d)
  @c2 Field.mod(-2 * @sqrt_m1 * @invsqrt_a_minus_d)
  @c3 Field.mod(-Field.invsqrt(Field.mod(1 + @d)))
  @c4 elem(Field.sqrt_ratio_m1(Field.mod(@sqrt_m1 * @d), 1), 1)
  @c5 Field.mod((@d + 1) * Field.inv(Field.mod(@d - 1)))

  # --- the method of section 8.4 ---

  defp jacobi_points(_point, x, y, z) do
    i = @sqrt_m1
    z2_minus_y2 = mod(z * z - y * y)
    y2 = mod(y * y)
    gamma = Field.invsqrt(mod(y2 * y2 * x * x * z2_minus_y2))
    delta = mod(gamma * y2)
    delta_p = mod(-z2_minus_y2 * @c3 * gamma)

    s0 = mod(delta * (z - y) * x)
    s1 = mod(-delta * (z + y) * x)

    if x == 0 or y == 0 do
      [{s0, 1}, {s1, 1}, {1, @c2}, {mod(-1), @c2}]
    else
      t0 = mod(@c1 * z * delta * (z - y))
      t1 = mod(@c1 * z * delta * (z + y))
      s2 = mod(delta_p * (i * z - x) * y)
      t2 = mod(@c1 * i * z * delta_p * (i * z - x))
      s3 = mod(-delta_p * (i * z + x) * y)
      t3 = mod(@c1 * i * z * delta_p * (i * z + x))
      [{s0, t0}, {s1, t1}, {s2, t2}, {s3, t3}]
    end
  end

  defp dual({s, t}), do: [{s, t}, {mod(-s), mod(-t)}]

  defp slot({0, 1}), do: encode(@c4)
  defp slot({0, _t}), do: encode(0)

  defp slot({s, t}) do
    a = mod((t + 1) * @c5)
    s2 = mod(s * s)

    case Field.sqrt_ratio_m1(1, mod(@sqrt_m1 * (s2 * s2 - a * a))) do
      {false, _} ->
        nil

      {true, root} ->
        sigma = if negative?(s), do: -1, else: 1
        encode(Field.abs_value(mod((a + sigma * s2) * root)))
    end
  end

  # --- RFC 9496 helpers ---

  # RFC 9496 section 4.3.1 DECODE to extended coordinates (x, y, 1, t).
  defp decode(<<_::binary-size(32)>> = bytes) do
    s = :binary.decode_unsigned(bytes, :little)

    if s >= Field.p() or negative?(s) do
      :error
    else
      ss = mod(s * s)
      u1 = mod(1 - ss)
      u2 = mod(1 + ss)
      u2_sqr = mod(u2 * u2)
      v = mod(-(@d * u1 * u1) - u2_sqr)
      {was_square, invsqrt} = Field.sqrt_ratio_m1(1, mod(v * u2_sqr))
      den_x = mod(invsqrt * u2)
      den_y = mod(invsqrt * den_x * v)
      x = Field.abs_value(mod(2 * s * den_x))
      y = mod(u1 * den_y)
      t = mod(x * y)

      if was_square and not negative?(t) and y != 0, do: {:ok, {x, y, 1, t}}, else: :error
    end
  end

  defp decode(_other), do: :error

  defp negative?(x), do: Field.negative?(x)
  defp mod(x), do: Field.mod(x)
  defp encode(x), do: <<mod(x)::little-256>>
end
