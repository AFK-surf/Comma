#include <lean/lean.h>
#include <openssl/evp.h>

/* SHA-256 for `VerifiedKernel.ByteDigest.sha256Bytes`, from OpenSSL libcrypto.
 * The Lean side borrows `message`; the 32-byte digest is a fresh ByteArray. */
lean_obj_res salix_verified_kernel_sha256(b_lean_obj_arg message) {
    lean_object *digest = lean_alloc_sarray(1, 32, 32);
    unsigned int size = 0;
    if (!EVP_Digest(lean_sarray_cptr(message), lean_sarray_size(message),
                    lean_sarray_cptr(digest), &size, EVP_sha256(), NULL) || size != 32) {
        lean_dec(digest);
        lean_internal_panic("OpenSSL SHA-256 failed");
    }
    return digest;
}
