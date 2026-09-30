defmodule SalixSignalProto.Crypto.X25519Test do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Crypto.X25519
  alias SalixSignalProto.Test.Vectors

  @vectors Vectors.load!("public/rfc7748_x25519.json")

  describe "RFC 7748 section 5.2 vectors" do
    test "X25519 function outputs, including a u-coordinate with the top bit set" do
      for %{"scalar" => k, "u" => u, "output" => out} <- @vectors["x25519"] do
        assert X25519.dh(Vectors.hex!(k), Vectors.hex!(u)) == {:ok, Vectors.hex!(out)}
      end
    end

    test "iterated X25519 after 1 and 1,000 iterations" do
      start = <<9, 0::248>>

      results =
        Enum.scan(1..1000, {start, start}, fn _, {k, u} ->
          {:ok, next} = X25519.dh(k, u)
          {next, k}
        end)

      assert results |> Enum.at(0) |> elem(0) == Vectors.hex!(@vectors["iterations"]["1"])
      assert results |> Enum.at(999) |> elem(0) == Vectors.hex!(@vectors["iterations"]["1000"])
    end
  end

  test "RFC 7748 section 6.1 Diffie-Hellman vector" do
    v = Map.new(@vectors["diffie_hellman"], fn {key, hex} -> {key, Vectors.hex!(hex)} end)

    assert X25519.public_key(v["alice_private"]) == v["alice_public"]
    assert X25519.public_key(v["bob_private"]) == v["bob_public"]
    assert X25519.dh(v["alice_private"], v["bob_public"]) == {:ok, v["shared"]}
    assert X25519.dh(v["bob_private"], v["alice_public"]) == {:ok, v["shared"]}
  end

  describe "CRS-03 section 3 vectors" do
    test "ec-key-pair.json: private keys serialize clamped; public key is 0x05 || X25519(k, 9)" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            Vectors.load!("crs/CRS-03/ec-key-pair.json")["cases"] do
        input = Vectors.hex!(inputs["private_key_input"])
        {public, private} = X25519.keypair(input)

        assert private == Vectors.hex!(outputs["private_key_serialized"])
        assert <<5>> <> public == Vectors.hex!(outputs["public_key_serialized"])
      end
    end

    test "x25519-agreement.json: shared secrets, and all-zero results rejected" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            Vectors.load!("crs/CRS-03/x25519-agreement.json")["cases"] do
        private = Vectors.hex!(inputs["private_key"])
        <<5, public::binary-size(32)>> = Vectors.hex!(inputs["their_public_key"])

        case outputs do
          %{"shared_secret" => shared} ->
            assert X25519.dh(private, public) == {:ok, Vectors.hex!(shared)}

          %{"reason" => _} ->
            assert X25519.dh(private, public) == {:error, :invalid_public_key}
        end
      end
    end
  end

  test "a small-order public key is refused instead of yielding an all-zero secret" do
    private_key = X25519.generate_private_key()

    for small_order <- [<<0::256>>, <<1::little-size(256)>>] do
      assert X25519.dh(private_key, small_order) == {:error, :invalid_public_key}
    end

    assert X25519.dh(private_key, <<9>>) == {:error, :invalid_public_key}
  end

  property "both parties derive the same secret, and clamping changes nothing" do
    check all(a <- binary(length: 32), b <- binary(length: 32), max_runs: 50) do
      {:ok, shared} = X25519.dh(a, X25519.public_key(b))
      assert X25519.dh(b, X25519.public_key(a)) == {:ok, shared}
      assert X25519.public_key(X25519.clamp(a)) == X25519.public_key(a)
      assert X25519.dh(X25519.clamp(a), X25519.public_key(b)) == {:ok, shared}
    end
  end
end
