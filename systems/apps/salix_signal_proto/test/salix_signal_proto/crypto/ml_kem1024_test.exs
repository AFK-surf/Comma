defmodule SalixSignalProto.Crypto.MlKem1024Test do
  # FIPS 203 ML-KEM-1024, the KEM of the contact discovery channel (CRS-11
  # §4.2), against the public C2SP CCTV intermediate values.
  use ExUnit.Case, async: true

  alias SalixSignalProto.Crypto.{Kyber1024, MlKem1024}
  alias SalixSignalProto.Test.Vectors

  test "CCTV vector: encapsulation and decapsulation give the FIPS 203 secret" do
    v = Vectors.load!("public/cctv_ml_kem1024.json")
    ek = Vectors.hex!(v["ek"])
    dk = Vectors.hex!(v["dk"])
    c = Vectors.hex!(v["c"])
    k = Vectors.hex!(v["K"])

    assert MlKem1024.encapsulate(ek, Vectors.hex!(v["m"])) == {:ok, {k, c}}
    assert MlKem1024.decapsulate_plain(dk, c) == {:ok, k}
    assert MlKem1024.decapsulate(dk, c) == {:ok, k}
  end

  test "keys round-trip; a changed ciphertext yields the implicit-rejection secret" do
    {ek, dk} = MlKem1024.keypair(:crypto.strong_rand_bytes(64))
    {:ok, {secret, c}} = MlKem1024.encapsulate(ek, :crypto.strong_rand_bytes(32))
    assert MlKem1024.decapsulate(dk, c) == {:ok, secret}

    <<first, rest::binary>> = c
    changed = <<Bitwise.bxor(first, 1), rest::binary>>
    z = binary_part(dk, byte_size(dk) - 32, 32)

    assert MlKem1024.decapsulate(dk, changed) ==
             {:ok, :crypto.hash_xof(:shake256, z <> changed, 256)}
  end

  test "differs from round-3 Kyber1024 on the same keys" do
    {ek, dk} = MlKem1024.keypair_from_seed(<<1::256>>, <<2::256>>)
    assert {ek, dk} == Kyber1024.keypair_from_seed(<<1::256>>, <<2::256>>, :fips203)
    {:ok, {secret, c}} = MlKem1024.encapsulate(ek, <<3::256>>)
    refute Kyber1024.decapsulate(dk, c) == {:ok, secret}
  end

  test "inputs of the wrong size are refused" do
    assert MlKem1024.decapsulate(<<0>>, <<0>>) == {:error, :invalid_input}
    assert MlKem1024.encapsulate(<<0>>, <<0::256>>) == {:error, :invalid_input}
  end
end
