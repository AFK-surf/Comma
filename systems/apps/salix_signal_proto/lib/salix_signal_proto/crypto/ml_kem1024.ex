defmodule SalixSignalProto.Crypto.MlKem1024 do
  @moduledoc """
  FIPS 203 ML-KEM-1024 (k = 4, eta1 = eta2 = 2, du = 11, dv = 5), the KEM of
  the contact discovery Noise channel (CRS-11 §4.2). The protocol name calls
  it "Kyber1024", but the channel uses the FIPS 203 algorithm, not the
  round-3 KEM of `SalixSignalProto.Crypto.Kyber1024`.

  Sizes: encapsulation key 1568 bytes, decapsulation key 3168 bytes
  (`dk_pke || ek || H(ek) || z`), ciphertext 1568 bytes, shared secret
  32 bytes.

  `keypair/1` and `decapsulate/2` handle the secret key. They run in constant
  time in OTP `:crypto`, which has ML-KEM-1024 with OpenSSL 3.5 (the
  production images). Only tests may run them in plain Elixir on
  `SalixSignalProto.Crypto.KyberPke`; anywhere else a node without that
  support raises `SalixSignalProto.KemBackend.UnsupportedError`
  (`SalixSignalProto.KemBackend`). `encapsulate/2` is plain Elixir with
  injected randomness; it touches only public values.
  """

  alias SalixSignalProto.Crypto.KyberPke
  alias SalixSignalProto.KemBackend

  @params %{k: 4, du: 11, dv: 5}
  @dk_pke_bytes 1536
  @ek_bytes 1568
  @dk_bytes 3168
  @ct_bytes 1568

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
    case KemBackend.select!(:mlkem1024) do
      :openssl -> :crypto.generate_key(:mlkem1024, [])
      :plain -> keypair_from_seed(d, z)
    end
  end

  @doc """
  FIPS 203 `ML-KEM.Encaps_internal(ek, m)`. Returns
  `{:ok, {shared_secret, ciphertext}}`, or `{:error, :invalid_input}` for a
  key of the wrong size.
  """
  @spec encapsulate(binary(), <<_::256>>) ::
          {:ok, {<<_::256>>, binary()}} | {:error, :invalid_input}
  def encapsulate(<<_::binary-size(@ek_bytes)>> = ek, <<_::binary-size(32)>> = m) do
    <<shared::binary-size(32), r::binary-size(32)>> = g(m <> h(ek))
    {:ok, {shared, KyberPke.encrypt(ek, m, r, @params)}}
  end

  def encapsulate(ek, <<_::binary-size(32)>>) when is_binary(ek), do: {:error, :invalid_input}

  @doc """
  FIPS 203 `ML-KEM.Decaps(dk, c)`, with implicit rejection `J(z || c)`, in
  OTP `:crypto` (plain Elixir only in tests, see `SalixSignalProto.KemBackend`).
  Returns `{:error, :invalid_input}` for inputs of the wrong size.
  """
  @spec decapsulate(binary(), binary()) :: {:ok, <<_::256>>} | {:error, :invalid_input}
  def decapsulate(<<_::binary-size(@dk_bytes)>> = dk, <<_::binary-size(@ct_bytes)>> = c) do
    case KemBackend.select!(:mlkem1024) do
      :openssl -> openssl_decapsulate(dk, c)
      :plain -> decapsulate_plain(dk, c)
    end
  end

  def decapsulate(dk, c) when is_binary(dk) and is_binary(c), do: {:error, :invalid_input}

  defp openssl_decapsulate(dk, c) do
    {:ok, :crypto.decapsulate_key(:mlkem1024, dk, c)}
  rescue
    ErlangError -> {:error, :invalid_input}
  end

  @doc "`decapsulate/2` in plain Elixir, on every host. For tests and vectors."
  @spec decapsulate_plain(binary(), binary()) :: {:ok, <<_::256>>} | {:error, :invalid_input}
  def decapsulate_plain(
        <<dk_pke::binary-size(@dk_pke_bytes), ek::binary-size(@ek_bytes),
          ek_hash::binary-size(32), z::binary-size(32)>>,
        <<_::binary-size(@ct_bytes)>> = c
      ) do
    m = KyberPke.decrypt(dk_pke, c, @params)
    <<shared::binary-size(32), r::binary-size(32)>> = g(m <> ek_hash)
    same = :crypto.hash_equals(c, KyberPke.encrypt(ek, m, r, @params))
    rejected = :crypto.hash_xof(:shake256, z <> c, 256)
    {:ok, if(same, do: shared, else: rejected)}
  end

  def decapsulate_plain(dk, c) when is_binary(dk) and is_binary(c), do: {:error, :invalid_input}

  defp h(bytes), do: :crypto.hash(:sha3_256, bytes)
  defp g(bytes), do: :crypto.hash(:sha3_512, bytes)
end
