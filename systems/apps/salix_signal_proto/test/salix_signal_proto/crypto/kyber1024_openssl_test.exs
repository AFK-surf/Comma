defmodule SalixSignalProto.Crypto.Kyber1024OpensslTest do
  # Kyber1024 round 3 (CRS-03 section 6), built on OTP :crypto ML-KEM-1024,
  # checked against the CRS-03 vectors and against the plain-Elixir
  # SalixSignalProto.Crypto.Kyber1024. OpenSSL 3.5 or later is required; the
  # release image (Debian trixie) has it. Hosts with an older OpenSSL run
  # only the "unsupported" test; the test-signal-proto-trixie CI job runs the
  # rest.
  use ExUnit.Case, async: true

  import Bitwise

  alias SalixSignalProto.Crypto.Kyber1024Openssl, as: Kyber1024
  alias SalixSignalProto.Test.Vectors

  @supported Kyber1024.supported?()
  @reference SalixSignalProto.Crypto.Kyber1024

  defp shake256(data), do: :crypto.hash_xof(:shake256, data, 256)
  defp strip(<<8, rest::binary>>), do: rest

  describe "without OpenSSL ML-KEM" do
    @describetag skip: @supported && "ML-KEM is available here"

    test "every operation reports :unsupported" do
      assert Kyber1024.generate_keypair() == {:error, :unsupported}
      assert Kyber1024.encapsulate(<<0::size(1568 * 8)>>) == {:error, :unsupported}

      assert Kyber1024.decapsulate(<<0::size(3168 * 8)>>, <<0::size(1568 * 8)>>) ==
               {:error, :unsupported}
    end
  end

  describe "with OpenSSL ML-KEM" do
    @describetag skip: not @supported && "the linked OpenSSL has no ML-KEM"

    test "CRS-03 kyber1024-decapsulate.json: round-3 secrets, never the FIPS 203 ones" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            Vectors.load!("crs/CRS-03/kyber1024-decapsulate.json")["cases"] do
        dk = strip(Vectors.hex!(inputs["secret_key"]))
        ciphertext = strip(Vectors.hex!(inputs["kem_ciphertext"]))
        {:ok, secret} = Kyber1024.decapsulate(dk, ciphertext)

        assert secret == Vectors.hex!(outputs["shared_secret"])
        assert secret != Vectors.hex!(outputs["fips203_mlkem1024_decapsulation_for_contrast"])
        assert Kyber1024.encapsulation_key(dk) == {:ok, strip(Vectors.hex!(inputs["public_key"]))}
      end
    end

    test "CRS-03 kyber1024-keys-from-seed.json: keys from either key generation" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            Vectors.load!("crs/CRS-03/kyber1024-keys-from-seed.json")["cases"] do
        ek = strip(Vectors.hex!(outputs["public_key"]))
        dk = strip(Vectors.hex!(outputs["secret_key"]))
        ciphertext = strip(Vectors.hex!(outputs["oracle_ciphertext"]))

        assert Kyber1024.decapsulate(dk, ciphertext) ==
                 {:ok, Vectors.hex!(outputs["shared_secret"])},
               inputs["keygen"]

        assert Kyber1024.encapsulation_key(dk) == {:ok, ek}
        {:ok, {secret, ciphertext}} = Kyber1024.encapsulate(ek)
        assert Kyber1024.decapsulate(dk, ciphertext) == {:ok, secret}
      end
    end

    test "agrees with the plain-Elixir implementation in both directions, for both key generations" do
      for keygen <- [:fips203, :round3] do
        {ek, dk} =
          @reference.keypair_from_seed(
            :crypto.strong_rand_bytes(32),
            :crypto.strong_rand_bytes(32),
            keygen
          )

        assert Kyber1024.encapsulation_key(dk) == {:ok, ek}

        {:ok, {secret, ciphertext}} = @reference.encapsulate(ek, :crypto.strong_rand_bytes(32))
        assert Kyber1024.decapsulate(dk, ciphertext) == {:ok, secret}, "#{keygen}"

        {:ok, {secret, ciphertext}} = Kyber1024.encapsulate(ek)
        assert @reference.decapsulate(dk, ciphertext) == {:ok, secret}, "#{keygen}"

        <<first, rest::binary>> = ciphertext
        changed = <<bxor(first, 1), rest::binary>>
        assert Kyber1024.decapsulate(dk, changed) == @reference.decapsulate(dk, changed)
      end
    end

    test "sizes and an encapsulation round trip" do
      {:ok, {ek, dk}} = Kyber1024.generate_keypair()
      assert {byte_size(ek), byte_size(dk)} == {1568, 3168}

      {:ok, {secret, ciphertext}} = Kyber1024.encapsulate(ek)
      assert {byte_size(secret), byte_size(ciphertext)} == {32, 1568}
      assert Kyber1024.decapsulate(dk, ciphertext) == {:ok, secret}
      assert Kyber1024.encapsulation_key(dk) == {:ok, ek}
    end

    test "CRS-03 kyber1024-implicit-rejection.json: the rule-6 secret, not the contrast values" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            Vectors.load!("crs/CRS-03/kyber1024-implicit-rejection.json")["cases"] do
        dk = strip(Vectors.hex!(inputs["kem_secret_key"]))
        # This vector's ciphertext has no type byte.
        ciphertext = Vectors.hex!(inputs["kem_ciphertext"])
        {:ok, secret} = Kyber1024.decapsulate(dk, ciphertext)

        assert secret == Vectors.hex!(outputs["shared_secret"]), inputs["label"]

        unless outputs["re_encryption_matches"] do
          assert secret != Vectors.hex!(outputs["not_round3_text_form"])
          assert secret != Vectors.hex!(outputs["not_fips203_rejection"])
        end
      end
    end

    test "a changed ciphertext yields the deployed implicit-rejection secret KDF(J(z || c) || H(c))" do
      # CRS-03 section 6.2 rule 6.
      {:ok, {ek, dk}} = Kyber1024.generate_keypair()
      {:ok, {secret, <<first, rest::binary>>}} = Kyber1024.encapsulate(ek)
      changed = <<bxor(first, 1), rest::binary>>
      z = binary_part(dk, 3136, 32)

      expected = shake256([shake256([z, changed]), :crypto.hash(:sha3_256, changed)])
      assert Kyber1024.decapsulate(dk, changed) == {:ok, expected}
      assert expected != secret
    end

    test "CRS-03 kem-public-key-no-modulus-check.json: OpenSSL refuses what peers accept" do
      # CRS-03 section 6.2 rule 4: deployed peers encapsulate to keys whose
      # coefficients are not below q, and an implementation SHOULD NOT reject
      # them. OpenSSL runs the FIPS 203 modulus check and refuses them, so
      # this module deviates from that SHOULD; the plain-Elixir Kyber1024
      # accepts them. Honest key generation never makes such keys.
      for %{"inputs" => inputs} <-
            Vectors.load!("crs/CRS-03/kem-public-key-no-modulus-check.json")["cases"] do
        ek = strip(Vectors.hex!(inputs["kem_public_key"]))

        if inputs["label"] == "unmodified" do
          assert {:ok, {_secret, _ciphertext}} = Kyber1024.encapsulate(ek)
        else
          assert Kyber1024.encapsulate(ek) == {:error, :invalid_encapsulation_key},
                 inputs["label"]

          assert {:ok, {_secret, _ciphertext}} = @reference.encapsulate(ek)
        end
      end
    end

    test "a decapsulation key failing the FIPS 203 hash check is refused" do
      {:ok, {ek, dk}} = Kyber1024.generate_keypair()
      {:ok, {_secret, ciphertext}} = Kyber1024.encapsulate(ek)
      # dk = dk_pke (1536 bytes) || ek (1568) || H(ek) (32) || z (32).
      # Change the first byte of the embedded ek, then of H(ek).
      for offset <- [1536, 3104] do
        <<before::binary-size(^offset), byte, after_byte::binary>> = dk
        changed = <<before::binary, bxor(byte, 1), after_byte::binary>>

        assert Kyber1024.encapsulation_key(changed) == {:error, :invalid_decapsulation_key}

        assert Kyber1024.decapsulate(changed, ciphertext) ==
                 {:error, :invalid_decapsulation_key}
      end
    end

    test "wrong sizes are rejected before OpenSSL sees them" do
      {:ok, {ek, dk}} = Kyber1024.generate_keypair()
      {:ok, {_secret, ciphertext}} = Kyber1024.encapsulate(ek)

      assert Kyber1024.encapsulate(binary_part(ek, 0, 1567)) ==
               {:error, :invalid_encapsulation_key}

      assert Kyber1024.decapsulate(dk, <<8>> <> ciphertext) == {:error, :invalid_ciphertext}

      assert Kyber1024.decapsulate(binary_part(dk, 0, 3167), ciphertext) ==
               {:error, :invalid_decapsulation_key}
    end
  end
end
