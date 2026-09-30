defmodule SalixSignalProto.SealedSenderTest do
  # Sealed sender (CRS-06) against the CRS-06 vectors access-key.json,
  # combined-access-key.json, known-constants.json, server-certificate.json,
  # sender-certificate.json, sealed-sender-v1-decrypt.json and
  # sealed-sender-v2.json.
  use ExUnit.Case, async: true

  alias SalixSignalProto.{Keys, SealedSender, ServiceId}
  alias SalixSignalProto.SealedSender.{AccessKey, Certificate, Inner}
  alias SalixSignalProto.Test.Vectors

  defp cases(file), do: Vectors.load!("crs/CRS-06/" <> file)["cases"]
  defp hex(nil), do: nil
  defp hex(value), do: Vectors.hex!(value)

  defp identity(private, public), do: %{private: hex(private), public: hex(public)}

  describe "unidentified access keys (access-key, combined-access-key)" do
    test "derived from the profile key, with the header value" do
      for %{"inputs" => %{"profile_key" => key}, "outputs" => outputs} <- cases("access-key.json") do
        access_key = AccessKey.derive(hex(key))
        assert access_key == hex(outputs["access_key"])
        assert AccessKey.header(access_key) == outputs["header_value"]
      end
    end

    test "the legacy multi-recipient key is the XOR of restricted recipients' keys" do
      for %{"inputs" => %{"access_keys" => keys}, "outputs" => outputs} <-
            cases("combined-access-key.json") do
        combined = AccessKey.combine(Enum.map(keys, &hex/1))
        assert combined == hex(outputs["combined"])
        assert AccessKey.header(combined) == outputs["header_value"]
      end
    end
  end

  describe "certificates" do
    test "trust roots and known server certificates (known-constants)" do
      vectors = cases("known-constants.json")

      roots =
        Map.new(
          for c <- vectors,
              c["inputs"]["base64"],
              do: {c["label"], hex(c["outputs"]["public_key"])}
        )

      for c <- vectors, base64 = c["inputs"]["base64"] do
        assert Keys.parse_ec_public(Base.decode64!(base64)) ==
                 {:ok, hex(c["outputs"]["public_key"])}
      end

      assert Certificate.trust_roots(:production) == [
               roots["production trust root A"],
               roots["production trust root B"]
             ]

      assert Certificate.trust_roots(:staging) == [
               roots["staging trust root A"],
               roots["staging trust root B"]
             ]

      for c <- vectors, bytes = c["inputs"]["server_certificate"] do
        {:ok, server} = Certificate.decode_server(hex(bytes))
        assert server.key_id == c["outputs"]["key_id"]
        assert server.key == hex(c["outputs"]["server_public"])
        root = roots[c["inputs"]["trust_root"]]

        assert Keys.verify_signature(root, server.body, server.signature) ==
                 c["outputs"]["verifies"]

        environment = if server.key_id == 2, do: :staging, else: :production

        assert Certificate.known_server_certificates(environment)[server.key_id].serialized ==
                 hex(bytes)
      end
    end

    test "server certificates decode and verify (server-certificate)" do
      for %{"inputs" => inputs, "outputs" => outputs} = vector <- cases("server-certificate.json") do
        {:ok, server} = Certificate.decode_server(hex(inputs["server_certificate"]))
        assert server.key_id == outputs["key_id"], vector["label"]
        assert server.key == hex(outputs["server_public"])
        assert server.body == hex(outputs["certificate_data"])
        assert server.signature == hex(outputs["signature"])

        assert Keys.verify_signature(
                 hex(inputs["trust_root_public"]),
                 server.body,
                 server.signature
               ) ==
                 outputs["signature_verifies"]

        assert Certificate.revoked?(server.key_id) == not outputs["accepted_as_signer"]
      end
    end

    test "sender certificates decode and validate (sender-certificate)" do
      for %{"inputs" => inputs, "outputs" => outputs} = vector <- cases("sender-certificate.json") do
        {:ok, certificate} = Certificate.decode_sender(hex(inputs["sender_certificate"]))
        roots = Enum.map(inputs["trust_roots"], &hex/1)
        validation = Certificate.validate(certificate, roots, inputs["validation_time"])
        assert validation == :ok == outputs["valid"], vector["label"]

        if outputs["sender_uuid"] do
          assert ServiceId.uuid_string(certificate.aci) == outputs["sender_uuid"]
          assert certificate.e164 == outputs["sender_e164"]
          assert certificate.device_id == outputs["sender_device"]
          assert certificate.expiration == outputs["expiration"]
          assert certificate.identity_key == hex(outputs["identity_key"])
          assert certificate.body == hex(outputs["certificate_data"])
          assert certificate.signature == hex(outputs["signature"])
          assert {:embedded, %{key_id: key_id}} = certificate.signer
          assert key_id == outputs["signer_key_id"]
        end

        if outputs["reason"] do
          assert certificate.signer == {:reference, 0x1234}
          assert validation == {:error, :unknown_signer}
        end
      end
    end

    test "a referenced signer resolves through the known certificates" do
      root = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      server = Keys.ec_keypair(:crypto.strong_rand_bytes(32))

      {:ok, server_certificate} =
        Certificate.decode_server(Certificate.issue_server(7, server.public, root.private))

      sender = Keys.ec_keypair(:crypto.strong_rand_bytes(32))

      fields = %{
        device_id: 3,
        expiration: 2_000,
        identity_key: sender.public,
        aci: <<1::128>>,
        signer: {:reference, 7}
      }

      {:ok, certificate} =
        Certificate.decode_sender(Certificate.issue_sender(fields, server.private))

      assert Certificate.validate(certificate, [root.public], 1_000, %{7 => server_certificate}) ==
               :ok

      assert Certificate.validate(certificate, [root.public], 1_000, %{}) ==
               {:error, :unknown_signer}

      assert Certificate.validate(certificate, [root.public], 2_001, %{7 => server_certificate}) ==
               {:error, :expired}

      {:ok, revoked} =
        Certificate.decode_server(
          Certificate.issue_server(0xDEADC357, server.public, root.private)
        )

      assert Certificate.validate(certificate, [root.public], 1_000, %{7 => revoked}) ==
               {:error, :revoked}
    end

    test "sender certificates with missing, extra or out-of-range fields fail to parse" do
      server = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      identity = Keys.ec_keypair(:crypto.strong_rand_bytes(32)).public

      base = %{
        device_id: 3,
        expiration: 2_000,
        identity_key: identity,
        aci: <<1::128>>,
        signer: {:reference, 7}
      }

      assert {:ok, _} = Certificate.decode_sender(Certificate.issue_sender(base, server.private))

      assert {:error, :malformed} =
               Certificate.decode_sender(
                 Certificate.issue_sender(%{base | device_id: 0}, server.private)
               )

      assert {:error, :malformed} =
               Certificate.decode_sender(
                 Certificate.issue_sender(%{base | device_id: 128}, server.private)
               )

      assert {:error, :malformed} =
               Certificate.decode_sender(
                 Certificate.issue_sender(%{base | aci: <<1::120>>}, server.private)
               )

      assert {:error, :malformed} = Certificate.decode_sender(<<0x0A, 0>>)
    end
  end

  describe "sealed sender v1 (sealed-sender-v1-decrypt)" do
    test "opens every positive vector with the stated intermediate keys" do
      for %{"inputs" => inputs, "outputs" => outputs} = vector <-
            cases("sealed-sender-v1-decrypt.json"),
          !outputs["error"] do
        recipient =
          identity(inputs["recipient_identity_private"], inputs["recipient_identity_public"])

        assert {:ok, opened} = SealedSender.open(hex(inputs["sealed_message"]), recipient),
               vector["label"]

        assert opened.inner_bytes == hex(outputs["inner"])

        if ephemeral = outputs["ephemeral_public"] do
          {:ok, shared} = Keys.agree(recipient.private, hex(ephemeral))
          stage1 = SealedSender.stage1(shared, recipient.public, hex(ephemeral))
          assert stage1.chain_key == hex(outputs["stage1_chain_key"])
          assert stage1.cipher_key == hex(outputs["stage1_cipher_key"])
          assert stage1.mac_key == hex(outputs["stage1_mac_key"])
          assert opened.sender_identity == hex(outputs["sender_identity_public"])

          inner = opened.inner
          assert Inner.type_number(inner.type) == outputs["inner_type"]
          assert inner.content_hint == outputs["inner_content_hint"]
          assert inner.group_id == hex(outputs["inner_group_id"])
          assert inner.content == hex(outputs["inner_content"])
          assert ServiceId.uuid_string(inner.certificate.aci) == outputs["sender_uuid"]
          assert inner.certificate.device_id == outputs["sender_device"]
          assert inner.certificate.expiration == outputs["certificate_expiration"]
          # The inner message re-encodes to the same bytes, unknown hints included.
          assert Inner.encode(inner) == opened.inner_bytes

          if outputs["certificate_valid"] do
            assert Certificate.validate(
                     inner.certificate,
                     [hex(inputs["trust_root_public"])],
                     inputs["validation_time"]
                   ) ==
                     :ok
          end
        end
      end
    end

    test "rejects every negative vector" do
      expected = %{
        "rejected: unknown version (high nibble 3)" => :unknown_version,
        "rejected: encrypted message failed its MAC check" => :bad_mac,
        "rejected: encrypted static key failed its MAC check" => :bad_mac,
        "rejected: sender certificate identity key differs from the decrypted static key" =>
          :identity_mismatch
      }

      for %{"inputs" => inputs, "outputs" => %{"error" => true} = outputs} = vector <-
            cases("sealed-sender-v1-decrypt.json") do
        recipient =
          identity(inputs["recipient_identity_private"], inputs["recipient_identity_public"])

        assert SealedSender.open(hex(inputs["sealed_message"]), recipient) ==
                 {:error, Map.fetch!(expected, outputs["reason"])},
               vector["label"]
      end
    end

    test "Comma seals and opens its own messages" do
      sender = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      recipient = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      inner = inner_bytes(sender.public)

      sealed = SealedSender.seal(inner, sender, recipient.public, ephemeral_private: <<7::256>>)
      assert <<0x11, _::binary>> = sealed

      assert SealedSender.seal(inner, sender, recipient.public, ephemeral_private: <<7::256>>) ==
               sealed

      assert {:ok, %{inner_bytes: ^inner, sender_identity: sender_public}} =
               SealedSender.open(sealed, recipient)

      assert sender_public == sender.public

      # Encrypted static is 43 bytes and the message MAC is 10 bytes (§7.1).
      <<0x11, proto::binary>> = sealed
      wire = SalixSignalProto.SealedSender.Wire.V1.decode(proto)
      assert byte_size(wire.encrypted_static) == 43
      assert byte_size(wire.encrypted_message) == byte_size(inner) + 10

      other = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      assert SealedSender.open(sealed, other) == {:error, :bad_mac}
    end
  end

  defp inner_bytes(sender_public) do
    server = Keys.ec_keypair(:crypto.strong_rand_bytes(32))

    certificate =
      Certificate.issue_sender(
        %{
          device_id: 2,
          expiration: 10_000,
          identity_key: sender_public,
          aci: <<9::128>>,
          signer: {:reference, 1}
        },
        server.private
      )

    {:ok, certificate} = Certificate.decode_sender(certificate)

    Inner.encode(%Inner{
      type: :whisper,
      certificate: certificate,
      content: "ciphertext",
      content_hint: 1
    })
  end

  describe "sealed sender v2 (sealed-sender-v2)" do
    test "the service's parse and fan-out give the stated deliveries, which open" do
      for %{"inputs" => inputs, "outputs" => outputs} = vector <- cases("sealed-sender-v2.json"),
          outputs["recipients"] do
        upload = hex(outputs["upload"])
        assert <<version, _::binary>> = upload
        assert version == outputs["version_byte"]
        assert {:ok, parsed} = SealedSender.parse_upload(upload), vector["label"]
        assert Enum.map(parsed.excluded, &ServiceId.to_string/1) == outputs["parsed_excluded"]

        deliveries = SealedSender.deliveries(parsed)
        assert length(deliveries) == length(outputs["recipients"])

        for {delivery, expected} <- Enum.zip(deliveries, outputs["recipients"]) do
          assert ServiceId.to_string(delivery.service_id) == expected["service_id"]
          assert Enum.map(delivery.devices, &elem(&1, 0)) == expected["device_ids"]
          assert Enum.map(delivery.devices, &elem(&1, 1)) == expected["registration_ids"]
          assert delivery.delivery == hex(expected["delivery"])

          derived = expected["derived"]

          assert SealedSender.seed_keys(hex(derived["seed"])) == %{
                   x: hex(derived["ephemeral_scalar"]),
                   k: hex(derived["aead_key"])
                 }

          recipient =
            identity(
              expected["recipient_identity_private"],
              expected["recipient_identity_public"]
            )

          assert {:ok, opened} = SealedSender.open(delivery.delivery, recipient)
          assert opened.inner_bytes == hex(derived["inner"])
          assert opened.inner_bytes == hex(inputs["inner"])
          assert opened.sender_identity == hex(inputs["sender_identity_public"])
          assert Inner.type_number(opened.inner.type) == expected["inner_type"]
          assert opened.inner.content_hint == expected["inner_content_hint"]
          assert opened.inner.group_id == hex(expected["inner_group_id"])
          assert opened.inner.content == hex(expected["inner_content"])
        end
      end
    end

    test "a single-recipient upload converts to its delivery" do
      [%{"inputs" => %{"upload" => upload}, "outputs" => %{"delivery" => delivery}}] =
        for c <- cases("sealed-sender-v2.json"), c["outputs"]["delivery"], do: c

      {:ok, parsed} = SealedSender.parse_upload(hex(upload))
      assert [%{delivery: bytes}] = SealedSender.deliveries(parsed)
      assert bytes == hex(delivery)
    end

    test "rejects every negative vector" do
      expected = %{
        "rejected: sender tag mismatch" => :bad_tag,
        "rejected: derived ephemeral key differs from the key in the message" => :wrong_recipient,
        "rejected: AEAD tag check failed" => :decryption_failed,
        "rejected: unknown version (high nibble 3)" => :unknown_version,
        "rejected: unknown version (byte 0x21)" => :unknown_version,
        "rejected: malformed upload" => :malformed,
        "rejected: empty upload" => :empty
      }

      for %{"inputs" => inputs, "outputs" => %{"error" => true, "reason" => reason}} = vector <-
            cases("sealed-sender-v2.json") do
        result =
          case inputs do
            %{"upload" => upload} ->
              SealedSender.parse_upload(hex(upload))

            %{"delivery" => delivery} ->
              recipient =
                identity(
                  inputs["recipient_identity_private"],
                  inputs["recipient_identity_public"]
                )

              SealedSender.open(hex(delivery), recipient)
          end

        assert result == {:error, Map.fetch!(expected, reason)}, vector["label"]
      end
    end

    test "Comma's upload parses, fans out and opens for each recipient" do
      sender = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      alice = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      bob = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      inner = inner_bytes(sender.public)

      recipients = [
        %{
          service_id: {:aci, <<1::128>>},
          identity_key: alice.public,
          devices: [{1, 16_383}, {4, 7}]
        },
        %{service_id: {:pni, <<2::128>>}, identity_key: bob.public, devices: [{2, 0}]}
      ]

      upload =
        SealedSender.seal_multi(inner, sender, recipients,
          excluded: [{:aci, <<3::128>>}],
          seed: <<5::256>>
        )

      assert <<0x23, 3, _::binary>> = upload

      {:ok, parsed} = SealedSender.parse_upload(upload)
      assert parsed.excluded == [{:aci, <<3::128>>}]
      [to_alice, to_bob] = SealedSender.deliveries(parsed)
      assert to_alice.devices == [{1, 16_383}, {4, 7}]
      assert {:ok, %{inner_bytes: ^inner}} = SealedSender.open(to_alice.delivery, alice)
      assert {:ok, %{inner_bytes: ^inner}} = SealedSender.open(to_bob.delivery, bob)
      assert SealedSender.open(to_bob.delivery, alice) == {:error, :wrong_recipient}

      assert_raise ArgumentError, fn ->
        SealedSender.seal_multi(inner, sender, [%{hd(recipients) | devices: [{1, 16_384}]}])
      end
    end

    test "an upload that names a service ID as recipient and as excluded is rejected" do
      sender = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      alice = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
      id = {:aci, <<1::128>>}

      upload =
        SealedSender.seal_multi(
          "x",
          sender,
          [%{service_id: id, identity_key: alice.public, devices: [{1, 1}]}],
          excluded: [id]
        )

      assert SealedSender.parse_upload(upload) == {:error, :conflicting}
    end
  end
end
