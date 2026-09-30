defmodule SalixSignalProto.Session.DerivationTest do
  # Key derivations and message layout of the session protocol (CRS-04 §3,
  # §4, §7) against the CRS-04 vectors hkdf-uses.json, chain-step.json,
  # root-step.json, pqxdh-initiator.json, signal-message-encode.json and
  # address-binding.json.
  use ExUnit.Case, async: true

  alias SalixSignalProto.{Address, Keys}
  alias SalixSignalProto.Session.{Kdf, Message, PreKeyMessage, Pqxdh}
  alias SalixSignalProto.Test.Vectors

  defp cases(file), do: Vectors.load!("crs/CRS-04/" <> file)["cases"]
  defp hex(nil), do: nil
  defp hex(value), do: Vectors.hex!(value)

  defp keys(%{cipher_key: cipher_key, mac_key: mac_key, iv: iv}), do: cipher_key <> mac_key <> iv

  test "message-key expansion with each salt form (hkdf-uses)" do
    for %{"inputs" => %{"info_ascii" => "WhisperMessageKeys"} = inputs, "outputs" => outputs} <-
          cases("hkdf-uses.json") do
      assert keys(Kdf.message_keys(hex(inputs["ikm"]), hex(inputs["salt"]))) ==
               hex(outputs["okm"]),
             inputs["label"]
    end
  end

  test "chain steps and message keys without a post-quantum salt (chain-step)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("chain-step.json") do
      chain_key = hex(inputs["chain_key"])
      seed = Kdf.seed(chain_key)

      assert Kdf.next(chain_key) == hex(outputs["next_chain_key"])
      assert seed == hex(outputs["message_key_seed"])

      assert Kdf.message_keys(seed, nil) == %{
               cipher_key: hex(outputs["cipher_key_without_pq_salt"]),
               mac_key: hex(outputs["mac_key_without_pq_salt"]),
               iv: hex(outputs["iv_without_pq_salt"])
             }
    end
  end

  test "DH ratchet steps on receipt (root-step)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("root-step.json") do
      their = hex(inputs["their_new_ratchet_public"])
      ours = Keys.ec_keypair(hex(inputs["our_new_ratchet_private"]))

      {:ok, {half, receiving}} =
        Kdf.root_step(hex(inputs["root_key"]), hex(inputs["our_ratchet_private"]), their)

      {:ok, {root, sending}} = Kdf.root_step(half, ours.private, their)

      assert half == hex(outputs["root_key_after_receive_half"])
      assert receiving == hex(outputs["receiving_chain_key_0"])
      assert root == hex(outputs["root_key_after"])
      assert sending == hex(outputs["sending_chain_key_0"])
      assert ours.public == hex(outputs["our_new_ratchet_public"])

      assert max(inputs["our_previous_sending_chain_index"] - 1, 0) ==
               outputs["previous_chain_length_after"]

      assert Kdf.next(receiving) ==
               hex(outputs["receiving_chain_state_after_first_message"]["chain_key"])
    end
  end

  test "PQXDH as responder reproduces the oracle initiator's keys (pqxdh-initiator)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("pqxdh-initiator.json") do
      one_time = hex(inputs["responder_one_time_pre_key_private"])

      {:ok, result} =
        Pqxdh.respond(%{
          identity_private: hex(inputs["responder_identity_private"]),
          signed_pre_key_private: hex(inputs["responder_signed_pre_key_private"]),
          one_time_pre_key_private: one_time,
          kem_secret: hex(inputs["responder_kem_secret_key"]),
          identity_key: hex(inputs["initiator_identity_public"]),
          base_key: hex(inputs["initiator_ephemeral_public"]),
          kem_ciphertext: hex(inputs["kem_ciphertext"])
        })

      assert result.root_key <> result.chain_key <> result.pq_secret == hex(outputs["okm_96"])
      assert result.root_key == hex(outputs["root_key_0"])
      assert result.chain_key == hex(outputs["chain_key_0"])

      assert Keys.kem_decapsulate(
               hex(inputs["responder_kem_secret_key"]),
               hex(inputs["kem_ciphertext"])
             ) ==
               {:ok, hex(outputs["kyber_shared_secret"])}

      dh_values = Enum.map(outputs["dh_values"], &hex/1)

      assert Pqxdh.secret_input(dh_values, hex(outputs["kyber_shared_secret"])) ==
               hex(outputs["secret_input"])

      assert length(dh_values) == if(one_time, do: 4, else: 3)

      ratchet = Keys.ec_keypair(hex(outputs["initiator_first_sending_ratchet_private"]))
      assert ratchet.public == hex(outputs["initiator_first_sending_ratchet_public"])

      assert Kdf.root_step(
               result.root_key,
               ratchet.private,
               hex(inputs["responder_signed_pre_key_public"])
             ) ==
               {:ok, {hex(outputs["root_key_1"]), hex(outputs["sending_chain_key_0"])}}
    end
  end

  test "double-ratchet message layout and MAC (signal-message-encode)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("signal-message-encode.json") do
      fields = %{
        version: inputs["session_version"],
        ratchet_key: hex(inputs["ratchet_public_key"]),
        message_number: inputs["message_number"],
        previous_chain_length: inputs["previous_chain_length"],
        body: hex(inputs["encrypted_body"]),
        pq_message: hex(inputs["post_quantum_message"])
      }

      sender = hex(inputs["sender_identity"])
      receiver = hex(inputs["receiver_identity"])
      mac_key = hex(inputs["mac_key"])
      serialized = hex(outputs["serialized"])

      assert Message.encode(fields, mac_key, sender, receiver) == serialized
      assert {:ok, message} = Message.decode(serialized)
      assert message.message_number == inputs["message_number"]
      assert message.previous_chain_length == inputs["previous_chain_length"]
      assert Message.valid_mac?(message, mac_key, sender, receiver)
      refute Message.valid_mac?(message, mac_key, receiver, sender)
    end
  end

  test "double-ratchet message parsing rules (CRS-04 §7.2)" do
    assert Message.decode(<<0x44, 0::64>> |> binary_part(0, 8)) == {:error, :too_short}
    assert Message.decode(<<0x24, 0::64>>) == {:error, :legacy_version}
    assert Message.decode(<<0x54, 0::64>>) == {:error, :unknown_version}
    # Version 4 with an empty protocol buffer lacks fields 1, 2 and 4.
    assert Message.decode(<<0x44, 0::64>>) == {:error, :malformed}
  end

  test "address binding layout for ACI and PNI recipients (address-binding)" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("address-binding.json") do
      sender = Address.new(inputs["sender"]["service_id"], inputs["sender"]["device_id"])
      recipient = Address.new(inputs["recipient"]["service_id"], inputs["recipient"]["device_id"])
      binding = hex(outputs["address_binding"])

      assert Address.binding(sender, recipient) == binding
      assert {:ok, message} = PreKeyMessage.decode(hex(inputs["pre_key_message"]))
      assert message.message.address_binding == binding

      wrong =
        Address.new(
          outputs["wrong_local_address"]["service_id"],
          outputs["wrong_local_address"]["device_id"]
        )

      refute Address.binding(sender, wrong) == binding
    end
  end

  test "names that are not service IDs, or bad device IDs, give no binding" do
    aci = Address.new("00000000-0000-4000-8000-000000000011", 1)
    assert Address.binding(aci, Address.new("local", 1)) == nil
    assert Address.binding(aci, %{aci | device_id: 0}) == nil
    assert Address.binding(aci, %{aci | device_id: 128}) == nil
  end
end
