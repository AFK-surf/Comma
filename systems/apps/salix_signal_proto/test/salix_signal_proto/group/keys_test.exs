defmodule SalixSignalProto.Group.KeysTest do
  # Level 1 vectors of CRS-09a sections 3 to 9 (vectors/CRS-09): generator
  # derivation, group keys, UID and profile key ciphertexts, profile key
  # values and attribute blobs.
  use ExUnit.Case, async: true

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Group.{Blob, Elligator, Generators, Params, ProfileKey, Uid}
  alias SalixSignalProto.Test.Vectors

  defp load(name), do: Vectors.load!("crs/CRS-09/#{name}.json")
  defp hex(value), do: Vectors.hex!(value)

  test "section 4: every generator table derives from its label (SHO-HMAC and SHO-SHA256)" do
    assert Generators.derive() == Generators.all()
  end

  test "section 4.3.4 MAP: 32 zero bytes map to the identity" do
    # The all-zero profile key's M4 (section 8.4) depends on this.
    assert Elligator.map(<<0::256>>) == R.identity()
  end

  test "section 6: group keys derive from the master key and from randomness" do
    for %{"inputs" => %{"master_key" => key}, "outputs" => out} <-
          load("group-secret-params-derive")["cases"] do
      params = Params.from_master_key(hex(key))
      assert Params.encode(params) == hex(out["group_secret_params"])
      assert Params.public_params(params) == hex(out["group_public_params"])
      assert params.group_id == hex(out["group_identifier"])
      assert Params.decode(hex(out["group_secret_params"])) == {:ok, params}
    end

    for %{"inputs" => %{"randomness" => r}, "outputs" => out} <-
          load("group-secret-params-generate")["cases"] do
      master_key = Params.generate_master_key(hex(r))
      assert master_key == hex(out["master_key"])
      assert Params.encode(Params.from_master_key(master_key)) == hex(out["group_secret_params"])
    end

    lengths = hd(load("serialized-lengths")["cases"])["outputs"]
    params = Params.from_master_key(<<1::256>>)
    assert byte_size(Params.encode(params)) == lengths["group_secret_params"]
    assert byte_size(Params.public_params(params)) == lengths["group_public_params"]
  end

  test "secret params whose keys do not match the master key are rejected" do
    <<head::binary-size(100), byte, rest::binary>> =
      Params.encode(Params.from_master_key(<<2::256>>))

    assert Params.decode(head <> <<Bitwise.bxor(byte, 1)>> <> rest) == {:error, :invalid}
  end

  test "section 7: UID ciphertexts are deterministic and decrypt to the same kind" do
    for %{"inputs" => inputs, "outputs" => out, "label" => label} <-
          load("uid-encryption")["cases"] do
      params = Params.from_master_key(hex(inputs["master_key"]))
      {:ok, service_id} = Uid.parse_tagged(hex(inputs["service_id_tagged"]))
      assert Uid.compact(service_id) == hex(inputs["service_id_compact"]), label

      ciphertext = Uid.encrypt(params, service_id)
      assert ciphertext == hex(out["uuid_ciphertext"]), label

      assert Uid.decrypt(params, ciphertext) ==
               Uid.parse_tagged(hex(out["decrypted_service_id_tagged"]))
    end
  end

  test "section 7.4: wrong key, swapped points, base point and reserved byte fail" do
    for %{"inputs" => inputs, "label" => label} <- load("uid-decryption-failures")["cases"] do
      params = Params.from_master_key(hex(inputs["master_key"] || String.duplicate("00", 32)))
      assert Uid.decrypt(params, hex(inputs["uuid_ciphertext"])) == {:error, :invalid}, label
    end
  end

  test "section 8: profile key ciphertexts; the all-zero key never decrypts; wrong ACI fails" do
    for %{"inputs" => inputs, "outputs" => out, "label" => label} <-
          load("profile-key-encryption")["cases"] do
      params = Params.from_master_key(hex(inputs["master_key"]))
      uuid = hex(inputs["aci_uuid"])

      case inputs do
        %{"profile_key" => key} ->
          ciphertext = ProfileKey.encrypt(params, hex(key), uuid)
          assert ciphertext == hex(out["profile_key_ciphertext"]), label

          case out["decrypt_result"] do
            "ok" ->
              assert ProfileKey.decrypt(params, ciphertext, uuid) ==
                       {:ok, hex(out["decrypted_profile_key"])}

            "error" ->
              assert ProfileKey.decrypt(params, ciphertext, uuid) == {:error, :invalid}, label
          end

        %{"profile_key_ciphertext" => ciphertext} ->
          assert out["result"] == "error"
          assert ProfileKey.decrypt(params, hex(ciphertext), uuid) == {:error, :invalid}, label
      end
    end
  end

  test "section 8.5: commitment, version and access key" do
    for %{"inputs" => inputs, "outputs" => out} <- load("profile-key-derived")["cases"] do
      key = hex(inputs["profile_key"])
      uuid = hex(inputs["aci_uuid"])
      assert ProfileKey.commitment(key, uuid) == hex(out["commitment"])
      assert ProfileKey.version(key, uuid) == out["profile_key_version"]
      assert ProfileKey.access_key(key) == hex(out["access_key"])
    end
  end

  test "section 9: blobs encrypt with fixed randomness and decrypt with any padding" do
    for %{"inputs" => inputs, "outputs" => out, "label" => label} <-
          load("blob-encryption")["cases"] do
      params = Params.from_master_key(hex(inputs["master_key"]))
      plaintext = hex(inputs["plaintext"])
      blob = Blob.encrypt(params, plaintext, inputs["padding_length"], hex(inputs["randomness"]))

      assert blob == hex(out["ciphertext"]), label
      assert Blob.decrypt(params, blob) == {:ok, hex(out["decrypted"])}
    end
  end

  test "section 9: the last byte is not checked; short or altered blobs fail" do
    params = Params.from_master_key(<<3::256>>)
    blob = Blob.encrypt(params, "title")
    size = byte_size(blob) - 1
    <<body::binary-size(^size), _last>> = blob

    assert Blob.decrypt(params, body <> <<0xFF>>) == {:ok, "title"}
    assert Blob.decrypt(params, binary_part(blob, 0, 28)) == {:error, :invalid}
    assert Blob.decrypt(Params.from_master_key(<<4::256>>), blob) == {:error, :invalid}
  end
end
