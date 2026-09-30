defmodule SalixSignalProto.Session.Spqr.ErasureCode do
  @moduledoc """
  The systematic erasure code of the post-quantum ratchet (CRS-04b §5).

  Arithmetic is in GF(2^16) with the reduction polynomial
  `x^16 + x^12 + x^3 + x + 1`. A payload of L bytes (a multiple of 32) is
  read as big-endian 16-bit words; word i is the point
  `(i div 16, w_i)` of polynomial `i mod 16`. Chunk c is
  `F_0(c) || ... || F_15(c)`, each value 2 bytes big-endian, where `F_j` is
  the polynomial of degree below `n = L / 32` through the points of
  polynomial j. Chunks 0 to n - 1 are the payload itself; later chunks are
  parity. Any n chunks with distinct indices give the payload back.
  """

  import Bitwise

  @reduction 0x1100B
  @chunk_bytes 32

  @doc "The number of chunks that a payload of `length` bytes needs."
  @spec chunks_needed(pos_integer()) :: pos_integer()
  def chunks_needed(length), do: div(length, @chunk_bytes)

  @doc "Chunk `index` (0 to 65535) of `payload`."
  @spec chunk(binary(), non_neg_integer()) :: <<_::256>>
  def chunk(payload, index) do
    n = chunks_needed(byte_size(payload))

    if index < n do
      binary_part(payload, index * @chunk_bytes, @chunk_bytes)
    else
      points = for x <- 0..(n - 1), do: {x, binary_part(payload, x * @chunk_bytes, @chunk_bytes)}
      evaluate(points, index)
    end
  end

  @doc """
  Decodes a payload of `length` bytes from a map of chunk index to chunk.
  Returns `:incomplete` while fewer than `length / 32` distinct chunks are
  known.
  """
  @spec decode(%{non_neg_integer() => <<_::256>>}, pos_integer()) :: {:ok, binary()} | :incomplete
  def decode(chunks, length) do
    n = chunks_needed(length)

    if map_size(chunks) < n do
      :incomplete
    else
      points = chunks |> Enum.sort() |> Enum.take(n)
      known = Map.new(points)

      payload =
        for x <- 0..(n - 1), into: <<>> do
          Map.get_lazy(known, x, fn -> evaluate(points, x) end)
        end

      {:ok, payload}
    end
  end

  # Evaluates all 16 polynomials at `target` by Lagrange interpolation. The
  # weights depend on the x values only, so they are shared.
  defp evaluate(points, target) do
    xs = Enum.map(points, &elem(&1, 0))

    weights =
      Enum.map(xs, fn x ->
        {numerator, denominator} =
          Enum.reduce(xs, {1, 1}, fn
            ^x, acc -> acc
            other, {num, den} -> {mul(num, bxor(target, other)), mul(den, bxor(x, other))}
          end)

        mul(numerator, inverse(denominator))
      end)

    words =
      points
      |> Enum.zip(weights)
      |> Enum.map(fn {{_x, chunk}, weight} ->
        for <<word::16 <- chunk>>, do: mul(weight, word)
      end)
      |> Enum.zip_with(fn values -> Enum.reduce(values, 0, &bxor/2) end)

    for word <- words, into: <<>>, do: <<word::16>>
  end

  @doc false
  def mul(a, b), do: mul(a, b, 0)

  defp mul(_a, 0, acc), do: acc

  defp mul(a, b, acc) do
    acc = if (b &&& 1) == 1, do: bxor(acc, a), else: acc
    a = a <<< 1
    a = if (a &&& 0x10000) != 0, do: bxor(a, @reduction), else: a
    mul(a, b >>> 1, acc)
  end

  # a^(2^16 - 2) = a^-1 for a != 0.
  defp inverse(a), do: pow(a, 0xFFFE, 1)

  defp pow(_a, 0, acc), do: acc

  defp pow(a, e, acc) do
    acc = if (e &&& 1) == 1, do: mul(acc, a), else: acc
    pow(mul(a, a), e >>> 1, acc)
  end
end
