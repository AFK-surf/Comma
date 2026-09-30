defmodule SalixSignalProto.Session.VectorsTest do
  # Whole-session behavior (CRS-04 §3, §5, §7, §8; CRS-04b) against the
  # CRS-04 vectors conversation-ec-only.json, prekey-message-rejections.json,
  # session-establishment.json and conversation-deployed.json.
  use ExUnit.Case, async: true

  import SalixSignalProto.Test.SessionFixtures

  alias SalixSignalProto.{Keys, PreKeyBundle, Session}
  alias SalixSignalProto.Crypto.XEdDSA
  alias SalixSignalProto.Session.{Kdf, PreKeyMessage, Pqxdh, Spqr, State}
  alias SalixSignalProto.Test.Vectors

  defp vector(file), do: Vectors.load!("crs/CRS-04/" <> file)
  defp hex(nil), do: nil
  defp hex(value), do: Vectors.hex!(value)

  defp no_pre_keys, do: pre_keys(%{})

  describe "EC-only conversation (conversation-ec-only)" do
    test "every send matches the oracle bytes and every delivery the oracle outcome and state" do
      [%{"inputs" => inputs, "outputs" => %{"events" => events}}] =
        vector("conversation-ec-only.json")["cases"]

      sends = for %{"event" => "send"} = event <- events, into: %{}, do: {event["name"], event}
      {:ok, first} = PreKeyMessage.decode(hex(sends["a1"]["serialized"]))

      initiator_ctx =
        context(
          hex(inputs["initiator_identity_private"]),
          1234,
          address(inputs["initiator_address"]),
          address(inputs["responder_address"])
        )

      responder_ctx =
        context(
          hex(inputs["responder_identity_private"]),
          4321,
          address(inputs["responder_address"]),
          address(inputs["initiator_address"])
        )

      common = %{base_key: first.base_key, pq_ratchet: nil}

      initiator =
        state_from_vector(
          inputs["initial_state"]["initiator"],
          Map.merge(common, %{
            local_identity: initiator_ctx.identity.public,
            remote_identity: responder_ctx.identity.public,
            local_registration_id: 1234,
            pending: %{
              one_time_pre_key_id: first.one_time_pre_key_id,
              signed_pre_key_id: first.signed_pre_key_id,
              kem_pre_key_id: first.kem_pre_key_id,
              kem_ciphertext: first.kem_ciphertext,
              created_at_ms: 0
            }
          })
        )

      responder =
        state_from_vector(
          inputs["initial_state"]["responder"],
          Map.merge(common, %{
            local_identity: responder_ctx.identity.public,
            remote_identity: initiator_ctx.identity.public
          })
        )

      parties = %{
        "initiator" => {record(initiator), initiator_ctx},
        "responder" => {record(responder), responder_ctx}
      }

      Enum.reduce(events, parties, fn event, parties -> replay(event, parties, sends) end)
    end
  end

  defp replay(%{"event" => "send", "sender" => sender} = event, parties, _sends) do
    {record, ctx} = parties[sender]

    assert {:ok, {type, bytes}, record} =
             Session.encrypt(record, hex(event["plaintext"]), ctx, now_ms: 0)

    assert type == event["message_type"], event["name"]
    assert bytes == hex(event["serialized"]), event["name"]
    assert_ec_state(record.current, event["sender_state_after"], event["name"])
    Map.put(parties, sender, {record, ctx})
  end

  defp replay(%{"event" => "deliver", "name" => name} = event, parties, sends) do
    send = sends[name]
    receiver = if send["sender"] == "initiator", do: "responder", else: "initiator"
    {record, ctx} = parties[receiver]
    bytes = hex(event["input"] || send["serialized"])
    after_state = event["receiver_state_after"]
    # The receiver's new sending ratchet key, if this delivery steps it.
    opts =
      if after_state,
        do: [ratchet_private: hex(after_state["sending_chain"]["ratchet_private"])],
        else: []

    result =
      if send["message_type"] == 3,
        do: Session.decrypt_pre_key(record, bytes, ctx, no_pre_keys(), opts),
        else: Session.decrypt(record, bytes, ctx, opts)

    case {event["result"], result} do
      {"plaintext", {:ok, plaintext, record, _effects}} ->
        assert plaintext == hex(event["plaintext"]), name
        assert_ec_state(record.current, after_state, name)
        Map.put(parties, receiver, {record, ctx})

      {expected, {:error, outcome}} when expected in ["duplicate", "invalid"] ->
        assert Atom.to_string(outcome) == expected, name
        parties

      {expected, other} ->
        flunk("#{name}: expected #{expected}, got #{inspect(other)}")
    end
  end

  describe "pre-key message rejections (prekey-message-rejections)" do
    test "each changed message gets the oracle's outcome and leaves no session or pre-key change" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            vector("prekey-message-rejections.json")["cases"] do
        bytes = hex(inputs["pre_key_message"])
        {ctx, pre_keys} = responder_for(inputs, bytes)

        case {outputs["result"], Session.decrypt_pre_key(nil, bytes, ctx, pre_keys)} do
          {"plaintext", {:ok, plaintext, _record, effects}} ->
            assert plaintext == hex(outputs["plaintext"])
            assert effects.used_one_time_pre_key != nil

          {"rejected", {:error, outcome}} ->
            assert outcome in [:invalid, :missing_pre_key], inputs["label"]

          {expected, other} ->
            flunk("#{inputs["label"]}: expected #{expected}, got #{inspect(other)}")
        end
      end
    end

    test "Comma as initiator rebuilds the generator's message from the same randomness" do
      %{"inputs" => inputs} =
        Enum.find(
          vector("prekey-message-rejections.json")["cases"],
          &(&1["inputs"]["label"] == "generator-built-without-post-quantum-field")
        )

      bytes = hex(inputs["pre_key_message"])
      {responder_ctx, pre_keys} = responder_for(inputs, bytes)

      # The message has no post-quantum field, so only an EC-only responder
      # reads it; that gives the plaintext to encrypt again.
      assert {:ok, plaintext, _record, _effects} =
               Session.decrypt_pre_key(nil, bytes, responder_ctx, pre_keys, pq_ratchet: :disabled)

      {:ok, message} = PreKeyMessage.decode(bytes)
      responder_identity = hex(inputs["responder_identity_private"])
      signed = Keys.ec_keypair(hex(inputs["responder_signed_pre_key_private"]))
      kem_public = Keys.kem_public_from_secret(hex(inputs["responder_kem_secret_key"]))

      bundle = %PreKeyBundle{
        registration_id: 4321,
        device_id: responder_ctx.local_address.device_id,
        identity_key: responder_ctx.identity.public,
        one_time_pre_key_id: message.one_time_pre_key_id,
        one_time_pre_key: Keys.ec_public(hex(inputs["responder_one_time_pre_key_private"])),
        signed_pre_key_id: message.signed_pre_key_id,
        signed_pre_key: signed.public,
        signed_pre_key_signature: XEdDSA.sign(responder_identity, signed.public),
        kem_pre_key_id: message.kem_pre_key_id,
        kem_pre_key: kem_public,
        kem_pre_key_signature: XEdDSA.sign(responder_identity, kem_public)
      }

      initiator_ctx =
        context(
          hex(inputs["initiator_identity_private"]),
          message.registration_id,
          responder_ctx.remote_address,
          responder_ctx.local_address
        )

      assert {:ok, record} =
               Session.process_bundle(nil, bundle, initiator_ctx,
                 ephemeral_private: hex(inputs["initiator_ephemeral_private"]),
                 ratchet_private: hex(inputs["initiator_ratchet_private"]),
                 kem_random: hex(inputs["kyber_encapsulation_randomness_m"]),
                 pq_ratchet: :disabled
               )

      assert {:ok, {3, ^bytes}, _record} = Session.encrypt(record, plaintext, initiator_ctx)
    end
  end

  # A responder context and pre-key lookup from vector inputs; addresses come
  # from the message's address binding.
  defp responder_for(inputs, bytes) do
    {sender, recipient} =
      case PreKeyMessage.decode(bytes) do
        {:ok, %{message: %{address_binding: binding}}} when is_binary(binding) ->
          addresses(binding)

        _ ->
          {SalixSignalProto.Address.new("initiator", 1),
           SalixSignalProto.Address.new("responder", 1)}
      end

    # The vector bundles use one-time pre-key 7, signed pre-key 11 and KEM
    # pre-key 13.
    lookup =
      pre_keys(%{
        signed: %{11 => hex(inputs["responder_signed_pre_key_private"])},
        one_time: %{7 => hex(inputs["responder_one_time_pre_key_private"])},
        kem: %{13 => hex(inputs["responder_kem_secret_key"])}
      })

    {context(hex(inputs["responder_identity_private"]), 4321, recipient, sender), lookup}
  end

  describe "deployed session start (session-establishment)" do
    test "Comma responder decrypts the first message, replies with the oracle bytes, and the initiator reads the reply" do
      for %{"inputs" => inputs, "outputs" => outputs} <-
            vector("session-establishment.json")["cases"] do
        initiator_address = address(inputs["initiator_address"])
        responder_address = address(inputs["responder_address"])

        responder_ctx =
          context(
            hex(inputs["responder_identity_private"]),
            inputs["responder_registration_id"],
            responder_address,
            initiator_address
          )

        initiator_ctx =
          context(
            hex(inputs["initiator_identity_private"]),
            inputs["initiator_registration_id"],
            initiator_address,
            responder_address
          )

        spk = inputs["responder_signed_pre_key"]
        opk = inputs["responder_one_time_pre_key"]
        kem = inputs["responder_kem_pre_key"]

        pre_keys =
          pre_keys(%{
            signed: %{spk["id"] => hex(spk["private"])},
            one_time: if(opk, do: %{opk["id"] => hex(opk["private"])}, else: %{}),
            kem: %{kem["id"] => hex(kem["secret"])}
          })

        after_first = outputs["responder_state_after_first_message"]
        bytes = hex(inputs["pre_key_message"])

        assert {:ok, plaintext, responder, effects} =
                 Session.decrypt_pre_key(nil, bytes, responder_ctx, pre_keys,
                   ratchet_private: hex(after_first["sending_chain"]["ratchet_private"])
                 )

        assert plaintext == hex(outputs["plaintext"])
        assert_ec_state(responder.current, after_first)
        {:ok, message} = PreKeyMessage.decode(bytes)
        assert effects.used_one_time_pre_key == opk["id"]

        assert effects.used_kem_pre_key == %{
                 id: kem["id"],
                 signed_pre_key_id: spk["id"],
                 base_key: message.base_key
               }

        assert effects.identity_key == initiator_ctx.identity.public

        reply = hex(outputs["responder_reply_message"])

        assert {:ok, {2, ^reply}, _responder} =
                 Session.encrypt(
                   responder,
                   hex(outputs["responder_reply_plaintext"]),
                   responder_ctx
                 )

        # The initiator after its first message, rebuilt from the vector.
        {:ok, pqxdh} =
          Pqxdh.respond(%{
            identity_private: responder_ctx.identity.private,
            signed_pre_key_private: hex(spk["private"]),
            one_time_pre_key_private: opk && hex(opk["private"]),
            kem_secret: hex(kem["secret"]),
            identity_key: message.identity_key,
            base_key: message.base_key,
            kem_ciphertext: message.kem_ciphertext
          })

        before_first = outputs["initiator_state_before_first_message"]

        initiator =
          state_from_vector(before_first, %{
            local_identity: initiator_ctx.identity.public,
            remote_identity: responder_ctx.identity.public,
            base_key: message.base_key,
            pq_ratchet: Spqr.new(:initiator, pqxdh.pq_secret)
          })

        initiator = %{
          initiator
          | sender: %{
              initiator.sender
              | chain_key: Kdf.next(initiator.sender.chain_key),
                index: 1
            }
        }

        assert {:ok, reply_plaintext, _record, _} =
                 Session.decrypt(record(initiator), reply, initiator_ctx)

        assert reply_plaintext == hex(outputs["responder_reply_plaintext"])
      end
    end
  end

  describe "deployed conversation (conversation-deployed)" do
    test "both Comma receivers decrypt every delivery, and the Comma responder sends the oracle's first replies" do
      [%{"inputs" => inputs, "outputs" => %{"events" => events}}] =
        vector("conversation-deployed.json")["cases"]

      sends = for %{"event" => "send"} = event <- events, into: %{}, do: {event["name"], event}
      ids = inputs["bundle_ids"]
      initiator_address = address(inputs["initiator_address"])
      responder_address = address(inputs["responder_address"])

      responder_ctx =
        context(
          hex(inputs["responder_identity_private"]),
          4321,
          responder_address,
          initiator_address
        )

      initiator_ctx =
        context(
          hex(inputs["initiator_identity_private"]),
          1234,
          initiator_address,
          responder_address
        )

      {:ok, first} = PreKeyMessage.decode(hex(sends["a1"]["serialized"]))

      pre_keys =
        pre_keys(%{
          signed: %{ids["signed_ec_pre_key"] => hex(inputs["responder_signed_pre_key_private"])},
          one_time: %{
            ids["one_time_ec_pre_key"] => hex(inputs["responder_one_time_pre_key_private"])
          },
          kem: %{ids["kem_pre_key"] => hex(inputs["responder_kem_secret_key"])}
        })

      {:ok, pqxdh} =
        Pqxdh.respond(%{
          identity_private: responder_ctx.identity.private,
          signed_pre_key_private: hex(inputs["responder_signed_pre_key_private"]),
          one_time_pre_key_private: hex(inputs["responder_one_time_pre_key_private"]),
          kem_secret: hex(inputs["responder_kem_secret_key"]),
          identity_key: first.identity_key,
          base_key: first.base_key,
          kem_ciphertext: first.kem_ciphertext
        })

      # The initiator after it sent a1 and a2 on its first chain.
      a1 = sends["a1"]
      ratchet = Keys.ec_keypair(hex(a1["sender_ratchet_private"]))
      signed_public = Keys.ec_public(hex(inputs["responder_signed_pre_key_private"]))
      {:ok, {root, _}} = Kdf.root_step(pqxdh.root_key, ratchet.private, signed_public)

      initiator = %State{
        local_identity: initiator_ctx.identity.public,
        remote_identity: responder_ctx.identity.public,
        root_key: root,
        sender: %{
          private: ratchet.private,
          public: ratchet.public,
          chain_key: hex(sends["a2"]["sender_chain_key_used"]) |> Kdf.next(),
          index: 2
        },
        receivers: [%{public: signed_public, chain_key: pqxdh.chain_key, index: 0, seeds: []}],
        base_key: first.base_key,
        pq_ratchet: Spqr.new(:initiator, pqxdh.pq_secret)
      }

      next_ratchet = fn from_name ->
        events
        |> Enum.drop_while(&(&1["name"] != from_name or &1["event"] != "deliver"))
        |> Enum.find(&(&1["event"] == "send"))
      end

      parties = %{
        "initiator" => {record(initiator), initiator_ctx},
        "responder" => {nil, responder_ctx}
      }

      Enum.reduce(events, parties, fn
        %{"event" => "send", "sender" => "responder", "name" => name} = event, parties
        when name in ["b1", "b2"] ->
          {record, ctx} = parties["responder"]
          assert {:ok, {2, bytes}, record} = Session.encrypt(record, hex(event["plaintext"]), ctx)
          assert bytes == hex(event["serialized"]), name
          Map.put(parties, "responder", {record, ctx})

        %{"event" => "send"}, parties ->
          parties

        %{"event" => "deliver", "name" => name} = event, parties ->
          send = sends[name]
          receiver = if send["sender"] == "initiator", do: "responder", else: "initiator"
          {record, ctx} = parties[receiver]
          bytes = hex(send["serialized"])
          # The receiver's next sending ratchet key, if this delivery steps it.
          next = next_ratchet.(name)

          opts =
            if next && next["sender"] == receiver,
              do: [ratchet_private: hex(next["sender_ratchet_private"])],
              else: []

          result =
            if send["message_type"] == 3,
              do: Session.decrypt_pre_key(record, bytes, ctx, pre_keys, opts),
              else: Session.decrypt(record, bytes, ctx, opts)

          case {event["result"], result} do
            {"plaintext", {:ok, plaintext, record, _}} ->
              assert plaintext == hex(event["plaintext"]), name
              Map.put(parties, receiver, {record, ctx})

            {"duplicate", {:error, :duplicate}} ->
              parties

            {expected, other} ->
              flunk("#{name}: expected #{expected}, got #{inspect(other)}")
          end
      end)
    end
  end
end
