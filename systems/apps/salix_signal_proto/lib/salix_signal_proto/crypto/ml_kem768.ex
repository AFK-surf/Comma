defmodule SalixSignalProto.Crypto.MlKem768 do
  @moduledoc """
  FIPS 203 ML-KEM-768 (k = 3, eta1 = eta2 = 2, du = 10, dv = 4), with the
  encapsulation split into two steps as the post-quantum ratchet uses it
  (CRS-04b §8).

  Sizes: encapsulation key 1184 bytes (`t_enc` 1152 bytes, then rho),
  decapsulation key 2400 bytes (`dk_pke || ek || H(ek) || z`), ciphertext
  1088 bytes (`c1` 960 bytes, then `c2` 128 bytes), shared secret 32 bytes.

  Two-step encapsulation (CRS-04b §8.3): `encapsulate_first/3` needs only
  rho and H(ek) and gives the shared secret and `c1`; `encapsulate_second/3`
  needs `t_enc` and gives `c2`. `c1 || c2` equals the one-step FIPS 203
  ciphertext for the same key and m.

  `keypair/1` and `decapsulate/2` handle the secret key. They run in constant
  time in OTP `:crypto`, which has ML-KEM-768 with OpenSSL 3.5 (the
  production images). Only tests may run them in plain Elixir; anywhere else
  a node without that support raises
  `SalixSignalProto.KemBackend.UnsupportedError` (`SalixSignalProto.KemBackend`).
  The other functions are plain Elixir, built on
  `SalixSignalProto.Crypto.KyberPke` (see that module for its timing
  properties): OTP `:crypto` cannot split encapsulation or take injected
  randomness.
  """

  alias SalixSignalProto.Crypto.KyberPke
  alias SalixSignalProto.KemBackend

  @params %{k: 3, du: 10, dv: 4}
  @t_bytes 1152
  @ek_bytes 1184
  @dk_bytes 2400
  @c1_bytes 960
  @c2_bytes 128

  @doc """
  FIPS 203 `ML-KEM.KeyGen_internal(d, z)`. Returns
  `{encapsulation_key, decapsulation_key}`.
  """
  @spec keypair_from_seed(<<_::256>>, <<_::256>>) :: {binary(), binary()}
  def keypair_from_seed(<<_::binary-size(32)>> = d, <<_::binary-size(32)>> = z) do
    <<rho::binary-size(32), sigma::binary-size(32)>> = g(d <> <<@params.k>>)
    {ek, dk_pke} = KyberPke.keygen(rho, sigma, @params)
    {ek, dk_pke <> ek <> h(ek) <> z}
  end

  @doc """
  Generates a key pair `{encapsulation_key, decapsulation_key}`. With OTP
  ML-KEM the 64 random bytes are not used; in the plain-Elixir test backend
  they are the seeds `d || z` of `keypair_from_seed/2`.
  """
  @spec keypair(<<_::512>>) :: {binary(), binary()}
  def keypair(<<d::binary-size(32), z::binary-size(32)>>) do
    case KemBackend.select!(:mlkem768) do
      :openssl -> :crypto.generate_key(:mlkem768, [])
      :plain -> keypair_from_seed(d, z)
    end
  end

  @doc "True when `ek` has the right size and passes the FIPS 203 modulus check."
  @spec valid_encapsulation_key?(binary()) :: boolean()
  def valid_encapsulation_key?(<<t::binary-size(@t_bytes), _rho::binary-size(32)>>),
    do: KyberPke.canonical_vector?(t)

  def valid_encapsulation_key?(ek) when is_binary(ek), do: false

  @doc """
  FIPS 203 `ML-KEM.Encaps_internal(ek, m)` in one step. Returns
  `{shared_secret, ciphertext}`.
  """
  @spec encapsulate(binary(), <<_::256>>) :: {<<_::256>>, binary()}
  def encapsulate(
        <<t::binary-size(@t_bytes), rho::binary-size(32)>> = ek,
        <<_::binary-size(32)>> = m
      ) do
    {shared, c1, r} = encapsulate_first(rho, h(ek), m)
    {shared, c1 <> encapsulate_second(t, r, m)}
  end

  @doc """
  Encapsulation step 1: `(K, r) = G(m || H(ek))` and `c1`. Returns
  `{shared_secret, c1, r}`; step 2 needs `r` and `m`.
  """
  @spec encapsulate_first(<<_::256>>, <<_::256>>, <<_::256>>) ::
          {<<_::256>>, binary(), <<_::256>>}
  def encapsulate_first(
        <<_::binary-size(32)>> = rho,
        <<_::binary-size(32)>> = ek_hash,
        <<_::binary-size(32)>> = m
      ) do
    <<shared::binary-size(32), r::binary-size(32)>> = g(m <> ek_hash)
    {shared, KyberPke.encrypt_u(rho, r, @params), r}
  end

  @doc "Encapsulation step 2: `c2` from `t_enc`, the step-1 `r` and `m`."
  @spec encapsulate_second(binary(), <<_::256>>, <<_::256>>) :: binary()
  def encapsulate_second(
        <<_::binary-size(@t_bytes)>> = t,
        <<_::binary-size(32)>> = r,
        <<_::binary-size(32)>> = m
      ),
      do: KyberPke.encrypt_v(t, r, m, @params)

  @doc """
  FIPS 203 `ML-KEM.Decaps(dk, c)`, with implicit rejection `J(z || c)`, in
  OTP `:crypto` (plain Elixir only in tests, see `SalixSignalProto.KemBackend`).
  Returns `{:error, :invalid_input}` for inputs of the wrong size.
  """
  @spec decapsulate(binary(), binary()) :: {:ok, <<_::256>>} | {:error, :invalid_input}
  def decapsulate(
        <<_::binary-size(@dk_bytes)>> = dk,
        <<_::binary-size(@c1_bytes + @c2_bytes)>> = c
      ) do
    case KemBackend.select!(:mlkem768) do
      :openssl -> openssl_decapsulate(dk, c)
      :plain -> decapsulate_plain(dk, c)
    end
  end

  def decapsulate(dk, c) when is_binary(dk) and is_binary(c), do: {:error, :invalid_input}

  defp openssl_decapsulate(dk, c) do
    {:ok, :crypto.decapsulate_key(:mlkem768, dk, c)}
  rescue
    ErlangError -> {:error, :invalid_input}
  end

  @doc "`decapsulate/2` in plain Elixir, on every host. For tests and vectors."
  @spec decapsulate_plain(binary(), binary()) :: {:ok, <<_::256>>} | {:error, :invalid_input}
  def decapsulate_plain(
        <<dk_pke::binary-size(@t_bytes), ek::binary-size(@ek_bytes), ek_hash::binary-size(32),
          z::binary-size(32)>>,
        <<_::binary-size(@c1_bytes + @c2_bytes)>> = c
      ) do
    m = KyberPke.decrypt(dk_pke, c, @params)
    <<shared::binary-size(32), r::binary-size(32)>> = g(m <> ek_hash)
    same = :crypto.hash_equals(c, KyberPke.encrypt(ek, m, r, @params))
    rejected = :crypto.hash_xof(:shake256, z <> c, 256)
    {:ok, if(same, do: shared, else: rejected)}
  end

  def decapsulate_plain(dk, c) when is_binary(dk) and is_binary(c), do: {:error, :invalid_input}

  @doc false
  def sizes, do: %{ek: @ek_bytes, dk: @dk_bytes, t: @t_bytes, c1: @c1_bytes, c2: @c2_bytes}

  defp h(bytes), do: :crypto.hash(:sha3_256, bytes)
  defp g(bytes), do: :crypto.hash(:sha3_512, bytes)
end
