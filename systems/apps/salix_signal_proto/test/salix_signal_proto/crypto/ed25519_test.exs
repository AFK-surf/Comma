defmodule SalixSignalProto.Crypto.Ed25519Test do
  use ExUnit.Case, async: true

  alias SalixSignalProto.Crypto.Ed25519
  alias SalixSignalProto.Test.Vectors

  @vectors Vectors.load!("public/rfc8032_ed25519.json")["ed25519"]

  test "RFC 8032 section 7.1 vectors: public key, signature and verification" do
    for vector <- @vectors do
      secret = Vectors.hex!(vector["secret_key"])
      public = Vectors.hex!(vector["public_key"])
      message = Vectors.hex!(vector["message"])
      signature = Vectors.hex!(vector["signature"])

      assert Ed25519.public_key(secret) == public, "TEST #{vector["name"]}"
      assert Ed25519.sign(secret, message) == signature, "TEST #{vector["name"]}"
      assert Ed25519.verify(public, message, signature), "TEST #{vector["name"]}"
    end
  end

  test "verification rejects a changed message or signature and malformed inputs" do
    [vector | _] = @vectors
    public = Vectors.hex!(vector["public_key"])
    <<first, rest::binary>> = signature = Vectors.hex!(vector["signature"])

    refute Ed25519.verify(public, "x", signature)
    refute Ed25519.verify(public, "", <<Bitwise.bxor(first, 1), rest::binary>>)
    refute Ed25519.verify(public, "", binary_part(signature, 0, 63))
    refute Ed25519.verify(binary_part(public, 0, 31), "", signature)
  end
end
