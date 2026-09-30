defmodule Agentvmm.Trust.V1.SignatureSuite do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "agentvmm.trust.v1.SignatureSuite",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:SIGNATURE_SUITE_UNSPECIFIED, 0)
  field(:SIGNATURE_SUITE_P256_SHA256, 1)
end

defmodule Agentvmm.Trust.V1.AuthorityClass do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "agentvmm.trust.v1.AuthorityClass",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:AUTHORITY_CLASS_UNSPECIFIED, 0)
  field(:AUTHORITY_CLASS_MANAGED_CONTROLLER, 1)
  field(:AUTHORITY_CLASS_PERSONAL_MESH, 2)
end

defmodule Agentvmm.Trust.V1.CapabilityKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "agentvmm.trust.v1.CapabilityKind",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:CAPABILITY_KIND_UNSPECIFIED, 0)
  field(:CAPABILITY_KIND_SERVICE_ROUTE, 1)
  field(:CAPABILITY_KIND_MESH_CONTROL, 2)
end

defmodule Agentvmm.Trust.V1.MeshPermission do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "agentvmm.trust.v1.MeshPermission",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:MESH_PERMISSION_UNSPECIFIED, 0)
  field(:MESH_PERMISSION_USE_SERVICES, 1)
  field(:MESH_PERMISSION_MANAGE_MEMBERS, 2)
end

defmodule Agentvmm.Trust.V1.MeshMembershipState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "agentvmm.trust.v1.MeshMembershipState",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:MESH_MEMBERSHIP_STATE_UNSPECIFIED, 0)
  field(:MESH_MEMBERSHIP_STATE_PENDING_JOIN, 1)
  field(:MESH_MEMBERSHIP_STATE_ACTIVE, 2)
  field(:MESH_MEMBERSHIP_STATE_REVOKED, 3)
end

defmodule Agentvmm.Trust.V1.RegistryOperationKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "agentvmm.trust.v1.RegistryOperationKind",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:REGISTRY_OPERATION_KIND_UNSPECIFIED, 0)
  field(:REGISTRY_OPERATION_KIND_GENESIS, 1)
  field(:REGISTRY_OPERATION_KIND_JOIN, 2)
  field(:REGISTRY_OPERATION_KIND_REVOKE, 3)
end

defmodule Agentvmm.Trust.V1.PairingRole do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "agentvmm.trust.v1.PairingRole",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:PAIRING_ROLE_UNSPECIFIED, 0)
  field(:PAIRING_ROLE_MANAGER, 1)
  field(:PAIRING_ROLE_JOINER, 2)
end

defmodule Agentvmm.Trust.V1.DeviceIdentity do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.DeviceIdentity",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:device_id, 1, type: :string, json_name: "deviceId")
  field(:root_public_key, 2, type: :bytes, json_name: "rootPublicKey")
  field(:root_key_revision, 3, type: :uint64, json_name: "rootKeyRevision")

  field(:signature_suite, 4,
    type: Agentvmm.Trust.V1.SignatureSuite,
    json_name: "signatureSuite",
    enum: true
  )
end

defmodule Agentvmm.Trust.V1.DeviceRootRotation do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.DeviceRootRotation",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:device_id, 1, type: :string, json_name: "deviceId")
  field(:old_root_key_revision, 2, type: :uint64, json_name: "oldRootKeyRevision")
  field(:old_root_public_key, 3, type: :bytes, json_name: "oldRootPublicKey")
  field(:new_root_key_revision, 4, type: :uint64, json_name: "newRootKeyRevision")
  field(:new_root_public_key, 5, type: :bytes, json_name: "newRootPublicKey")
  field(:old_signs_new, 6, type: :bytes, json_name: "oldSignsNew")
  field(:new_signs_old, 7, type: :bytes, json_name: "newSignsOld")
  field(:rotated_at, 8, type: Google.Protobuf.Timestamp, json_name: "rotatedAt")
end

defmodule Agentvmm.Trust.V1.AuthorityDescriptor do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.AuthorityDescriptor",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:authority_id, 1, type: :string, json_name: "authorityId")

  field(:authority_class, 2,
    type: Agentvmm.Trust.V1.AuthorityClass,
    json_name: "authorityClass",
    enum: true
  )

  field(:key_id, 3, type: :string, json_name: "keyId")
  field(:trust_domain_ref, 4, type: :bytes, json_name: "trustDomainRef")
  field(:revision, 5, type: :uint64)
end

defmodule Agentvmm.Trust.V1.VerificationKey do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.VerificationKey",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:key_id, 1, type: :string, json_name: "keyId")
  field(:public_key, 2, type: :bytes, json_name: "publicKey")

  field(:signature_suite, 3,
    type: Agentvmm.Trust.V1.SignatureSuite,
    json_name: "signatureSuite",
    enum: true
  )
end

defmodule Agentvmm.Trust.V1.TrustAnchor do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.TrustAnchor",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:authority, 1, type: Agentvmm.Trust.V1.AuthorityDescriptor)

  field(:verification_keys, 2,
    repeated: true,
    type: Agentvmm.Trust.V1.VerificationKey,
    json_name: "verificationKeys"
  )

  field(:allowed_capability_kinds, 3,
    repeated: true,
    type: Agentvmm.Trust.V1.CapabilityKind,
    json_name: "allowedCapabilityKinds",
    enum: true
  )

  field(:not_before, 4, type: Google.Protobuf.Timestamp, json_name: "notBefore")
  field(:not_after, 5, type: Google.Protobuf.Timestamp, json_name: "notAfter")
  field(:revision, 6, type: :uint64)
end

defmodule Agentvmm.Trust.V1.MembershipCredential do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.MembershipCredential",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:authority, 1, type: Agentvmm.Trust.V1.AuthorityDescriptor)
  field(:subject_device_id, 2, type: :string, json_name: "subjectDeviceId")
  field(:subject_root_key_revision, 3, type: :uint64, json_name: "subjectRootKeyRevision")
  field(:opaque_claims_digest, 4, type: :bytes, json_name: "opaqueClaimsDigest")
  field(:policy_revision, 5, type: :uint64, json_name: "policyRevision")
  field(:expires_at, 6, type: Google.Protobuf.Timestamp, json_name: "expiresAt")
  field(:signature, 7, type: :bytes)
  field(:subject_root_public_key, 8, type: :bytes, json_name: "subjectRootPublicKey")
end

defmodule Agentvmm.Trust.V1.PersonalMeshDescriptor do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.PersonalMeshDescriptor",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_id, 1, type: :string, json_name: "meshId")
  field(:genesis_device_id, 2, type: :string, json_name: "genesisDeviceId")
  field(:genesis_root_public_key, 3, type: :bytes, json_name: "genesisRootPublicKey")
  field(:registry_audience, 4, type: :string, json_name: "registryAudience")
  field(:policy_epoch, 5, type: :uint64, json_name: "policyEpoch")
  field(:created_at, 6, type: Google.Protobuf.Timestamp, json_name: "createdAt")
  field(:genesis_signature, 7, type: :bytes, json_name: "genesisSignature")
end

defmodule Agentvmm.Trust.V1.MeshMembership do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.MeshMembership",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_id, 1, type: :string, json_name: "meshId")
  field(:device_id, 2, type: :string, json_name: "deviceId")
  field(:root_public_key, 3, type: :bytes, json_name: "rootPublicKey")
  field(:root_key_revision, 4, type: :uint64, json_name: "rootKeyRevision")
  field(:permissions, 5, repeated: true, type: Agentvmm.Trust.V1.MeshPermission, enum: true)
  field(:state, 6, type: Agentvmm.Trust.V1.MeshMembershipState, enum: true)
  field(:joined_at_revision, 7, type: :uint64, json_name: "joinedAtRevision")

  field(:revoked_at_revision, 8,
    proto3_optional: true,
    type: :uint64,
    json_name: "revokedAtRevision"
  )

  field(:operation_digest, 9, type: :bytes, json_name: "operationDigest")
  field(:signatures, 10, repeated: true, type: :bytes)
end

defmodule Agentvmm.Trust.V1.MeshTombstone do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.MeshTombstone",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:device_id, 1, type: :string, json_name: "deviceId")
  field(:root_key_revision, 2, type: :uint64, json_name: "rootKeyRevision")
  field(:revoked_at_revision, 3, type: :uint64, json_name: "revokedAtRevision")
  field(:policy_epoch, 4, type: :uint64, json_name: "policyEpoch")
  field(:operation_digest, 5, type: :bytes, json_name: "operationDigest")
end

defmodule Agentvmm.Trust.V1.RegistryReceipt do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.RegistryReceipt",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:registry_audience, 1, type: :string, json_name: "registryAudience")
  field(:mesh_id, 2, type: :string, json_name: "meshId")
  field(:revision, 3, type: :uint64)
  field(:policy_epoch, 4, type: :uint64, json_name: "policyEpoch")
  field(:snapshot_digest, 5, type: :bytes, json_name: "snapshotDigest")
  field(:issued_at, 6, type: Google.Protobuf.Timestamp, json_name: "issuedAt")
  field(:expires_at, 7, type: Google.Protobuf.Timestamp, json_name: "expiresAt")
  field(:key_id, 8, type: :string, json_name: "keyId")
  field(:signature, 9, type: :bytes)
end

defmodule Agentvmm.Trust.V1.MeshSnapshot do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.MeshSnapshot",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_id, 1, type: :string, json_name: "meshId")
  field(:revision, 2, type: :uint64)
  field(:policy_epoch, 3, type: :uint64, json_name: "policyEpoch")
  field(:previous_digest, 4, type: :bytes, json_name: "previousDigest")

  field(:active_members, 5,
    repeated: true,
    type: Agentvmm.Trust.V1.MeshMembership,
    json_name: "activeMembers"
  )

  field(:tombstones, 6, repeated: true, type: Agentvmm.Trust.V1.MeshTombstone)
  field(:snapshot_digest, 7, type: :bytes, json_name: "snapshotDigest")
  field(:issued_at, 8, type: Google.Protobuf.Timestamp, json_name: "issuedAt")
  field(:expires_at, 9, type: Google.Protobuf.Timestamp, json_name: "expiresAt")

  field(:registry_receipt, 10,
    type: Agentvmm.Trust.V1.RegistryReceipt,
    json_name: "registryReceipt"
  )
end

defmodule Agentvmm.Trust.V1.EndpointObservation do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.EndpointObservation",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:device_id, 1, type: :string, json_name: "deviceId")
  field(:root_key_revision, 2, type: :uint64, json_name: "rootKeyRevision")
  field(:endpoint_node_id, 3, type: :bytes, json_name: "endpointNodeId")
  field(:endpoint_generation, 4, type: :uint64, json_name: "endpointGeneration")
  field(:supported_alpns, 5, repeated: true, type: :string, json_name: "supportedAlpns")
  field(:feature_set, 6, repeated: true, type: :string, json_name: "featureSet")
  field(:observed_addresses_digest, 7, type: :bytes, json_name: "observedAddressesDigest")
  field(:expires_at, 8, type: Google.Protobuf.Timestamp, json_name: "expiresAt")
  field(:device_signature, 9, type: :bytes, json_name: "deviceSignature")
end

defmodule Agentvmm.Trust.V1.PairingProof do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.PairingProof",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:session_id, 1, type: :bytes, json_name: "sessionId")
  field(:mesh_id, 2, type: :string, json_name: "meshId")
  field(:invite_revision, 3, type: :uint64, json_name: "inviteRevision")
  field(:role, 4, type: Agentvmm.Trust.V1.PairingRole, enum: true)
  field(:device_id, 5, type: :string, json_name: "deviceId")
  field(:root_key_revision, 6, type: :uint64, json_name: "rootKeyRevision")
  field(:root_public_key, 7, type: :bytes, json_name: "rootPublicKey")
  field(:permissions, 8, repeated: true, type: Agentvmm.Trust.V1.MeshPermission, enum: true)
  field(:context_digest, 9, type: :bytes, json_name: "contextDigest")
  field(:expires_at, 10, type: Google.Protobuf.Timestamp, json_name: "expiresAt")
  field(:signature, 11, type: :bytes)
end

defmodule Agentvmm.Trust.V1.RouteBudget do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.RouteBudget",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:connection_limit, 1, type: :uint32, json_name: "connectionLimit")
  field(:byte_limit, 2, type: :uint64, json_name: "byteLimit")
  field(:concurrency_limit, 3, type: :uint32, json_name: "concurrencyLimit")
end

defmodule Agentvmm.Trust.V1.RouteCapability do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.RouteCapability",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:capability_id, 1, type: :string, json_name: "capabilityId")
  field(:authority, 2, type: Agentvmm.Trust.V1.AuthorityDescriptor)
  field(:source_device_id, 3, type: :string, json_name: "sourceDeviceId")

  field(:source_allocation_id, 4,
    proto3_optional: true,
    type: :string,
    json_name: "sourceAllocationId"
  )

  field(:destination_device_id, 5, type: :string, json_name: "destinationDeviceId")
  field(:destination_export_id, 6, type: :string, json_name: "destinationExportId")
  field(:allowed_protocol, 7, type: :string, json_name: "allowedProtocol")
  field(:allowed_verbs, 8, repeated: true, type: :string, json_name: "allowedVerbs")
  field(:route_generation, 9, type: :uint64, json_name: "routeGeneration")
  field(:policy_revision, 10, type: :uint64, json_name: "policyRevision")
  field(:budget, 11, type: Agentvmm.Trust.V1.RouteBudget)
  field(:not_before, 12, type: Google.Protobuf.Timestamp, json_name: "notBefore")
  field(:expires_at, 13, type: Google.Protobuf.Timestamp, json_name: "expiresAt")
  field(:nonce, 14, type: :bytes)
  field(:audience, 15, type: :string)
  field(:issuer_key_id, 16, type: :string, json_name: "issuerKeyId")
  field(:signature, 17, type: :bytes)
  field(:issuer_device_id, 18, type: :string, json_name: "issuerDeviceId")
  field(:route_class, 19, type: :string, json_name: "routeClass")

  field(:source_membership_credential, 20,
    type: Agentvmm.Trust.V1.MembershipCredential,
    json_name: "sourceMembershipCredential"
  )
end

defmodule Agentvmm.Trust.V1.RegistryOperation do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.RegistryOperation",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:operation_id, 1, type: :string, json_name: "operationId")
  field(:kind, 2, type: Agentvmm.Trust.V1.RegistryOperationKind, enum: true)
  field(:mesh_id, 3, type: :string, json_name: "meshId")
  field(:expected_revision, 4, type: :uint64, json_name: "expectedRevision")
  field(:policy_epoch, 5, type: :uint64, json_name: "policyEpoch")
  field(:issuer_device_id, 6, type: :string, json_name: "issuerDeviceId")
  field(:issuer_root_key_revision, 7, type: :uint64, json_name: "issuerRootKeyRevision")
  field(:membership, 8, type: Agentvmm.Trust.V1.MeshMembership)
  field(:invite_id, 9, type: :string, json_name: "inviteId")
  field(:expires_at, 10, type: Google.Protobuf.Timestamp, json_name: "expiresAt")
  field(:nonce, 11, type: :bytes)
  field(:signature, 12, type: :bytes)
  field(:pairing_proof, 13, type: :bytes, json_name: "pairingProof")
end

defmodule Agentvmm.Trust.V1.GetDeviceIdentityRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.GetDeviceIdentityRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Agentvmm.Trust.V1.SignEndpointObservationRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.SignEndpointObservationRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:unsigned_observation, 1,
    type: Agentvmm.Trust.V1.EndpointObservation,
    json_name: "unsignedObservation"
  )
end

defmodule Agentvmm.Trust.V1.ApplyMeshEndpointObservationRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.ApplyMeshEndpointObservationRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_id, 1, type: :string, json_name: "meshId")
  field(:observation, 2, type: Agentvmm.Trust.V1.EndpointObservation)
end

defmodule Agentvmm.Trust.V1.GetEndpointObservationRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.GetEndpointObservationRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:device_id, 1, type: :string, json_name: "deviceId")
end

defmodule Agentvmm.Trust.V1.ListPersonalMeshesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.ListPersonalMeshesRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Agentvmm.Trust.V1.PersonalMeshState do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.PersonalMeshState",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_descriptor, 1,
    type: Agentvmm.Trust.V1.PersonalMeshDescriptor,
    json_name: "meshDescriptor"
  )

  field(:snapshot, 2, type: Agentvmm.Trust.V1.MeshSnapshot)
end

defmodule Agentvmm.Trust.V1.ListPersonalMeshesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.ListPersonalMeshesResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:meshes, 1, repeated: true, type: Agentvmm.Trust.V1.PersonalMeshState)
end

defmodule Agentvmm.Trust.V1.InstallManagedTrustRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.InstallManagedTrustRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:trust_anchor, 1, type: Agentvmm.Trust.V1.TrustAnchor, json_name: "trustAnchor")

  field(:membership_credential, 2,
    type: Agentvmm.Trust.V1.MembershipCredential,
    json_name: "membershipCredential"
  )
end

defmodule Agentvmm.Trust.V1.InstallManagedTrustResponse do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.InstallManagedTrustResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:authority_id, 1, type: :string, json_name: "authorityId")
  field(:anchor_revision, 2, type: :uint64, json_name: "anchorRevision")
  field(:policy_revision, 3, type: :uint64, json_name: "policyRevision")
end

defmodule Agentvmm.Trust.V1.ApplyMeshSnapshotRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.ApplyMeshSnapshotRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:snapshot, 1, type: Agentvmm.Trust.V1.MeshSnapshot)
  field(:expected_revision, 2, type: :uint64, json_name: "expectedRevision")
end

defmodule Agentvmm.Trust.V1.ApplyMeshSnapshotResponse do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.ApplyMeshSnapshotResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:applied_revision, 1, type: :uint64, json_name: "appliedRevision")
end

defmodule Agentvmm.Trust.V1.AuthorizeRouteRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.AuthorizeRouteRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:capability, 1, type: Agentvmm.Trust.V1.RouteCapability)
  field(:expected_audience, 2, type: :string, json_name: "expectedAudience")
  field(:observed_at, 3, type: Google.Protobuf.Timestamp, json_name: "observedAt")
  field(:expected_source_device_id, 4, type: :string, json_name: "expectedSourceDeviceId")

  field(:expected_source_allocation_id, 5,
    proto3_optional: true,
    type: :string,
    json_name: "expectedSourceAllocationId"
  )

  field(:expected_destination_device_id, 6,
    type: :string,
    json_name: "expectedDestinationDeviceId"
  )

  field(:expected_destination_export_id, 7,
    type: :string,
    json_name: "expectedDestinationExportId"
  )

  field(:expected_route_generation, 8, type: :uint64, json_name: "expectedRouteGeneration")
  field(:expected_policy_revision, 9, type: :uint64, json_name: "expectedPolicyRevision")
  field(:expected_route_class, 10, type: :string, json_name: "expectedRouteClass")
end

defmodule Agentvmm.Trust.V1.AuthorizeRouteResponse do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.AuthorizeRouteResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:authorized, 1, type: :bool)
  field(:denial_code, 2, type: :string, json_name: "denialCode")
  field(:remaining_budget, 3, type: Agentvmm.Trust.V1.RouteBudget, json_name: "remainingBudget")
end

defmodule Agentvmm.Trust.V1.PendingRegistryOperation do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.PendingRegistryOperation",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:sequence, 1, type: :uint64)
  field(:operation, 2, type: Agentvmm.Trust.V1.RegistryOperation)

  field(:mesh_descriptor, 3,
    type: Agentvmm.Trust.V1.PersonalMeshDescriptor,
    json_name: "meshDescriptor"
  )
end

defmodule Agentvmm.Trust.V1.PullRegistryOperationsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.PullRegistryOperationsRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:after_sequence, 1, type: :uint64, json_name: "afterSequence")
  field(:limit, 2, type: :uint32)
end

defmodule Agentvmm.Trust.V1.PullRegistryOperationsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.PullRegistryOperationsResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:operations, 1, repeated: true, type: Agentvmm.Trust.V1.PendingRegistryOperation)
end

defmodule Agentvmm.Trust.V1.CommitRegistryOperationRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.CommitRegistryOperationRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:operation_id, 1, type: :string, json_name: "operationId")
  field(:snapshot, 2, type: Agentvmm.Trust.V1.MeshSnapshot)
end

defmodule Agentvmm.Trust.V1.CreateMeshRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.CreateMeshRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_descriptor, 1,
    type: Agentvmm.Trust.V1.PersonalMeshDescriptor,
    json_name: "meshDescriptor"
  )

  field(:genesis, 2, type: Agentvmm.Trust.V1.RegistryOperation)
end

defmodule Agentvmm.Trust.V1.CommitJoinRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.CommitJoinRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:operation, 1, type: Agentvmm.Trust.V1.RegistryOperation)
end

defmodule Agentvmm.Trust.V1.CommitRevokeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.CommitRevokeRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:operation, 1, type: Agentvmm.Trust.V1.RegistryOperation)
end

defmodule Agentvmm.Trust.V1.MeshCommitResponse do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.MeshCommitResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:snapshot, 1, type: Agentvmm.Trust.V1.MeshSnapshot)
end

defmodule Agentvmm.Trust.V1.GetSnapshotRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.GetSnapshotRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_id, 1, type: :string, json_name: "meshId")
  field(:minimum_revision, 2, type: :uint64, json_name: "minimumRevision")
end

defmodule Agentvmm.Trust.V1.PublishEndpointRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.PublishEndpointRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_id, 1, type: :string, json_name: "meshId")
  field(:expected_revision, 2, type: :uint64, json_name: "expectedRevision")
  field(:observation, 3, type: Agentvmm.Trust.V1.EndpointObservation)
end

defmodule Agentvmm.Trust.V1.PublishEndpointResponse do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.PublishEndpointResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:receipt, 1, type: Agentvmm.Trust.V1.RegistryReceipt)
end

defmodule Agentvmm.Trust.V1.ListMeshEndpointsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.ListMeshEndpointsRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_id, 1, type: :string, json_name: "meshId")
  field(:expected_revision, 2, type: :uint64, json_name: "expectedRevision")
end

defmodule Agentvmm.Trust.V1.ListMeshEndpointsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.ListMeshEndpointsResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:observations, 1, repeated: true, type: Agentvmm.Trust.V1.EndpointObservation)
  field(:mesh_revision, 2, type: :uint64, json_name: "meshRevision")
end

defmodule Agentvmm.Trust.V1.WatchRevisionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.WatchRevisionRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_id, 1, type: :string, json_name: "meshId")
  field(:after_revision, 2, type: :uint64, json_name: "afterRevision")
end

defmodule Agentvmm.Trust.V1.RevisionNotice do
  @moduledoc false

  use Protobuf,
    full_name: "agentvmm.trust.v1.RevisionNotice",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:mesh_id, 1, type: :string, json_name: "meshId")
  field(:revision, 2, type: :uint64)
end
