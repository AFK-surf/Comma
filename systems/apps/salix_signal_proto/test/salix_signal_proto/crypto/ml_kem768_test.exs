defmodule SalixSignalProto.Crypto.MlKem768Test do
  # FIPS 203 ML-KEM-768 as the post-quantum ratchet uses it (CRS-04b §8),
  # against the CRS-04b vector spqr-mlkem768.json.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Crypto.MlKem768
  alias SalixSignalProto.Test.Vectors

  test "decapsulates the oracle epochs to the FIPS 203 secret; header and key part come from the key" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-04b/spqr-mlkem768.json")["cases"] do
      dk = Vectors.hex!(inputs["decapsulation_key"])
      ciphertext = Vectors.hex!(inputs["ciphertext_1"]) <> Vectors.hex!(inputs["ciphertext_2"])

      assert {:ok, secret} = MlKem768.decapsulate_plain(dk, ciphertext)
      assert secret == Vectors.hex!(outputs["shared_secret"])
      assert MlKem768.decapsulate(dk, ciphertext) == {:ok, secret}
      refute secret == Vectors.hex!(outputs["kyber768_round3_decapsulation_for_contrast"])

      <<_dk_pke::binary-size(1152), ek::binary-size(1184), _::binary>> = dk
      <<t::binary-size(1152), rho::binary-size(32)>> = ek
      assert rho <> :crypto.hash(:sha3_256, ek) == Vectors.hex!(outputs["header"])
      assert t == Vectors.hex!(outputs["key_part"])
      assert MlKem768.valid_encapsulation_key?(ek)
    end
  end

  property "the two encapsulation steps give the one-step ciphertext, which decapsulates" do
    check all(
            d <- binary(length: 32),
            z <- binary(length: 32),
            m <- binary(length: 32),
            max_runs: 5
          ) do
      {ek, dk} = MlKem768.keypair_from_seed(d, z)
      <<t::binary-size(1152), rho::binary-size(32)>> = ek

      {secret, c1, r} = MlKem768.encapsulate_first(rho, :crypto.hash(:sha3_256, ek), m)
      c2 = MlKem768.encapsulate_second(t, r, m)

      assert MlKem768.encapsulate(ek, m) == {secret, c1 <> c2}
      assert MlKem768.decapsulate(dk, c1 <> c2) == {:ok, secret}
    end
  end

  test "keys from keypair/1 decapsulate what the split encapsulation makes" do
    {ek, dk} = MlKem768.keypair(:crypto.strong_rand_bytes(64))
    {secret, ciphertext} = MlKem768.encapsulate(ek, :crypto.strong_rand_bytes(32))
    assert MlKem768.decapsulate(dk, ciphertext) == {:ok, secret}
    assert MlKem768.decapsulate_plain(dk, ciphertext) == {:ok, secret}
  end

  test "the modulus check refuses a key with a coefficient at or above q" do
    {ek, _dk} = MlKem768.keypair_from_seed(<<1::256>>, <<2::256>>)
    <<_b0, b1, rest::binary>> = ek
    # Coefficient 0 = b0 + 256 * (b1 & 15); 0xFFF = 4095 >= 3329.
    refute MlKem768.valid_encapsulation_key?(<<0xFF, Bitwise.bor(b1, 0x0F), rest::binary>>)
  end
end
