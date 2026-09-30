defmodule SalixSignalProto do
  @moduledoc """
  Pure Signal protocol core for Salix.

  This application has no processes, storage, or network access. Where an
  algorithm consumes randomness, the randomness is an explicit argument with
  a secure default, so tests and the differential oracle can inject it. The
  exception is `SalixSignalProto.Crypto.Kyber1024Openssl`: OTP `:crypto`
  accepts no injected randomness for ML-KEM.

  Layer C1 (`SalixSignalProto.Crypto.*`) holds the primitives:

    * `SalixSignalProto.Crypto.X25519` and `SalixSignalProto.Crypto.Ed25519`
      (RFC 7748, RFC 8032) through OTP `:crypto`.
    * `SalixSignalProto.Crypto.XEdDSA`: XEd25519 as deployed (CRS-03
      section 5). No deployed step uses VXEdDSA (CRS-03 section 5.4), so it
      is not implemented.
    * `SalixSignalProto.Crypto.Ristretto255` (RFC 9496) with scalar arithmetic.
    * `SalixSignalProto.Crypto.Kyber1024Openssl`: CRYSTALS-Kyber round 3,
      the KEM of CRS-03 section 6, derived from OTP `:crypto` ML-KEM-1024.
    * `SalixSignalProto.Crypto.AesGcm`, `SalixSignalProto.Crypto.AesCbc`,
      `SalixSignalProto.Crypto.Hmac` and `SalixSignalProto.Crypto.Hkdf`
      (RFC 5869).

  Values are raw: wire type bytes such as `0x05` and `0x08` (CRS-03) belong
  to the key codecs of later layers.

  Layer C2 holds the 1:1 session protocol (CRS-03, CRS-04, CRS-04b):

    * `SalixSignalProto.Keys`: key, KEM and signature wire forms.
    * `SalixSignalProto.Address` and `SalixSignalProto.PreKeyBundle`.
    * `SalixSignalProto.Session`: PQXDH, the EC Double Ratchet, the sparse
      post-quantum ratchet (`SalixSignalProto.Session.Spqr`) and session
      records, as pure functions over a stored record.
    * `SalixSignalProto.Crypto.Kyber1024` (round 3, for PQXDH) and
      `SalixSignalProto.Crypto.MlKem768` (FIPS 203, for the post-quantum
      ratchet), in plain Elixir with injectable randomness. Secret-key KEM
      operations run in OTP `:crypto`; the plain-Elixir versions stand in
      for them only in tests (`SalixSignalProto.KemBackend`).

  Layer C5 holds messaging (CRS-05, CRS-06, CRS-07):

    * `SalixSignalProto.Message.*`: the server envelope, the content
      container and its builders, padding, the decryption error message and
      its plaintext wrapper, and the 1:1 disappearing-message timer.
    * `SalixSignalProto.SealedSender`: sealed sender v1 and v2, with
      certificates, access keys and the sealed inner message in
      `SalixSignalProto.SealedSender.*`.
    * `SalixSignalProto.Receive`: one received envelope from its bytes to a
      validated content container and the state changes to commit.
    * `SalixSignalProto.ServiceId`: service ID wire forms.

  Layer C7 holds groups (CRS-09a, CRS-09b, CRS-09c):

    * `SalixSignalProto.Group.*`: group keys, UID and profile key
      ciphertexts, attribute blobs (over `SalixSignalProto.Crypto.AesGcmSiv`),
      the proof system, the group auth credential, the expiring profile key
      credential, notary signatures, group send endorsements, group state and
      changes, invite links and storage-service request helpers.
    * `SalixSignalProto.SenderKey.*`: sender key messages, the sender key
      record and the send-side rules.

  Layer C8 holds contact discovery (CRS-11):

    * `SalixSignalProto.ContactDiscovery.Attestation`: verification of the
      enclave's SGX attestation, over `SalixSignalProto.ContactDiscovery.X509`
      and `SalixSignalProto.ContactDiscovery.Collateral`.
    * `SalixSignalProto.ContactDiscovery.Noise`: the NKhfs Noise channel,
      with `SalixSignalProto.Crypto.MlKem1024` (FIPS 203).
    * `SalixSignalProto.ContactDiscovery.Lookup`: request and response
      messages and close codes.

  Secret-dependent curve operations run in one C NIF over libsodium
  (`c_src/`). Operations on public data only, such as signature verification,
  run in OTP `:crypto` or plain Elixir.
  """
end
