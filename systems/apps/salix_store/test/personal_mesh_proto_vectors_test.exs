defmodule SalixStore.PersonalMeshProtoVectorsTest do
  use ExUnit.Case, async: true

  @types ~w(PersonalMeshDescriptor MembershipCredential EndpointObservation PairingProof RouteCapability RegistryOperation RegistryReceipt)
  @domain "agent-vmm/signature/v1\0"

  test "the registry's seven signed wire types match the shared Agent VMM vectors" do
    vectors =
      __DIR__
      |> Path.join("testdata/agent_vmm_signing_vectors.json")
      |> File.read!()
      |> Jason.decode!()

    for type <- @types do
      vector = Enum.find(vectors, &(&1["type"] == type))

      message =
        Protobuf.JSON.decode!(
          Jason.encode!(vector["message"]),
          Module.concat(Agentvmm.Trust.V1, type)
        )

      input = @domain <> type <> "\0" <> Protobuf.encode(message)
      assert Base.encode16(input, case: :lower) == vector["canonical_hex"], type

      <<r::unsigned-big-integer-size(256), s::unsigned-big-integer-size(256)>> =
        Base.decode16!(vector["signature_hex"], case: :lower)

      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
      public_key = Base.decode16!(vector["public_key_hex"], case: :lower)
      assert :crypto.verify(:ecdsa, :sha256, input, der, [public_key, :secp256r1]), type
    end
  end
end
