defmodule SalixStore.PersonalMeshProto do
  @moduledoc """
  Generated trust.v1 protobuf adapter for canonical signatures and registry wire responses.

  Business owners construct typed messages here and the official Protobuf codec
  emits their bytes. No caller-provided canonical payload or hand-written wire
  encoder is accepted at the signature boundary.
  """

  alias Agentvmm.Trust.V1.{
    AuthorityDescriptor,
    EndpointObservation,
    MembershipCredential,
    MeshCommitResponse,
    MeshMembership,
    MeshSnapshot,
    MeshTombstone,
    PairingProof,
    PublishEndpointResponse,
    RegistryOperation,
    RegistryReceipt,
    RouteBudget,
    RouteCapability,
    PersonalMeshDescriptor
  }

  @signature_domain "agent-vmm/signature/v1\0"

  def encode_snapshot(snapshot) do
    issued_at = DateTime.utc_now()
    expires_at = snapshot.freshness_expires_at

    base = %MeshSnapshot{
      mesh_id: snapshot.mesh.id,
      revision: snapshot.mesh.revision,
      policy_epoch: snapshot.mesh.policy_epoch,
      active_members: Enum.map(snapshot.members, &member(snapshot.mesh.id, &1)),
      tombstones: Enum.map(snapshot.tombstones, &tombstone/1),
      issued_at: timestamp(issued_at),
      expires_at: timestamp(expires_at)
    }

    snapshot_digest = :crypto.hash(:sha256, Protobuf.encode(base))
    receipt = receipt(snapshot, snapshot_digest, issued_at, expires_at)
    encoded = %{base | snapshot_digest: snapshot_digest, registry_receipt: receipt}

    %{
      snapshot: Protobuf.encode(encoded),
      receipt: Protobuf.encode(receipt),
      snapshot_digest: snapshot_digest
    }
  end

  def encode_commit_response(snapshot) do
    decoded = Agentvmm.Trust.V1.MeshSnapshot.decode(encode_snapshot(snapshot).snapshot)
    Protobuf.encode(%MeshCommitResponse{snapshot: decoded})
  end

  def encode_endpoint_response(snapshot) do
    decoded = Agentvmm.Trust.V1.RegistryReceipt.decode(encode_snapshot(snapshot).receipt)
    Protobuf.encode(%PublishEndpointResponse{receipt: decoded})
  end

  def managed_credential_signing_input(attrs) do
    canonical("MembershipCredential", managed_credential(attrs, <<>>))
  end

  def managed_route_signing_input(attrs) do
    message = %RouteCapability{
      capability_id: attrs.id,
      authority: authority(attrs),
      source_device_id: attrs.source_device_id,
      source_allocation_id: attrs.source_allocation_id,
      destination_device_id: attrs.destination_device_id,
      destination_export_id: attrs.destination_export_id,
      allowed_protocol: attrs.allowed_protocol,
      allowed_verbs: attrs.allowed_verbs,
      route_generation: attrs.route_generation,
      policy_revision: attrs.policy_revision,
      budget: %RouteBudget{
        connection_limit: attrs.connection_limit,
        byte_limit: attrs.byte_limit,
        concurrency_limit: attrs.concurrency_limit
      },
      not_before: timestamp(attrs.not_before),
      expires_at: timestamp(attrs.expires_at),
      nonce: attrs.nonce,
      audience: attrs.audience,
      issuer_key_id: attrs.key_id,
      route_class: attrs.route_class,
      source_membership_credential:
        managed_credential(attrs.source_credential, attrs.source_credential.signature)
    }

    canonical("RouteCapability", message)
  end

  def personal_mesh_descriptor_signing_input(attrs) do
    canonical(
      "PersonalMeshDescriptor",
      %PersonalMeshDescriptor{
        mesh_id: attrs.mesh_id,
        genesis_device_id: attrs.genesis_device_id,
        genesis_root_public_key: attrs.genesis_root_public_key,
        registry_audience: attrs.registry_audience,
        policy_epoch: attrs.policy_epoch,
        created_at: timestamp(attrs.created_at)
      }
    )
  end

  def registry_operation_signing_input(attrs) do
    canonical(
      "RegistryOperation",
      %RegistryOperation{
        operation_id: attrs.operation_id,
        kind: operation_kind(attrs.kind),
        mesh_id: attrs.mesh_id,
        expected_revision: attrs.expected_revision,
        policy_epoch: attrs.policy_epoch,
        issuer_device_id: attrs.issuer_device_id,
        issuer_root_key_revision: attrs.issuer_root_key_revision,
        membership: canonical_membership(attrs.canonical_membership),
        invite_id: attrs.invite_id || "",
        expires_at: timestamp(attrs[:expires_at]),
        nonce: attrs.nonce,
        pairing_proof: attrs[:pairing_proof] || <<>>
      }
    )
  end

  def pairing_proof_signing_input(attrs) do
    canonical(
      "PairingProof",
      %PairingProof{
        session_id: attrs.session_id,
        mesh_id: attrs.mesh_id,
        invite_revision: attrs.invite_revision,
        role: pairing_role(attrs.role),
        device_id: attrs.device_id,
        root_key_revision: attrs.root_key_revision,
        root_public_key: attrs.root_public_key,
        permissions: Enum.map(attrs.permissions, &permission_enum/1),
        context_digest: attrs.context_digest,
        expires_at: timestamp(attrs.expires_at)
      }
    )
  end

  def encode_pairing_proof(attrs, signature) when is_binary(signature) do
    attrs
    |> pairing_proof_message(signature)
    |> Protobuf.encode()
  end

  def endpoint_observation_signing_input(attrs) do
    canonical(
      "EndpointObservation",
      %EndpointObservation{
        device_id: attrs.device_id,
        root_key_revision: attrs.root_key_revision,
        endpoint_node_id: attrs.endpoint_node_id,
        endpoint_generation: attrs.generation,
        supported_alpns: attrs.supported_alpns,
        feature_set: attrs.feature_set,
        observed_addresses_digest: attrs.observed_addresses_digest,
        expires_at: timestamp(attrs.expires_at)
      }
    )
  end

  defp canonical(type, message), do: @signature_domain <> type <> "\0" <> Protobuf.encode(message)

  defp pairing_proof_message(attrs, signature) do
    %PairingProof{
      session_id: attrs.session_id,
      mesh_id: attrs.mesh_id,
      invite_revision: attrs.invite_revision,
      role: pairing_role(attrs.role),
      device_id: attrs.device_id,
      root_key_revision: attrs.root_key_revision,
      root_public_key: attrs.root_public_key,
      permissions: Enum.map(attrs.permissions, &permission_enum/1),
      context_digest: attrs.context_digest,
      expires_at: timestamp(attrs.expires_at),
      signature: signature
    }
  end

  defp managed_credential(attrs, signature) do
    %MembershipCredential{
      authority: authority(attrs),
      subject_device_id: attrs.device_id,
      subject_root_key_revision: attrs.root_key_revision,
      opaque_claims_digest: attrs.claims_digest,
      policy_revision: attrs.policy_revision,
      expires_at: timestamp(attrs.expires_at),
      signature: signature || <<>>,
      subject_root_public_key: attrs.root_public_key
    }
  end

  defp authority(attrs) do
    %AuthorityDescriptor{
      authority_id: attrs.authority_id,
      authority_class: :AUTHORITY_CLASS_MANAGED_CONTROLLER,
      key_id: attrs.key_id,
      trust_domain_ref: attrs.trust_domain_ref,
      revision: attrs.anchor_revision
    }
  end

  defp canonical_membership(attrs) do
    %MeshMembership{
      mesh_id: attrs.mesh_id,
      device_id: attrs.device_id,
      root_public_key: attrs.root_public_key,
      root_key_revision: attrs.root_key_revision,
      permissions: Enum.map(attrs.permissions, &permission_enum/1),
      state: membership_state(attrs.state),
      joined_at_revision: attrs.joined_at_revision,
      revoked_at_revision: attrs.revoked_at_revision,
      operation_digest: attrs.operation_digest,
      signatures: attrs.signatures
    }
  end

  defp member(mesh_id, member) do
    permissions =
      member.permissions
      |> Enum.map(&permission/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %MeshMembership{
      mesh_id: mesh_id,
      device_id: member.device_id,
      root_public_key: member.root_public_key,
      root_key_revision: member.root_key_revision,
      permissions: permissions,
      state: :MESH_MEMBERSHIP_STATE_ACTIVE,
      joined_at_revision: member.joined_revision
    }
  end

  defp tombstone(value) do
    %MeshTombstone{
      device_id: value.device_id,
      root_key_revision: value.root_key_revision,
      revoked_at_revision: value.revoked_revision,
      policy_epoch: value.policy_epoch,
      operation_digest: value.operation_digest
    }
  end

  defp receipt(snapshot, snapshot_digest, issued_at, expires_at) do
    base = %RegistryReceipt{
      registry_audience: snapshot.mesh.registry_audience,
      mesh_id: snapshot.mesh.id,
      revision: snapshot.mesh.revision,
      policy_epoch: snapshot.mesh.policy_epoch,
      snapshot_digest: snapshot_digest,
      issued_at: timestamp(issued_at),
      expires_at: timestamp(expires_at)
    }

    signer = Application.get_env(:salix_store, :personal_mesh_registry_receipt_signer)

    key_id =
      case signer && signer.(canonical("RegistryReceipt", base)) do
        {key_id, signature}
        when is_binary(key_id) and key_id != "" and is_binary(signature) and
               byte_size(signature) > 0 ->
          key_id

        _ ->
          raise "personal mesh registry receipt signer unavailable"
      end

    unsigned = %{base | key_id: key_id}

    signature =
      case signer.(canonical("RegistryReceipt", unsigned)) do
        {^key_id, signature} when is_binary(signature) and byte_size(signature) > 0 -> signature
        _ -> raise "personal mesh registry receipt signer rotated during issuance"
      end

    %{unsigned | signature: signature}
  end

  defp operation_kind("genesis"), do: :REGISTRY_OPERATION_KIND_GENESIS
  defp operation_kind("join"), do: :REGISTRY_OPERATION_KIND_JOIN
  defp operation_kind("revoke"), do: :REGISTRY_OPERATION_KIND_REVOKE

  defp pairing_role("manager"), do: :PAIRING_ROLE_MANAGER
  defp pairing_role("joiner"), do: :PAIRING_ROLE_JOINER

  defp membership_state(1), do: :MESH_MEMBERSHIP_STATE_PENDING_JOIN
  defp membership_state(2), do: :MESH_MEMBERSHIP_STATE_ACTIVE
  defp membership_state(3), do: :MESH_MEMBERSHIP_STATE_REVOKED
  defp membership_state(value) when is_atom(value), do: value

  defp permission_enum(1), do: :MESH_PERMISSION_USE_SERVICES
  defp permission_enum(2), do: :MESH_PERMISSION_MANAGE_MEMBERS
  defp permission_enum("use_services"), do: :MESH_PERMISSION_USE_SERVICES
  defp permission_enum("request_routes"), do: :MESH_PERMISSION_USE_SERVICES
  defp permission_enum("manage_members"), do: :MESH_PERMISSION_MANAGE_MEMBERS
  defp permission_enum(value) when is_atom(value), do: value

  defp permission("use_services"), do: :MESH_PERMISSION_USE_SERVICES
  defp permission("request_routes"), do: :MESH_PERMISSION_USE_SERVICES
  defp permission("manage_members"), do: :MESH_PERMISSION_MANAGE_MEMBERS
  defp permission(_), do: nil

  defp timestamp(nil), do: nil

  defp timestamp(datetime) do
    micros = elem(datetime.microsecond, 0)

    %Google.Protobuf.Timestamp{
      seconds: DateTime.to_unix(datetime, :second),
      nanos: micros * 1_000
    }
  end
end
