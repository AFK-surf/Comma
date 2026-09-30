defmodule SalixSignalProto.Crypto.XEdDSATest do
  # Deployed XEd25519: CRS-03 section 5 (vectors in fixtures/crs/CRS-03).
  # Other checks are independent: the OpenSSL Ed25519 verifier, and a direct
  # transcription of the signing definition on the plain-Elixir curve code
  # (test/support/xeddsa_reference.ex).
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias SalixSignalProto.Crypto.{Ed25519, Edwards25519, X25519, XEdDSA}
  alias SalixSignalProto.Test.{Vectors, XEdDSAReference}

  @q Edwards25519.q()
  @p Edwards25519.p()

  defp le(n), do: <<n::little-size(256)>>
  defp un(bytes), do: :binary.decode_unsigned(bytes, :little)
  defp flip(<<first, rest::binary>>), do: <<bxor(first, 1), rest::binary>>

  describe "Edwards25519 arithmetic (public-data verifier code)" do
    test "the base point is the RFC 8032 base point" do
      assert Edwards25519.encode(Edwards25519.base_point()) ==
               Vectors.hex!("5866666666666666666666666666666666666666666666666666666666666666")
    end

    test "scalar multiplication matches OpenSSL Ed25519 key derivation (RFC 8032 section 7.1)" do
      for vector <- Vectors.load!("public/rfc8032_ed25519.json")["ed25519"] do
        <<a_bytes::binary-size(32), _::binary>> =
          :crypto.hash(:sha512, Vectors.hex!(vector["secret_key"]))

        a = a_bytes |> X25519.clamp() |> un()

        assert Edwards25519.encode(Edwards25519.mul(a, Edwards25519.base_point())) ==
                 Vectors.hex!(vector["public_key"])
      end
    end

    test "convert_mont maps an X25519 public key to the Edwards key of the same scalar" do
      k = X25519.generate_private_key()
      {:ok, a} = Edwards25519.convert_mont(un(X25519.public_key(k)))
      e = Edwards25519.mul(un(X25519.clamp(k)), Edwards25519.base_point())

      # Same y; convert_mont fixes the sign bit to 0.
      assert band(un(Edwards25519.encode(a)), (1 <<< 255) - 1) ==
               band(un(Edwards25519.encode(e)), (1 <<< 255) - 1)

      assert un(Edwards25519.encode(a)) >>> 255 == 0
    end
  end

  describe "deployed XEd25519: CRS-03 section 5 vectors" do
    test "xeddsa-verify.json: every case, including sign-bit, range and s + q cases" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            Vectors.load!("crs/CRS-03/xeddsa-verify.json")["cases"] do
        <<5, u::binary-size(32)>> = Vectors.hex!(inputs["public_key"])
        message = Vectors.hex!(inputs["message"])
        signature = Vectors.hex!(inputs["signature"])

        assert XEdDSA.verify(u, message, signature) == outputs["valid"],
               "case #{inputs["label"] || "valid"}"

        if outputs["ed25519_standard_verify"] do
          # The converted key and cleared-bit signature are a standard
          # Ed25519 pair (CRS-03 section 5.3, informative note).
          assert Ed25519.verify(
                   Vectors.hex!(outputs["ed25519_public_key"]),
                   message,
                   Vectors.hex!(outputs["ed25519_signature"])
                 )
        end
      end
    end

    test "prekey-signatures.json: signatures cover the serialized keys with type bytes" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            Vectors.load!("crs/CRS-03/prekey-signatures.json")["cases"] do
        <<5, identity::binary-size(32)>> = Vectors.hex!(inputs["identity_public"])
        <<5, raw_ec::binary-size(32)>> = ec = Vectors.hex!(inputs["signed_pre_key_public"])
        ec_signature = Vectors.hex!(inputs["signed_pre_key_signature"])
        kem = Vectors.hex!(inputs["kem_pre_key_public"])

        assert XEdDSA.verify(identity, ec, ec_signature) ==
                 outputs["signed_pre_key_signature_valid"]

        assert XEdDSA.verify(identity, kem, Vectors.hex!(inputs["kem_pre_key_signature"])) ==
                 outputs["kem_pre_key_signature_valid"]

        assert XEdDSA.verify(identity, raw_ec, ec_signature) ==
                 outputs["signature_over_raw_32_byte_key_valid"]
      end
    end

    test "alternate-identity-signature.json: plain verification over the signed message" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            Vectors.load!("crs/CRS-03/alternate-identity-signature.json")["cases"] do
        <<5, signer::binary-size(32)>> = Vectors.hex!(inputs["signer_identity_public"])
        signed = Vectors.hex!(outputs["signed_message"])

        assert signed ==
                 :binary.copy(<<0xFF>>, 32) <>
                   "Signal_PNI_Signature" <> Vectors.hex!(inputs["other_identity_public"])

        assert XEdDSA.verify(signer, signed, Vectors.hex!(inputs["signature"])) ==
                 outputs["plain_xeddsa_verify_over_signed_message"]
      end
    end
  end

  describe "deployed XEd25519: signing" do
    property "signatures verify, carry the sign bit of A = kB, and match the CRS-03 definition" do
      check all(
              k <- binary(length: 32),
              message <- binary(max_length: 200),
              z <- binary(length: 64),
              max_runs: 40
            ) do
        u = X25519.public_key(k)
        <<r::binary-size(32), s_field::little-size(256)>> = signature = XEdDSA.sign(k, message, z)

        assert XEdDSA.verify(u, message, signature)
        assert signature == XEdDSAReference.xeddsa_sign(k, message, z)
        assert XEdDSA.sign(X25519.clamp(k), message, z) == signature

        # With bit 255 cleared, the signature is a standard Ed25519
        # signature under A = kB (independent OpenSSL verifier).
        a = Edwards25519.encode(Edwards25519.mul(un(X25519.clamp(k)), Edwards25519.base_point()))
        assert s_field >>> 255 == un(a) >>> 255
        assert Ed25519.verify(a, message, r <> le(band(s_field, (1 <<< 255) - 1)))
      end
    end

    test "both sign-bit values occur" do
      bits =
        for _ <- 1..32, into: MapSet.new() do
          <<_::binary-size(63), top>> = XEdDSA.sign(X25519.generate_private_key(), "m")
          top >>> 7
        end

      assert bits == MapSet.new([0, 1])
    end

    test "rejects a changed message, signature, sign bit or key, and wrong sizes" do
      k = X25519.generate_private_key()
      u = X25519.public_key(k)
      <<head::binary-size(63), last>> = signature = XEdDSA.sign(k, "message")

      refute XEdDSA.verify(u, "messagE", signature)
      refute XEdDSA.verify(u, "message", flip(signature))
      refute XEdDSA.verify(u, "message", head <> <<bxor(last, 0x80)>>)
      refute XEdDSA.verify(X25519.public_key(X25519.generate_private_key()), "message", signature)
      refute XEdDSA.verify(u, "message", binary_part(signature, 0, 63))
      refute XEdDSA.verify(binary_part(u, 0, 31), "message", signature)
    end

    test "CRS-03 section 5.3 range rules: s + q accepted below 2^253, bit 253 rejected, bit 255 of u ignored" do
      k = X25519.generate_private_key()
      u = X25519.public_key(k)
      <<r::binary-size(32), s_field::little-size(256)>> = XEdDSA.sign(k, "m")
      sign = s_field >>> 255
      s = band(s_field, (1 <<< 255) - 1)
      with_s = fn value -> r <> le(value + (sign <<< 255)) end

      if s + @q < 1 <<< 253, do: assert(XEdDSA.verify(u, "m", with_s.(s + @q)))
      refute XEdDSA.verify(u, "m", with_s.(bor(s, 1 <<< 253)))
      refute XEdDSA.verify(u, "m", with_s.(bor(s, 1 <<< 254)))
      assert XEdDSA.verify(le(un(u) + (1 <<< 255)), "m", with_s.(s))
    end

    test "public keys without a curve point or with u = -1 are rejected" do
      signature = XEdDSA.sign(X25519.generate_private_key(), "m")

      # u = 2 maps to a y-coordinate with no x on the Edwards curve.
      assert Edwards25519.convert_mont(2) == :error
      refute XEdDSA.verify(le(2), "m", signature)
      refute XEdDSA.verify(le(@p - 1), "m", signature)
    end

    test "u = 0 (A = (0, -1)): sign bit 0 decodes; sign bit 1 fails RFC 8032 decoding" do
      base = Edwards25519.base_point()

      for sign <- [0, 1] do
        a_bytes = le(@p - 1 + (sign <<< 255))

        # A has order 2, so for an even h: sB - hA = sB, and s = r gives R.
        {r_bytes, r, message} =
          Enum.find_value(1..1000, fn i ->
            r = :rand.uniform(@q - 1)
            r_bytes = Edwards25519.encode(Edwards25519.mul(r, base))
            message = <<i::32>>
            h = rem(un(:crypto.hash(:sha512, [r_bytes, a_bytes, message])), @q)
            if rem(h, 2) == 0, do: {r_bytes, r, message}
          end)

        signature = r_bytes <> le(r + (sign <<< 255))
        assert XEdDSA.verify(le(0), message, signature) == (sign == 0), "sign bit #{sign}"
      end
    end
  end
end
