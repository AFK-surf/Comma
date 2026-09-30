defmodule SalixSignalProto.SenderKey.RecordTest do
  # Level 1 vectors of CRS-09c (vectors/CRS-09): distribution messages,
  # sender key messages from a fixed chain, the receiver state machine and
  # the forward jump limit.
  use ExUnit.Case, async: true

  alias SalixSignalProto.SenderKey.{Message, Record}
  alias SalixSignalProto.Test.Vectors

  defp load(name), do: Vectors.load!("crs/CRS-09/#{name}.json")
  defp hex(value), do: Vectors.hex!(value)
  defp uuid(text), do: text |> String.replace("-", "") |> hex()

  defp distribution(fields) do
    Message.encode_distribution(%{
      distribution_id: uuid(fields["distribution_id"]),
      chain_id: fields["chain_id"],
      iteration: fields["iteration"] || fields["starting_iteration"] || 0,
      chain_key: hex(fields["chain_key"]),
      signing_key: hex(fields["signing_public_key"])
    })
  end

  test "section 2: distribution messages encode byte for byte and decode" do
    for %{"inputs" => inputs, "outputs" => out} <-
          load("sender-key-distribution-message")["cases"] do
      bytes = hex(out["serialized"])
      assert distribution(inputs) == bytes
      {:ok, decoded} = Message.decode_distribution(bytes)
      assert decoded.chain_id == out["parsed_chain_id"]
      assert decoded.iteration == out["parsed_iteration"]
      assert decoded.chain_key == hex(inputs["chain_key"])
    end
  end

  test "sections 3 to 5: a sender's messages match; receivers decrypt out of order, once" do
    for %{"inputs" => inputs, "outputs" => out, "label" => label} <-
          load("sender-key-message")["cases"] do
      distribution_id = uuid(inputs["distribution_id"])
      signing_public = hex(inputs["signing_public_key"])

      sender =
        Record.create(Record.new(),
          chain_id: inputs["chain_id"],
          iteration: inputs["starting_iteration"],
          chain_key: hex(inputs["chain_key"]),
          signing_private: hex(inputs["signing_private_key"])
        )

      {_sender, _} =
        Enum.reduce(out["messages"], {sender, nil}, fn expected, {sender, _} ->
          {:ok, bytes, sender} =
            Record.encrypt(sender, distribution_id, hex(expected["plaintext"]))

          {:ok, ours} = Message.decode_message(bytes)
          {:ok, theirs} = Message.decode_message(hex(expected["sender_key_message"]))

          # Everything but the randomized signature is deterministic.
          assert ours.signed == theirs.signed, label
          assert ours.iteration == expected["iteration"]
          assert Message.verify(ours, signing_public)
          assert Message.verify(theirs, signing_public)
          {sender, nil}
        end)

      messages = Enum.map(out["messages"], &hex(&1["sender_key_message"]))

      {:ok, receiver, ^distribution_id} =
        Record.process_distribution(Record.new(), distribution(inputs))

      receiver =
        Enum.reduce(out["decrypt_order_results"], receiver, fn %{"index" => i, "plaintext" => pt},
                                                               receiver ->
          {:ok, plaintext, receiver} = Record.decrypt(receiver, Enum.at(messages, i))
          assert plaintext == hex(pt), label
          receiver
        end)

      assert out["redecrypt_first_message"] == "error:duplicate"
      assert Record.decrypt(receiver, hd(messages)) == {:error, :duplicate}

      assert out["decrypt_with_flipped_signature_bit"] == "error:bad-signature"
      {:ok, fresh, _} = Record.process_distribution(Record.new(), distribution(inputs))
      assert Record.decrypt(fresh, flip_last_bit(hd(messages))) == {:error, :bad_signature}

      assert Record.decode(Record.encode(receiver)) == {:ok, receiver}
    end
  end

  defp flip_last_bit(bytes) do
    size = byte_size(bytes) - 1
    <<head::binary-size(^size), last>> = bytes
    head <> <<Bitwise.bxor(last, 1)>>
  end

  test "section 5: a receiver accepts a jump of 25000 iterations and rejects 25001" do
    file = load("sender-key-forward-jump-limit")

    for %{"inputs" => inputs, "outputs" => %{"result" => result}, "label" => label} <-
          file["cases"] do
      {:ok, receiver, _} = Record.process_distribution(Record.new(), distribution(file))
      decrypted = Record.decrypt(receiver, hex(inputs["sender_key_message"]))

      case result do
        "ok" -> assert {:ok, _, _} = decrypted
        "error:too-far-ahead" -> assert decrypted == {:error, :too_far_ahead}, label
      end
    end
  end

  test "a repeated distribution keeps the chain position; a new one replaces the chain" do
    distribution_id = <<1::128>>
    sender = Record.create(Record.new(), chain_id: 7)
    {:ok, first} = Record.distribution_message(sender, distribution_id)
    {:ok, m0, sender} = Record.encrypt(sender, distribution_id, "zero")
    {:ok, m1, _sender} = Record.encrypt(sender, distribution_id, "one")

    {:ok, receiver, _} = Record.process_distribution(Record.new(), first)
    {:ok, "one", receiver} = Record.decrypt(receiver, m1)

    # The same chain again (an old iteration) does not rewind the receiver.
    {:ok, receiver, _} = Record.process_distribution(receiver, first)
    assert Record.decrypt(receiver, m1) == {:error, :duplicate}
    assert {:ok, "zero", _} = Record.decrypt(receiver, m0)

    # A new key with the same chain ID replaces the held chain.
    rotated = Record.create(Record.new(), chain_id: 7)
    {:ok, second} = Record.distribution_message(rotated, distribution_id)
    {:ok, receiver, _} = Record.process_distribution(receiver, second)
    assert Record.decrypt(receiver, m0) == {:error, :bad_signature}
    {:ok, n0, _} = Record.encrypt(rotated, distribution_id, "new")
    assert {:ok, "new", _} = Record.decrypt(receiver, n0)
    assert length(receiver.chains) == 1
  end

  test "a receiver holds at most 5 chains and 2000 skipped message keys" do
    distribution_id = <<2::128>>

    senders = for id <- 1..6, do: Record.create(Record.new(), chain_id: id)

    receiver =
      Enum.reduce(senders, Record.new(), fn sender, receiver ->
        {:ok, message} = Record.distribution_message(sender, distribution_id)
        {:ok, receiver, _} = Record.process_distribution(receiver, message)
        receiver
      end)

    assert Enum.map(receiver.chains, & &1.chain_id) == [6, 5, 4, 3, 2]
    {:ok, oldest, _} = Record.encrypt(hd(senders), distribution_id, "gone")
    assert Record.decrypt(receiver, oldest) == {:error, :no_sender_key}

    # Skip 2500 iterations: only the newest 2000 skipped keys are kept.
    sender = List.last(senders)
    {:ok, early, sender} = Record.encrypt(sender, distribution_id, "early")

    sender =
      Enum.reduce(1..2499, sender, fn _, s ->
        {:ok, _, s} = Record.encrypt(s, distribution_id, "")
        s
      end)

    {:ok, near, sender} = Record.encrypt(sender, distribution_id, "near")
    {:ok, latest, _} = Record.encrypt(sender, distribution_id, "latest")
    {:ok, "latest", receiver} = Record.decrypt(receiver, latest)
    assert length(hd(receiver.chains).skipped) == 2000
    assert {:ok, "near", _} = Record.decrypt(receiver, near)
    assert Record.decrypt(receiver, early) == {:error, :duplicate}
  end

  test "messages with a wrong version or too short are rejected" do
    assert Message.decode_distribution(<<0x23, 0::512>>) == {:error, :old_version}
    assert Message.decode_distribution(<<0x43, 0::512>>) == {:error, :unknown_version}
    assert Message.decode_message(<<0x33, 0::256>>) == {:error, :invalid_message}
    assert Record.decrypt(Record.new(), <<0x33, 0::1000>>) == {:error, :invalid_message}
  end
end
