defmodule SalixSignalProto.Session.SpqrTest do
  # The post-quantum ratchet (CRS-04b) against the CRS-04b vectors
  # spqr-erasure-code.json, spqr-message-format.json,
  # spqr-authenticator.json, spqr-chain.json and spqr-field-variants.json.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.{Address, Keys, Session}
  alias SalixSignalProto.Session.{PreKeyMessage, Spqr}
  alias SalixSignalProto.Session.Spqr.{ErasureCode, Message}
  alias SalixSignalProto.Test.Vectors

  defp cases(file), do: Vectors.load!("crs/CRS-04b/" <> file)["cases"]
  defp hex(value), do: Vectors.hex!(value)

  describe "erasure code (spqr-erasure-code)" do
    test "systematic and parity chunks match the oracle, and chunks 5, 0, 7 decode the header" do
      for %{"inputs" => inputs, "outputs" => outputs} <- cases("spqr-erasure-code.json") do
        case inputs do
          %{"payload" => payload} ->
            payload = hex(payload)
            assert ErasureCode.chunks_needed(byte_size(payload)) == outputs["systematic_chunks"]

            for {index, chunk} <- outputs["chunks"] do
              assert ErasureCode.chunk(payload, String.to_integer(index)) == hex(chunk),
                     inputs["label"]
            end

          %{"chunks" => chunks} ->
            chunks =
              Map.new(chunks, fn {index, chunk} -> {String.to_integer(index), hex(chunk)} end)

            assert ErasureCode.decode(chunks, inputs["payload_length"]) ==
                     {:ok, hex(outputs["payload"])}

            assert ErasureCode.decode(Map.delete(chunks, 7), inputs["payload_length"]) ==
                     :incomplete
        end
      end
    end

    property "any n distinct chunks give the payload back" do
      check all(
              length <- member_of([96, 160]),
              payload <- binary(length: length),
              indices <- uniq_list_of(integer(0..40), length: div(length, 32)),
              max_runs: 20
            ) do
        chunks = Map.new(indices, &{&1, ErasureCode.chunk(payload, &1)})
        assert ErasureCode.decode(chunks, length) == {:ok, payload}
      end
    end
  end

  test "post-quantum message parsing and encoding (spqr-message-format)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("spqr-message-format.json") do
      bytes = hex(inputs["post_quantum_message"])
      assert {:ok, message} = Message.decode(bytes)

      assert {message.version, message.epoch, message.index, message.type, message.chunk_index} ==
               {outputs["version"], outputs["epoch"], outputs["index"], outputs["type"],
                outputs["chunk_index"]}

      assert message.chunk == (outputs["chunk_data"] && hex(outputs["chunk_data"]))
      assert Message.encode(message) == bytes
    end
  end

  test "authenticator schedule and MACs (spqr-authenticator)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("spqr-authenticator.json") do
      case inputs do
        %{"root_key_before" => root} ->
          assert Spqr.auth_update(%{root: hex(root)}, inputs["epoch"], hex(inputs["key"])) ==
                   %{root: hex(outputs["root_key"]), mac: hex(outputs["mac_key"])}

        %{"header" => header} ->
          assert Spqr.header_mac(hex(inputs["mac_key"]), inputs["epoch"], hex(header)) ==
                   hex(outputs["mac"])

        %{"ciphertext" => ciphertext} ->
          <<c1::binary-size(960), c2::binary>> = hex(ciphertext)

          assert Spqr.ciphertext_mac(hex(inputs["mac_key"]), inputs["epoch"], c1, c2) ==
                   hex(outputs["mac"])
      end
    end
  end

  test "epoch secrets from the ML-KEM secrets (spqr-mlkem768)" do
    for %{"outputs" => outputs} <- Vectors.load!("crs/CRS-04b/spqr-mlkem768.json")["cases"] do
      assert Spqr.epoch_secret(hex(outputs["shared_secret"]), outputs["epoch"]) ==
               hex(outputs["epoch_secret"])
    end
  end

  test "chain epochs and the first keys of each direction (spqr-chain)" do
    [start | added] = cases("spqr-chain.json")

    # Chain epoch 0 as each role starts it: the initiator sends on the
    # initiator-to-responder chain, the responder on the other.
    start_secret = hex(start["inputs"]["start_secret"])
    check_keys(Spqr.new(:initiator, start_secret), 0, start["outputs"])

    for %{"inputs" => inputs, "outputs" => outputs} <- added do
      {next_root, i2r, r2i} =
        Spqr.chain_epoch(hex(inputs["previous_next_root"]), hex(inputs["epoch_secret"]))

      assert next_root == hex(outputs["next_root"])
      assert i2r == hex(outputs["initiator_to_responder_chain_key"])
      assert r2i == hex(outputs["responder_to_initiator_chain_key"])
      check_chain(i2r, outputs["initiator_to_responder_keys"])
      check_chain(r2i, outputs["responder_to_initiator_keys"])
    end
  end

  defp check_keys(%Spqr{chains: %{0 => chain}, next_root: next_root}, 0, outputs) do
    assert next_root == hex(outputs["next_root"])
    assert chain.send.chain_key == hex(outputs["initiator_to_responder_chain_key"])
    assert chain.receive.chain_key == hex(outputs["responder_to_initiator_chain_key"])
    check_chain(chain.send.chain_key, outputs["initiator_to_responder_keys"])
    check_chain(chain.receive.chain_key, outputs["responder_to_initiator_keys"])
  end

  defp check_chain(chain_key, keys) do
    Enum.reduce(keys, chain_key, fn %{"index" => index} = key, chain_key ->
      {next, message_key} = Spqr.chain_next(chain_key, index)
      assert next == hex(key["next_chain_key_after"])
      assert message_key == hex(key["message_key"])
      next
    end)
  end

  test "field-5 variants of a first message get the oracle's outcome (spqr-field-variants)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("spqr-field-variants.json") do
      bytes = hex(inputs["pre_key_message"])
      {:ok, pre_key_message} = PreKeyMessage.decode(bytes)
      assert pre_key_message.message.pq_message == non_empty(hex(inputs["post_quantum_message"]))

      {sender, recipient} = addresses(pre_key_message.message.address_binding)

      context = %{
        identity: Keys.ec_keypair(hex(inputs["responder_identity_private"])),
        registration_id: 1,
        local_address: recipient,
        remote_address: sender,
        trusted?: fn _key, _direction -> true end
      }

      pre_keys = fn
        {:signed_pre_key, _id} -> {:ok, hex(inputs["responder_signed_pre_key_private"])}
        {:one_time_pre_key, _id} -> {:ok, hex(inputs["responder_one_time_pre_key_private"])}
        {:kem_pre_key, _id} -> {:ok, hex(inputs["responder_kem_secret_key"])}
        {:kem_pre_key_used?, _, _, _} -> false
      end

      case {outputs["result"], Session.decrypt_pre_key(nil, bytes, context, pre_keys)} do
        {"plaintext", {:ok, plaintext, _record, _effects}} ->
          assert plaintext == hex(outputs["plaintext"]), inputs["label"]

        {"rejected", {:error, outcome}} ->
          assert outcome == :invalid, inputs["label"]

        {expected, other} ->
          flunk("#{inputs["label"]}: expected #{expected}, got #{inspect(other)}")
      end
    end
  end

  defp non_empty(<<>>), do: nil
  defp non_empty(bytes), do: bytes

  # The generator's addresses, read back from the binding it wrote.
  defp addresses(
         <<sender::binary-size(17), sender_device, recipient::binary-size(17), recipient_device>>
       ),
       do:
         {Address.new(service_id(sender), sender_device),
          Address.new(service_id(recipient), recipient_device)}

  defp service_id(<<kind, a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    uuid = Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
    if kind == 1, do: "PNI:" <> uuid, else: uuid
  end

  describe "state machine" do
    test "an epoch completes in both roles and the next epoch starts with the roles swapped" do
      secret = :crypto.strong_rand_bytes(32)

      {alice, bob} =
        Enum.reduce(1..90, {Spqr.new(:initiator, secret), Spqr.new(:responder, secret)}, fn _step,
                                                                                            {alice,
                                                                                             bob} ->
          {alice, bob} = exchange(alice, bob)
          {bob, alice} = exchange(bob, alice)
          {alice, bob}
        end)

      assert alice.epoch >= 2 and bob.epoch >= 2
      assert alice.top_chain_epoch >= 1 and bob.top_chain_epoch >= 1
    end

    test "a message from a future epoch, or a reused index, is rejected without a state change" do
      secret = :crypto.strong_rand_bytes(32)
      alice = Spqr.new(:initiator, secret)
      bob = Spqr.new(:responder, secret)
      {:ok, bytes, _key, _alice} = Spqr.send(alice, :crypto.strong_rand_bytes(64))

      {:ok, _key, bob_after} = Spqr.receive(bob, bytes)
      assert Spqr.receive(bob_after, bytes) == {:error, :invalid}

      {:ok, message} = Message.decode(bytes)
      assert Spqr.receive(bob, Message.encode(%{message | epoch: 2})) == {:error, :invalid}
    end

    test "a failed decapsulation when ciphertext 2 completes rejects the message" do
      secret = :crypto.strong_rand_bytes(32)

      # Alternate until Alice, the key owner of epoch 1, waits for ciphertext 2.
      {alice, bob} =
        Enum.reduce_while(1..200, {Spqr.new(:initiator, secret), Spqr.new(:responder, secret)}, fn
          _step, {%Spqr{agreement: %{name: :o5}}, _bob} = parties ->
            {:halt, parties}

          _step, {alice, bob} ->
            {alice, bob} = exchange(alice, bob)
            {bob, alice} = exchange(bob, alice)
            {:cont, {alice, bob}}
        end)

      assert alice.agreement.name == :o5
      # A decapsulation key that the KEM backend refuses, as a damaged record could hold.
      broken = update_in(alice.agreement.dk, &binary_part(&1, 0, byte_size(&1) - 1))

      # Bob's ciphertext-2 chunks; one of them completes the payload.
      outcome =
        Enum.reduce_while(1..10, {bob, alice, broken}, fn _step, {bob, alice, broken} ->
          {:ok, bytes, _key, bob} = Spqr.send(bob, :crypto.strong_rand_bytes(64))
          {:ok, _key, next_alice} = Spqr.receive(alice, bytes)

          case Spqr.receive(broken, bytes) do
            {:ok, _key, next_broken} -> {:cont, {bob, next_alice, next_broken}}
            error -> {:halt, {error, next_alice}}
          end
        end)

      assert {{:error, :invalid}, %Spqr{epoch: 2}} = outcome
    end

    # CRS-04b §5.3 and Q5 (clean question C2-1): in a one-way stream of
    # 65540 messages in state O2, the header chunk indices wrap to 0 after
    # 65535, the wrapped chunks repeat the first ones, and every message
    # still decrypts.
    @tag timeout: 300_000
    test "chunk indices wrap modulo 65536 in a long one-way stream" do
      secret = :crypto.strong_rand_bytes(32)

      {_alice, _bob, chunks} =
        Enum.reduce(
          1..65_540,
          {Spqr.new(:initiator, secret), Spqr.new(:responder, secret), []},
          fn _step, {alice, bob, chunks} ->
            {:ok, bytes, key, alice} = Spqr.send(alice, :crypto.strong_rand_bytes(64))
            assert {:ok, ^key, bob} = Spqr.receive(bob, bytes)
            {:ok, %Message{type: 1} = message} = Message.decode(bytes)
            {alice, bob, [{message.chunk_index, message.chunk} | chunks]}
          end
        )

      chunks = Enum.reverse(chunks)
      last = Enum.take(chunks, -7)
      assert Enum.map(last, &elem(&1, 0)) == [65_533, 65_534, 65_535, 0, 1, 2, 3]
      assert Enum.take(last, -4) == Enum.take(chunks, 4)
    end
  end

  defp exchange(sender, receiver) do
    {:ok, bytes, key, sender} = Spqr.send(sender, :crypto.strong_rand_bytes(64))
    assert {:ok, ^key, receiver} = Spqr.receive(receiver, bytes)
    {sender, receiver}
  end
end
