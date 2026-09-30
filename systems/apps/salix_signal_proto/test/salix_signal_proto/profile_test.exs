defmodule SalixSignalProto.ProfileTest do
  # Level 1: CRS-08 vectors for the profile key derivations and the
  # encrypted profile fields.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Profile
  alias SalixSignalProto.Test.Vectors

  # CRS-08 section 3.1 and 3.2: vectors/CRS-08/access-key.json
  test "access keys and checksums match the CRS-08 access-key vectors" do
    for vector <- Vectors.load!("crs/CRS-08/access-key.json")["cases"] do
      profile_key = Vectors.hex!(vector["inputs"]["profile_key"])
      access_key = Profile.access_key(profile_key)
      checksum = Vectors.hex!(vector["outputs"]["access_key_checksum"])

      assert access_key == Vectors.hex!(vector["outputs"]["access_key"])
      assert Profile.access_key_checksum(access_key) == checksum
      assert Profile.checksum_matches?(profile_key, checksum)
      refute Profile.checksum_matches?(Profile.generate(), checksum)
    end
  end

  # CRS-08 section 3.3: vectors/CRS-08/profile-key-version-and-commitment.json
  # and profile-key-version-steps.json. The commitment outputs need CRS-09
  # and are not checked here.
  test "profile key versions match the CRS-08 version vectors" do
    cases =
      Vectors.load!("crs/CRS-08/profile-key-version-and-commitment.json")["cases"] ++
        Vectors.load!("crs/CRS-08/profile-key-version-steps.json")["cases"]

    for vector <- cases do
      profile_key = Vectors.hex!(vector["inputs"]["profile_key"])
      aci = Vectors.hex!(vector["inputs"]["aci_uuid_bytes"])
      assert Profile.version(profile_key, aci) == vector["outputs"]["version_string"]
    end
  end

  # CRS-08 sections 4.1, 4.2 and 5.5: vectors/CRS-08/profile-field-encryption.json
  describe "CRS-08 profile-field-encryption" do
    for {vector, index} <-
          Enum.with_index(Vectors.load!("crs/CRS-08/profile-field-encryption.json")["cases"]) do
      @vector vector
      test "case #{index} (#{vector["inputs"]["field"]}) encrypts and decrypts" do
        inputs = @vector["inputs"]
        key = Vectors.hex!(inputs["profile_key"])
        nonce = Vectors.hex!(inputs["nonce"])
        expected = Vectors.hex!(@vector["outputs"]["encrypted"])

        assert encrypt_field(inputs, key, nonce) == expected

        if base64 = @vector["outputs"]["encrypted_base64"],
          do: assert(Base.encode64(expected) == base64)

        assert_decrypts(inputs, key, expected)
      end
    end
  end

  defp encrypt_field(%{"field" => "name"} = inputs, key, nonce) do
    plaintext = Vectors.hex!(inputs["plaintext_utf8_hex"])

    {given, family} =
      case :binary.split(plaintext, <<0>>) do
        [given] -> {given, nil}
        [given, family] -> {given, family}
      end

    {:ok, encrypted} = Profile.encrypt_name(key, given, family, nonce)
    encrypted
  end

  defp encrypt_field(%{"field" => "about"} = inputs, key, nonce) do
    {:ok, encrypted} =
      Profile.encrypt_about(key, Vectors.hex!(inputs["plaintext_utf8_hex"]), nonce)

    encrypted
  end

  defp encrypt_field(%{"field" => "aboutEmoji"} = inputs, key, nonce) do
    {:ok, encrypted} =
      Profile.encrypt_about_emoji(key, Vectors.hex!(inputs["plaintext_utf8_hex"]), nonce)

    encrypted
  end

  defp encrypt_field(%{"field" => "phoneNumberSharing"} = inputs, key, nonce),
    do: Profile.encrypt_phone_number_sharing(key, inputs["padded_plaintext"] == "01", nonce)

  defp encrypt_field(%{"field" => "avatar"} = inputs, key, nonce),
    do: Profile.encrypt(key, Vectors.hex!(inputs["plaintext"]), nonce)

  defp encrypt_field(%{"field" => "cross-check"} = inputs, key, nonce),
    do: Profile.encrypt(key, Vectors.hex!(inputs["padded_plaintext"]), nonce)

  defp assert_decrypts(%{"field" => "name"} = inputs, key, encrypted) do
    plaintext = Vectors.hex!(inputs["plaintext_utf8_hex"])

    expected =
      case :binary.split(plaintext, <<0>>) do
        [given] -> {given, nil}
        [given, family] -> {given, family}
      end

    assert Profile.decrypt_name(key, encrypted) == {:ok, expected}
  end

  defp assert_decrypts(%{"field" => field} = inputs, key, encrypted)
       when field in ["about", "aboutEmoji"] do
    assert Profile.decrypt_text(key, encrypted) ==
             {:ok, Vectors.hex!(inputs["plaintext_utf8_hex"])}
  end

  defp assert_decrypts(%{"field" => "phoneNumberSharing"} = inputs, key, encrypted) do
    assert Profile.decrypt_phone_number_sharing(key, encrypted) ==
             {:ok, inputs["padded_plaintext"] == "01"}
  end

  defp assert_decrypts(%{"field" => "avatar"} = inputs, key, encrypted),
    do: assert(Profile.decrypt(key, encrypted) == {:ok, Vectors.hex!(inputs["plaintext"])})

  defp assert_decrypts(%{"field" => "cross-check"} = inputs, key, encrypted) do
    assert Profile.decrypt(key, encrypted) == {:ok, Vectors.hex!(inputs["padded_plaintext"])}
    # CRS-08 section 3.1: the access key is the first 16 ciphertext bytes.
    assert binary_part(encrypted, 12, 16) == Profile.access_key(key)
  end

  test "padding picks the smallest allowed length and refuses longer plaintexts" do
    assert {:ok, padded} = Profile.pad(:about, :binary.copy("a", 129))
    assert byte_size(padded) == 254
    assert {:ok, padded} = Profile.pad(:about, :binary.copy("a", 254))
    assert byte_size(padded) == 254
    assert Profile.pad(:about, :binary.copy("a", 513)) == {:error, :too_long}
    assert Profile.pad(:about_emoji, :binary.copy("a", 33)) == {:error, :too_long}

    key = Profile.generate()
    assert Profile.encrypt_name(key, :binary.copy("a", 200), "b") |> elem(1) |> byte_size() == 285
    assert Profile.encrypt_name(key, :binary.copy("a", 250), "bbbbbbb") == {:error, :too_long}
    assert Profile.encrypt_name(key, "a" <> <<0>>, nil) == {:error, :invalid_text}
  end

  test "a reader with another profile key or a short input gets an error" do
    key = Profile.generate()
    {:ok, encrypted} = Profile.encrypt_name(key, "Comma", nil)

    assert Profile.decrypt_name(Profile.generate(), encrypted) == {:error, :invalid}
    assert Profile.decrypt(key, :binary.copy(<<0>>, 28)) == {:error, :too_short}
  end

  property "names round-trip with and without a family name" do
    check all(
            given <- string(:printable, max_length: 60),
            family <- one_of([constant(nil), string(:printable, min_length: 1, max_length: 60)]),
            not String.contains?(given <> (family || ""), <<0>>),
            byte_size(given) + byte_size(family || "") < 256
          ) do
      key = Profile.generate()
      {:ok, encrypted} = Profile.encrypt_name(key, given, family)
      assert byte_size(encrypted) in [81, 285]
      assert Profile.decrypt_name(key, encrypted) == {:ok, {given, family}}
    end
  end

  # CRS-08 section 8.
  test "the access key to present follows the profile's unidentified-access fields" do
    key = Profile.generate()
    checksum = key |> Profile.access_key() |> Profile.access_key_checksum()
    other = Profile.generate() |> Profile.access_key() |> Profile.access_key_checksum()
    profile = &%{unidentified_access: &1, unrestricted_unidentified_access: &2}

    assert Profile.unidentified_access(profile.(checksum, true), nil) == {:open, <<0::128>>}

    assert Profile.unidentified_access(profile.(checksum, false), key) ==
             {:keyed, Profile.access_key(key)}

    assert Profile.unidentified_access(profile.(other, false), key) == :off
    assert Profile.unidentified_access(profile.(nil, true), key) == :off
    assert Profile.unidentified_access(profile.(checksum, false), nil) == :off
    assert Profile.unidentified_access(nil, key) == {:unknown, Profile.access_key(key)}
    assert Profile.unidentified_access(nil, nil) == {:unknown, <<0::128>>}
  end
end
