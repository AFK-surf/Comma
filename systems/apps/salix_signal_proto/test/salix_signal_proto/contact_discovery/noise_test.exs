defmodule SalixSignalProto.ContactDiscovery.NoiseTest do
  # CRS-11 §4.2 and §4.3: the Noise NKhfs channel to the contact discovery
  # enclave. The symmetric state and the NK pattern are checked against the
  # public Noise test vectors (cacophony, Noise_NK_25519_ChaChaPoly_SHA256);
  # the HFS tokens, sizes and transport framing against the CRS text.
  use ExUnit.Case, async: true

  alias SalixSignalProto.ContactDiscovery.{Lookup, Noise}
  alias SalixSignalProto.Crypto.{MlKem1024, X25519}
  alias SalixSignalProto.Test.Vectors

  test "Noise NK vector: handshake messages, handshake hash and transport messages" do
    v = Vectors.load!("public/noise_nk_25519_chachapoly_sha256.json")
    hex = &Vectors.hex!/1
    [m1, m2 | transport] = v["messages"]
    rs = X25519.public_key(hex.(v["resp_static"]))
    prologue = hex.(v["init_prologue"])

    assert {:ok, message1, initiator} =
             Noise.initiator_write(rs,
               hfs: false,
               ephemeral: hex.(v["init_ephemeral"]),
               prologue: prologue,
               payload: hex.(m1["payload"])
             )

    assert message1 == hex.(m1["ciphertext"])

    assert {:ok, payload1, responder} =
             Noise.responder_read(hex.(v["resp_static"]), message1,
               hfs: false,
               prologue: prologue
             )

    assert payload1 == hex.(m1["payload"])

    assert {:ok, message2, responder} =
             Noise.responder_write(responder,
               ephemeral: hex.(v["resp_ephemeral"]),
               payload: hex.(m2["payload"])
             )

    assert message2 == hex.(m2["ciphertext"])
    assert {:ok, payload2, initiator} = Noise.initiator_read(initiator, message2)
    assert payload2 == hex.(m2["payload"])
    assert initiator.handshake_hash == hex.(v["handshake_hash"])
    assert responder.handshake_hash == initiator.handshake_hash

    transport
    |> Enum.with_index()
    |> Enum.reduce({initiator, responder}, fn {m, i}, {initiator, responder} ->
      {sender, receiver} =
        if rem(i, 2) == 0, do: {initiator, responder}, else: {responder, initiator}

      {:ok, ciphertext, sender} = Noise.encrypt_transport(sender, hex.(m["payload"]))
      assert ciphertext == hex.(m["ciphertext"])
      {:ok, plaintext, receiver} = Noise.decrypt_transport(receiver, ciphertext)
      assert plaintext == hex.(m["payload"])
      if rem(i, 2) == 0, do: {sender, receiver}, else: {receiver, sender}
    end)
  end

  test "the NKhfs handshake has two 1,632-byte messages and agrees on both directions" do
    {initiator, responder, message1, message2} = handshake()
    assert byte_size(message1) == 1632
    assert byte_size(message2) == 1632
    assert initiator.handshake_hash == responder.handshake_hash

    # §8 worked example: a first lookup for +14155550100 is 10 bytes of
    # plaintext and one 26-byte transport message.
    {:ok, request} = Lookup.encode_request(new_numbers: ["+14155550100"])
    assert request == Base.decode16!("1A08000000034BBC8D94")
    {:ok, sealed, _initiator} = Noise.seal(initiator, request)
    assert byte_size(sealed) == 26
    assert {:ok, ^request, _} = Noise.open(responder, sealed)

    # The token acknowledgement: 2 bytes of plaintext + 16.
    {:ok, ack, _} = Noise.seal(initiator, Lookup.token_ack())
    assert byte_size(ack) == 18
  end

  test "a long message is split into 65,519-byte chunks, one nonce each" do
    {initiator, responder, _, _} = handshake()
    plaintext = :crypto.strong_rand_bytes(2 * 65_519 + 5)

    {:ok, sealed, initiator} = Noise.seal(initiator, plaintext)
    assert byte_size(sealed) == byte_size(plaintext) + 3 * 16
    assert initiator.send.n == 3
    assert {:ok, ^plaintext, responder} = Noise.open(responder, sealed)
    assert responder.receive.n == 3

    # Responder to initiator uses the second cipher state.
    {:ok, reply, _} = Noise.seal(responder, "results")
    assert {:ok, "results", _} = Noise.open(initiator, reply)

    <<first, rest::binary>> = sealed

    assert Noise.open(
             %{responder | receive: %{responder.receive | n: 0}},
             <<Bitwise.bxor(first, 1), rest::binary>>
           ) ==
             {:error, :decrypt_failed}
  end

  test "a tampered or foreign handshake fails" do
    s = X25519.generate_private_key()
    other = X25519.generate_private_key()
    kem = MlKem1024.keypair(:crypto.strong_rand_bytes(64))

    {:ok, message1, initiator} =
      Noise.initiator_write(X25519.public_key(s),
        ephemeral: X25519.generate_private_key(),
        kem: kem
      )

    # Written to another static key: the responder cannot decrypt e1.
    assert Noise.responder_read(other, message1) == {:error, :handshake_failed}
    assert Noise.responder_read(s, binary_part(message1, 0, 1631)) == {:error, :handshake_failed}

    {:ok, _, responder} = Noise.responder_read(s, message1)

    {:ok, message2, _} =
      Noise.responder_write(responder,
        ephemeral: X25519.generate_private_key(),
        kem_randomness: :crypto.strong_rand_bytes(32)
      )

    <<head::binary-size(100), byte, tail::binary>> = message2
    tampered = <<head::binary, Bitwise.bxor(byte, 1), tail::binary>>
    assert Noise.initiator_read(initiator, tampered) == {:error, :handshake_failed}
    assert {:ok, "", _} = Noise.initiator_read(initiator, message2)
  end

  defp handshake do
    s = X25519.generate_private_key()
    kem = MlKem1024.keypair(:crypto.strong_rand_bytes(64))

    {:ok, message1, initiator} =
      Noise.initiator_write(X25519.public_key(s),
        ephemeral: X25519.generate_private_key(),
        kem: kem
      )

    {:ok, "", responder} = Noise.responder_read(s, message1)

    {:ok, message2, responder} =
      Noise.responder_write(responder,
        ephemeral: X25519.generate_private_key(),
        kem_randomness: :crypto.strong_rand_bytes(32)
      )

    {:ok, "", initiator} = Noise.initiator_read(initiator, message2)
    {initiator, responder, message1, message2}
  end
end
