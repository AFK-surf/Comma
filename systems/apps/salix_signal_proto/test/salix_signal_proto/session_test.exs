defmodule SalixSignalProto.SessionTest do
  # Session behavior between two Comma parties (CRS-04 §5, §8, §9; CRS-04b):
  # delivery in any order across post-quantum epochs, pending sessions,
  # session promotion, trust, pre-key use, limits, and failure without side
  # effects.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import SalixSignalProto.Test.SessionFixtures

  alias SalixSignalProto.{Address, Session}
  alias SalixSignalProto.Session.{PreKeyMessage, Record}

  @alice_address Address.new("00000000-0000-4000-8000-000000000011", 1)
  @bob_address Address.new("00000000-0000-4000-8000-000000000012", 2)

  defp start(opts \\ []) do
    bob = responder(Keyword.take(opts, [:one_time]))
    alice_ctx = context(:crypto.strong_rand_bytes(32), 1234, @alice_address, @bob_address)

    bob_ctx = %{
      identity: bob.identity,
      registration_id: 4321,
      local_address: @bob_address,
      remote_address: @alice_address,
      trusted?: &trust_all/2
    }

    session_opts = Keyword.take(opts, [:pq_ratchet])
    {:ok, alice} = Session.process_bundle(nil, bob.bundle, alice_ctx, session_opts)

    %{
      alice: alice,
      alice_ctx: alice_ctx,
      bob: nil,
      bob_ctx: bob_ctx,
      bob_keys: bob,
      opts: session_opts
    }
  end

  # Delivers one message to the other party; type 3 goes through the
  # pre-key path.
  defp deliver(record, {3, bytes}, ctx, keys, opts),
    do: Session.decrypt_pre_key(record, bytes, ctx, keys.pre_keys, opts)

  defp deliver(record, {2, bytes}, ctx, _keys, _opts), do: Session.decrypt(record, bytes, ctx)

  describe "conversation" do
    property "every message decrypts once, in any delivery order, across post-quantum epochs" do
      check all(
              schedule <-
                list_of({member_of([:alice, :bob]), integer(0..3)},
                  min_length: 60,
                  max_length: 120
                ),
              max_runs: 3
            ) do
        s = start()
        {:ok, first, alice} = Session.encrypt(s.alice, "first", s.alice_ctx)
        {:ok, "first", bob, _} = deliver(nil, first, s.bob_ctx, s.bob_keys, [])
        state = %{alice: alice, bob: bob, to_alice: [], to_bob: []}

        state =
          Enum.reduce(schedule, state, fn {sender, delay}, state ->
            state = send_one(state, sender, s)
            # Deliver the queue of the other direction out of order: hold
            # back the `delay` newest messages and deliver the rest newest
            # first.
            flush(state, other(sender), delay, s)
          end)

        state = flush(state, :alice, 0, s) |> flush(:bob, 0, s)
        assert state.to_alice == [] and state.to_bob == []
      end
    end

    test "post-quantum epochs advance in a long alternating conversation" do
      s = start()

      {alice, bob} =
        Enum.reduce(1..120, {s.alice, nil}, fn i, {alice, bob} ->
          {:ok, message, alice} = Session.encrypt(alice, "a#{i}", s.alice_ctx)
          {:ok, _, bob, _} = deliver(bob, message, s.bob_ctx, s.bob_keys, [])
          {:ok, {2, reply}, bob} = Session.encrypt(bob, "b#{i}", s.bob_ctx)
          {:ok, "b" <> _, alice, _} = Session.decrypt(alice, reply, s.alice_ctx)
          {alice, bob}
        end)

      assert alice.current.pq_ratchet.epoch >= 3
      assert bob.current.pq_ratchet.epoch >= 3
    end
  end

  defp other(:alice), do: :bob
  defp other(:bob), do: :alice

  defp send_one(state, :alice, s) do
    {:ok, message, alice} = Session.encrypt(state.alice, "from alice", s.alice_ctx)
    %{state | alice: alice, to_bob: [message | state.to_bob]}
  end

  defp send_one(state, :bob, s) do
    {:ok, message, bob} = Session.encrypt(state.bob, "from bob", s.bob_ctx)
    %{state | bob: bob, to_alice: [message | state.to_alice]}
  end

  defp flush(state, receiver, hold, s) do
    queue_key = if receiver == :alice, do: :to_alice, else: :to_bob
    oldest_first = Enum.reverse(Map.fetch!(state, queue_key))
    {ready, held} = Enum.split(oldest_first, max(length(oldest_first) - hold, 0))
    {ctx, keys} = if receiver == :alice, do: {s.alice_ctx, nil}, else: {s.bob_ctx, s.bob_keys}

    record =
      ready
      |> Enum.reverse()
      |> Enum.reduce(Map.fetch!(state, receiver), fn message, record ->
        assert {:ok, "from " <> _, record, _} = deliver(record, message, ctx, keys, [])
        # A second delivery of the same message is a duplicate.
        assert {:error, :duplicate} = deliver(record, message, ctx, keys, [])
        record
      end)

    state |> Map.put(receiver, record) |> Map.put(queue_key, Enum.reverse(held))
  end

  describe "pending sessions (CRS-04 §8.2)" do
    test "messages are pre-key messages with the same pre-key data until a reply decrypts" do
      s = start()
      {:ok, {3, m1}, alice} = Session.encrypt(s.alice, "one", s.alice_ctx)
      {:ok, {3, m2}, alice} = Session.encrypt(alice, "two", s.alice_ctx)
      {:ok, p1} = PreKeyMessage.decode(m1)
      {:ok, p2} = PreKeyMessage.decode(m2)
      assert Map.drop(p1, [:message, :serialized]) == Map.drop(p2, [:message, :serialized])
      assert p1.message.address_binding == Address.binding(@alice_address, @bob_address)

      {:ok, "two", bob, _} = Session.decrypt_pre_key(nil, m2, s.bob_ctx, s.bob_keys.pre_keys)
      # The second pre-key message of the same session uses no pre-key.
      {:ok, "one", bob, effects} = Session.decrypt_pre_key(bob, m1, s.bob_ctx, pre_keys(%{}))
      assert effects.used_one_time_pre_key == nil and effects.used_kem_pre_key == nil

      {:ok, {2, reply}, _bob} = Session.encrypt(bob, "reply", s.bob_ctx)
      {:ok, "reply", alice, _} = Session.decrypt(alice, reply, s.alice_ctx)
      assert {:ok, {2, _}, _alice} = Session.encrypt(alice, "three", s.alice_ctx)
    end

    test "a pending session is not used for sending after 30 days" do
      s = start()
      now = System.system_time(:millisecond)

      assert {:ok, {3, _}, _} =
               Session.encrypt(s.alice, "x", s.alice_ctx, now_ms: now + 29 * 86_400_000)

      assert Session.encrypt(s.alice, "x", s.alice_ctx, now_ms: now + 31 * 86_400_000) ==
               {:error, :no_session}
    end
  end

  describe "session records (CRS-04 §8.1, §8.4, §8.5)" do
    test "a message for a previous session promotes it, and replies converge on it" do
      s = start()
      {:ok, m1, alice} = Session.encrypt(s.alice, "s1", s.alice_ctx)
      {:ok, "s1", bob, _} = deliver(nil, m1, s.bob_ctx, s.bob_keys, [])
      {:ok, {2, reply}, bob} = Session.encrypt(bob, "ack", s.bob_ctx)
      {:ok, "ack", alice, _} = Session.decrypt(alice, reply, s.alice_ctx)
      {:ok, {2, in_flight}, alice} = Session.encrypt(alice, "old session", s.alice_ctx)

      # Alice starts session 2 from a new bundle of Bob's while "old session"
      # is in flight.
      new_keys = responder()
      bundle = %{new_keys.bundle | identity_key: s.bob_keys.bundle.identity_key}
      bundle = resign(bundle, s.bob_keys.identity.private)
      {:ok, alice} = Session.process_bundle(alice, bundle, s.alice_ctx)
      assert length(alice.previous) == 1
      {:ok, {3, m2}, alice} = Session.encrypt(alice, "s2", s.alice_ctx)

      {:ok, "s2", bob, _} = Session.decrypt_pre_key(bob, m2, s.bob_ctx, new_keys.pre_keys)
      {:ok, "old session", bob, _} = Session.decrypt(bob, in_flight, s.bob_ctx)

      # Bob replies on the promoted session 1; Alice promotes it too.
      {:ok, {2, answer}, bob} = Session.encrypt(bob, "on s1", s.bob_ctx)
      {:ok, "on s1", alice, _} = Session.decrypt(alice, answer, s.alice_ctx)
      assert alice.current.base_key == bob.current.base_key
      assert length(alice.previous) == 1 and length(bob.previous) == 1
    end

    test "no record is no session; a record without sessions is invalid" do
      s = start()
      {:ok, {3, message}, _} = Session.encrypt(s.alice, "x", s.alice_ctx)
      {:ok, pre_key} = PreKeyMessage.decode(message)
      inner = pre_key.message.serialized
      assert Session.decrypt(nil, inner, s.bob_ctx) == {:error, :no_session}
      assert Session.decrypt(Record.new(), inner, s.bob_ctx) == {:error, :invalid}
      assert Session.encrypt(nil, "x", s.alice_ctx) == {:error, :no_session}
    end

    test "records survive encoding for storage" do
      s = start()
      assert Record.decode(Record.encode(s.alice)) == {:ok, s.alice}
      assert Record.decode("not a record") == {:error, :invalid_record}

      assert Record.decode(:erlang.term_to_binary({Record, 1, :other})) ==
               {:error, :invalid_record}
    end
  end

  describe "failures leave no trace (CRS-04 §8.7)" do
    test "a tampered message is invalid, and the original still decrypts" do
      s = start()
      {:ok, {3, message}, _} = Session.encrypt(s.alice, "hello", s.alice_ctx)
      size = byte_size(message)
      <<head::binary-size(^size - 1), last>> = message
      tampered = <<head::binary, Bitwise.bxor(last, 1)>>

      assert Session.decrypt_pre_key(nil, tampered, s.bob_ctx, s.bob_keys.pre_keys) ==
               {:error, :invalid}

      assert {:ok, "hello", _, effects} =
               Session.decrypt_pre_key(nil, message, s.bob_ctx, s.bob_keys.pre_keys)

      assert effects.used_one_time_pre_key == 7
      assert effects.used_kem_pre_key.id == 13
    end

    test "a wrong address binding fails like a MAC failure" do
      s = start()
      {:ok, {3, message}, _} = Session.encrypt(s.alice, "hello", s.alice_ctx)
      wrong = %{s.bob_ctx | local_address: %{@bob_address | device_id: 3}}

      assert Session.decrypt_pre_key(nil, message, wrong, s.bob_keys.pre_keys) ==
               {:error, :invalid}
    end
  end

  describe "hostile input" do
    property "changed or truncated messages give an outcome, never an exception" do
      s = start()
      {:ok, {3, pre_key}, alice} = Session.encrypt(s.alice, "one", s.alice_ctx)
      {:ok, "one", bob, _} = Session.decrypt_pre_key(nil, pre_key, s.bob_ctx, s.bob_keys.pre_keys)
      {:ok, {2, reply}, _bob} = Session.encrypt(bob, "two", s.bob_ctx)

      check all(
              {base, type} <- member_of([{pre_key, 3}, {reply, 2}]),
              at <- integer(0..(byte_size(base) - 1)),
              change <- one_of([constant(:truncate), integer(0..255)]),
              max_runs: 100
            ) do
        <<head::binary-size(^at), byte, tail::binary>> = base

        bytes =
          if change == :truncate,
            do: head,
            else: <<head::binary, Bitwise.bxor(byte, change), tail::binary>>

        result =
          if type == 3,
            do: Session.decrypt_pre_key(nil, bytes, s.bob_ctx, s.bob_keys.pre_keys),
            else: Session.decrypt(alice, bytes, s.alice_ctx)

        assert match?({:ok, _, %Record{}, _}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "trust (CRS-04 §8.3 rule 1, §8.4 item 6, §8.6)" do
    test "an untrusted identity is refused before anything changes, in every direction" do
      s = start()
      distrust = fn _key, _direction -> false end
      {:ok, {3, message}, _} = Session.encrypt(s.alice, "hello", s.alice_ctx)

      assert Session.decrypt_pre_key(
               nil,
               message,
               %{s.bob_ctx | trusted?: distrust},
               s.bob_keys.pre_keys
             ) ==
               {:error, :untrusted_identity}

      assert Session.encrypt(s.alice, "x", %{s.alice_ctx | trusted?: distrust}) ==
               {:error, :untrusted_identity}

      assert Session.process_bundle(nil, s.bob_keys.bundle, %{s.alice_ctx | trusted?: distrust}) ==
               {:error, :untrusted_identity}

      {:ok, "hello", bob, _} =
        Session.decrypt_pre_key(nil, message, s.bob_ctx, s.bob_keys.pre_keys)

      {:ok, {2, reply}, _} = Session.encrypt(bob, "reply", s.bob_ctx)
      receiving_only = fn _key, direction -> direction == :sending end

      assert Session.decrypt(s.alice, reply, %{s.alice_ctx | trusted?: receiving_only}) ==
               {:error, :untrusted_identity}

      assert {:ok, "reply", _, _} = Session.decrypt(s.alice, reply, s.alice_ctx)
    end
  end

  describe "pre-keys (CRS-03 §10.2, CRS-04 §8.3 rule 3)" do
    test "a missing pre-key rejects a new session" do
      s = start()
      {:ok, {3, message}, _} = Session.encrypt(s.alice, "x", s.alice_ctx)

      for missing <- [:signed, :one_time, :kem] do
        keys = pre_keys(Map.put(s.bob_keys.keys, missing, %{}))

        assert Session.decrypt_pre_key(nil, message, s.bob_ctx, keys) ==
                 {:error, :missing_pre_key}
      end
    end

    test "a bundle without a one-time pre-key starts a session" do
      s = start(one_time: false)
      {:ok, {3, message}, _} = Session.encrypt(s.alice, "x", s.alice_ctx)

      assert {:ok, "x", _, %{used_one_time_pre_key: nil}} =
               Session.decrypt_pre_key(nil, message, s.bob_ctx, s.bob_keys.pre_keys)
    end

    test "a used last-resort combination does not start a second session" do
      s = start()
      {:ok, {3, message}, _} = Session.encrypt(s.alice, "x", s.alice_ctx)

      {:ok, "x", _, %{used_kem_pre_key: used}} =
        Session.decrypt_pre_key(nil, message, s.bob_ctx, s.bob_keys.pre_keys)

      replayed = pre_keys(s.bob_keys.keys, [{used.id, used.signed_pre_key_id, used.base_key}])
      assert Session.decrypt_pre_key(nil, message, s.bob_ctx, replayed) == {:error, :invalid}
    end
  end

  describe "limits (CRS-04 §5.3, §10)" do
    test "a forward jump over 25000 is invalid, and only the newest 2000 skipped seeds are kept" do
      s = start(pq_ratchet: :disabled)
      {:ok, first, alice} = Session.encrypt(s.alice, "first", s.alice_ctx)
      {:ok, "first", bob, _} = deliver(nil, first, s.bob_ctx, s.bob_keys, pq_ratchet: :disabled)
      {:ok, {2, reply}, _} = Session.encrypt(bob, "ack", s.bob_ctx)
      {:ok, "ack", alice, _} = Session.decrypt(alice, reply, s.alice_ctx)

      {:ok, {2, oldest}, alice} = Session.encrypt(alice, "oldest", s.alice_ctx)
      {:ok, {2, kept}, alice} = Session.encrypt(alice, "kept", s.alice_ctx)

      alice =
        Enum.reduce(2..2000, alice, fn _, alice ->
          {:ok, _, alice} = Session.encrypt(alice, "skipped", s.alice_ctx)
          alice
        end)

      # "latest" skips 2001 indices; the oldest of them is dropped and the
      # next one is the oldest seed kept.
      {:ok, {2, latest}, alice} = Session.encrypt(alice, "latest", s.alice_ctx)
      {:ok, "latest", bob, _} = Session.decrypt(bob, latest, s.bob_ctx)
      assert Session.decrypt(bob, oldest, s.bob_ctx) == {:error, :duplicate}
      assert {:ok, "kept", _, _} = Session.decrypt(bob, kept, s.bob_ctx)

      far = put_in(alice.current.sender.index, alice.current.sender.index + 25_001)
      {:ok, {2, too_far}, _} = Session.encrypt(far, "too far", s.alice_ctx)
      assert Session.decrypt(bob, too_far, s.bob_ctx) == {:error, :invalid}
    end
  end

  defp resign(bundle, identity_private) do
    alias SalixSignalProto.Crypto.XEdDSA

    %{
      bundle
      | signed_pre_key_signature: XEdDSA.sign(identity_private, bundle.signed_pre_key),
        kem_pre_key_signature: XEdDSA.sign(identity_private, bundle.kem_pre_key)
    }
  end
end
