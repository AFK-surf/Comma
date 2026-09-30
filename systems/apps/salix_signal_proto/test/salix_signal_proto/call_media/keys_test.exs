defmodule SalixSignalProto.CallMedia.KeysTest do
  use ExUnit.Case, async: true

  alias SalixSignalProto.CallMedia.Keys
  alias SalixSignalProto.Test.Vectors

  # CRS-13 section 4: vectors/CRS-13/direct-srtp-key-derivation.json
  describe "CRS-13 direct-srtp-key-derivation" do
    for {vector, index} <-
          Enum.with_index(Vectors.load!("crs/CRS-13/direct-srtp-key-derivation.json")["cases"]) do
      @vector vector
      test "case #{index}: both sides derive the oracle keys" do
        input = hex_map(@vector["inputs"])
        out = hex_map(@vector["outputs"])

        caller_public = Keys.public_key(input["caller_ephemeral_private"])
        callee_public = Keys.public_key(input["callee_ephemeral_private"])
        assert caller_public == out["caller_ephemeral_public"]
        assert callee_public == out["callee_ephemeral_public"]

        caller_ik = Keys.public_key(input["caller_identity_private_for_test"])
        callee_ik = Keys.public_key(input["callee_identity_private_for_test"])
        assert caller_ik == out["caller_identity_public"]
        assert callee_ik == out["callee_identity_public"]

        assert Keys.label() <> caller_ik <> callee_ik == out["hkdf_info"]

        assert {:ok, out["okm_88"]} ==
                 Keys.okm(input["caller_ephemeral_private"], callee_public, caller_ik, callee_ik)

        caller_to_callee = %{
          key: out["caller_to_callee_srtp_key"],
          salt: out["caller_to_callee_srtp_salt"]
        }

        callee_to_caller = %{
          key: out["callee_to_caller_srtp_key"],
          salt: out["callee_to_caller_srtp_salt"]
        }

        assert {:ok, %{send: ^caller_to_callee, receive: ^callee_to_caller}} =
                 Keys.derive(
                   :caller,
                   input["caller_ephemeral_private"],
                   callee_public,
                   caller_ik,
                   callee_ik
                 )

        assert {:ok, %{send: ^callee_to_caller, receive: ^caller_to_callee}} =
                 Keys.derive(
                   :callee,
                   input["callee_ephemeral_private"],
                   caller_public,
                   caller_ik,
                   callee_ik
                 )
      end
    end
  end

  # CRS-13 section 4.2 step 2: vectors/CRS-13/direct-srtp-low-order-reject.json
  describe "CRS-13 direct-srtp-low-order-reject" do
    for {vector, index} <-
          Enum.with_index(Vectors.load!("crs/CRS-13/direct-srtp-low-order-reject.json")["cases"]) do
      @vector vector
      test "case #{index}: a low-order peer key rejects the call" do
        input = hex_map(@vector["inputs"])
        assert @vector["outputs"]["result"] == "rejected"
        identity = :crypto.strong_rand_bytes(32)

        assert {:error, :invalid_public_key} =
                 Keys.derive(
                   :callee,
                   input["local_ephemeral_private"],
                   input["remote_public_key"],
                   identity,
                   identity
                 )
      end
    end
  end

  test "a peer key or identity key of the wrong length is refused" do
    {_public, private} = Keys.generate_keypair()
    {peer, _} = Keys.generate_keypair()
    ik = :crypto.strong_rand_bytes(32)

    assert {:error, :invalid_public_key} =
             Keys.derive(:caller, private, <<5, peer::binary>>, ik, ik)

    assert {:error, :invalid_identity_key} =
             Keys.derive(:caller, private, peer, <<5, ik::binary>>, ik)
  end

  defp hex_map(map), do: Map.new(map, fn {key, value} -> {key, Vectors.hex!(value)} end)
end
