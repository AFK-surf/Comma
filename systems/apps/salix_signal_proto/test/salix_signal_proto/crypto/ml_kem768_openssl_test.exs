defmodule SalixSignalProto.Crypto.MlKem768OpensslTest do
  # ML-KEM-768 of the post-quantum ratchet (CRS-04b §8) on the OTP :crypto
  # backend, which production uses for key generation and decapsulation
  # (SalixSignalProto.KemBackend), against the CRS-04b vector
  # spqr-mlkem768.json and the plain-Elixir encapsulation steps.
  #
  # OpenSSL 3.5 or later is required; the release image (Debian trixie) has
  # it. On hosts with an older OpenSSL these tests skip, and the
  # test-signal-proto-trixie CI job runs them in a build that does not allow
  # the plain-Elixir fallback.
  use ExUnit.Case, async: true

  import Bitwise

  alias SalixSignalProto.Crypto.MlKem768
  alias SalixSignalProto.KemBackend
  alias SalixSignalProto.Session.Spqr
  alias SalixSignalProto.Test.Vectors

  @moduletag skip: not KemBackend.openssl?(:mlkem768) && "the linked OpenSSL has no ML-KEM-768"

  test "the secret-key operations run in OpenSSL" do
    assert KemBackend.select!(:mlkem768) == :openssl
  end

  test "CRS-04b spqr-mlkem768.json: OpenSSL decapsulates the oracle epochs to the FIPS 203 secret" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-04b/spqr-mlkem768.json")["cases"] do
      dk = Vectors.hex!(inputs["decapsulation_key"])
      ciphertext = Vectors.hex!(inputs["ciphertext_1"]) <> Vectors.hex!(inputs["ciphertext_2"])

      assert MlKem768.decapsulate(dk, ciphertext) == {:ok, Vectors.hex!(outputs["shared_secret"])}
    end
  end

  test "OpenSSL key pairs have the FIPS 203 layout and decapsulate the two-step encapsulation" do
    {ek, dk} = MlKem768.keypair(:crypto.strong_rand_bytes(64))
    assert {byte_size(ek), byte_size(dk)} == {1184, 2400}
    # dk = dk_pke (1152) || ek (1184) || H(ek) (32) || z (32).
    assert binary_part(dk, 1152, 1184) == ek
    assert binary_part(dk, 2336, 32) == :crypto.hash(:sha3_256, ek)
    assert MlKem768.valid_encapsulation_key?(ek)

    <<t::binary-size(1152), rho::binary-size(32)>> = ek
    m = :crypto.strong_rand_bytes(32)
    {secret, c1, r} = MlKem768.encapsulate_first(rho, :crypto.hash(:sha3_256, ek), m)
    c2 = MlKem768.encapsulate_second(t, r, m)
    assert MlKem768.decapsulate(dk, c1 <> c2) == {:ok, secret}

    # Implicit rejection agrees with the plain-Elixir decapsulation.
    <<first, rest::binary>> = c1 <> c2
    changed = <<bxor(first, 1), rest::binary>>
    {:ok, rejected} = MlKem768.decapsulate(dk, changed)
    assert rejected != secret
    assert MlKem768.decapsulate_plain(dk, changed) == {:ok, rejected}
  end

  test "a decapsulation key that fails the FIPS 203 hash check is refused, not raised" do
    {ek, dk} = MlKem768.keypair(:crypto.strong_rand_bytes(64))
    {_secret, ciphertext} = MlKem768.encapsulate(ek, :crypto.strong_rand_bytes(32))
    <<before::binary-size(2336), byte, after_byte::binary>> = dk

    assert MlKem768.decapsulate(<<before::binary, bxor(byte, 1), after_byte::binary>>, ciphertext) ==
             {:error, :invalid_input}
  end

  test "post-quantum ratchet epochs complete with OpenSSL key generation and decapsulation" do
    secret = :crypto.strong_rand_bytes(32)

    {alice, bob} =
      Enum.reduce(1..100, {Spqr.new(:initiator, secret), Spqr.new(:responder, secret)}, fn
        _step, {alice, bob} ->
          {alice, bob} = exchange(alice, bob)
          {bob, alice} = exchange(bob, alice)
          {alice, bob}
      end)

    # Epoch 1 completes with Alice as key owner and epoch 2 with Bob.
    assert alice.epoch >= 3 and bob.epoch >= 3
  end

  defp exchange(sender, receiver) do
    {:ok, bytes, key, sender} = Spqr.send(sender, :crypto.strong_rand_bytes(64))
    assert {:ok, ^key, receiver} = Spqr.receive(receiver, bytes)
    {sender, receiver}
  end
end
