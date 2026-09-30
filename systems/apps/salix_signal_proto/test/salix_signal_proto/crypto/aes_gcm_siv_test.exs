defmodule SalixSignalProto.Crypto.AesGcmSivTest do
  # AES-256-GCM-SIV (RFC 8452) at the AEAD level, against the oracle-made
  # group blob ciphertexts of CRS-09a section 9 (vectors/CRS-09/
  # blob-encryption.json): the blob key of the master key, the nonce and
  # the padded plaintext `be32(n) ‖ m ‖ 0^n` give the listed ciphertext.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Crypto.AesGcmSiv
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Test.Vectors

  @vectors Vectors.load!("crs/CRS-09/blob-encryption.json")

  defp cases do
    for %{"inputs" => inputs, "outputs" => %{"ciphertext" => blob}} <- @vectors["cases"] do
      key = Params.from_master_key(Vectors.hex!(inputs["master_key"])).blob_key
      padding = inputs["padding_length"]
      plaintext = <<padding::32>> <> Vectors.hex!(inputs["plaintext"]) <> <<0::size(padding * 8)>>
      blob = Vectors.hex!(blob)
      size = byte_size(blob) - 13
      <<aead::binary-size(^size), nonce::binary-size(12), 0>> = blob
      {key, nonce, plaintext, aead}
    end
  end

  test "CRS-09a blob ciphertexts encrypt and decrypt byte for byte" do
    assert length(cases()) == length(@vectors["cases"])

    for {key, nonce, plaintext, aead} <- cases() do
      assert AesGcmSiv.encrypt(key, nonce, plaintext) == aead
      assert AesGcmSiv.decrypt(key, nonce, aead) == {:ok, plaintext}
    end
  end

  test "a changed bit anywhere, a wrong key, or a short input fails authentication" do
    {key, nonce, _plaintext, aead} =
      Enum.max_by(cases(), fn {_, _, _, aead} -> byte_size(aead) end)

    last = byte_size(aead) - 1

    for index <- [0, div(last, 2), last] do
      <<prefix::binary-size(^index), byte, rest::binary>> = aead
      tampered = prefix <> <<Bitwise.bxor(byte, 1)>> <> rest
      assert AesGcmSiv.decrypt(key, nonce, tampered) == {:error, :invalid}
    end

    assert AesGcmSiv.decrypt(:binary.copy(<<7>>, 32), nonce, aead) == {:error, :invalid}
    assert AesGcmSiv.decrypt(key, nonce, binary_part(aead, 0, 15)) == {:error, :invalid}
  end

  property "associated data and the nonce are authenticated" do
    check all(
            key <- binary(length: 32),
            nonce <- binary(length: 12),
            plaintext <- binary(max_length: 100),
            aad <- binary(max_length: 40),
            max_runs: 50
          ) do
      ciphertext = AesGcmSiv.encrypt(key, nonce, plaintext, aad)
      assert AesGcmSiv.decrypt(key, nonce, ciphertext, aad) == {:ok, plaintext}
      assert AesGcmSiv.decrypt(key, nonce, ciphertext, aad <> "x") == {:error, :invalid}

      <<first, rest::binary-size(11)>> = nonce

      assert AesGcmSiv.decrypt(key, <<Bitwise.bxor(first, 1), rest::binary>>, ciphertext, aad) ==
               {:error, :invalid}
    end
  end
end
