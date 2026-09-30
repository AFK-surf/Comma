defmodule SalixSignalProto.MessagingOracleTest do
  # Level 2 and level 3 differential tests of layer C5 against the oracle
  # (ORACLE_INTERFACE.md sections 6.8 and 6.10): sealed sender v1 and v2 in
  # both directions, certificate parsing and validation, decryption error
  # messages, and sealed 1:1 messages through Comma's receive path. Sealing in
  # the oracle uses internal randomness, so every check is a round trip or a
  # comparison of deterministic results. Run with `--include signal_oracle`
  # and COMMA_SIGNAL_ORACLE=host:port.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.{Address, Keys, PreKeyBundle, Receive, SealedSender, ServiceId, Session}
  alias SalixSignalProto.Message.{Content, DecryptionError, Envelope, Padding}
  alias SalixSignalProto.SealedSender.{Certificate, Inner}
  alias SalixSignalProto.Test.{Oracle, Party}

  @moduletag :signal_oracle
  @moduletag timeout: 300_000

  @now 1_760_000_000_000

  # `sealed_sender.content_decode` reports the ciphertext type (3 for a
  # pre-key message), not the wire value of inner field 1 (CRS-06 §5).
  @oracle_message_type %{whisper: 2, prekey: 3, sender_key: 7, plaintext: 8}

  setup do
    {:ok, oracle: Oracle.connect!(), authority: Party.certificate_authority()}
  end

  defp text(value), do: {:text, value}
  defp store_name, do: "c5-#{System.unique_integer([:positive])}"
  defp aci(n), do: <<0::48, 0x40, 0x00, 0x80, 0x00, 0::40, n>>

  defp create_store(oracle, identity, registration_id \\ 1) do
    name = store_name()

    Oracle.call!(oracle, "store.create", %{
      store: text(name),
      identity_private: identity.private,
      registration_id: registration_id
    })

    name
  end

  defp wire_address(%Address{name: name, device_id: device_id}),
    do: %{name: name, device_id: device_id}

  defp inner_bytes(party, authority, type, content, hint, group_id) do
    certificate = Party.sender_certificate(party, authority, @now + 60_000)

    Inner.encode(%Inner{
      type: type,
      certificate: certificate,
      content: content,
      content_hint: hint,
      group_id: group_id
    })
  end

  describe "sealed sender v1" do
    property "Comma's sealed messages open in the oracle to the same inner message", %{
      oracle: oracle,
      authority: authority
    } do
      sender = Party.new(aci: aci(1), device_id: 2)
      recipient = Keys.ec_keypair()
      store = create_store(oracle, recipient)

      check all(
              type <- member_of([:whisper, :prekey, :sender_key, :plaintext]),
              content <- binary(min_length: 1, max_length: 300),
              hint <- member_of([0, 1, 2, 9]),
              group? <- boolean(),
              max_runs: 25
            ) do
        group_id = if group?, do: :crypto.strong_rand_bytes(32)
        inner = inner_bytes(sender, authority, type, content, hint, group_id)
        sealed = SealedSender.seal(inner, sender.identity, recipient.public)

        result =
          Oracle.call!(oracle, "sealed_sender.decrypt_to_content", %{
            store: text(store),
            ciphertext: sealed
          })

        assert Oracle.unhex(result["content"]) == inner
        assert result["message_type"] == @oracle_message_type[type]
        assert Oracle.unhex(result["contents"]) == content
        assert result["content_hint"] == hint
        assert result["group_id"] == (group_id && Oracle.hex(group_id))
      end
    end

    test "the oracle's sealed messages open in Comma", %{oracle: oracle, authority: authority} do
      sender = Party.new(aci: aci(2))
      recipient = Party.new(aci: aci(3))
      store = create_store(oracle, sender.identity)
      remote = wire_address(Party.address(recipient))

      Oracle.call!(oracle, "store.put_identity", %{
        store: text(store),
        address: remote,
        public: recipient.identity.public
      })

      {:ok, message} = DecryptionError.build(<<0x33>>, :sender_key, @now, 1)
      wrapper = DecryptionError.wrap(message)
      certificate = Party.sender_certificate(sender, authority, @now + 60_000)

      built =
        Oracle.call!(oracle, "sealed_sender.content_build", %{
          sender_certificate: certificate.serialized,
          content_hint: 2,
          source: %{"kind" => "plaintext_content", "message" => Oracle.hex(wrapper)}
        })

      content = Oracle.unhex(built["content"])

      sealed =
        Oracle.call!(oracle, "sealed_sender.encrypt", %{
          store: text(store),
          remote: remote,
          content: content
        })

      assert {:ok, opened} =
               SealedSender.open(Oracle.unhex(sealed["ciphertext"]), recipient.identity)

      assert opened.inner_bytes == content
      assert opened.sender_identity == sender.identity.public
      assert opened.inner.type == :plaintext
      assert opened.inner.content == wrapper
    end
  end

  describe "sealed sender v2" do
    property "the oracle splits Comma's upload into Comma's deliveries and opens them", %{
      oracle: oracle,
      authority: authority
    } do
      sender = Party.new(aci: aci(4))

      check all(
              count <- integer(1..3),
              device_lists <-
                list_of(uniq_list_of(integer(1..127), min_length: 1, max_length: 3),
                  length: count
                ),
              excluded? <- boolean(),
              max_runs: 10
            ) do
        recipients =
          for {devices, index} <- Enum.with_index(device_lists) do
            keys = Keys.ec_keypair()
            kind = if index == 2, do: :pni, else: :aci
            registration = for d <- devices, do: {d, :rand.uniform(16_383)}

            %{
              service_id: {kind, aci(10 + index)},
              identity_key: keys.public,
              devices: registration,
              keys: keys
            }
          end

        excluded = if excluded?, do: [{:aci, aci(20)}], else: []

        inner =
          inner_bytes(
            sender,
            authority,
            :sender_key,
            :crypto.strong_rand_bytes(40),
            1,
            :crypto.strong_rand_bytes(32)
          )

        upload =
          SealedSender.seal_multi(
            inner,
            sender.identity,
            Enum.map(recipients, &Map.delete(&1, :keys)),
            excluded: excluded
          )

        split = Oracle.call!(oracle, "sealed_sender.multi_recipient_split", %{ciphertext: upload})
        assert split["excluded"] == Enum.map(excluded, &ServiceId.to_string/1)

        {:ok, parsed} = SealedSender.parse_upload(upload)
        ours = Enum.sort_by(SealedSender.deliveries(parsed), &ServiceId.to_string(&1.service_id))
        assert length(split["recipients"]) == length(ours)

        for {theirs, mine} <- Enum.zip(split["recipients"], ours) do
          assert theirs["service_id"] == ServiceId.to_string(mine.service_id)
          assert theirs["device_ids"] == Enum.map(mine.devices, &elem(&1, 0))
          assert theirs["registration_ids"] == Enum.map(mine.devices, &elem(&1, 1))
          assert Oracle.unhex(theirs["message"]) == mine.delivery

          keys = Enum.find(recipients, &(&1.service_id == mine.service_id)).keys
          store = create_store(oracle, keys)

          opened =
            Oracle.call!(oracle, "sealed_sender.decrypt_to_content", %{
              store: text(store),
              ciphertext: mine.delivery
            })

          assert Oracle.unhex(opened["content"]) == inner
        end
      end
    end
  end

  describe "certificates" do
    property "decode and validation agree on mutated sender certificates (level 3)", %{
      oracle: oracle,
      authority: authority
    } do
      party = Party.new(aci: aci(5))
      valid = Party.sender_certificate(party, authority, @now).serialized

      check all(
              position <- integer(0..(byte_size(valid) - 1)),
              xor <- integer(1..255),
              time <- member_of([@now - 1, @now, @now + 1]),
              max_runs: 60
            ) do
        <<head::binary-size(^position), byte, tail::binary>> = valid
        mutated = <<head::binary, Bitwise.bxor(byte, xor), tail::binary>>

        comma =
          case Certificate.decode_sender(mutated) do
            {:ok, certificate} ->
              Certificate.validate(certificate, [authority.root.public], time) == :ok

            {:error, :malformed} ->
              false
          end

        oracle_valid =
          case Oracle.call(oracle, "sealed_sender.sender_certificate_validate", %{
                 certificate: mutated,
                 trust_roots: [Oracle.hex(authority.root.public)],
                 time: time
               }) do
            {:ok, %{"valid" => valid?}} -> valid?
            {:error, _kind} -> false
          end

        assert comma == oracle_valid
      end
    end

    test "the oracle's certificates decode and validate in Comma", %{oracle: oracle} do
      root = Keys.ec_keypair()
      server = Keys.ec_keypair()
      identity = Keys.ec_keypair()

      %{"certificate" => server_certificate} =
        Oracle.call!(oracle, "sealed_sender.server_certificate_create", %{
          key_id: 77,
          server_public: server.public,
          trust_root_private: root.private
        })

      %{"certificate" => sender_certificate} =
        Oracle.call!(oracle, "sealed_sender.sender_certificate_create", %{
          sender_uuid: text(ServiceId.uuid_string(aci(6))),
          sender_device_id: 9,
          sender_identity_public: identity.public,
          expiration: @now,
          server_certificate: {:text, server_certificate},
          server_private: server.private
        })

      {:ok, certificate} = Certificate.decode_sender(Oracle.unhex(sender_certificate))
      assert certificate.aci == aci(6)
      assert certificate.device_id == 9
      assert certificate.identity_key == identity.public
      assert Certificate.validate(certificate, [root.public], @now) == :ok
      assert Certificate.validate(certificate, [root.public], @now + 1) == {:error, :expired}
    end
  end

  describe "decryption error messages" do
    property "Comma builds and wraps the same messages as the oracle", %{oracle: oracle} do
      alice = Party.new(aci: aci(7), device_id: 2)
      bob = Party.new(aci: aci(8))

      {:ok, record} =
        Session.process_bundle(nil, Party.bundle(bob), Party.session_context(alice, bob))

      check all(
              plaintext <- binary(min_length: 1, max_length: 100),
              timestamp <- integer(0..9_000_000_000_000),
              device <- integer(1..127),
              max_runs: 25
            ) do
        {:ok, {3, prekey}, _record} =
          Session.encrypt(record, plaintext, Party.session_context(alice, bob))

        {:ok, decoded} = SalixSignalProto.Session.PreKeyMessage.decode(prekey)

        for {bytes, type, number} <- [
              {prekey, :prekey, 3},
              {decoded.message.serialized, :whisper, 2}
            ] do
          {:ok, ours} = DecryptionError.build(bytes, type, timestamp, device)

          %{"message" => theirs} =
            Oracle.call!(oracle, "message.decryption_error_create", %{
              original_message: bytes,
              original_type: number,
              original_timestamp: timestamp,
              original_sender_device_id: device
            })

          assert ours == Oracle.unhex(theirs)

          %{"message" => wrapped} =
            Oracle.call!(oracle, "message.plaintext_content_wrap", %{
              decryption_error_message: ours
            })

          assert DecryptionError.wrap(ours) == Oracle.unhex(wrapped)
        end
      end
    end
  end

  describe "sealed 1:1 messages end to end" do
    test "a sealed pre-key message from the oracle is a message in Comma's receive path", %{
      oracle: oracle,
      authority: authority
    } do
      alice = Party.new(aci: aci(30), device_id: 2)
      bob = Party.new(aci: aci(31))
      store = create_store(oracle, alice.identity, alice.registration_id)
      bundle = Party.bundle(bob)

      Oracle.call!(oracle, "session.process_bundle", %{
        store: text(store),
        remote: wire_address(Party.address(bob)),
        local_address: wire_address(Party.address(alice)),
        bundle: %{
          "registration_id" => bundle.registration_id,
          "device_id" => bundle.device_id,
          "identity_public" => Oracle.hex(bundle.identity_key),
          "prekey_id" => bundle.one_time_pre_key_id,
          "prekey_public" => Oracle.hex(bundle.one_time_pre_key),
          "signed_prekey_id" => bundle.signed_pre_key_id,
          "signed_prekey_public" => Oracle.hex(bundle.signed_pre_key),
          "signed_prekey_signature" => Oracle.hex(bundle.signed_pre_key_signature),
          "kem_prekey_id" => bundle.kem_pre_key_id,
          "kem_prekey_public" => Oracle.hex(bundle.kem_pre_key),
          "kem_prekey_signature" => Oracle.hex(bundle.kem_pre_key_signature)
        }
      })

      padded = Padding.pad(Content.text(@now, "from the oracle"))
      certificate = Party.sender_certificate(alice, authority, @now + 60_000)

      built =
        Oracle.call!(oracle, "sealed_sender.content_build", %{
          sender_certificate: certificate.serialized,
          content_hint: 1,
          source: %{
            "kind" => "session",
            "store" => store,
            "remote" => wire_address(Party.address(bob)),
            "plaintext" => Oracle.hex(padded),
            "local_address" => wire_address(Party.address(alice))
          }
        })

      sealed =
        Oracle.call!(oracle, "sealed_sender.encrypt", %{
          store: text(store),
          remote: wire_address(Party.address(bob)),
          content: Oracle.unhex(built["content"])
        })

      envelope = %Envelope{
        kind: 6,
        client_timestamp: @now,
        payload: Oracle.unhex(sealed["ciphertext"]),
        destination: {:aci, bob.aci},
        server_guid: :crypto.strong_rand_bytes(16)
      }

      result = Receive.open(envelope, Party.receive_context(bob, [authority.root.public], @now))
      assert result.outcome == :message
      assert result.content.data_message.body == "from the oracle"
      assert {result.sender, result.sender_device, result.content_hint} == {alice.aci, 2, 1}
    end

    test "Comma's sealed pre-key message decrypts in the oracle", %{
      oracle: oracle,
      authority: authority
    } do
      alice = Party.new(aci: aci(32))
      bob_identity = Keys.ec_keypair()
      store = create_store(oracle, bob_identity, 4321)
      Oracle.call!(oracle, "store.put_prekey", %{store: text(store), id: 5})
      Oracle.call!(oracle, "store.put_signed_prekey", %{store: text(store), id: 6})
      Oracle.call!(oracle, "store.put_kem_prekey", %{store: text(store), id: 7})

      %{"bundle" => wire} =
        Oracle.call!(oracle, "store.bundle", %{
          store: text(store),
          device_id: 1,
          prekey_id: 5,
          signed_prekey_id: 6,
          kem_prekey_id: 7
        })

      bundle = %PreKeyBundle{
        registration_id: wire["registration_id"],
        device_id: wire["device_id"],
        identity_key: Oracle.unhex(wire["identity_public"]),
        one_time_pre_key_id: wire["prekey_id"],
        one_time_pre_key: Oracle.unhex(wire["prekey_public"]),
        signed_pre_key_id: wire["signed_prekey_id"],
        signed_pre_key: Oracle.unhex(wire["signed_prekey_public"]),
        signed_pre_key_signature: Oracle.unhex(wire["signed_prekey_signature"]),
        kem_pre_key_id: wire["kem_prekey_id"],
        kem_pre_key: Oracle.unhex(wire["kem_prekey_public"]),
        kem_pre_key_signature: Oracle.unhex(wire["kem_prekey_signature"])
      }

      bob_uuid = aci(33)
      bob = Address.new(ServiceId.to_string({:aci, bob_uuid}), 1)

      context = %{
        identity: alice.identity,
        registration_id: alice.registration_id,
        local_address: Party.address(alice),
        remote_address: bob,
        trusted?: fn _, _ -> true end
      }

      {:ok, record} = Session.process_bundle(nil, bundle, context)
      padded = Padding.pad(Content.text(@now, "from Comma"))
      {:ok, {3, prekey}, _record} = Session.encrypt(record, padded, context)
      inner = inner_bytes(alice, authority, :prekey, prekey, 1, nil)
      sealed = SealedSender.seal(inner, alice.identity, bundle.identity_key)

      result =
        Oracle.call!(oracle, "sealed_sender.decrypt", %{
          store: text(store),
          ciphertext: sealed,
          trust_root: authority.root.public,
          timestamp: @now,
          local_uuid: text(ServiceId.uuid_string(bob_uuid)),
          local_device_id: 1
        })

      assert Oracle.unhex(result["plaintext"]) == padded
      assert result["sender_uuid"] == ServiceId.uuid_string(alice.aci)
    end
  end
end
