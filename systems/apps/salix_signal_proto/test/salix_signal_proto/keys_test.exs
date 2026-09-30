defmodule SalixSignalProto.KeysTest do
  # Key and signature wire formats (CRS-03 §3 to §8) against the CRS-03
  # vectors, and the initiator ephemeral-key check of CRS-04 §3.4.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Crypto.Edwards25519, as: Ed
  alias SalixSignalProto.Crypto.XEdDSA
  alias SalixSignalProto.Keys
  alias SalixSignalProto.Test.Vectors

  defp cases(file), do: Vectors.load!("crs/CRS-03/" <> file)["cases"]
  defp hex(value), do: Vectors.hex!(value)

  test "EC key pairs: the private key is clamped and the public key has type byte 0x05 (ec-key-pair)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("ec-key-pair.json") do
      pair = Keys.ec_keypair(hex(inputs["private_key_input"]))
      assert pair.private == hex(outputs["private_key_serialized"])
      assert pair.public == hex(outputs["public_key_serialized"])
    end
  end

  test "EC public key parsing (ec-public-key-parse)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("ec-public-key-parse.json") do
      case Keys.parse_ec_public(hex(inputs["bytes"])) do
        {:ok, key} ->
          assert outputs["accepted"], inputs["label"]
          assert key == hex(outputs["reserialized"])

        {:error, _reason} ->
          refute outputs["accepted"], inputs["label"]
      end
    end
  end

  test "X25519 agreement over serialized keys rejects an all-zero result (x25519-agreement)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("x25519-agreement.json") do
      result = Keys.agree(hex(inputs["private_key"]), hex(inputs["their_public_key"]))

      case outputs do
        %{"shared_secret" => shared} -> assert result == {:ok, hex(shared)}
        %{"reason" => _} -> assert result == {:error, :invalid_key}
      end
    end
  end

  test "deployed XEdDSA verification, including the sign bit and s + q (xeddsa-verify)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("xeddsa-verify.json") do
      assert Keys.verify_signature(
               hex(inputs["public_key"]),
               hex(inputs["message"]),
               hex(inputs["signature"])
             ) ==
               outputs["valid"],
             inspect(inputs["label"])
    end
  end

  test "pre-keys are signed over the serialized key with its type byte (prekey-signatures)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("prekey-signatures.json") do
      identity = hex(inputs["identity_public"])
      signed = hex(inputs["signed_pre_key_public"])

      assert Keys.verify_signature(identity, signed, hex(inputs["signed_pre_key_signature"])) ==
               outputs["signed_pre_key_signature_valid"]

      assert Keys.verify_signature(
               identity,
               hex(inputs["kem_pre_key_public"]),
               hex(inputs["kem_pre_key_signature"])
             ) ==
               outputs["kem_pre_key_signature_valid"]

      <<5, raw::binary>> = signed

      assert Keys.verify_signature(identity, raw, hex(inputs["signed_pre_key_signature"])) ==
               outputs["signature_over_raw_32_byte_key_valid"]
    end
  end

  test "alternate identity signatures (alternate-identity-signature)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("alternate-identity-signature.json") do
      other = hex(inputs["other_identity_public"])
      assert Keys.alternate_identity_message(other) == hex(outputs["signed_message"])

      assert Keys.verify_alternate_identity(
               hex(inputs["signer_identity_public"]),
               other,
               hex(inputs["signature"])
             ) ==
               outputs["valid"]
    end
  end

  property "signatures of the XEdDSA signer verify under the deployed rules" do
    check all(private <- binary(length: 32), message <- binary(max_length: 100), max_runs: 20) do
      signature = XEdDSA.sign(private, message)
      assert Keys.verify_signature(Keys.ec_public(private), message, signature)
      refute Keys.verify_signature(Keys.ec_public(private), message <> "x", signature)
    end
  end

  test "KEM keys: type byte 0x08 and an exact length (kem-key-parse)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("kem-key-parse.json") do
      bytes = hex(inputs["bytes"])

      result =
        if inputs["kind"] == "public",
          do: Keys.parse_kem_public(bytes),
          else: Keys.parse_kem_secret(bytes)

      case result do
        {:ok, key} ->
          assert outputs["accepted"] and byte_size(key) == outputs["length"], inputs["label"]

        {:error, _} ->
          refute outputs["accepted"], inputs["label"]
      end
    end
  end

  test "device IDs 1 to 127 (device-id-range)" do
    for %{"inputs" => %{"device_id" => id}, "outputs" => %{"accepted" => accepted}} <-
          cases("device-id-range.json") do
      assert Keys.valid_device_id?(id) == accepted
    end
  end

  describe "canonical initiator ephemeral keys (CRS-04 §3.4)" do
    property "keys made from clamped scalars are canonical" do
      check all(private <- binary(length: 32), max_runs: 20) do
        assert Keys.canonical_public?(Keys.ec_public(private))
      end
    end

    test "bit 255, u >= p, low-order points and twist points are not" do
      <<5, u::binary-size(31), last>> = Keys.ec_public(<<7::256>>)
      refute Keys.canonical_public?(<<5, u::binary, Bitwise.bor(last, 0x80)>>)
      # p = 2^255 - 19 and u = 0, 1 (low order).
      refute Keys.canonical_public?(<<5, 2 ** 255 - 19::little-size(256)>>)
      refute Keys.canonical_public?(<<5, 0::256>>)
      refute Keys.canonical_public?(<<5, 1::little-size(256)>>)
      # A u-coordinate with no Edwards point is on the twist.
      twist = Enum.find(2..100, &(Ed.from_y(Ed.u_to_y(&1), 0) == :error))
      refute Keys.canonical_public?(<<5, twist::little-size(256)>>)
    end

    test "an order-8 point, and an honest key plus a torsion component, are not" do
      <<5, u_bytes::binary>> = Keys.ec_public(:crypto.strong_rand_bytes(32))
      {:ok, honest} = Ed.convert_mont(:binary.decode_unsigned(u_bytes, :little))
      order8 = torsion_point()

      assert Keys.canonical_public?(<<5, to_u(honest)::binary>>)
      refute Keys.canonical_public?(<<5, to_u(order8)::binary>>)
      refute Keys.canonical_public?(<<5, to_u(Ed.add(honest, order8))::binary>>)
    end

    # u = (1 + y) / (1 - y) (RFC 7748 section 4.1).
    defp to_u(point) do
      p = Ed.p()
      encoded = :binary.decode_unsigned(Ed.encode(point), :little)
      y = Bitwise.band(encoded, Bitwise.bsl(1, 255) - 1)
      inverse = :crypto.mod_pow(Integer.mod(1 - y, p), p - 2, p) |> :binary.decode_unsigned()
      <<Integer.mod((1 + y) * inverse, p)::little-size(256)>>
    end

    # q times a random curve point has order dividing 8; keep one of order 8.
    defp torsion_point do
      Stream.repeatedly(fn -> :crypto.strong_rand_bytes(32) end)
      |> Stream.map(&Ed.decode/1)
      |> Stream.filter(&match?({:ok, _}, &1))
      |> Stream.map(fn {:ok, point} -> Ed.mul(Ed.q(), point) end)
      |> Enum.find(fn t -> not Ed.identity?(Ed.mul(4, t)) end)
    end
  end
end
