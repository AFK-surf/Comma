defmodule SalixSignalProto.ReceiveTest do
  # The receive path of one envelope (CRS-05 §3, §4, §7; CRS-06 §9; CRS-07
  # §5.4, §6): a full sealed pre-key decryption from
  # vectors/CRS-06/sealed-sender-v1-decrypt.json, and Comma-to-Comma envelopes
  # for each outcome class.
  use ExUnit.Case, async: true

  alias SalixSignalProto.{Keys, Receive, SealedSender, ServiceId, Session}
  alias SalixSignalProto.Message.{Content, DecryptionError, Envelope, Padding, Wire}
  alias SalixSignalProto.SealedSender.Inner
  alias SalixSignalProto.Test.{Party, Vectors}

  @t 1_727_222_400_000

  defp hex(nil), do: nil
  defp hex(value), do: Vectors.hex!(value)

  describe "sealed pre-key message from the CRS-06 vector" do
    setup do
      [vector | _] = Vectors.load!("crs/CRS-06/sealed-sender-v1-decrypt.json")["cases"]
      inputs = vector["inputs"]
      {:ok, aci} = ServiceId.aci_from_string(inputs["recipient_aci"])

      pre_keys = fn
        {:signed_pre_key, 7} -> {:ok, hex(inputs["recipient_signed_prekey_private"])}
        {:one_time_pre_key, 11} -> {:ok, hex(inputs["recipient_one_time_prekey_private"])}
        {:kem_pre_key, 13} -> {:ok, hex(inputs["recipient_kyber_secret_key"])}
        {:kem_pre_key_used?, _, _, _} -> false
        _ -> :error
      end

      context = %{
        aci: aci,
        pni: nil,
        device_id: inputs["recipient_device_id"],
        identities: %{
          aci: %{
            private: hex(inputs["recipient_identity_private"]),
            public: hex(inputs["recipient_identity_public"])
          }
        },
        registration_ids: %{aci: inputs["recipient_registration_id"]},
        trust_roots: [hex(inputs["trust_root_public"])],
        known_server_certificates: %{},
        now_ms: inputs["validation_time"],
        session: fn _address -> nil end,
        pre_keys: fn :aci -> pre_keys end
      }

      envelope = %Envelope{
        kind: 6,
        client_timestamp: 1000,
        server_timestamp: 1001,
        payload: hex(inputs["sealed_message"]),
        destination: {:aci, aci},
        server_guid: <<1::128>>
      }

      %{context: context, envelope: envelope, outputs: vector["outputs"]}
    end

    test "opens and decrypts with the recipient's pre-keys", ctx do
      # The sealed layer and the pre-key decryption give the vector's padded
      # plaintext.
      {:ok, opened} = SealedSender.open(ctx.envelope.payload, ctx.context.identities.aci)

      sender =
        SalixSignalProto.Address.new(ServiceId.to_string({:aci, opened.inner.certificate.aci}), 2)

      local = SalixSignalProto.Address.new(ServiceId.to_string({:aci, ctx.context.aci}), 1)

      session_context = %{
        identity: ctx.context.identities.aci,
        registration_id: 2222,
        local_address: local,
        remote_address: sender,
        trusted?: fn _, _ -> true end
      }

      assert {:ok, padded, _record, effects} =
               Session.decrypt_pre_key(
                 nil,
                 opened.inner.content,
                 session_context,
                 ctx.context.pre_keys.(:aci)
               )

      assert padded == hex(ctx.outputs["decrypted_padded_content"])
      assert Padding.unpad(padded) == {:ok, hex(ctx.outputs["decrypted_content_unpadded"])}
      assert effects.used_one_time_pre_key == 11

      # The republished vector's content container (CRS-06 section 11, answer
      # to question C5-3) is a data message with body "hello" and timestamp
      # 1000, the envelope's client timestamp.
      result = Receive.open(ctx.envelope, ctx.context)

      assert {:ok, :data, wire} = Content.decode(hex(ctx.outputs["decrypted_content_unpadded"]))
      assert %{body: "hello", timestamp: 1000} = wire.data_message
      assert result.outcome == :message
      assert result.content_kind == :data
      assert result.content == wire

      assert result.sealed?
      assert ServiceId.uuid_string(result.sender) == ctx.outputs["full_decrypt_sender_uuid"]
      assert result.sender_device == ctx.outputs["full_decrypt_sender_device"]
      assert result.content_hint == 1
      assert result.group_id == hex(ctx.outputs["inner_group_id"])
      assert result.session.effects.used_one_time_pre_key == 11
      assert result.session.effects.used_kem_pre_key.id == 13
      assert result.session.address.device_id == 2
    end

    test "an expired certificate and a self-send are dropped", ctx do
      expired =
        Receive.open(ctx.envelope, %{
          ctx.context
          | now_ms: ctx.outputs["certificate_expiration"] + 1
        })

      assert {expired.outcome, expired.reason} == {:drop, {:certificate, :expired}}

      {:ok, sender} = ServiceId.aci_from_string(ctx.outputs["sender_uuid"])
      self_context = %{ctx.context | aci: sender, device_id: ctx.outputs["sender_device"]}
      self_send = Receive.open(%{ctx.envelope | destination: {:aci, sender}}, self_context)
      assert {self_send.outcome, self_send.reason} == {:drop, :self_send}
    end
  end

  describe "Comma-to-Comma envelopes" do
    setup do
      alice = Party.new(device_id: 2)
      bob = Party.new()
      authority = Party.certificate_authority()

      {:ok, record} =
        Session.process_bundle(nil, Party.bundle(bob), Party.session_context(alice, bob))

      alice = Party.put_session(alice, Party.address(bob), record)
      %{alice: alice, bob: bob, authority: authority}
    end

    defp encrypt(alice, bob, content) do
      address = Party.address(bob)
      record = Map.fetch!(alice.sessions, address)

      {:ok, {type, bytes}, record} =
        Session.encrypt(record, Padding.pad(content), Party.session_context(alice, bob))

      {type, bytes, Party.put_session(alice, address, record)}
    end

    defp identified(alice, bob, type, bytes, timestamp \\ @t) do
      %Envelope{
        kind: if(type == 2, do: 1, else: 3),
        client_timestamp: timestamp,
        source: {:aci, alice.aci},
        source_device: alice.device_id,
        payload: bytes,
        destination: {:aci, bob.aci},
        server_guid: :crypto.strong_rand_bytes(16)
      }
    end

    defp sealed(alice, bob, authority, inner_type, bytes, opts \\ []) do
      certificate =
        Party.sender_certificate(
          alice,
          authority,
          Keyword.get(opts, :expiration, @t + 1000),
          Keyword.get(opts, :e164)
        )

      inner =
        Inner.encode(%Inner{
          type: inner_type,
          certificate: certificate,
          content: bytes,
          content_hint: Keyword.get(opts, :hint, 1),
          group_id: Keyword.get(opts, :group_id)
        })

      %Envelope{
        kind: 6,
        client_timestamp: Keyword.get(opts, :timestamp, @t),
        payload: SealedSender.seal(inner, alice.identity, bob.identity.public),
        destination: {:aci, bob.aci},
        server_guid: :crypto.strong_rand_bytes(16)
      }
    end

    defp context(bob, authority), do: Party.receive_context(bob, [authority.root.public], @t)

    defp commit(party, %Receive.Result{session: %{address: address, record: record}}),
      do: Party.put_session(party, address, record)

    test "an identified pre-key message, then a sealed reply, decrypt as messages", %{
      alice: alice,
      bob: bob,
      authority: authority
    } do
      {3, bytes, alice} = encrypt(alice, bob, Content.text(@t, "first"))

      result =
        Receive.open(Envelope.encode(identified(alice, bob, 3, bytes)), context(bob, authority))

      assert result.outcome == :message
      refute result.sealed?
      assert {result.sender, result.sender_device} == {alice.aci, 2}
      assert result.content.data_message.body == "first"
      bob = commit(bob, result)

      # The duplicate of the same envelope is dropped silently (CRS-07 §5.4).
      duplicate = Receive.open(identified(alice, bob, 3, bytes), context(bob, authority))
      assert {duplicate.outcome, duplicate.reason} == {:drop, :duplicate}

      # Bob answers sealed; Alice's pending session ends when she decrypts it.
      {2, reply, _bob} = encrypt(bob, alice, Content.text(@t + 1, "reply"))
      envelope = sealed(bob, alice, authority, :whisper, reply, timestamp: @t + 1)
      result = Receive.open(envelope, Party.receive_context(alice, [authority.root.public], @t))
      assert result.outcome == :message
      assert result.sealed?
      assert result.content.data_message.body == "reply"
      assert result.content_hint == 1
    end

    # CRS-06 §9: a certificate that names the local ACI, or an E.164 equal
    # to the local one, together with the local device ID is a self-send.
    test "a certificate with the local number and device is a self-send", %{
      alice: alice,
      bob: bob,
      authority: authority
    } do
      {3, bytes, _alice} = encrypt(alice, bob, Content.text(@t, "echo"))
      number = "+15550100002"
      same_device = %{context(bob, authority) | device_id: alice.device_id}

      open = fn certificate_e164, local_e164 ->
        envelope = sealed(alice, bob, authority, :prekey, bytes, e164: certificate_e164)
        Receive.open(envelope, Map.put(same_device, :e164, local_e164))
      end

      # Past the self-send check the message goes on to decryption; the
      # changed local device ID makes that fail, which is not a drop.
      assert %{outcome: :drop, reason: :self_send} = open.(number, number)
      assert open.("+15550100009", number).outcome == :failed
      assert open.(nil, nil).outcome == :failed
      assert open.(number, nil).outcome == :failed

      # The local number on another device is not a self-send.
      other_device = Map.put(context(bob, authority), :e164, number)
      envelope = sealed(alice, bob, authority, :prekey, bytes, e164: number)
      assert Receive.open(envelope, other_device).outcome == :message
    end

    test "a message that does not decrypt fails with the inputs of a retry request", %{
      alice: alice,
      bob: bob,
      authority: authority
    } do
      {3, first, alice} = encrypt(alice, bob, Content.text(@t, "first"))
      bob = commit(bob, Receive.open(identified(alice, bob, 3, first), context(bob, authority)))

      {3, second, alice} = encrypt(alice, bob, Content.text(@t + 5, "second"))
      {:ok, prekey} = SalixSignalProto.Session.PreKeyMessage.decode(second)
      inner = prekey.message.serialized

      inner =
        binary_part(inner, 0, byte_size(inner) - 1) <> <<Bitwise.bxor(:binary.last(inner), 1)>>

      tampered =
        SalixSignalProto.Session.PreKeyMessage.encode(%{Map.from_struct(prekey) | message: inner})

      result =
        Receive.open(
          sealed(alice, bob, authority, :prekey, tampered, timestamp: @t + 5),
          context(bob, authority)
        )

      assert result.outcome == :failed
      assert result.failed == %{type: :prekey, message: tampered}
      assert result.session == nil
      assert {:ok, message} = Receive.retry_request(result)

      expected_timestamp = @t + 5

      assert {:ok,
              %DecryptionError{
                timestamp: ^expected_timestamp,
                device_id: 2,
                ratchet_key: ratchet_key
              }} =
               DecryptionError.decode(message)

      # The requester names Alice's current sending ratchet key, so Alice
      # stops using that session (CRS-07 §6.3).
      {:ok, dem} = DecryptionError.decode(message)
      record = alice.sessions[Party.address(bob)]
      assert record.current.sender.public == ratchet_key
      assert {:reset_session, reset} = Receive.handle_retry_request(dem, 2, record)
      assert reset.current == nil
      assert Receive.handle_retry_request(dem, 3, record) == :ignore
      assert Receive.handle_retry_request(%{dem | ratchet_key: nil}, 2, record) == :sender_key
    end

    test "decrypted content that fails the rules is dropped, bad padding fails", %{
      alice: alice,
      bob: bob,
      authority: authority
    } do
      {3, bytes, alice} = encrypt(alice, bob, Content.text(@t + 1, "wrong timestamp"))
      result = Receive.open(identified(alice, bob, 3, bytes), context(bob, authority))
      assert {result.outcome, result.reason} == {:drop, {:invalid_content, :timestamp_mismatch}}
      # The message key is used, so the new record is still committed.
      assert %{record: _} = result.session
      bob = commit(bob, result)

      record = alice.sessions[Party.address(bob)]

      {:ok, {3, bad}, _record} =
        Session.encrypt(record, "no terminator" <> <<1>>, Party.session_context(alice, bob))

      result = Receive.open(identified(alice, bob, 3, bad), context(bob, authority))
      assert {result.outcome, result.reason} == {:failed, :bad_padding}
      assert %{record: _} = result.session
    end

    test "without a session a 1:1 message fails; an unknown version is unsupported", %{
      alice: alice,
      bob: bob,
      authority: authority
    } do
      {3, bytes, _alice} = encrypt(alice, bob, Content.text(@t, "x"))
      {:ok, prekey} = SalixSignalProto.Session.PreKeyMessage.decode(bytes)

      result =
        Receive.open(
          identified(alice, bob, 2, prekey.message.serialized),
          context(bob, authority)
        )

      assert {result.outcome, result.reason} == {:failed, :no_session}

      legacy = <<0x22>> <> binary_part(bytes, 1, byte_size(bytes) - 1)
      result = Receive.open(identified(alice, bob, 3, legacy), context(bob, authority))
      assert {result.outcome, result.reason} == {:unsupported, :legacy_version}
    end

    test "a sender-key message without sender-key state fails without a ratchet key", %{
      alice: alice,
      bob: bob,
      authority: authority
    } do
      group_id = :crypto.strong_rand_bytes(32)
      envelope = sealed(alice, bob, authority, :sender_key, <<0x33, 1, 2, 3>>, group_id: group_id)
      result = Receive.open(envelope, context(bob, authority))

      assert {result.outcome, result.reason} == {:failed, :no_sender_key_state}
      assert result.group_id == group_id
      {:ok, message} = Receive.retry_request(result)

      assert {:ok, %DecryptionError{ratchet_key: nil, timestamp: @t, device_id: 2}} =
               DecryptionError.decode(message)

      decrypt = fn address, <<0x33, _::binary>>, ^group_id ->
        assert address.device_id == 2

        {:ok,
         Padding.pad(Content.text(@t, "group", group: %{master_key: <<1::256>>, revision: 1})),
         :new_state}
      end

      result = Receive.open(envelope, Map.put(context(bob, authority), :sender_key, decrypt))
      assert result.outcome == :message
      assert result.sender_key == :new_state
    end

    test "plaintext wrappers carry decryption error messages", %{
      alice: alice,
      bob: bob,
      authority: authority
    } do
      {:ok, message} = DecryptionError.build(<<0x33>>, :sender_key, @t, 1)
      wrapper = DecryptionError.wrap(message)

      identified = %Envelope{
        kind: 8,
        client_timestamp: @t + 9,
        source: {:aci, alice.aci},
        source_device: 2,
        payload: wrapper,
        destination: {:aci, bob.aci}
      }

      result = Receive.open(identified, context(bob, authority))
      assert {result.outcome, result.content_kind} == {:message, :decryption_error}
      assert result.content.decryption_error == message

      result =
        Receive.open(
          sealed(alice, bob, authority, :plaintext, wrapper, hint: 2),
          context(bob, authority)
        )

      assert {result.outcome, result.content_kind, result.content_hint} ==
               {:message, :decryption_error, 2}

      bad = Receive.open(%{identified | payload: <<0xC0, 0x80>>}, context(bob, authority))
      assert bad.outcome == :drop
    end

    test "server receipts, sealed-layer failures and wrong destinations", %{
      alice: alice,
      bob: bob,
      authority: authority
    } do
      receipt = %Envelope{
        kind: 5,
        client_timestamp: @t,
        source: {:aci, alice.aci},
        source_device: 2,
        destination: {:aci, bob.aci}
      }

      result = Receive.open(receipt, context(bob, authority))

      assert {result.outcome, result.sender, result.sender_device} ==
               {:server_receipt, alice.aci, 2}

      envelope = sealed(alice, bob, authority, :whisper, <<0x44>>)
      <<version, rest::binary>> = envelope.payload

      broken = %{
        envelope
        | payload: <<version>> <> binary_part(rest, 0, byte_size(rest) - 1) <> <<0>>
      }

      result = Receive.open(broken, context(bob, authority))
      assert {result.outcome, result.reason} == {:drop, {:sealed, :bad_mac}}

      untrusted =
        Receive.open(envelope, Party.receive_context(bob, [Keys.ec_keypair().public], @t))

      assert {untrusted.outcome, untrusted.reason} == {:drop, {:certificate, :untrusted_signer}}

      wrong = Receive.open(%{envelope | destination: {:aci, alice.aci}}, context(bob, authority))
      assert {wrong.outcome, wrong.reason} == {:drop, :wrong_destination}

      assert Receive.open(<<0xFF>>, context(bob, authority)).reason == :malformed_envelope
    end
  end
end
