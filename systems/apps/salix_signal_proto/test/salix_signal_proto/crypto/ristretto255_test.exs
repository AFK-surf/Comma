defmodule SalixSignalProto.Crypto.Ristretto255Test do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Test.Vectors

  @vectors Vectors.load!("public/rfc9496_ristretto255.json")
  # The group order l, little-endian.
  @order <<0xEDD3F55C1A631258D69CF7A2DEF9DE1400000000000000000000000000000010::size(256)>>

  defp scalar(n), do: <<n::little-size(256)>>

  test "RFC 9496 A.1: multiples 0 to 15 of the generator, by multiplication and addition" do
    multiples = Enum.map(@vectors["generator_multiples"], &Vectors.hex!/1)

    assert hd(multiples) == R.identity()
    assert Enum.at(multiples, 1) == R.generator()

    for {encoding, i} <- Enum.with_index(multiples) do
      assert R.mul_base(scalar(i)) == encoding, "B[#{i}] by mul_base"
      assert R.mul(scalar(i), R.generator()) == encoding, "B[#{i}] by mul"
      assert R.decode(encoding) == {:ok, encoding}
    end

    multiples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] -> assert R.add(a, R.generator()) == b end)
  end

  test "RFC 9496 A.2: invalid encodings are rejected at decode and by every operation" do
    for hex <- @vectors["invalid_encodings"] do
      bad = Vectors.hex!(hex)
      assert R.decode(bad) == :error, hex
      refute R.valid?(bad)
      assert_raise ArgumentError, fn -> R.add(bad, R.generator()) end
      assert_raise ArgumentError, fn -> R.sub(R.generator(), bad) end
      assert_raise ArgumentError, fn -> R.mul(scalar(1), bad) end
    end
  end

  test "RFC 9496 A.3: element derivation from uniform byte strings" do
    for %{"input" => input, "output" => output} <- @vectors["from_uniform_bytes"] do
      assert R.from_uniform_bytes(Vectors.hex!(input)) == Vectors.hex!(output)
    end

    same = @vectors["from_uniform_bytes_same_output"]

    for input <- same["inputs"] do
      assert R.from_uniform_bytes(Vectors.hex!(input)) == Vectors.hex!(same["output"])
    end
  end

  test "scalars must be canonical; the order itself is not" do
    assert R.decode_scalar(@order) == :error
    assert R.decode_scalar(scalar(0)) == {:ok, scalar(0)}
    assert R.decode_scalar(<<1, 2, 3>>) == :error
    assert_raise ArgumentError, fn -> R.mul_base(@order) end
    assert_raise ArgumentError, fn -> R.scalar_add(@order, scalar(1)) end

    # l reduces to zero; 2^512 - 1 reduces to a canonical scalar.
    assert R.scalar_from_wide_bytes(@order <> <<0::256>>) == scalar(0)
    assert {:ok, _} = R.decode_scalar(R.scalar_from_wide_bytes(:binary.copy(<<255>>, 64)))
  end

  test "zero has no inverse, and the identity is a valid product" do
    assert R.scalar_invert(scalar(0)) == {:error, :zero_scalar}
    assert R.mul_base(scalar(0)) == R.identity()
    assert R.mul(scalar(5), R.identity()) == R.identity()
    assert R.sub(R.generator(), R.generator()) == R.identity()
  end

  property "scalar arithmetic agrees with the group operation" do
    check all(a <- wide_scalar(), b <- wide_scalar(), max_runs: 50) do
      g = R.generator()

      assert R.mul_base(R.scalar_add(a, b)) == R.add(R.mul_base(a), R.mul_base(b))
      assert R.mul_base(R.scalar_sub(a, b)) == R.sub(R.mul_base(a), R.mul_base(b))
      assert R.mul_base(R.scalar_mul(a, b)) == R.mul(a, R.mul(b, g))
      assert R.add(R.mul_base(a), R.mul_base(R.scalar_negate(a))) == R.identity()

      if a != scalar(0) do
        {:ok, inverse} = R.scalar_invert(a)
        assert R.scalar_mul(a, inverse) == scalar(1)
        assert R.mul(inverse, R.mul(a, R.mul_base(b))) == R.mul_base(b)
      end
    end
  end

  defp wide_scalar do
    gen(all(bytes <- binary(length: 64), do: R.scalar_from_wide_bytes(bytes)))
  end
end
