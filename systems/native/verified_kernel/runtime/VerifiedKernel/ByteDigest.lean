import Init

namespace VerifiedKernel.ByteDigest

/-! SHA-256 comes from the host's OpenSSL `libcrypto` through one C extern in
the NIF wrapper (`salix_verified_kernel_sha256`). The kernel does not
implement the hash itself; OpenSSL is a trusted native dependency, like the
Lean runtime and the BEAM. Base64 stays an executable Lean definition. -/

/-- The 32-byte SHA-256 digest of `message`, computed by OpenSSL. -/
@[extern "salix_verified_kernel_sha256"]
opaque sha256Bytes (message : @& ByteArray) : ByteArray

private def alphabet (index : Nat) : UInt8 :=
  UInt8.ofNat (if index < 26 then 65 + index
    else if index < 52 then 97 + index - 26
    else if index < 62 then 48 + index - 52
    else if index = 62 then 45 else 95)

/-- RFC 4648 URL alphabet. No '=' padding is emitted. -/
def base64Url : List UInt8 → List UInt8
  | [] => []
  | [a] => [alphabet (a.toNat / 4), alphabet ((a.toNat % 4) * 16)]
  | [a, b] => [alphabet (a.toNat / 4), alphabet ((a.toNat % 4) * 16 + b.toNat / 16),
      alphabet ((b.toNat % 16) * 4)]
  | a :: b :: c :: rest =>
      alphabet (a.toNat / 4) :: alphabet ((a.toNat % 4) * 16 + b.toNat / 16) ::
      alphabet ((b.toNat % 16) * 4 + c.toNat / 64) :: alphabet (c.toNat % 64) :: base64Url rest

end VerifiedKernel.ByteDigest
