defmodule SalixSignalProto.Crypto.Kyber1024Test do
  # Kyber1024 round 3 (CRS-03 §6.2) against the CRS-03 vectors
  # kyber1024-decapsulate.json, kyber1024-keys-from-seed.json and
  # kyber1024-implicit-rejection.json.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Crypto.Kyber1024
  alias SalixSignalProto.Test.Vectors

  defp raw(hex), do: hex |> Vectors.hex!() |> binary_part(1, div(byte_size(hex), 2) - 1)

  test "decapsulates oracle ciphertexts to the round-3 secret, not the FIPS 203 one" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-03/kyber1024-decapsulate.json")["cases"] do
      assert {:ok, secret} =
               Kyber1024.decapsulate(raw(inputs["secret_key"]), raw(inputs["kem_ciphertext"]))

      assert secret == Vectors.hex!(outputs["shared_secret"])
      refute secret == Vectors.hex!(outputs["fips203_mlkem1024_decapsulation_for_contrast"])
    end
  end

  test "key generation from seeds reproduces the keys the oracle accepted, with either expansion" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-03/kyber1024-keys-from-seed.json")["cases"] do
      keygen = if inputs["keygen"] == "fips203-keygen", do: :fips203, else: :round3
      d = Vectors.hex!(inputs["d"])
      z = Vectors.hex!(inputs["z"])

      assert {ek, dk} = Kyber1024.keypair_from_seed(d, z, keygen)
      assert ek == raw(outputs["public_key"])
      assert dk == raw(outputs["secret_key"])

      assert Kyber1024.decapsulate(dk, raw(outputs["oracle_ciphertext"])) ==
               {:ok, Vectors.hex!(outputs["shared_secret"])}
    end
  end

  property "encapsulation round-trips, and a changed ciphertext gives a different secret" do
    {ek, dk} = Kyber1024.keypair()

    check all(m <- binary(length: 32), position <- integer(0..1567), max_runs: 5) do
      {:ok, {secret, ciphertext}} = Kyber1024.encapsulate(ek, m)
      assert Kyber1024.decapsulate(dk, ciphertext) == {:ok, secret}

      <<before::binary-size(^position), byte, rest::binary>> = ciphertext
      changed = <<before::binary, Bitwise.bxor(byte, 1), rest::binary>>
      assert {:ok, other} = Kyber1024.decapsulate(dk, changed)
      refute other == secret

      # CRS-03 §6.2 rule 6: the deployed implicit-rejection secret is
      # KDF(J(z || c) || H(c)), not the round-3 text form KDF(z || H(c)).
      z = binary_part(dk, 3136, 32)
      assert other == shake256([shake256([z, changed]), :crypto.hash(:sha3_256, changed)])
      refute other == shake256([z, :crypto.hash(:sha3_256, changed)])
    end
  end

  defp shake256(data), do: :crypto.hash_xof(:shake256, data, 256)

  describe "CRS-03 kyber1024-implicit-rejection.json (section 6.2 rule 6)" do
    import SalixSignalProto.Test.SessionFixtures, only: [context: 4, pre_keys: 1]

    alias SalixSignalProto.{Address, Keys, Session}

    defp rejection_cases,
      do: Vectors.load!("crs/CRS-03/kyber1024-implicit-rejection.json")["cases"]

    test "a changed ciphertext decapsulates to the rule-6 secret, never to the contrast values" do
      for %{"inputs" => inputs, "outputs" => outputs} <- rejection_cases() do
        assert {:ok, secret} =
                 Kyber1024.decapsulate(
                   raw(inputs["kem_secret_key"]),
                   Vectors.hex!(inputs["kem_ciphertext"])
                 )

        assert secret == Vectors.hex!(outputs["shared_secret"]), inputs["label"]

        unless outputs["re_encryption_matches"] do
          refute secret == Vectors.hex!(outputs["not_round3_text_form"]), inputs["label"]
          refute secret == Vectors.hex!(outputs["not_fips203_rejection"]), inputs["label"]
        end
      end
    end

    test "a Comma responder decrypts the messages the oracle decrypted, and rejects the contrast messages" do
      for %{"inputs" => inputs, "outputs" => %{"oracle_session_evidence" => evidence} = outputs} <-
            rejection_cases() do
        address = fn %{"name" => name, "device_id" => device} -> Address.new(name, device) end

        ctx =
          context(
            Vectors.hex!(evidence["responder_identity_private"]),
            evidence["responder_registration_id"],
            address.(evidence["responder_address"]),
            address.(evidence["initiator_address"])
          )

        lookup =
          pre_keys(%{
            signed: %{
              evidence["responder_signed_prekey_id"] =>
                Vectors.hex!(evidence["responder_signed_prekey_private"])
            },
            one_time: %{
              evidence["responder_one_time_prekey_id"] =>
                Vectors.hex!(evidence["responder_one_time_prekey_private"])
            },
            kem: %{evidence["responder_kem_prekey_id"] => Vectors.hex!(inputs["kem_secret_key"])}
          })

        assert evidence["oracle_decrypted"]

        assert {:ok, plaintext, _record, _effects} =
                 Session.decrypt_pre_key(
                   nil,
                   Vectors.hex!(evidence["prekey_message"]),
                   ctx,
                   lookup
                 )

        assert plaintext == Vectors.hex!(evidence["oracle_plaintext_padded"]), inputs["label"]

        for {message, decrypted} <- [
              {"prekey_message_with_round3_text_form_secret",
               "oracle_decrypted_with_round3_text_form_secret"},
              {"prekey_message_with_fips203_secret", "oracle_decrypted_with_fips203_secret"}
            ],
            Map.has_key?(evidence, message) do
          refute evidence[decrypted]

          assert {:error, _} =
                   Session.decrypt_pre_key(nil, Vectors.hex!(evidence[message]), ctx, lookup),
                 "#{inputs["label"]}: #{message}"
        end

        # The KEM pre-key decapsulates through the module the session uses
        # (the vector's ciphertext has no type byte; the session's has 0x08).
        assert Keys.kem_decapsulate(
                 Vectors.hex!(inputs["kem_secret_key"]),
                 <<8>> <> Vectors.hex!(inputs["kem_ciphertext"])
               ) == {:ok, Vectors.hex!(outputs["shared_secret"])}
      end
    end
  end

  test "rejects inputs of the wrong size" do
    {ek, dk} = Kyber1024.keypair()

    assert Kyber1024.encapsulate(binary_part(ek, 0, 1567), <<0::256>>) ==
             {:error, :invalid_encapsulation_key}

    assert Kyber1024.decapsulate(dk, <<0::size(1567 * 8)>>) == {:error, :invalid_ciphertext}

    assert Kyber1024.decapsulate(<<dk::binary, 0>>, <<0::size(1568 * 8)>>) ==
             {:error, :invalid_decapsulation_key}
  end
end
