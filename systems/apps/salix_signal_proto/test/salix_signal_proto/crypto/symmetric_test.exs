defmodule SalixSignalProto.Crypto.SymmetricTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias SalixSignalProto.Crypto.{AesCbc, AesGcm, Hmac}

  defp flip(<<first, rest::binary>>), do: <<bxor(first, 1), rest::binary>>

  describe "AES-GCM" do
    property "round-trips and rejects any change to ciphertext, tag, AAD or nonce" do
      check all(
              key <- one_of([binary(length: 16), binary(length: 32)]),
              nonce <- binary(length: 12),
              plaintext <- binary(min_length: 1),
              aad <- binary(),
              max_runs: 50
            ) do
        {ciphertext, tag} = AesGcm.encrypt(key, nonce, plaintext, aad)

        assert byte_size(ciphertext) == byte_size(plaintext)
        assert AesGcm.decrypt(key, nonce, ciphertext, tag, aad) == {:ok, plaintext}
        assert AesGcm.decrypt(key, nonce, flip(ciphertext), tag, aad) == {:error, :invalid}
        assert AesGcm.decrypt(key, nonce, ciphertext, flip(tag), aad) == {:error, :invalid}
        assert AesGcm.decrypt(key, nonce, ciphertext, tag, aad <> "x") == {:error, :invalid}
        assert AesGcm.decrypt(key, flip(nonce), ciphertext, tag, aad) == {:error, :invalid}

        assert AesGcm.decrypt(key, nonce, ciphertext, binary_part(tag, 0, 12), aad) ==
                 {:error, :invalid}
      end
    end
  end

  describe "AES-CBC with PKCS#7 padding" do
    property "round-trips every length and pads to whole blocks" do
      check all(
              key <- one_of([binary(length: 16), binary(length: 32)]),
              iv <- binary(length: 16),
              plaintext <- binary(max_length: 80),
              max_runs: 50
            ) do
        ciphertext = AesCbc.encrypt(key, iv, plaintext)

        assert byte_size(ciphertext) == (div(byte_size(plaintext), 16) + 1) * 16
        assert AesCbc.decrypt(key, iv, ciphertext) == {:ok, plaintext}
      end
    end

    test "rejects empty, partial-block and badly padded ciphertexts" do
      key = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(16)
      raw = fn block -> :crypto.crypto_one_time(:aes_256_cbc, key, iv, block, true) end

      assert AesCbc.decrypt(key, iv, "") == {:error, :invalid}
      assert AesCbc.decrypt(key, iv, :binary.copy(<<0>>, 15)) == {:error, :invalid}
      # Pad byte 0, pad byte above the block size, and inconsistent pad bytes.
      assert AesCbc.decrypt(key, iv, raw.(:binary.copy(<<0>>, 16))) == {:error, :invalid}
      assert AesCbc.decrypt(key, iv, raw.(:binary.copy(<<17>>, 16))) == {:error, :invalid}

      assert AesCbc.decrypt(key, iv, raw.(:binary.copy(<<1>>, 13) <> <<2, 3, 3>>)) ==
               {:error, :invalid}

      assert AesCbc.decrypt(key, iv, raw.(:binary.copy(<<16>>, 16))) == {:ok, ""}
    end
  end

  describe "HMAC-SHA256" do
    test "equal?/2 compares MACs and treats different sizes as unequal" do
      mac = Hmac.sha256("key", "data")

      assert byte_size(mac) == 32
      assert Hmac.equal?(mac, Hmac.sha256("key", ["da", "ta"]))
      refute Hmac.equal?(mac, Hmac.sha256("key", "datb"))
      refute Hmac.equal?(mac, binary_part(mac, 0, 16))
    end
  end
end
