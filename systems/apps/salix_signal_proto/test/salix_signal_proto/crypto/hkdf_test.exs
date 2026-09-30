defmodule SalixSignalProto.Crypto.HkdfTest do
  use ExUnit.Case, async: true

  alias SalixSignalProto.Crypto.Hkdf
  alias SalixSignalProto.Test.Vectors

  @cases Vectors.load!("public/rfc5869_hkdf.json")["hkdf"]

  test "RFC 5869 appendix A.1-A.3 (SHA-256): PRK and OKM" do
    for c <- @cases do
      ikm = Vectors.hex!(c["ikm"])
      salt = Vectors.hex!(c["salt"])
      info = Vectors.hex!(c["info"])

      assert Hkdf.extract(salt, ikm) == Vectors.hex!(c["prk"]), c["name"]
      assert Hkdf.derive(ikm, salt, info, c["length"]) == Vectors.hex!(c["okm"]), c["name"]
    end
  end

  test "CRS-04 hkdf-uses.json: deployed labels; no salt, zero salt and empty salt agree" do
    for %{"inputs" => inputs, "outputs" => %{"okm" => okm}} <-
          Vectors.load!("crs/CRS-04/hkdf-uses.json")["cases"] do
      salt = if inputs["salt"], do: Vectors.hex!(inputs["salt"]), else: ""
      info = Vectors.hex!(inputs["info"])

      assert info == inputs["info_ascii"]

      assert Hkdf.derive(Vectors.hex!(inputs["ikm"]), salt, info, inputs["length"]) ==
               Vectors.hex!(okm),
             inputs["label"]
    end
  end

  test "output is limited to 255 hash blocks" do
    prk = :crypto.strong_rand_bytes(32)
    assert byte_size(Hkdf.expand(prk, "", 255 * 32)) == 255 * 32
    assert_raise ArgumentError, fn -> Hkdf.expand(prk, "", 255 * 32 + 1) end
    assert byte_size(Hkdf.expand(prk, "", 255 * 64, :sha512)) == 255 * 64
  end
end
