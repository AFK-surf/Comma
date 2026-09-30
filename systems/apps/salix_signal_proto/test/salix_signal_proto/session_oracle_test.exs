defmodule SalixSignalProto.SessionOracleTest do
  # Level 2 and short level 4 differential tests of layer C2 against the
  # oracle (ORACLE_INTERFACE.md sections 6.6 and 6.7): sessions started by
  # either side, then conversations with out-of-order delivery through
  # several post-quantum epochs. Session operations in the oracle use
  # internal randomness, so every check is a round trip: what one side sends,
  # the other must decrypt to the same plaintext. Run with
  # `--include signal_oracle` and COMMA_SIGNAL_ORACLE=host:port.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import SalixSignalProto.Test.SessionFixtures, only: [context: 4, responder: 0]

  alias SalixSignalProto.{Address, Keys, PreKeyBundle, Session}
  alias SalixSignalProto.Crypto.{Hkdf, XEdDSA}
  alias SalixSignalProto.Session.{Pqxdh, Record, State}
  alias SalixSignalProto.Test.Oracle

  @moduletag :signal_oracle
  @moduletag timeout: 300_000

  @comma Address.new("00000000-0000-4000-8000-000000000011", 1)
  @peer Address.new("00000000-0000-4000-8000-000000000012", 2)

  setup do
    {:ok, oracle: Oracle.connect!(), store: "peer-#{System.unique_integer([:positive])}"}
  end

  defp wire_address(%Address{name: name, device_id: device_id}),
    do: %{name: name, device_id: device_id}

  defp text(value), do: {:text, value}

  defp create_store(oracle, store, identity_private, registration_id) do
    Oracle.call!(oracle, "store.create", %{
      store: text(store),
      identity_private: identity_private,
      registration_id: registration_id
    })
  end

  defp comma_context(registration_id \\ 1234) do
    context(:crypto.strong_rand_bytes(32), registration_id, @comma, @peer)
  end

  # --- The oracle sends and receives on its session with Comma ---

  defp oracle_encrypt(oracle, store, plaintext) do
    result =
      Oracle.call!(oracle, "session.encrypt", %{
        store: text(store),
        remote: wire_address(@comma),
        local_address: wire_address(@peer),
        plaintext: plaintext
      })

    {result["type"], Oracle.unhex(result["ciphertext"])}
  end

  defp oracle_decrypt(oracle, store, {type, bytes}) do
    op = if type == 3, do: "session.decrypt_prekey", else: "session.decrypt_whisper"

    case Oracle.call(oracle, op, %{
           store: text(store),
           remote: wire_address(@comma),
           local_address: wire_address(@peer),
           ciphertext: bytes
         }) do
      {:ok, %{"plaintext" => plaintext}} -> {:ok, Oracle.unhex(plaintext)}
      {:error, kind} -> {:error, kind}
    end
  end

  describe "Comma starts the session" do
    test "the oracle accepts Comma's first message; Comma verifies the oracle's pre-key signatures",
         %{
           oracle: oracle,
           store: store
         } do
      for one_time <- [true, false] do
        store = "#{store}-#{one_time}"
        {peer_identity, bundle, _kem} = oracle_bundle(oracle, store, one_time)
        ctx = comma_context()

        assert {:ok, record} = Session.process_bundle(nil, bundle, ctx)
        assert {:ok, {3, _} = message, record} = Session.encrypt(record, "hello oracle", ctx)
        assert oracle_decrypt(oracle, store, message) == {:ok, "hello oracle"}
        assert bundle.identity_key == peer_identity

        reply = oracle_encrypt(oracle, store, "hello Comma")
        assert {2, _} = reply
        assert {:ok, "hello Comma", _record, _} = Session.decrypt(record, elem(reply, 1), ctx)
      end
    end

    property "conversations with the oracle decrypt on both sides", %{
      oracle: oracle,
      store: store
    } do
      check all(
              schedule <- list_of(schedule_step(), min_length: 100, max_length: 140),
              max_runs: 2
            ) do
        store = "#{store}-#{System.unique_integer([:positive])}"
        {_peer_identity, bundle, _kem} = oracle_bundle(oracle, store, true)
        ctx = comma_context()
        {:ok, record} = Session.process_bundle(nil, bundle, ctx)
        converse(oracle, store, %{record: record, oracle_ready: false}, ctx, nil, schedule)
      end
    end
  end

  # CRS-03 §6.2 rule 6: a KEM ciphertext that does not re-encrypt gives the
  # implicit-rejection secret KDF(J(z || c) || H(c)). The oracle responder
  # accepts a first message of random ciphertext bytes whose keys use Comma's
  # decapsulation result, and refuses one whose keys use the round-3 text
  # form KDF(z || H(c)).
  test "the oracle agrees with Comma's implicit-rejection secret for a random KEM ciphertext", %{
    oracle: oracle,
    store: store
  } do
    for form <- [:deployed, :round3_text] do
      store = "#{store}-#{form}"
      {_peer_identity, bundle, kem} = oracle_bundle(oracle, store, false)
      ctx = comma_context()
      ciphertext = <<8>> <> :crypto.strong_rand_bytes(1568)
      <<8, raw_ciphertext::binary>> = ciphertext
      z = binary_part(kem.secret, 1 + 3136, 32)
      text_form = shake256([z, :crypto.hash(:sha3_256, raw_ciphertext)])
      {:ok, deployed} = Keys.kem_decapsulate(kem.secret, ciphertext)
      refute deployed == text_form

      shared = if form == :deployed, do: deployed, else: text_form
      record = initiator_record(ctx, bundle, ciphertext, shared)
      {:ok, {3, _} = first, _record} = Session.encrypt(record, "random ciphertext", ctx)

      case form do
        :deployed -> assert oracle_decrypt(oracle, store, first) == {:ok, "random ciphertext"}
        :round3_text -> assert {:error, _kind} = oracle_decrypt(oracle, store, first)
      end
    end
  end

  # An initiator session like Session.process_bundle/4 makes, but with a
  # chosen KEM ciphertext and KEM shared secret (CRS-04 §3).
  defp initiator_record(ctx, bundle, kem_ciphertext, kem_shared) do
    ephemeral = Keys.ec_keypair()
    {:ok, dh1} = Keys.agree(ctx.identity.private, bundle.signed_pre_key)
    {:ok, dh2} = Keys.agree(ephemeral.private, bundle.identity_key)
    {:ok, dh3} = Keys.agree(ephemeral.private, bundle.signed_pre_key)

    <<root_key::binary-size(32), chain_key::binary-size(32), pq_secret::binary-size(32)>> =
      [dh1, dh2, dh3]
      |> Pqxdh.secret_input(kem_shared)
      |> Hkdf.derive("", "WhisperText_X25519_SHA-256_CRYSTALS-KYBER-1024", 96)

    {:ok, state} =
      State.initiator(%{
        result: %{root_key: root_key, chain_key: chain_key, pq_secret: pq_secret},
        local_identity: ctx.identity.public,
        remote_identity: bundle.identity_key,
        base_key: ephemeral.public,
        ratchet_private: :crypto.strong_rand_bytes(32),
        signed_pre_key: bundle.signed_pre_key,
        pending: %{
          one_time_pre_key_id: nil,
          signed_pre_key_id: bundle.signed_pre_key_id,
          kem_pre_key_id: bundle.kem_pre_key_id,
          kem_ciphertext: kem_ciphertext,
          created_at_ms: System.system_time(:millisecond)
        },
        local_registration_id: ctx.registration_id,
        remote_registration_id: bundle.registration_id,
        pq: :required
      })

    Record.promote(Record.new(), state)
  end

  defp shake256(data), do: :crypto.hash_xof(:shake256, data, 256)

  # A bundle made by the oracle from keys that Comma generated, with the
  # oracle's signatures.
  defp oracle_bundle(oracle, store, one_time) do
    identity = Keys.ec_keypair()
    create_store(oracle, store, identity.private, 4321)
    signed = Keys.ec_keypair()
    kem = Keys.kem_keypair()

    Oracle.call!(oracle, "store.put_signed_prekey", %{
      store: text(store),
      id: 11,
      private: signed.private
    })

    Oracle.call!(oracle, "store.put_kem_prekey", %{
      store: text(store),
      id: 13,
      public: kem.public,
      secret: kem.secret
    })

    if one_time,
      do:
        Oracle.call!(oracle, "store.put_prekey", %{
          store: text(store),
          id: 7,
          private: Keys.ec_keypair().private
        })

    args = %{
      store: text(store),
      device_id: @peer.device_id,
      signed_prekey_id: 11,
      kem_prekey_id: 13
    }

    args = if one_time, do: Map.put(args, :prekey_id, 7), else: args
    %{"bundle" => b} = Oracle.call!(oracle, "store.bundle", args)
    hex = &Oracle.unhex/1

    bundle = %PreKeyBundle{
      registration_id: b["registration_id"],
      device_id: b["device_id"],
      identity_key: hex.(b["identity_public"]),
      one_time_pre_key_id: b["prekey_id"],
      one_time_pre_key: b["prekey_public"] && hex.(b["prekey_public"]),
      signed_pre_key_id: b["signed_prekey_id"],
      signed_pre_key: hex.(b["signed_prekey_public"]),
      signed_pre_key_signature: hex.(b["signed_prekey_signature"]),
      kem_pre_key_id: b["kem_prekey_id"],
      kem_pre_key: hex.(b["kem_prekey_public"]),
      kem_pre_key_signature: hex.(b["kem_prekey_signature"])
    }

    {identity.public, bundle, kem}
  end

  describe "the oracle starts the session" do
    test "Comma decrypts the oracle's first message and the oracle reads Comma's reply", %{
      oracle: oracle,
      store: store
    } do
      {record, ctx, keys} = oracle_starts(oracle, store)
      {3, _} = first = oracle_encrypt(oracle, store, "hello Comma")

      assert {:ok, "hello Comma", record, effects} =
               Session.decrypt_pre_key(record, elem(first, 1), ctx, keys.pre_keys)

      assert effects.used_one_time_pre_key == 7
      assert {:ok, {2, _} = reply, _record} = Session.encrypt(record, "hello oracle", ctx)
      assert oracle_decrypt(oracle, store, reply) == {:ok, "hello oracle"}
    end

    property "conversations with the oracle decrypt on both sides", %{
      oracle: oracle,
      store: store
    } do
      check all(
              schedule <- list_of(schedule_step(), min_length: 100, max_length: 140),
              max_runs: 2
            ) do
        store = "#{store}-#{System.unique_integer([:positive])}"
        {record, ctx, keys} = oracle_starts(oracle, store)
        converse(oracle, store, %{record: record, oracle_ready: true}, ctx, keys, schedule)
      end
    end
  end

  test "post-quantum epochs complete in both roles with the oracle", %{
    oracle: oracle,
    store: store
  } do
    {nil, ctx, keys} = oracle_starts(oracle, store)
    {3, first} = oracle_encrypt(oracle, store, "start")
    {:ok, "start", record, _} = Session.decrypt_pre_key(nil, first, ctx, keys.pre_keys)

    record =
      Enum.reduce(1..100, record, fn i, record ->
        {:ok, message, record} = Session.encrypt(record, "comma #{i}", ctx)
        assert oracle_decrypt(oracle, store, message) == {:ok, "comma #{i}"}
        {2, reply} = oracle_encrypt(oracle, store, "oracle #{i}")
        assert {:ok, "oracle " <> _, record, _} = Session.decrypt(record, reply, ctx)
        record
      end)

    # Each epoch completes in about 40 messages each way; the roles swap.
    assert record.current.pq_ratchet.epoch >= 3
  end

  # The oracle processes a bundle of Comma's keys, signed by Comma.
  defp oracle_starts(oracle, store) do
    create_store(oracle, store, Keys.ec_keypair().private, 4321)
    keys = responder()
    ctx = %{comma_context(keys.bundle.registration_id) | identity: keys.identity}
    b = keys.bundle
    hex = &Oracle.hex/1

    bundle = %{
      registration_id: b.registration_id,
      device_id: @comma.device_id,
      identity_public: hex.(b.identity_key),
      prekey_id: b.one_time_pre_key_id,
      prekey_public: hex.(b.one_time_pre_key),
      signed_prekey_id: b.signed_pre_key_id,
      signed_prekey_public: hex.(b.signed_pre_key),
      signed_prekey_signature: hex.(XEdDSA.sign(keys.identity.private, b.signed_pre_key)),
      kem_prekey_id: b.kem_pre_key_id,
      kem_prekey_public: hex.(b.kem_pre_key),
      kem_prekey_signature: hex.(XEdDSA.sign(keys.identity.private, b.kem_pre_key))
    }

    Oracle.call!(oracle, "session.process_bundle", %{
      store: text(store),
      remote: wire_address(@comma),
      local_address: wire_address(@peer),
      bundle: bundle
    })

    {nil, ctx, keys}
  end

  # One step: who sends, and how many of the newest messages to the other
  # side to hold back before delivering the rest newest first.
  defp schedule_step, do: tuple({member_of([:comma, :oracle]), integer(0..2)})

  defp converse(oracle, store, start, ctx, keys, schedule) do
    state = Map.merge(start, %{to_comma: [], to_oracle: []})

    state =
      Enum.reduce(schedule, state, fn {sender, hold}, state ->
        state = send_from(sender, state, oracle, store, ctx)

        deliver_to(
          if(sender == :comma, do: :oracle, else: :comma),
          state,
          hold,
          oracle,
          store,
          ctx,
          keys
        )
      end)

    state = deliver_to(:comma, state, 0, oracle, store, ctx, keys)
    state = deliver_to(:oracle, state, 0, oracle, store, ctx, keys)
    assert state.to_comma == [] and state.to_oracle == []
  end

  # A side sends only once it holds a session; until then the other side
  # sends.
  defp send_from(:comma, %{record: nil} = state, oracle, store, ctx),
    do: send_from(:oracle, state, oracle, store, ctx)

  defp send_from(:oracle, %{oracle_ready: false} = state, oracle, store, ctx),
    do: send_from(:comma, state, oracle, store, ctx)

  defp send_from(:comma, state, _oracle, _store, ctx) do
    plaintext = "comma #{System.unique_integer([:positive])}"
    {:ok, message, record} = Session.encrypt(state.record, plaintext, ctx)
    %{state | record: record, to_oracle: [{message, plaintext} | state.to_oracle]}
  end

  defp send_from(:oracle, state, oracle, store, _ctx) do
    plaintext = "oracle #{System.unique_integer([:positive])}"
    %{state | to_comma: [{oracle_encrypt(oracle, store, plaintext), plaintext} | state.to_comma]}
  end

  defp deliver_to(receiver, state, hold, oracle, store, ctx, keys) do
    key = if receiver == :comma, do: :to_comma, else: :to_oracle
    oldest_first = Enum.reverse(Map.fetch!(state, key))
    {ready, held} = Enum.split(oldest_first, max(length(oldest_first) - hold, 0))

    state =
      ready
      |> Enum.reverse()
      |> Enum.reduce(state, fn {message, plaintext}, state ->
        case receiver do
          :oracle ->
            assert oracle_decrypt(oracle, store, message) == {:ok, plaintext}
            %{state | oracle_ready: true}

          :comma ->
            assert {:ok, ^plaintext, record, _} = comma_decrypt(state.record, message, ctx, keys)
            %{state | record: record}
        end
      end)

    Map.put(state, key, Enum.reverse(held))
  end

  defp comma_decrypt(record, {3, bytes}, ctx, keys),
    do: Session.decrypt_pre_key(record, bytes, ctx, keys.pre_keys)

  defp comma_decrypt(record, {2, bytes}, ctx, _keys), do: Session.decrypt(record, bytes, ctx)

  describe "parser agreement (level 3 sample)" do
    property "Comma and the oracle accept and reject the same double-ratchet and pre-key messages",
             %{oracle: oracle} do
      keys = responder()
      ctx = comma_context()
      {:ok, record} = Session.process_bundle(nil, keys.bundle, ctx)
      {:ok, {3, pre_key_message}, _record} = Session.encrypt(record, "parse me", ctx)
      {:ok, parsed} = SalixSignalProto.Session.PreKeyMessage.decode(pre_key_message)
      inner = parsed.message.serialized

      check all(
              {op, base} <-
                member_of([
                  {"message.whisper_decode", inner},
                  {"message.prekey_decode", pre_key_message}
                ]),
              bytes <- mutation(base),
              max_runs: 150
            ) do
        comma =
          case op do
            "message.whisper_decode" -> SalixSignalProto.Session.Message.decode(bytes)
            "message.prekey_decode" -> SalixSignalProto.Session.PreKeyMessage.decode(bytes)
          end

        oracle_accepts = match?({:ok, _}, Oracle.call(oracle, op, %{message: bytes}))
        assert match?({:ok, _}, comma) == oracle_accepts, "#{op} #{Oracle.hex(bytes)}"
      end
    end
  end

  # Truncations, byte changes and insertions of a valid message.
  defp mutation(base) do
    size = byte_size(base)

    one_of([
      map(integer(0..size), &binary_part(base, 0, &1)),
      map({integer(0..(size - 1)), integer(0..255)}, fn {at, byte} ->
        <<head::binary-size(^at), _old, tail::binary>> = base
        <<head::binary, byte, tail::binary>>
      end),
      map({integer(0..size), binary(min_length: 1, max_length: 3)}, fn {at, extra} ->
        <<head::binary-size(^at), tail::binary>> = base
        head <> extra <> tail
      end)
    ])
  end
end
