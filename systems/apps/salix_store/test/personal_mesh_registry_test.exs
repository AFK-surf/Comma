defmodule SalixStore.PersonalMeshRegistryTest do
  use ExUnit.Case, async: false

  alias SalixStore.{PersonalMeshRegistry, Repo}

  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  setup do
    previous_signer = Application.get_env(:salix_store, :personal_mesh_registry_receipt_signer)
    previous_limits = Application.get_env(:salix_store, :personal_mesh_registry_rate_limits)

    Application.put_env(:salix_store, :personal_mesh_registry_receipt_signer, fn payload ->
      {"test-receipt-key", :crypto.hash(:sha256, payload)}
    end)

    Repo.query!(
      "TRUNCATE personal_mesh_registry_audit, personal_mesh_rate_buckets, personal_mesh_endpoints, personal_mesh_operations, personal_mesh_invites, personal_mesh_tombstones, personal_mesh_members, personal_meshes CASCADE"
    )

    on_exit(fn ->
      if previous_signer,
        do:
          Application.put_env(
            :salix_store,
            :personal_mesh_registry_receipt_signer,
            previous_signer
          ),
        else: Application.delete_env(:salix_store, :personal_mesh_registry_receipt_signer)

      if previous_limits,
        do:
          Application.put_env(:salix_store, :personal_mesh_registry_rate_limits, previous_limits),
        else: Application.delete_env(:salix_store, :personal_mesh_registry_rate_limits)
    end)

    :ok
  end

  test "A joins B, B joins C, and remove-wins revoke does not merge or cascade" do
    {a_public, a_private} = keypair()
    {b_public, b_private} = keypair()
    {c_public, c_private} = keypair()
    expires = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, genesis} =
      PersonalMeshRegistry.genesis(
        operation(
          %{
            operation_id: "genesis",
            mesh_id: "mesh-one",
            kind: "genesis",
            issuer_device_id: "a",
            expected_revision: 0,
            device_id: "a",
            root_public_key: a_public,
            root_key_revision: 1,
            descriptor: "descriptor-one",
            expires_at: expires
          },
          a_private
        )
      )

    assert genesis.mesh.revision == 1
    assert genesis.freshness_receipt.key_id == "test-receipt-key"

    assert genesis.freshness_receipt.signature ==
             :crypto.hash(:sha256, genesis.freshness_receipt.payload)

    assert {:ok, :ok} =
             PersonalMeshRegistry.create_invite("mesh-one", "a", "invite-b", "digest-b", expires)

    {:ok, joined_b} =
      PersonalMeshRegistry.join(
        operation(
          %{
            operation_id: "join-b",
            mesh_id: "mesh-one",
            kind: "join",
            issuer_device_id: "a",
            issuer_root_public_key: a_public,
            expected_revision: 1,
            invite_id: "invite-b",
            invite_digest: "digest-b",
            device_id: "b",
            root_public_key: b_public,
            root_key_revision: 1,
            permissions: ["manage_members", "request_routes"],
            pairing_private: b_private,
            expires_at: expires
          },
          a_private
        )
      )

    assert Enum.map(joined_b.members, & &1.device_id) == ["a", "b"]

    assert {:ok, :ok} =
             PersonalMeshRegistry.create_invite("mesh-one", "b", "invite-c", "digest-c", expires)

    {:ok, joined_c} =
      PersonalMeshRegistry.join(
        operation(
          %{
            operation_id: "join-c",
            mesh_id: "mesh-one",
            kind: "join",
            issuer_device_id: "b",
            issuer_root_public_key: b_public,
            expected_revision: 2,
            invite_id: "invite-c",
            invite_digest: "digest-c",
            device_id: "c",
            root_public_key: c_public,
            root_key_revision: 1,
            permissions: ["request_routes"],
            pairing_private: c_private,
            expires_at: expires
          },
          b_private
        )
      )

    assert Enum.map(joined_c.members, & &1.device_id) == ["a", "b", "c"]

    {:ok, revoked} =
      PersonalMeshRegistry.revoke(
        operation(
          %{
            operation_id: "revoke-b",
            mesh_id: "mesh-one",
            kind: "revoke",
            issuer_device_id: "a",
            issuer_root_public_key: a_public,
            expected_revision: 3,
            device_id: "b"
          },
          a_private
        )
      )

    assert Enum.map(revoked.members, & &1.device_id) == ["a", "c"]
    assert Enum.map(revoked.tombstones, & &1.device_id) == ["b"]
    assert revoked.mesh.policy_epoch == 2

    assert {:ok, :ok} =
             PersonalMeshRegistry.create_invite(
               "mesh-one",
               "a",
               "invite-b2",
               "digest-b2",
               expires
             )

    assert {:error, :remove_wins} =
             PersonalMeshRegistry.join(
               operation(
                 %{
                   operation_id: "rejoin-b",
                   mesh_id: "mesh-one",
                   kind: "join",
                   issuer_device_id: "a",
                   issuer_root_public_key: a_public,
                   expected_revision: 4,
                   invite_id: "invite-b2",
                   invite_digest: "digest-b2",
                   device_id: "b",
                   root_public_key: b_public,
                   root_key_revision: 2,
                   permissions: ["request_routes"],
                   pairing_private: b_private,
                   expires_at: expires
                 },
                 a_private
               )
             )

    {other_public, other_private} = keypair()

    assert {:ok, other} =
             PersonalMeshRegistry.genesis(
               operation(
                 %{
                   operation_id: "other-genesis",
                   mesh_id: "mesh-two",
                   kind: "genesis",
                   issuer_device_id: "other",
                   expected_revision: 0,
                   device_id: "other",
                   root_public_key: other_public,
                   root_key_revision: 1,
                   descriptor: "descriptor-two",
                   expires_at: expires
                 },
                 other_private
               )
             )

    assert Enum.map(other.members, & &1.device_id) == ["other"]
  end

  test "signature, CAS, invite consumption, and endpoint generation fail closed" do
    {public, private} = keypair()
    {joining_public, joining_private} = keypair()
    expires = DateTime.add(DateTime.utc_now(), 3600, :second)

    attrs = %{
      operation_id: "genesis",
      mesh_id: "mesh",
      kind: "genesis",
      issuer_device_id: "a",
      expected_revision: 0,
      device_id: "a",
      root_public_key: public,
      root_key_revision: 1,
      descriptor: "descriptor",
      expires_at: expires
    }

    assert {:error, :invalid_operation} =
             PersonalMeshRegistry.genesis(
               Map.put(operation(attrs, private), :signature, :binary.copy(<<0>>, 64))
             )

    signed = operation(attrs, private)

    assert PersonalMeshRegistry.verify_p256_signature(
             signed.canonical_payload,
             signed.signature,
             public
           )

    refute PersonalMeshRegistry.verify_p256_signature(
             signed.canonical_payload,
             to_high_s(signed.signature),
             public
           )

    assert {:error, :invalid_operation} = PersonalMeshRegistry.genesis(%{signed | device_id: "b"})

    assert {:ok, _} = PersonalMeshRegistry.genesis(operation(attrs, private))

    assert {:ok, :ok} =
             PersonalMeshRegistry.create_invite("mesh", "a", "invite", "digest", expires)

    {_attacker_public, attacker_private} = keypair()

    assert {:error, :invalid_pairing_proof} =
             PersonalMeshRegistry.join(
               operation(
                 %{
                   operation_id: "forged-join",
                   mesh_id: "mesh",
                   kind: "join",
                   issuer_device_id: "a",
                   issuer_root_public_key: public,
                   expected_revision: 1,
                   invite_id: "invite",
                   invite_digest: "digest",
                   device_id: "b",
                   root_public_key: joining_public,
                   root_key_revision: 1,
                   permissions: ["request_routes"],
                   pairing_private: attacker_private,
                   expires_at: expires
                 },
                 private
               )
             )

    join =
      operation(
        %{
          operation_id: "join",
          mesh_id: "mesh",
          kind: "join",
          issuer_device_id: "a",
          issuer_root_public_key: public,
          expected_revision: 1,
          invite_id: "invite",
          invite_digest: "digest",
          device_id: "b",
          root_public_key: joining_public,
          root_key_revision: 1,
          permissions: ["request_routes"],
          pairing_private: joining_private,
          expires_at: expires
        },
        private
      )

    assert {:ok, _} = PersonalMeshRegistry.join(join)
    assert {:ok, idempotent} = PersonalMeshRegistry.join(join)
    assert idempotent.mesh.revision == 2

    endpoint_attrs = %{
      mesh_id: "mesh",
      device_id: "a",
      root_key_revision: 1,
      generation: 1,
      observation:
        Jason.encode!(%{
          "deviceId" => "a",
          "rootKeyRevision" => "1",
          "endpointNodeId" => Base.encode64("node-a"),
          "endpointGeneration" => "1",
          "supportedAlpns" => ["agent-vmm/service-tunnel/1"],
          "featureSet" => ["direct"],
          "observedAddressesDigest" => Base.encode64("addresses")
        }),
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    }

    endpoint_payload = PersonalMeshRegistry.canonical_endpoint(endpoint_attrs)
    endpoint_signature = sign(endpoint_payload, private)

    assert :ok =
             PersonalMeshRegistry.publish_endpoint(
               Map.merge(endpoint_attrs, %{
                 canonical_payload: endpoint_payload,
                 signature: endpoint_signature,
                 root_public_key: public
               })
             )

    assert {:error, :stale_generation} =
             PersonalMeshRegistry.publish_endpoint(
               Map.merge(endpoint_attrs, %{
                 canonical_payload: endpoint_payload,
                 signature: endpoint_signature,
                 root_public_key: public
               })
             )

    renewed_endpoint = %{
      endpoint_attrs
      | expires_at: DateTime.add(endpoint_attrs.expires_at, 60, :second)
    }

    renewed_payload = PersonalMeshRegistry.canonical_endpoint(renewed_endpoint)

    assert :ok =
             PersonalMeshRegistry.publish_endpoint(
               Map.merge(renewed_endpoint, %{
                 canonical_payload: renewed_payload,
                 signature: sign(renewed_payload, private),
                 root_public_key: public
               })
             )

    joining_endpoint = %{
      endpoint_attrs
      | device_id: "b",
        observation:
          Jason.encode!(%{
            "deviceId" => "b",
            "rootKeyRevision" => "1",
            "endpointNodeId" => Base.encode64("node-b"),
            "endpointGeneration" => "1",
            "supportedAlpns" => ["agent-vmm/service-tunnel/1"],
            "featureSet" => ["direct"],
            "observedAddressesDigest" => Base.encode64("addresses-b")
          })
    }

    joining_endpoint_payload = PersonalMeshRegistry.canonical_endpoint(joining_endpoint)

    publish = fn ->
      receive do
        :start ->
          PersonalMeshRegistry.publish_endpoint(
            Map.merge(joining_endpoint, %{
              canonical_payload: joining_endpoint_payload,
              signature: sign(joining_endpoint_payload, joining_private),
              root_public_key: joining_public
            })
          )
      end
    end

    revoke = fn ->
      receive do
        :start ->
          PersonalMeshRegistry.revoke(
            operation(
              %{
                operation_id: "revoke-b-race",
                mesh_id: "mesh",
                kind: "revoke",
                issuer_device_id: "a",
                issuer_root_public_key: public,
                expected_revision: 2,
                device_id: "b"
              },
              private
            )
          )
      end
    end

    publish_task = Task.async(publish)
    revoke_task = Task.async(revoke)
    send(publish_task.pid, :start)
    send(revoke_task.pid, :start)

    assert Task.await(revoke_task) |> elem(0) == :ok
    assert Task.await(publish_task) in [:ok, {:error, :unavailable}]

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM personal_mesh_endpoints WHERE mesh_id = $1 AND device_id = $2",
               ["mesh", "b"]
             )

    Application.put_env(:salix_store, :personal_mesh_registry_rate_limits, %{"snapshot" => 1})
    assert {:ok, _} = PersonalMeshRegistry.snapshot("mesh")
    assert {:error, :rate_limited} = PersonalMeshRegistry.snapshot("mesh")

    Application.delete_env(:salix_store, :personal_mesh_registry_receipt_signer)

    assert {:error, :receipt_signer_unavailable} =
             PersonalMeshRegistry.genesis(
               operation(%{attrs | operation_id: "no-signer", mesh_id: "no-signer"}, private)
             )
  end

  defp operation(attrs, private) do
    attrs =
      attrs
      |> Map.put_new(:registry_audience, "personal-mesh-registry")
      |> maybe_add_pairing_proof()

    payload = PersonalMeshRegistry.canonical_operation(attrs)
    attrs |> Map.put(:canonical_payload, payload) |> Map.put(:signature, sign(payload, private))
  end

  defp maybe_add_pairing_proof(%{kind: "join", pairing_private: private} = attrs) do
    proof_attrs = %{
      session_id: binary_part(:crypto.hash(:sha256, attrs.operation_id), 0, 16),
      mesh_id: attrs.mesh_id,
      invite_revision: attrs.expected_revision,
      role: "joiner",
      device_id: attrs.device_id,
      root_key_revision: attrs.root_key_revision,
      root_public_key: attrs.root_public_key,
      permissions: attrs.permissions,
      context_digest: :crypto.hash(:sha256, attrs.invite_id <> attrs.device_id),
      expires_at: attrs.expires_at
    }

    signature =
      proof_attrs
      |> SalixStore.PersonalMeshProto.pairing_proof_signing_input()
      |> sign(private)

    Map.put(
      attrs,
      :pairing_proof,
      SalixStore.PersonalMeshProto.encode_pairing_proof(proof_attrs, signature)
    )
  end

  defp maybe_add_pairing_proof(attrs), do: attrs

  defp keypair do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private_key} =
      :crypto.generate_key(:ecdh, :secp256r1)

    prefix = 2 + Bitwise.band(:binary.last(y), 1)
    {<<prefix, x::binary>>, private_key}
  end

  defp sign(payload, private) do
    der = :crypto.sign(:ecdsa, :sha256, payload, [private, :secp256r1])
    <<0x30, _size, 0x02, r_size, rest::binary>> = der
    <<r::binary-size(^r_size), 0x02, s_size, s::binary-size(s_size)>> = rest
    r = pad32(r)
    s_value = :binary.decode_unsigned(s)
    s_value = min(s_value, @p256_order - s_value)
    r <> pad32(:binary.encode_unsigned(s_value))
  end

  defp pad32(<<0, rest::binary>>), do: pad32(rest)
  defp pad32(value), do: :binary.copy(<<0>>, 32 - byte_size(value)) <> value

  defp to_high_s(<<r::binary-size(32), s::binary-size(32)>>) do
    high_s = @p256_order - :binary.decode_unsigned(s)
    r <> pad32(:binary.encode_unsigned(high_s))
  end
end
