defmodule SalixSignalProto.Crypto.Kyber1024 do
  @moduledoc """
  Kyber1024 as specified in the CRYSTALS-Kyber round-3 submission, version
  3.02 (2021-08-04): the CCA-secure KEM with k = 4, eta1 = eta2 = 2,
  du = 11 and dv = 5.

  CRS-03 §6.2 requires this algorithm for KEM keys of type `0x08`. It is not
  FIPS 203 ML-KEM-1024: the two share the key formats and the inner
  public-key encryption (`SalixSignalProto.Crypto.KyberPke`), but derive
  different shared secrets. Keys use the raw formats here (1568-byte
  encapsulation key, 3168-byte decapsulation key `dk_pke || ek || H(ek) || z`,
  1568-byte ciphertext); `SalixSignalProto.Keys` adds the `0x08` type byte.

  Key generation accepts either seed expansion, because only the resulting
  key values reach the wire (CRS-03 §6.2 rule 2): `:round3` computes
  `(rho, sigma) = G(d)` and `:fips203` computes `G(d || 0x04)`.

  Encapsulation and decapsulation run no input checks on keys, as the
  round-3 text and deployed peers do not (CRS-03 §6.2 rule 4).

  Plain Elixir; see `SalixSignalProto.Crypto.KyberPke` for its timing
  properties. The re-encryption comparison uses `:crypto.hash_equals/2`.
  Randomness is an explicit argument so that tests can inject it.
  """

  alias SalixSignalProto.Crypto.KyberPke

  @params %{k: 4, du: 11, dv: 5}
  @dk_pke_bytes 1536
  @ek_bytes 1568
  @dk_bytes 3168
  @ct_bytes 1568

  @type encapsulation_key :: <<_::12_544>>
  @type decapsulation_key :: <<_::25_344>>
  @type ciphertext :: <<_::12_544>>
  @type shared_secret :: <<_::256>>

  @doc """
  Generates a key pair from the 32-byte seeds `d` and `z`. `keygen` selects
  the seed expansion (`:round3` or `:fips203`). Returns
  `{encapsulation_key, decapsulation_key}`.
  """
  @spec keypair_from_seed(<<_::256>>, <<_::256>>, :round3 | :fips203) ::
          {encapsulation_key(), decapsulation_key()}
  def keypair_from_seed(<<_::binary-size(32)>> = d, <<_::binary-size(32)>> = z, keygen \\ :round3)
      when keygen in [:round3, :fips203] do
    seed = if keygen == :round3, do: d, else: d <> <<@params.k>>
    <<rho::binary-size(32), sigma::binary-size(32)>> = g(seed)
    {ek, dk_pke} = KyberPke.keygen(rho, sigma, @params)
    {ek, dk_pke <> ek <> h(ek) <> z}
  end

  @doc "Generates a key pair from fresh random seeds."
  @spec keypair() :: {encapsulation_key(), decapsulation_key()}
  def keypair, do: keypair_from_seed(:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32))

  @doc """
  Encapsulates to `encapsulation_key` with the 32-byte random input `m`
  (round 3 hashes it first). Returns `{:ok, {shared_secret, ciphertext}}`, or
  `{:error, :invalid_encapsulation_key}` for a key of the wrong size.
  """
  @spec encapsulate(binary(), <<_::256>>) ::
          {:ok, {shared_secret(), ciphertext()}} | {:error, :invalid_encapsulation_key}
  def encapsulate(encapsulation_key, m \\ :crypto.strong_rand_bytes(32))

  def encapsulate(<<_::binary-size(@ek_bytes)>> = ek, <<_::binary-size(32)>> = m) do
    m = h(m)
    <<k_bar::binary-size(32), r::binary-size(32)>> = g(m <> h(ek))
    c = KyberPke.encrypt(ek, m, r, @params)
    {:ok, {kdf(k_bar <> h(c)), c}}
  end

  def encapsulate(ek, <<_::binary-size(32)>>) when is_binary(ek),
    do: {:error, :invalid_encapsulation_key}

  @doc """
  Decapsulates `ciphertext`. A ciphertext of the right size that does not
  re-encrypt yields the implicit-rejection secret, not an error. Returns
  `{:error, reason}` only for inputs of the wrong size.

  The implicit-rejection secret is the deployed one (CRS-03 §6.2 rule 6):
  `KDF(J(z || c) || H(c))` with `J(x) = SHAKE256(x, 32 bytes)`, not the
  round-3 text form `KDF(z || H(c))`.
  """
  @spec decapsulate(binary(), binary()) ::
          {:ok, shared_secret()} | {:error, :invalid_decapsulation_key | :invalid_ciphertext}
  def decapsulate(
        <<dk_pke::binary-size(@dk_pke_bytes), ek::binary-size(@ek_bytes),
          ek_hash::binary-size(32), z::binary-size(32)>>,
        <<_::binary-size(@ct_bytes)>> = c
      ) do
    m = KyberPke.decrypt(dk_pke, c, @params)
    <<k_bar::binary-size(32), r::binary-size(32)>> = g(m <> ek_hash)
    same = :crypto.hash_equals(c, KyberPke.encrypt(ek, m, r, @params))
    accepted = kdf(k_bar <> h(c))
    rejected = kdf(kdf(z <> c) <> h(c))
    {:ok, if(same, do: accepted, else: rejected)}
  end

  def decapsulate(<<_::binary-size(@dk_bytes)>>, c) when is_binary(c),
    do: {:error, :invalid_ciphertext}

  def decapsulate(dk, c) when is_binary(dk) and is_binary(c),
    do: {:error, :invalid_decapsulation_key}

  defp h(bytes), do: :crypto.hash(:sha3_256, bytes)
  defp g(bytes), do: :crypto.hash(:sha3_512, bytes)
  defp kdf(bytes), do: :crypto.hash_xof(:shake256, bytes, 256)
end
