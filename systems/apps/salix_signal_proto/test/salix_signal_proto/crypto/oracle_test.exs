defmodule SalixSignalProto.Crypto.OracleTest do
  # Level 2 differential tests of layer C1 against the oracle's function mode
  # (ORACLE_INTERFACE.md sections 6.2 and 6.4), on the same random inputs.
  # Rejections are compared as accept versus reject only. Run with
  # `--include signal_oracle` and COMMA_SIGNAL_ORACLE=host:port.
  #
  # Kyber1024 has no oracle operation (ORACLE_INTERFACE.md section 6.3); the
  # CRS-03 decapsulation vectors cover it at level 1, and pre-key sessions
  # (layer C2) cover encapsulation.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias SalixSignalProto.Crypto.{AesCbc, AesGcm, Hkdf, Hmac, X25519, XEdDSA}
  alias SalixSignalProto.Test.Oracle

  @moduletag :signal_oracle

  # Low-order u-coordinates, including u = 0 and u = 1 (RFC 7748 section 6.1).
  @low_order [
    <<0::256>>,
    <<1::little-size(256)>>,
    Base.decode16!("E0EB7A7C3B41B8AE1656E3FAF19FC46ADA098DEB9C32B1FD866205165F49B800"),
    Base.decode16!("5F9C95BCA3508C24B1D0B1559C83EF5B04445CC4581C8E86D8224EDDD09F1157"),
    Base.decode16!("ECFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F")
  ]

  setup_all do
    {:ok, oracle: Oracle.connect!()}
  end

  defp accepted?({:ok, _}), do: true
  defp accepted?({:error, _}), do: false

  describe "X25519 (CRS-03 section 3)" do
    property "clamped private key and public key match", %{oracle: oracle} do
      check all(private <- binary(length: 32), max_runs: 50) do
        result = Oracle.call!(oracle, "x25519.public_from_private", %{private: private})
        {public, clamped} = X25519.keypair(private)

        assert Oracle.unhex(result["private"]) == clamped
        assert Oracle.unhex(result["public_raw"]) == public
        assert Oracle.unhex(result["public"]) == <<5>> <> public
      end
    end

    property "agreement matches, and rejects exactly the same peer keys", %{oracle: oracle} do
      check all(
              private <- binary(length: 32),
              peer <- one_of([member_of(@low_order), binary(length: 32)]),
              max_runs: 60
            ) do
        oracle_result =
          Oracle.call(oracle, "x25519.agree", %{private: private, public: <<5>> <> peer})

        case X25519.dh(private, peer) do
          {:ok, shared} -> assert oracle_result == {:ok, %{"shared" => Oracle.hex(shared)}}
          {:error, _} -> refute accepted?(oracle_result)
        end
      end
    end
  end

  describe "XEd25519 (CRS-03 section 5)" do
    property "the oracle verifies Comma signatures, and Comma verifies oracle signatures",
             %{oracle: oracle} do
      check all(private <- binary(length: 32), message <- binary(max_length: 300), max_runs: 40) do
        public = <<5>> <> X25519.public_key(private)
        signature = XEdDSA.sign(private, message)

        assert Oracle.call!(oracle, "xeddsa.verify", %{
                 public: public,
                 message: message,
                 signature: signature
               }) == %{"valid" => true}

        oracle_signature =
          oracle
          |> Oracle.call!("xeddsa.sign", %{private: private, message: message})
          |> Map.fetch!("signature")
          |> Oracle.unhex()

        assert XEdDSA.verify(X25519.public_key(private), message, oracle_signature)
      end
    end

    property "verification agrees on changed signatures, keys and messages", %{oracle: oracle} do
      check all(
              private <- binary(length: 32),
              message <- binary(max_length: 64),
              change <- member_of([:signature_bit, :key_bit, :s_plus_q, :message, :none]),
              bit <- integer(0..511),
              max_runs: 150
            ) do
        u = X25519.public_key(private)
        signature = XEdDSA.sign(private, message)

        {u, message, signature} =
          case change do
            :signature_bit -> {u, message, flip_bit(signature, bit)}
            :key_bit -> {flip_bit(u, rem(bit, 256)), message, signature}
            :s_plus_q -> {u, message, add_q(signature)}
            :message -> {u, message <> <<rem(bit, 256)>>, signature}
            :none -> {u, message, signature}
          end

        %{"valid" => oracle_valid} =
          Oracle.call!(oracle, "xeddsa.verify", %{
            public: <<5>> <> u,
            message: message,
            signature: signature
          })

        assert XEdDSA.verify(u, message, signature) == oracle_valid
      end
    end
  end

  describe "symmetric primitives (ORACLE_INTERFACE.md section 6.4)" do
    property "HKDF-SHA256 with and without salt", %{oracle: oracle} do
      check all(
              ikm <- binary(max_length: 100),
              salt <- one_of([constant(nil), binary(max_length: 64)]),
              info <- binary(max_length: 100),
              length <- integer(1..300),
              max_runs: 60
            ) do
        args = %{ikm: ikm, info: info, length: length}
        args = if salt, do: Map.put(args, :salt, salt), else: args
        %{"okm" => okm} = Oracle.call!(oracle, "hkdf.sha256", args)

        assert Hkdf.derive(ikm, salt || "", info, length) == Oracle.unhex(okm)
      end
    end

    property "HMAC-SHA256", %{oracle: oracle} do
      check all(key <- binary(max_length: 100), data <- binary(max_length: 300), max_runs: 40) do
        %{"mac" => mac} = Oracle.call!(oracle, "hmac.sha256", %{key: key, data: data})
        assert Hmac.sha256(key, data) == Oracle.unhex(mac)
      end
    end

    property "AES-256-CBC encryption, and padding acceptance of arbitrary blocks",
             %{oracle: oracle} do
      check all(
              key <- binary(length: 32),
              iv <- binary(length: 16),
              plaintext <- binary(max_length: 100),
              blocks <- integer(1..3),
              max_runs: 60
            ) do
        %{"ciphertext" => ciphertext} =
          Oracle.call!(oracle, "aes256cbc.encrypt", %{key: key, iv: iv, plaintext: plaintext})

        assert AesCbc.encrypt(key, iv, plaintext) == Oracle.unhex(ciphertext)

        random = :crypto.strong_rand_bytes(16 * blocks)

        oracle_result =
          Oracle.call(oracle, "aes256cbc.decrypt", %{key: key, iv: iv, ciphertext: random})

        case AesCbc.decrypt(key, iv, random) do
          {:ok, plain} -> assert oracle_result == {:ok, %{"plaintext" => Oracle.hex(plain)}}
          {:error, _} -> refute accepted?(oracle_result)
        end
      end
    end

    property "AES-256-GCM encryption and tamper rejection", %{oracle: oracle} do
      check all(
              key <- binary(length: 32),
              nonce <- binary(length: 12),
              plaintext <- binary(max_length: 100),
              aad <- binary(max_length: 40),
              max_runs: 40
            ) do
        %{"ciphertext" => sealed} =
          Oracle.call!(oracle, "aes256gcm.encrypt", %{
            key: key,
            nonce: nonce,
            plaintext: plaintext,
            aad: aad
          })

        {ciphertext, tag} = AesGcm.encrypt(key, nonce, plaintext, aad)
        assert ciphertext <> tag == Oracle.unhex(sealed)

        tampered = flip_bit(ciphertext <> tag, 0)
        size = byte_size(tampered) - 16
        <<tampered_ciphertext::binary-size(^size), tampered_tag::binary>> = tampered

        refute accepted?(
                 Oracle.call(oracle, "aes256gcm.decrypt", %{
                   key: key,
                   nonce: nonce,
                   ciphertext: tampered,
                   aad: aad
                 })
               )

        assert AesGcm.decrypt(key, nonce, tampered_ciphertext, tampered_tag, aad) ==
                 {:error, :invalid}
      end
    end
  end

  defp flip_bit(bytes, bit) do
    size = byte_size(bytes) * 8
    <<value::size(^size)>> = bytes
    # Bit numbering: bit 0 is the least significant bit of the first byte.
    position = size - 8 - div(bit, 8) * 8 + rem(bit, 8)
    <<bxor(value, 1 <<< position)::size(size)>>
  end

  # Adds the group order q to s, keeping the sign bit (bit 7 of byte 63).
  defp add_q(<<r::binary-size(32), s_field::little-size(256)>>) do
    q = SalixSignalProto.Crypto.Edwards25519.q()
    sign = s_field >>> 255
    s = band(s_field, (1 <<< 255) - 1)
    r <> <<s + q + (sign <<< 255)::little-size(256)>>
  end
end
