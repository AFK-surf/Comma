defmodule SalixSignalProto.Crypto.Kyber1024Openssl do
  @moduledoc """
  Kyber1024 as specified by CRYSTALS-Kyber round 3 (version 3.02), the KEM of
  type `0x08` (CRS-03 section 6.2), derived from the FIPS 203 ML-KEM-1024
  operations of OTP `:crypto` (OpenSSL 3.5 or later). OpenSSL does the
  secret-dependent lattice arithmetic in constant time.
  `SalixSignalProto.Crypto.Kyber1024` is a plain-Elixir implementation of the
  same algorithm; the tests check that the two agree.

  With `H = SHA3-256` and `KDF(x) = SHAKE256(x, 32 bytes)`, the round-3
  results follow from the FIPS 203 ones. The key formats and the inner
  public-key encryption are the same in both algorithms (CRS-03 section 6.2).

    * Key generation uses FIPS 203 key generation. CRS-03 section 6.2 rule 2
      allows either key generation, because only the key values reach the
      wire.
    * Encapsulation: FIPS 203 encapsulation picks a random m and returns
      `K = G(m || H(ek))[0..32)` and `c = Enc(ek, m, r)`. Round 3 computes the
      same `K̄` and `c` from its message `m'`, so with `m' = m` its shared
      secret is `KDF(K || H(c))`. A peer cannot tell a random `m'` from
      `m' = H(m)` for a random m.
    * Decapsulation: when re-encryption matches, FIPS 203 returns `K̄'` and
      round 3 returns `KDF(K̄' || H(c))`. When it does not match, FIPS 203
      returns `J(z || c) = SHAKE256(z || c, 32)` and deployed peers return
      `KDF(J(z || c) || H(c))` (CRS-03 section 6.2 rule 6). In both cases the
      result is `KDF(K_fips || H(c))` of the FIPS 203 result `K_fips`.

  OpenSSL also applies the FIPS 203 input checks: the encapsulation-key
  modulus check and the decapsulation-key hash check. Round 3 has no such
  checks (CRS-03 Q3). Keys that honest peers make always pass them; a key that
  fails is refused.

  Values are raw: encapsulation key 1568 bytes, decapsulation key 3168 bytes,
  ciphertext 1568 bytes, shared secret 32 bytes. OTP accepts no injected
  randomness, so key generation and encapsulation are not reproducible from a
  seed. With an OpenSSL older than 3.5, `supported?/0` is false and every
  other function returns `{:error, :unsupported}`.
  """

  @encapsulation_key_bytes 1568
  @decapsulation_key_bytes 3168
  @ciphertext_bytes 1568

  @type encapsulation_key :: binary()
  @type decapsulation_key :: binary()
  @type ciphertext :: binary()
  @type shared_secret :: <<_::256>>

  @doc "Returns true when the linked OpenSSL provides ML-KEM-1024."
  @spec supported?() :: boolean()
  def supported? do
    :mlkem1024 in Keyword.get(:crypto.supports(), :kems, [])
  end

  @doc "Generates a key pair. Returns `{:ok, {encapsulation_key, decapsulation_key}}`."
  @spec generate_keypair() ::
          {:ok, {encapsulation_key(), decapsulation_key()}} | {:error, :unsupported}
  def generate_keypair do
    with :ok <- check_supported() do
      {:ok, :crypto.generate_key(:mlkem1024, [])}
    end
  end

  @doc "Returns the encapsulation key embedded in a decapsulation key."
  @spec encapsulation_key(binary()) ::
          {:ok, encapsulation_key()} | {:error, :invalid_decapsulation_key | :unsupported}
  def encapsulation_key(decapsulation_key) when is_binary(decapsulation_key) do
    with :ok <- check_supported(),
         :ok <-
           check_size(decapsulation_key, @decapsulation_key_bytes, :invalid_decapsulation_key) do
      {encapsulation_key, _} = :crypto.generate_key(:mlkem1024, [], decapsulation_key)
      {:ok, encapsulation_key}
    end
  rescue
    ErlangError -> {:error, :invalid_decapsulation_key}
  end

  @doc """
  Encapsulates a fresh shared secret to `encapsulation_key`. Returns
  `{:ok, {shared_secret, ciphertext}}`.
  """
  @spec encapsulate(binary()) ::
          {:ok, {shared_secret(), ciphertext()}}
          | {:error, :invalid_encapsulation_key | :unsupported}
  def encapsulate(encapsulation_key) when is_binary(encapsulation_key) do
    with :ok <- check_supported(),
         :ok <-
           check_size(encapsulation_key, @encapsulation_key_bytes, :invalid_encapsulation_key) do
      {key, ciphertext} = :crypto.encapsulate_key(:mlkem1024, encapsulation_key)
      {:ok, {kdf(key, ciphertext), ciphertext}}
    end
  rescue
    ErlangError -> {:error, :invalid_encapsulation_key}
  end

  @doc """
  Decapsulates `ciphertext`. A ciphertext of the right size always yields a
  secret: an invalid one yields the deployed implicit-rejection secret
  (CRS-03 section 6.2 rule 6).
  """
  @spec decapsulate(binary(), binary()) ::
          {:ok, shared_secret()}
          | {:error, :invalid_decapsulation_key | :invalid_ciphertext | :unsupported}
  def decapsulate(decapsulation_key, ciphertext)
      when is_binary(decapsulation_key) and is_binary(ciphertext) do
    with :ok <- check_supported(),
         :ok <-
           check_size(decapsulation_key, @decapsulation_key_bytes, :invalid_decapsulation_key),
         :ok <- check_size(ciphertext, @ciphertext_bytes, :invalid_ciphertext) do
      key = :crypto.decapsulate_key(:mlkem1024, decapsulation_key, ciphertext)
      {:ok, kdf(key, ciphertext)}
    end
  rescue
    ErlangError -> {:error, :invalid_decapsulation_key}
  end

  # KDF(prefix || H(c)) of round 3.
  defp kdf(prefix, ciphertext), do: shake256([prefix, :crypto.hash(:sha3_256, ciphertext)])

  defp shake256(data), do: :crypto.hash_xof(:shake256, data, 256)

  defp check_supported, do: if(supported?(), do: :ok, else: {:error, :unsupported})

  defp check_size(bytes, size, _reason) when byte_size(bytes) == size, do: :ok
  defp check_size(_bytes, _size, reason), do: {:error, reason}
end
