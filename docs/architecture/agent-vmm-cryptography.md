# Agent VMM cryptography profile

Status: protocol suites approved for local Phase 0–6 implementation on
2026-08-12. Release-artifact boundaries were narrowed by RFC22 on 2026-08-27.
Production GA still requires the independently owned gates below.

## Final suite boundaries

| Use case                                                                            | Suite                                                                                 | Independent authority and consumer                                                                                                                                             | Decision                                                                                                                    |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Device identity, managed authority, personal-mesh operations and route capabilities | P-256 ECDSA with SHA-256, compressed SEC1 public key, fixed 64-byte `r \|\| s`, low-S | Device, managed-authority, and registry-receipt keys have separate owners; Host and registry verifiers consume their respective signatures                                     | Keep for the project's approximately 128-bit classical security target and platform interoperability.                       |
| Eight-digit PIN or QR pairing                                                       | RFC 9382 SPAKE2-P256 with SHA-256, HKDF-SHA256 and HMAC-SHA256                        | The two pairing peers independently possess the short secret; the pairing state machine consumes the transcript                                                                | Keep as a separate PAKE protocol. The shared curve does not authorize key reuse.                                            |
| PAKE-confirmed identity and permission exchange                                     | Directional ChaCha20-Poly1305 records with transcript, direction and sequence AAD     | The completed PAKE transcript derives directional session keys; the pairing endpoints consume and erase them on terminal state                                                 | Keep. Iroh authenticates a transport endpoint, not the PIN peer.                                                            |
| Connector and gateway transport                                                     | TLS 1.3 plus a 256-bit rotatable bearer; bearer wire is RFC 4648 base64 ASCII         | The TLS endpoint identity and connector credential are issued independently of the device root; gateway admission consumes them                                                | Keep. A headless daemon stores the bearer in its service-user-owned state directory. Token digests use SHA-256 because the token is high entropy, not a password. |
| Iroh service transport                                                              | Iroh QUIC/TLS endpoint identity                                                       | A device-signed observation binds the endpoint key; the remote connector and registry consume that binding                                                                     | Keep. Reachability never grants application authority.                                                                      |
| Server-bound Runner/Host downloads                                                  | SHA-256 from the immutable descriptor embedded in the same Server release             | The Server release image owns the expected digest; the installer compares downloaded R2/CDN bytes before atomic replacement                                                    | Keep. Digest mismatch leaves the current install untouched and reports the exact component/path.                            |
| macOS package admission                                                             | Apple code-signing/notarization checks once per package boundary                      | Apple platform policy is the independent verifier; lifecycle installation consumes its result. Publisher identity is checked only when a separately approved Team ID is pinned | Keep as a platform gate. Structural `codesign --verify` alone is not project publisher authentication.                      |
| Third-party release artifacts                                                       | Offline publisher signature only when signer/key owner is independent of Server/CI    | The approved third-party publisher key is independent authority; the artifact importer consumes it                                                                             | Conditional. First-party Guest and Appliance artifacts built with their verifier/key in one CI release do not use this row. |

Application signatures use one versioned canonical protobuf rule:
`agent-vmm/signature/v1\0 || message type || \0 || deterministic protobuf`.
Unknown fields, non-canonical business reconstruction, invalid compressed keys,
non-fixed signatures and high-S signatures fail closed in Go and Elixir.

For macOS release artifacts, `codesign --verify` alone proves only structural
validity. The Server descriptor SHA already authenticates the exact project
bytes against the untrusted download channel. Add a designated requirement or
Team ID check only if owner review explicitly expands the boundary to Apple
publisher identity. Staging ad-hoc signatures are permitted only for
debug/conformance testing and must be reported as structural integrity.

## Library decision

The phase implementation pins `pakery` 0.2.1 behind the Agent VMM pairing
adapter and uses its RFC 9382 P-256 suite. This is acceptable for local
implementation and interoperability testing, but an independent cryptographic
review or replacement with a mature audited implementation remains a GA gate.

RustCrypto/PAKEs is not a replacement at this time. Its `spake2` crate exposes
only its older Ed25519-group protocol, does not implement the RFC 9382 P-256
transcript, does not provide mutual explicit key confirmation, does not erase
password/state material, and describes itself as unaudited and probably not
constant-time. Adopting it would require a fork plus handwritten transcript,
confirmation and secret-lifecycle code. Reconsider it only after a released
RFC 9382 P-256 suite, closure of upstream transcript issue 186, built-in mutual
confirmation, `ZeroizeOnDrop`, deterministic KAT hooks and an independent
audit.

## Removed and deferred complexity

- `TrustAnchor.signature` is reserved and removed from V1. Enrollment TLS
  authenticates the initial authority key set. A future offline rotation must
  use a distinct previous-anchor-signed rotation message.
- Suite unification never means key unification. Device, managed authority,
  registry freshness, PAKE, Iroh and artifact keys remain purpose-separated.
- Internal mTLS admits the environment's Comma service class through its
  dedicated client issuer. The reverse Gateway-to-Comma callback uses a separate
  credential. Workload SAN/SPIFFE admission remains deferred. It cannot replace
  the opposite-direction callback credential.
- Post-quantum hybrid transport is threat-model driven. It is not a Phase 0–6
  requirement without a long-term confidentiality requirement.

## Gateway CA custody and renewal

Owner decision, 2026-09-30: use Cloud KMS plus existing mTLS. Keep separate
server and client issuers per environment. Each root directly signs leaves.
SOFTWARE RSA3072/SHA256 keys stay in KMS. Terraform owns key resources and IAM
in `gcp-infra`. The `comma-release` tool uses Go `crypto/x509` for certificates
and Smallstep's `cloudkms` library for KMS signing. It needs no separate signing
binary or CA service.

One signer identity per environment can use those two keys and publish the
TLS bundle. Its OIDC binding requires the repository numeric ID, main ref,
environment and certificate workflow. Runtime Pods receive leaf keys and public
roots. They receive no CA signing permission. Deployment uses the existing
release identity and approved mainline image/chart.

KMS prevents routine runners from exporting the CA key. It does not prevent
a compromised authorized signer from requesting malicious signatures. Cloud
administrators and release owners can replace trust. An imported offline key
backup remains a valid signer until its owner retires it. No online KMS call,
CI-success check, extra signature or image-version gate is added to RPCs.

One GSM bundle version contains both leaves, their private keys and public
trust. Delivery expands it into the three existing native TLS Secrets. Atomic
publication prevents later releases from selecting a partially published pair.
Kubernetes delivery remains non-transactional. Retry the same numeric candidate
after partial delivery, then roll both consumers within the existing budget.
Runtime and callback credentials keep their separate containers and owners.

Leaves retain the one-year baseline. The monthly staging workflow renews within 60
days of expiry and performs delivery and rolling reload. Production scheduling
remains part of its approved activation. Ordinary renewal keeps
root keys, Host trust, registrations, child processes and owned data. A root
change remains an explicit owner operation. Disabling a signer stops issuance
but does not revoke existing certificates. The current Go path consumes no CRL.

The recovered staging server root can be imported without changing Host trust.
The missing client signer needs replacement. Client trust and leaf switch
together, with a possible brief control interruption. Existing rolling policy
allows that interruption. No overlap or shutdown is required merely to keep
an intermediate version serving. Production follows staging proof and promotion.

## Production gates

| GA item                                                          | Independent authority                                               | Consumer and decision                                                                              |
| ---------------------------------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| PAKE dependency review or replacement                            | Independent cryptographic review or a mature audited implementation | Security owner decides whether the pairing implementation is acceptable for GA                     |
| Managed and registry signer separation                           | Purpose-separated HSM/KMS key policy                                | Signing services consume only their assigned keys; a boundary violation blocks GA                  |
| Bearer, certificate, root, and endpoint rotation/recovery drills | The independently owned current and replacement credentials/keys    | Release operator confirms replacement and recovery without retaining an obsolete credential path   |
| Dependency advisory and license checks                           | External advisory data and package license metadata                 | CI blocks an affected build according to the owned policy                                          |
| Guest SBOM                                                       | The packages observed in the built Guest filesystem                 | Dependency/license tooling may consume it as CI inventory; it is not runtime or security authority |
| Iroh endpoint-key and relay metadata policy                      | Product privacy and security owners                                 | Connector and operations logging/storage follow the approved retention and disclosure decision     |
| Real-device pairing/fault matrix                                 | The macOS platform and independently provisioned test devices       | Release owner confirms the platform integration before GA                                          |

TLS and protocol choices follow RFC 8446, RFC 9382 and RFC 8439; P-256
signatures follow FIPS 186-5/SP 800-186.

## Comma installation recovery proof

The existing Host root proves possession when the original User logs in with a new Session.
The independent expected value is the Host identity digest saved during the original installation exchange.
The installation owner verifies that identity and its P-256 SHA-256 low-S signature before moving the delivery target.
A cloud workspace owner alone cannot adopt another subject's installation. A root mismatch, revoked registration, or stale challenge fails closed.
Local disposal also disables this proof for that exact registration. It does not revoke PersonalMesh membership or replace the root.

The purpose is `agent-vmm/comma-recovery/1`. This endpoint cannot sign arbitrary payloads.
The server stores one 32-byte random nonce, authorization revision, new Session, original subject, and exact installation scope for 120 seconds.
The canonical wire has newline-delimited purpose, then unpadded base64url UTF-8 values in this order:
`audience`, `subject`, `session_id`, `tenant_id`, `group_id`, `scope_key`, `environment_id`, `operation_id`, `registration_id`, `nonce`.
Canonical decimal revision and Unix expiry follow, with a final newline.
Signature bytes are fixed 64-byte `r || s`, as in the device suite above.
Preview grants no authority. Consumption rechecks the active original subject and Workspace owner, scope, revision, and nonce under the installation row lock.
The same lock protects ordinary configure, retry, revoke, and initialization against a validated old Session continuing after recovery.
A lost consume response is resolved by an authenticated read of that exact original binding, without replaying a consumed challenge.
Before exchange, the original subject can resolve a lost authorize response through its saved request ID.
This indexed lookup requires the current active Workspace owner and returns only the original operation, registration, scope, and authorization status.
It neither rotates the ticket nor moves the delivery target. The user can explicitly close that unexchanged request before creating a new one.

Go standard-library crypto and Erlang OTP crypto implement P-256 and SHA-256. The small wire adapter binds this product purpose and scope.
No library defines this installation-owner transcript. Both implementations check the same canonical UTF-8 vector and their runtime signature boundaries.
The nonce/revision is an existing authorization fence. It is not a release, artifact, or availability gate.
