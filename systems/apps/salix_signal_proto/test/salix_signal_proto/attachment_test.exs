defmodule SalixSignalProto.AttachmentTest do
  # Level 1: CRS-10 vectors for attachment padding, encryption, the
  # incremental MAC and the pointer codec.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias SalixSignalProto.Attachment
  alias SalixSignalProto.Attachment.{IncrementalMac, Pointer}
  alias SalixSignalProto.Test.Vectors

  # CRS-10 sections 6.3 and 7: vectors/CRS-10/padded-size.json
  test "padded and blob sizes match the CRS-10 padded-size vectors" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-10/padded-size.json")["cases"] do
      size = inputs["plaintext_size"]
      assert Attachment.padded_size(size) == outputs["padded_size"], "size #{size}"
      assert Attachment.blob_size(size) == outputs["encrypted_blob_size"], "size #{size}"
    end
  end

  test "padded sizes never shrink and are exact at bucket boundaries" do
    sizes = [2, 3, 17, 540, 541, 542] ++ Enum.map(1..40, &(&1 * 1_000_003))

    for size <- sizes do
      padded = Attachment.padded_size(size)
      assert padded >= size
      # The next smaller size bucket would not hold the plaintext.
      assert Attachment.padded_size(padded) == padded
    end
  end

  # CRS-10 section 6: vectors/CRS-10/attachment-encrypt.json
  describe "CRS-10 attachment-encrypt" do
    for {vector, index} <-
          Enum.with_index(Vectors.load!("crs/CRS-10/attachment-encrypt.json")["cases"]) do
      @vector vector
      test "case #{index}: the blob, MAC and digest match and decrypt" do
        inputs = @vector["inputs"]
        outputs = @vector["outputs"]
        keys = Vectors.hex!(inputs["keys"])
        plaintext = Vectors.hex!(inputs["plaintext"])
        blob = Vectors.hex!(outputs["encrypted_blob"])
        digest = Vectors.hex!(outputs["digest"])

        assert Attachment.encrypt(plaintext, keys, Vectors.hex!(inputs["iv"])) ==
                 %{blob: blob, digest: digest, size: inputs["plaintext_size"]}

        assert byte_size(blob) == outputs["encrypted_blob_size"]
        assert binary_part(blob, byte_size(blob) - 32, 32) == Vectors.hex!(outputs["mac"])
        assert Attachment.padded_size(inputs["plaintext_size"]) == outputs["padded_size"]

        assert Attachment.decrypt(blob, keys, digest, inputs["plaintext_size"]) ==
                 {:ok, plaintext}
      end
    end
  end

  test "a receiver refuses a changed blob, a wrong digest and a short blob" do
    keys = Attachment.generate_keys()

    %{blob: blob, digest: digest, size: size} =
      Attachment.encrypt("hello", keys, Attachment.generate_iv())

    flipped =
      :binary.part(blob, 0, 20) <>
        <<bxor(:binary.at(blob, 20), 1)>> <> :binary.part(blob, 21, byte_size(blob) - 21)

    assert Attachment.decrypt(flipped, keys, digest, size) == {:error, :bad_mac}

    assert Attachment.decrypt(blob, keys, :crypto.hash(:sha256, "x"), size) ==
             {:error, :bad_digest}

    assert Attachment.decrypt(binary_part(blob, 0, 48), keys, digest, size) ==
             {:error, :too_short}

    assert Attachment.decrypt(blob, keys, digest, 10_000) == {:error, :bad_size}
    assert Attachment.decrypt(blob, keys, :none, size) == {:ok, "hello"}
  end

  property "encryption round-trips for any plaintext" do
    check all(plaintext <- binary(max_length: 3000), max_runs: 50) do
      keys = Attachment.generate_keys()
      result = Attachment.encrypt(plaintext, keys, Attachment.generate_iv())
      assert byte_size(result.blob) == Attachment.blob_size(byte_size(plaintext))
      assert Attachment.decrypt(result.blob, keys, result.digest, result.size) == {:ok, plaintext}
    end
  end

  # CRS-10 section 9.3: vectors/CRS-10/incremental-mac-chunk-size.json
  test "chunk sizes match the CRS-10 chunk-size vectors" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-10/incremental-mac-chunk-size.json")["cases"] do
      assert IncrementalMac.chunk_size(inputs["data_size"]) == outputs["chunk_size"]
    end
  end

  # CRS-10 section 9.2: vectors/CRS-10/incremental-mac.json
  test "incremental MACs match the CRS-10 incremental-mac vectors" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-10/incremental-mac.json")["cases"] do
      key = Vectors.hex!(inputs["mac_key"])
      # Large cases give only the rule "byte i = (7*i + 3) mod 256".
      data = for i <- 0..(inputs["data_size"] - 1)//1, into: <<>>, do: <<rem(7 * i + 3, 256)>>
      if inputs["data"], do: assert(data == Vectors.hex!(inputs["data"]))
      macs = IncrementalMac.compute(key, data, inputs["chunk_size"])

      assert macs == Vectors.hex!(outputs["incremental_mac"])
      assert byte_size(macs) == 32 * outputs["digest_count"]
      assert IncrementalMac.verify(key, data, inputs["chunk_size"], macs) == :ok
    end
  end

  # CRS-10 section 9.4: vectors/CRS-10/incremental-mac-validation.json
  test "stream validation accepts and rejects as the CRS-10 validation vectors say" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-10/incremental-mac-validation.json")["cases"] do
      key = Vectors.hex!(inputs["mac_key"])
      data = Vectors.hex!(inputs["data"])
      macs = Vectors.hex!(inputs["incremental_mac"])

      result =
        with {:ok, validator} <- IncrementalMac.validator(key, inputs["chunk_size"], macs),
             {:ok, validator, _} <- feed_in_pieces(validator, data, 7),
             :ok <- IncrementalMac.finish(validator),
             do: {:accepted, validator.position}

      case outputs["result"] do
        "accepted" -> assert result == {:accepted, outputs["bytes_released"]}, inputs["case"]
        "rejected" -> assert result == {:error, :mismatch}, inputs["case"]
      end
    end
  end

  test "a validator releases each prefix once its chunk boundary MAC matches" do
    key = :crypto.strong_rand_bytes(32)
    data = :crypto.strong_rand_bytes(100)
    macs = IncrementalMac.compute(key, data, 16)
    {:ok, validator} = IncrementalMac.validator(key, 16, macs)

    assert {:ok, validator, 0} = IncrementalMac.update(validator, binary_part(data, 0, 15))
    assert {:ok, validator, 48} = IncrementalMac.update(validator, binary_part(data, 15, 40))
    assert {:ok, validator, 96} = IncrementalMac.update(validator, binary_part(data, 55, 45))
    assert IncrementalMac.finish(validator) == :ok
    # An extra value, or a value list that is not whole, is refused.
    assert IncrementalMac.verify(key, data, 16, macs <> binary_part(macs, 0, 32)) ==
             {:error, :mismatch}

    assert IncrementalMac.validator(key, 16, binary_part(macs, 0, 31)) == {:error, :invalid}
  end

  defp feed_in_pieces(validator, <<>>, _size), do: {:ok, validator, validator.verified}

  defp feed_in_pieces(validator, data, size) do
    take = min(size, byte_size(data))
    <<piece::binary-size(^take), rest::binary>> = data

    with {:ok, validator, _} <- IncrementalMac.update(validator, piece),
         do: feed_in_pieces(validator, rest, size)
  end

  # CRS-10 section 8 and CRS-05 section 5.6.
  test "a pointer round-trips and needs a CDN id or key" do
    pointer = %Pointer{
      cdn_key: "abcdefghijklmnopqrst",
      cdn_number: 3,
      content_type: "audio/aac",
      keys: :binary.copy(<<7>>, 64),
      size: 1234,
      digest: :binary.copy(<<9>>, 32),
      flags: Pointer.flag_voice_message(),
      upload_timestamp: 1_758_790_000_000,
      client_uuid: :binary.copy(<<1>>, 16)
    }

    bytes = Pointer.encode(pointer)
    assert {:ok, decoded} = Pointer.from_binary(bytes)
    assert decoded == pointer
    assert Pointer.voice_message?(decoded)
    assert Pointer.cdn(decoded) == 3
    # Field 15 (CDN key) is a length-delimited field; field 1 is fixed64.
    assert :binary.match(bytes, <<15 <<< 3 ||| 2, 20>> <> "abcdefghijklmnopqrst") != :nomatch

    legacy = Pointer.encode(%Pointer{cdn_id: 0x0102030405060708})
    assert legacy == <<1 <<< 3 ||| 1, 8, 7, 6, 5, 4, 3, 2, 1>>
    assert {:ok, %Pointer{cdn_id: 0x0102030405060708}} = Pointer.from_binary(legacy)
    assert Pointer.cdn(%Pointer{cdn_id: 1}) == 0

    assert Pointer.from_binary(Pointer.encode(%Pointer{content_type: "image/png"})) ==
             {:error, :invalid}

    assert Pointer.from_binary(<<0xFF, 0xFF>>) == {:error, :invalid}
  end
end
