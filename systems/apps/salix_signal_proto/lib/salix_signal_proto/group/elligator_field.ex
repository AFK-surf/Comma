defmodule SalixSignalProto.Group.Elligator.Field do
  @moduledoc false
  # Variable-time arithmetic modulo p = 2^255 - 19 on integers, and the RFC
  # 9496 helpers SQRT_RATIO_M1, IS_NEGATIVE and CT_ABS (here not constant
  # time).

  import Bitwise

  @p (1 <<< 255) - 19
  @sqrt_m1 (fn ->
              root = :crypto.mod_pow(2, div(@p - 1, 4), @p) |> :binary.decode_unsigned()
              if band(root, 1) == 1, do: @p - root, else: root
            end).()

  def p, do: @p
  def mod(x), do: Integer.mod(x, @p)
  def inv(x), do: pow(x, @p - 2)
  def pow(x, e), do: :crypto.mod_pow(mod(x), e, @p) |> :binary.decode_unsigned()
  def negative?(x), do: band(mod(x), 1) == 1
  def abs_value(x), do: if(negative?(x), do: mod(-x), else: mod(x))
  def d, do: mod(-121_665 * inv(121_666))
  def sqrt_m1, do: @sqrt_m1

  # RFC 9496 section 4.2 SQRT_RATIO_M1(u, v) -> {was_square, r}.
  def sqrt_ratio_m1(u, v) do
    i = @sqrt_m1
    v3 = mod(v * v * v)
    v7 = mod(v3 * v3 * v)
    r = mod(u * v3 * pow(mod(u * v7), div(@p - 5, 8)))
    check = mod(v * r * r)
    correct = check == mod(u)
    flipped = check == mod(-u)
    flipped_i = check == mod(-u * i)
    r = if flipped or flipped_i, do: mod(i * r), else: r
    {correct or flipped, abs_value(r)}
  end

  # The second output of SQRT_RATIO_M1(1, x).
  def invsqrt(x), do: elem(sqrt_ratio_m1(1, x), 1)
end
