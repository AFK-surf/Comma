defmodule SalixSignalProto.Keys do
  @moduledoc """
  Wire formats of the keys and signatures that the 1:1 session protocol
  carries (CRS-03 §2 to §6), and the checks that CRS-04 puts on them.

  | Value | Wire form |
  | --- | --- |
  | EC public key | 33 bytes: `0x05 || u` (X25519 u-coordinate) |
  | EC private key | 32 bytes, clamped (never sent) |
  | KEM public key | 1569 bytes: `0x08 || ek` (Kyber1024 round 3) |
  | KEM secret key | 3169 bytes: `0x08 || dk` (never sent) |
  | KEM ciphertext | 1569 bytes: `0x08 || c` |
  | Signature | 64 bytes: deployed XEdDSA, sign bit in bit 7 of byte 63 |

  Signatures use deployed XEdDSA (`SalixSignalProto.Crypto.XEdDSA`, CRS-03
  §5) over the serialized forms of §4.
  """

  alias SalixSignalProto.Crypto.Edwards25519
  alias SalixSignalProto.Crypto.Kyber1024
  alias SalixSignalProto.Crypto.Kyber1024Openssl
  alias SalixSignalProto.Crypto.X25519
  alias SalixSignalProto.Crypto.XEdDSA
  alias SalixSignalProto.KemBackend

  @ec_type 0x05
  @kem_type 0x08
  @kem_bytes 1568
  @kem_secret_bytes 3168
  @alternate_identity_prefix :binary.copy(<<0xFF>>, 32) <> "Signal_PNI_Signature"

  @type ec_public :: <<_::264>>
  @type ec_private :: <<_::256>>
  @type kem_public :: <<_::12_552>>
  @type kem_secret :: <<_::25_352>>
  @type kem_ciphertext :: <<_::12_552>>

  # --- EC keys (CRS-03 §3) ---

  @doc "Clamps a 32-byte private key as RFC 7748 §5 does (CRS-03 §3.1)."
  @spec ec_private(<<_::256>>) :: ec_private()
  def ec_private(<<_::binary-size(32)>> = private), do: X25519.clamp(private)

  @doc "Returns the 33-byte serialized public key `0x05 || X25519(k, 9)`."
  @spec ec_public(<<_::256>>) :: ec_public()
  def ec_public(<<_::binary-size(32)>> = private), do: <<@ec_type>> <> X25519.public_key(private)

  @doc """
  Returns `%{public: ec_public, private: ec_private}` for `private` (new and
  random by default). The private key is returned clamped.
  """
  @spec ec_keypair(<<_::256>>) :: %{public: ec_public(), private: ec_private()}
  def ec_keypair(private \\ X25519.generate_private_key()) do
    %{public: ec_public(private), private: ec_private(private)}
  end

  @doc """
  Parses a serialized EC public key (CRS-03 §3.2). Bytes after byte 32 are
  accepted and dropped, as deployed peers do; the result is always 33 bytes.
  """
  @spec parse_ec_public(binary()) ::
          {:ok, ec_public()} | {:error, :empty | :unknown_type | :too_short}
  def parse_ec_public(<<@ec_type, u::binary-size(32), _trailing::binary>>),
    do: {:ok, <<@ec_type, u::binary>>}

  def parse_ec_public(<<@ec_type, _short::binary>>), do: {:error, :too_short}
  def parse_ec_public(<<>>), do: {:error, :empty}
  def parse_ec_public(bytes) when is_binary(bytes), do: {:error, :unknown_type}

  @doc """
  X25519 agreement of a private key with a serialized public key (CRS-03
  §3.3). An all-zero result fails.
  """
  @spec agree(<<_::256>>, binary()) :: {:ok, <<_::256>>} | {:error, :invalid_key}
  def agree(<<_::binary-size(32)>> = private, <<@ec_type, u::binary-size(32)>>) do
    case X25519.dh(private, u) do
      {:ok, secret} -> {:ok, secret}
      {:error, _} -> {:error, :invalid_key}
    end
  end

  def agree(<<_::binary-size(32)>>, public) when is_binary(public), do: {:error, :invalid_key}

  @doc """
  True when a serialized public key is canonical in the sense of CRS-04 §3.4:
  bit 255 of u is 0, u < 2^255 - 19, and u is a point of the prime-order
  subgroup of Curve25519 (not on the twist, no small-order component).
  Runs on public data in variable time.
  """
  @spec canonical_public?(binary()) :: boolean()
  def canonical_public?(<<@ec_type, u_bytes::binary-size(32)>>) do
    u = :binary.decode_unsigned(u_bytes, :little)
    p = Edwards25519.p()

    # u = p - 1 has no Edwards image; u = 0 has order 2.
    with true <- u < p and u != 0 and u != p - 1,
         {:ok, point} <- Edwards25519.from_y(Edwards25519.u_to_y(u), 0) do
      Edwards25519.identity?(Edwards25519.mul(Edwards25519.q(), point))
    else
      _ -> false
    end
  end

  def canonical_public?(public) when is_binary(public), do: false

  # --- Signatures (CRS-03 §4, §5) ---

  @doc """
  Verifies a deployed XEdDSA signature (CRS-03 §5.3) on `message` under the
  33-byte serialized public key. Returns false for any malformed input.
  """
  @spec verify_signature(binary(), binary(), binary()) :: boolean()
  def verify_signature(public, message, signature)
      when is_binary(public) and is_binary(message) and is_binary(signature) do
    case parse_ec_public(public) do
      {:ok, <<@ec_type, u::binary-size(32)>>} -> XEdDSA.verify(u, message, signature)
      {:error, _} -> false
    end
  end

  @doc """
  The message that an identity key signs to bind another identity key
  (CRS-03 §4): `0xFF * 32 || "Signal_PNI_Signature" || other_public`.
  """
  @spec alternate_identity_message(ec_public()) :: binary()
  def alternate_identity_message(<<@ec_type, _::binary-size(32)>> = other_public),
    do: @alternate_identity_prefix <> other_public

  @doc "Verifies an alternate-identity signature (CRS-03 §4)."
  @spec verify_alternate_identity(binary(), binary(), binary()) :: boolean()
  def verify_alternate_identity(identity_public, other_public, signature)
      when is_binary(identity_public) and is_binary(other_public) and is_binary(signature) do
    case parse_ec_public(other_public) do
      {:ok, other} ->
        verify_signature(identity_public, alternate_identity_message(other), signature)

      {:error, _} ->
        false
    end
  end

  # --- KEM keys (CRS-03 §6) ---

  @doc """
  Parses a serialized KEM public key: type `0x08` and exactly 1569 bytes
  (CRS-03 §6.1).
  """
  @spec parse_kem_public(binary()) :: {:ok, kem_public()} | {:error, atom()}
  def parse_kem_public(bytes) when is_binary(bytes), do: parse_kem(bytes, @kem_bytes)

  @doc "Parses a serialized KEM secret key: type `0x08` and exactly 3169 bytes."
  @spec parse_kem_secret(binary()) :: {:ok, kem_secret()} | {:error, atom()}
  def parse_kem_secret(bytes) when is_binary(bytes), do: parse_kem(bytes, @kem_secret_bytes)

  @doc "Parses a serialized KEM ciphertext: type `0x08` and exactly 1569 bytes."
  @spec parse_kem_ciphertext(binary()) :: {:ok, kem_ciphertext()} | {:error, atom()}
  def parse_kem_ciphertext(bytes) when is_binary(bytes), do: parse_kem(bytes, @kem_bytes)

  defp parse_kem(<<>>, _size), do: {:error, :empty}

  defp parse_kem(<<@kem_type, body::binary>> = bytes, size) do
    if byte_size(body) == size, do: {:ok, bytes}, else: {:error, :wrong_length}
  end

  defp parse_kem(_bytes, _size), do: {:error, :unknown_type}

  @doc """
  Generates a serialized KEM key pair `%{public: kem_public, secret:
  kem_secret}`. The secret arithmetic runs in constant time in OTP `:crypto`
  (`SalixSignalProto.Crypto.Kyber1024Openssl`, FIPS 203 key generation),
  which needs OpenSSL 3.5. Only tests may fall back to plain Elixir; anywhere
  else a node without that support raises
  `SalixSignalProto.KemBackend.UnsupportedError` (`SalixSignalProto.KemBackend`).
  Peers accept keys from either key generation (CRS-03 §6.2 rule 2).
  """
  @spec kem_keypair() :: %{public: kem_public(), secret: kem_secret()}
  def kem_keypair do
    {ek, dk} =
      case KemBackend.select!(:mlkem1024) do
        :openssl ->
          {:ok, pair} = Kyber1024Openssl.generate_keypair()
          pair

        :plain ->
          Kyber1024.keypair()
      end

    %{public: <<@kem_type>> <> ek, secret: <<@kem_type>> <> dk}
  end

  @doc """
  Generates a serialized KEM key pair from the seeds `d` and `z` in plain
  Elixir, for tests and seeded vectors. `keygen` is `:round3` or `:fips203`.
  """
  @spec kem_keypair_from_seed(<<_::256>>, <<_::256>>, :round3 | :fips203) ::
          %{public: kem_public(), secret: kem_secret()}
  def kem_keypair_from_seed(d, z, keygen \\ :round3) do
    {ek, dk} = Kyber1024.keypair_from_seed(d, z, keygen)
    %{public: <<@kem_type>> <> ek, secret: <<@kem_type>> <> dk}
  end

  @doc """
  Encapsulates to a serialized KEM public key with the 32-byte random input
  `m` (CRS-03 §6.2, round 3). Returns `{:ok, {shared_secret, ciphertext}}`
  with a serialized ciphertext. It runs in plain Elixir, because it takes
  injected randomness and must not run the FIPS 203 key check (CRS-03 §6.2
  rule 4).
  """
  @spec kem_encapsulate(binary(), <<_::256>>) ::
          {:ok, {<<_::256>>, kem_ciphertext()}} | {:error, :invalid_key}
  def kem_encapsulate(public, m \\ :crypto.strong_rand_bytes(32)) when is_binary(public) do
    with {:ok, <<@kem_type, ek::binary>>} <- parse_kem_public(public),
         {:ok, {secret, c}} <- Kyber1024.encapsulate(ek, m) do
      {:ok, {secret, <<@kem_type>> <> c}}
    else
      _ -> {:error, :invalid_key}
    end
  end

  @doc """
  Decapsulates a serialized KEM ciphertext with a serialized secret key. Like
  `kem_keypair/0`, it runs in OTP `:crypto`, and in plain Elixir only in
  tests; otherwise it raises `SalixSignalProto.KemBackend.UnsupportedError`.
  """
  @spec kem_decapsulate(binary(), binary()) :: {:ok, <<_::256>>} | {:error, :invalid_key}
  def kem_decapsulate(secret, ciphertext) when is_binary(secret) and is_binary(ciphertext) do
    kem =
      case KemBackend.select!(:mlkem1024) do
        :openssl -> Kyber1024Openssl
        :plain -> Kyber1024
      end

    with {:ok, <<@kem_type, dk::binary>>} <- parse_kem_secret(secret),
         {:ok, <<@kem_type, c::binary>>} <- parse_kem_ciphertext(ciphertext),
         {:ok, shared} <- kem.decapsulate(dk, c) do
      {:ok, shared}
    else
      _ -> {:error, :invalid_key}
    end
  end

  @doc "Returns the serialized public key held in a serialized KEM secret key."
  @spec kem_public_from_secret(kem_secret()) :: kem_public()
  def kem_public_from_secret(
        <<@kem_type, _dk_pke::binary-size(1536), ek::binary-size(@kem_bytes), _::binary-size(64)>>
      ),
      do: <<@kem_type>> <> ek

  # --- Identifiers (CRS-03 §8) ---

  @doc "True for a device ID the protocol accepts: 1 to 127 (CRS-03 §8)."
  @spec valid_device_id?(term()) :: boolean()
  def valid_device_id?(id), do: is_integer(id) and id >= 1 and id <= 127
end
