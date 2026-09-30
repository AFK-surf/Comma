defmodule SalixStore.AgentVMMTrustTest do
  use ExUnit.Case, async: false

  alias SalixStore.{AgentVMMManagedTrustSigning, AgentVMMTrust, PersonalMeshProto, Repo}

  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_route_capabilities, agent_vmm_membership_credentials, agent_vmm_trust_anchors CASCADE"
    )

    :ok
  end

  test "managed anchor rotation and credentials remain tenant/revision scoped" do
    now = DateTime.utc_now()
    {public_key, private_key} = keypair()
    signer = &sign_low_s(&1, private_key)

    {:ok, anchor} =
      AgentVMMTrust.create_anchor(%{
        id: "anchor-1",
        tenant_id: "tenant",
        authority_id: "authority",
        public_key: public_key,
        key_revision: 1,
        policy_revision: 3,
        not_before: DateTime.add(now, -10, :second),
        expires_at: DateTime.add(now, 3600, :second)
      })

    attrs = %{
      id: "credential",
      tenant_id: "tenant",
      device_id: "device",
      root_public_key: "device-root",
      root_key_revision: 1,
      opaque_claims_digest: :binary.copy(<<1>>, 32),
      permissions: ["compute"],
      policy_revision: 3,
      canonical_payload: "credential-payload",
      not_before: now,
      expires_at: DateTime.add(now, 600, :second)
    }

    assert {:ok, credential} =
             AgentVMMTrust.issue_credential(anchor.id, attrs, signer)

    refute credential.signature == attrs.canonical_payload

    route_attrs = %{
      id: "route-capability",
      tenant_id: "tenant",
      source_device_id: "device",
      source_allocation_id: "allocation",
      destination_device_id: "destination",
      destination_export_id: "export",
      route_class: "compute",
      allowed_protocol: "tcp",
      allowed_verbs: ["connect"],
      route_generation: 1,
      policy_revision: 3,
      connection_limit: 8,
      byte_limit: 1_048_576,
      concurrency_limit: 2,
      audience: "agent-vmm/service-tunnel/1",
      issuer_key_id: "managed-key",
      nonce: :binary.copy(<<7>>, 32),
      not_before: now,
      expires_at: DateTime.add(now, 600, :second)
    }

    assert {:ok, route} =
             AgentVMMTrust.issue_route_capability(
               anchor.id,
               route_attrs,
               fn candidate ->
                 if candidate.source_device_id == "device", do: :ok, else: {:error, :denied}
               end,
               signer
             )

    assert route.audience == "agent-vmm/service-tunnel/1"

    assert SalixStore.P256Signature.verify(
             route.canonical_payload,
             route.signature,
             public_key
           )

    assert {:error, :invalid_scope} =
             AgentVMMTrust.issue_route_capability(
               anchor.id,
               %{route_attrs | id: "wrong-audience", audience: "other"},
               fn _ -> :ok end,
               signer
             )

    assert :ok = AgentVMMTrust.revoke_route_capability("tenant", route.id)

    assert {:error, :authority_mismatch} =
             AgentVMMTrust.issue_credential(
               anchor.id,
               %{attrs | id: "cross-tenant", tenant_id: "other"},
               signer
             )

    {:ok, rotated} =
      AgentVMMTrust.rotate_anchor(anchor.id, 1, %{
        id: "anchor-2",
        tenant_id: "tenant",
        authority_id: "authority",
        public_key: "public-2",
        key_revision: 2,
        policy_revision: 4,
        not_before: now,
        expires_at: DateTime.add(now, 7200, :second)
      })

    assert rotated.key_revision == 2

    assert {:error, :anchor_inactive} =
             AgentVMMTrust.issue_credential(
               anchor.id,
               %{attrs | id: "old-key"},
               signer
             )

    assert :ok = AgentVMMTrust.revoke_credential("tenant", credential.id)
    assert {:error, :not_found} = AgentVMMTrust.revoke_credential("other", credential.id)
  end

  test "managed key rotation creates the reviewed revision beside the old anchor" do
    now = DateTime.utc_now()
    {old_public_key, _old_private_key} = keypair()
    {public_key, private_key} = keypair()

    previous = Application.get_env(:salix_store, :agent_vmm_managed_trust_signing)

    Application.put_env(
      :salix_store,
      :agent_vmm_managed_trust_signing,
      AgentVMMManagedTrustSigning.from_json(%{"private_key" => Base.encode64(private_key)})
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :agent_vmm_managed_trust_signing, previous),
        else: Application.delete_env(:salix_store, :agent_vmm_managed_trust_signing)
    end)

    assert {:ok, anchor} =
             AgentVMMTrust.create_anchor(%{
               id: "salix-managed:tenant:1",
               tenant_id: "tenant",
               authority_id: "salix-managed:tenant",
               public_key: old_public_key,
               key_revision: 1,
               policy_revision: 1,
               not_before: DateTime.add(now, -10, :second),
               expires_at: DateTime.add(now, 3600, :second)
             })

    registration = %{
      id: "registration-policy-2",
      tenant_id: "tenant",
      group_id: "group",
      device_id: "device",
      policy_revision: 9
    }

    identity = %{
      "deviceId" => "device",
      "rootPublicKey" => Base.encode64(public_key),
      "rootKeyRevision" => "1"
    }

    assert {:ok, bundle} = AgentVMMTrust.issue_enrollment_bundle(registration, identity)
    assert bundle.trust_anchor["revision"] == "2"
    assert bundle.membership_credential["policyRevision"] == "2"
    assert Repo.get!(AgentVMMTrust.Anchor, anchor.id).policy_revision == 1

    rotated = Repo.get!(AgentVMMTrust.Anchor, "salix-managed:tenant:2")
    assert rotated.public_key == public_key
    assert rotated.key_revision == 2
    assert rotated.policy_revision == 2
  end

  test "re-enrollment reuses the exact active membership credential for one device identity" do
    {public_key, private_key} = keypair()
    previous = Application.get_env(:salix_store, :agent_vmm_managed_trust_signing)

    Application.put_env(
      :salix_store,
      :agent_vmm_managed_trust_signing,
      AgentVMMManagedTrustSigning.from_json(%{"private_key" => Base.encode64(private_key)})
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :agent_vmm_managed_trust_signing, previous),
        else: Application.delete_env(:salix_store, :agent_vmm_managed_trust_signing)
    end)

    identity = %{
      "deviceId" => "device-reenroll",
      "rootPublicKey" => Base.encode64(public_key),
      "rootKeyRevision" => "3"
    }

    registration = %{
      id: "registration-reenroll-1",
      tenant_id: "tenant-reenroll",
      group_id: "group-reenroll",
      device_id: "device-reenroll",
      policy_revision: 1
    }

    assert {:ok, first} = AgentVMMTrust.issue_enrollment_bundle(registration, identity)

    assert {:ok, second} =
             AgentVMMTrust.issue_enrollment_bundle(
               %{registration | id: "registration-reenroll-2"},
               identity
             )

    assert second.membership_credential == first.membership_credential
    assert second.trust_anchor == first.trust_anchor
    assert Repo.aggregate(AgentVMMTrust.Credential, :count) == 1

    credential = Repo.one!(AgentVMMTrust.Credential)

    assert first.membership_credential["signature"] == Base.encode64(credential.signature)

    assert first.membership_credential["expiresAt"] ==
             DateTime.to_iso8601(credential.expires_at)

    assert :ok = AgentVMMTrust.revoke_credential(registration.tenant_id, credential.id)

    assert {:ok, after_revocation} =
             AgentVMMTrust.issue_enrollment_bundle(
               %{registration | id: "registration-reenroll-3"},
               identity
             )

    refute after_revocation.membership_credential == first.membership_credential
    assert Repo.aggregate(AgentVMMTrust.Credential, :count) == 2
  end

  test "managed membership canonical bytes match the Agent VMM vector" do
    input =
      PersonalMeshProto.managed_credential_signing_input(%{
        authority_id: "managed:test",
        key_id: "key-1",
        trust_domain_ref: <<1, 2, 3>>,
        anchor_revision: 7,
        device_id: "device-a",
        root_key_revision: 3,
        root_public_key: :binary.copy(<<0>>, 33),
        claims_digest: :binary.copy(<<4>>, 32),
        policy_revision: 9,
        expires_at: ~U[2033-05-18 03:33:20Z]
      })

    assert Base.encode16(input, case: :lower) ==
             "6167656e742d766d6d2f7369676e61747572652f7631004d656d6265727368697043726564656e7469616c000a1e0a0c6d616e616765643a7465737410011a056b65792d312203010203280712086465766963652d61180322200404040404040404040404040404040404040404040404040404040404040404280932060880a8d6b9074221000000000000000000000000000000000000000000000000000000000000000000"
  end

  test "managed signer rejects a valid high-S representation" do
    now = DateTime.utc_now()
    {public_key, private_key} = keypair()

    {:ok, anchor} =
      AgentVMMTrust.create_anchor(%{
        id: "anchor-high-s",
        tenant_id: "tenant",
        authority_id: "authority-high-s",
        public_key: public_key,
        key_revision: 1,
        policy_revision: 1,
        not_before: DateTime.add(now, -10, :second),
        expires_at: DateTime.add(now, 3600, :second)
      })

    attrs = %{
      id: "credential-high-s",
      tenant_id: "tenant",
      device_id: "device",
      root_public_key: public_key,
      root_key_revision: 1,
      opaque_claims_digest: :binary.copy(<<1>>, 32),
      permissions: ["compute"],
      policy_revision: 1,
      canonical_payload: "credential-payload",
      not_before: now,
      expires_at: DateTime.add(now, 600, :second)
    }

    high_s_signer = fn payload -> payload |> sign_low_s(private_key) |> to_high_s() end

    assert {:error, :signer_unavailable} =
             AgentVMMTrust.issue_credential(anchor.id, attrs, high_s_signer)
  end

  test "managed route canonical bytes match the Agent VMM vector" do
    expires_at = ~U[2033-05-18 03:33:20Z]

    source_credential = %{
      authority_id: "managed:test",
      key_id: "key-1",
      trust_domain_ref: <<1, 2, 3>>,
      anchor_revision: 7,
      device_id: "device-a",
      root_key_revision: 3,
      root_public_key: :binary.copy(<<0>>, 33),
      claims_digest: :binary.copy(<<4>>, 32),
      policy_revision: 9,
      expires_at: expires_at,
      signature: :binary.copy(<<5>>, 64)
    }

    input =
      PersonalMeshProto.managed_route_signing_input(%{
        id: "route-1",
        source_device_id: "device-a",
        source_allocation_id: "alloc-1",
        destination_device_id: "device-b",
        destination_export_id: "export-1",
        allowed_protocol: "tcp",
        allowed_verbs: ["connect"],
        route_generation: 2,
        policy_revision: 9,
        connection_limit: 3,
        byte_limit: 4096,
        concurrency_limit: 2,
        not_before: ~U[2033-05-18 03:31:40Z],
        expires_at: expires_at,
        nonce: :binary.copy(<<6>>, 32),
        audience: "agent-vmm/service-tunnel/1",
        route_class: "compute",
        authority_id: "managed:test",
        key_id: "key-1",
        trust_domain_ref: <<1, 2, 3>>,
        anchor_revision: 7,
        source_credential: source_credential
      })

    assert :crypto.hash(:sha256, input) |> Base.encode16(case: :lower) ==
             "fa37b567d74edd504ba560b5f4080a70d767475dc6d6c8ce39ff67838654f013"
  end

  defp sign_low_s(payload, private_key) do
    der = :crypto.sign(:ecdsa, :sha256, payload, [private_key, :secp256r1])
    <<0x30, _size, 0x02, r_size, rest::binary>> = der
    <<r::binary-size(^r_size), 0x02, s_size, s::binary-size(s_size)>> = rest
    r = r |> :binary.decode_unsigned() |> encode32()
    s_value = :binary.decode_unsigned(s)
    s_value = min(s_value, @p256_order - s_value)
    r <> encode32(s_value)
  end

  defp to_high_s(<<r::binary-size(32), s::binary-size(32)>>) do
    r <> encode32(@p256_order - :binary.decode_unsigned(s))
  end

  defp encode32(value) when is_integer(value) do
    encoded = :binary.encode_unsigned(value)
    :binary.copy(<<0>>, 32 - byte_size(encoded)) <> encoded
  end

  defp keypair do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private_key} =
      :crypto.generate_key(:ecdh, :secp256r1)

    prefix = 2 + Bitwise.band(:binary.last(y), 1)
    {<<prefix, x::binary>>, private_key}
  end
end
