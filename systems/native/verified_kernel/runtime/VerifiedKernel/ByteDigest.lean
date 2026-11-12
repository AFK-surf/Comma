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

def base64UrlTR (bytes : List UInt8) : List UInt8 := go bytes []
where
  go : List UInt8 → List UInt8 → List UInt8
    | [], acc => acc.reverse
    | [a], acc => acc.reverse ++ [alphabet (a.toNat / 4), alphabet ((a.toNat % 4) * 16)]
    | [a, b], acc => acc.reverse ++
        [alphabet (a.toNat / 4), alphabet ((a.toNat % 4) * 16 + b.toNat / 16), alphabet ((b.toNat % 16) * 4)]
    | a :: b :: c :: rest, acc => go rest
        (alphabet (c.toNat % 64) :: alphabet ((b.toNat % 16) * 4 + c.toNat / 64) ::
          alphabet ((a.toNat % 4) * 16 + b.toNat / 16) :: alphabet (a.toNat / 4) :: acc)

private theorem base64UrlTR_go_eq (bytes acc : List UInt8) :
    base64UrlTR.go bytes acc = acc.reverse ++ base64Url bytes := by
  fun_induction base64Url bytes generalizing acc <;> simp_all [base64UrlTR.go, List.append_assoc]

@[csimp] theorem base64Url_eq_base64UrlTR : @base64Url = @base64UrlTR := by
  funext bytes
  simp [base64UrlTR, base64UrlTR_go_eq]

end VerifiedKernel.ByteDigest
