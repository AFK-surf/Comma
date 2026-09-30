defmodule SalixSignalProto.ContactDiscovery.Noise do
  @moduledoc """
  The Noise channel to the contact discovery enclave (CRS-11 §4.2 and §4.3).

  The protocol is `Noise_NKhfs_25519+Kyber1024_ChaChaPoly_SHA256` with an
  empty prologue and no pre-shared keys: pattern NK with the HFS modifier
  (`<- s`, `...`, `-> e, es, e1`, `<- e, ee, ekem1`). The client is the
  initiator; the responder static key comes from the verified attestation.
  The KEM is FIPS 203 ML-KEM-1024 (`SalixSignalProto.Crypto.MlKem1024`).
  Everything else follows the Noise Protocol Framework: SHA-256 hashing and
  HKDF, ChaCha20-Poly1305 with the nonce `0x00000000 || LE64(n)`, and
  `Split()` after message 2.

  With `hfs: false` the functions run the plain NK pattern
  (`Noise_NK_25519_ChaChaPoly_SHA256`). The tests use it to check the
  symmetric state against the public Noise test vectors, which have no HFS
  case.

  Randomness is an argument: the ephemeral X25519 private key, the ML-KEM
  key pair of the `e1` token, and the ML-KEM encapsulation input of the
  `ekem1` token.
  """

  alias SalixSignalProto.Crypto.{Hkdf, MlKem1024, X25519}

  @hfs_name "Noise_NKhfs_25519+Kyber1024_ChaChaPoly_SHA256"
  @nk_name "Noise_NK_25519_ChaChaPoly_SHA256"
  @dh_bytes 32
  @tag_bytes 16
  @kem_bytes 1568
  @max_message 65_535
  @max_chunk @max_message - @tag_bytes
  @max_nonce 0xFFFFFFFFFFFFFFFF

  defmodule Cipher do
    @moduledoc "A Noise cipher state: key `k` and nonce counter `n`."
    @enforce_keys [:k]
    defstruct [:k, n: 0]
    @type t :: %__MODULE__{k: <<_::256>>, n: non_neg_integer()}

    defimpl Inspect do
      def inspect(%{n: n}, _opts), do: "#SalixSignalProto.ContactDiscovery.Noise.Cipher<n=#{n}>"
    end
  end

  defmodule Transport do
    @moduledoc """
    The two cipher states after the handshake: `send` encrypts this party's
    messages, `receive` decrypts the peer's. `handshake_hash` is the final
    `h` of the handshake.
    """
    @enforce_keys [:send, :receive, :handshake_hash]
    defstruct [:send, :receive, :handshake_hash]

    @type t :: %__MODULE__{
            send: SalixSignalProto.ContactDiscovery.Noise.Cipher.t(),
            receive: SalixSignalProto.ContactDiscovery.Noise.Cipher.t(),
            handshake_hash: <<_::256>>
          }

    defimpl Inspect do
      def inspect(_transport, _opts), do: "#SalixSignalProto.ContactDiscovery.Noise.Transport<>"
    end
  end

  @typedoc false
  @opaque handshake :: map()

  @doc "The protocol name of the contact discovery channel."
  @spec protocol_name() :: String.t()
  def protocol_name, do: @hfs_name

  # --- Initiator ---------------------------------------------------------

  @doc """
  Writes handshake message 1 to the responder static key `rs` (32 bytes).

  Options: `:ephemeral` (32-byte X25519 private key, required), `:kem`
  (`{encapsulation_key, decapsulation_key}` of ML-KEM-1024, required unless
  `hfs: false`), `:hfs` (default true), `:prologue` (default empty) and
  `:payload` (default empty).

  Returns `{:ok, message, handshake}` or `{:error, :handshake_failed}` when
  a Diffie-Hellman result is invalid.
  """
  @spec initiator_write(binary(), keyword()) ::
          {:ok, binary(), handshake()} | {:error, :handshake_failed}
  def initiator_write(<<_::binary-size(@dh_bytes)>> = rs, opts) do
    hfs = Keyword.get(opts, :hfs, true)
    e_private = Keyword.fetch!(opts, :ephemeral)
    {e_public, e_private} = X25519.keypair(e_private)
    ss = initialize(hfs, Keyword.get(opts, :prologue, ""), rs)

    ss = mix_hash(ss, e_public)

    with {:ok, es} <- dh(e_private, rs) do
      ss = mix_key(ss, es)

      {kem_part, ss, kem_dk} =
        if hfs do
          {ek, dk} = Keyword.fetch!(opts, :kem)
          {ciphertext, ss} = encrypt_and_hash(ss, ek)
          {ciphertext, ss, dk}
        else
          {"", ss, nil}
        end

      {payload, ss} = encrypt_and_hash(ss, Keyword.get(opts, :payload, ""))

      {:ok, e_public <> kem_part <> payload,
       %{role: :initiator, hfs: hfs, ss: ss, e: e_private, kem_dk: kem_dk}}
    end
  end

  @doc """
  Reads handshake message 2 and splits. Returns
  `{:ok, payload, %Transport{}}` or `{:error, :handshake_failed}` when the
  message has the wrong length, does not authenticate, or gives an invalid
  Diffie-Hellman result.
  """
  @spec initiator_read(handshake(), binary()) ::
          {:ok, binary(), Transport.t()} | {:error, :handshake_failed}
  def initiator_read(%{role: :initiator} = hs, message) when is_binary(message) do
    with <<re::binary-size(@dh_bytes), rest::binary>> <- message,
         ss = mix_hash(hs.ss, re),
         {:ok, ee} <- dh(hs.e, re),
         ss = mix_key(ss, ee),
         {:ok, ss, rest} <- read_ekem1(hs, ss, rest),
         {:ok, payload, ss} <- decrypt_and_hash(ss, rest) do
      {c1, c2} = split(ss)
      {:ok, payload, %Transport{send: c1, receive: c2, handshake_hash: ss.h}}
    else
      _ -> {:error, :handshake_failed}
    end
  end

  defp read_ekem1(%{hfs: false}, ss, rest), do: {:ok, ss, rest}

  defp read_ekem1(%{hfs: true, kem_dk: dk}, ss, message) do
    with <<ciphertext::binary-size(@kem_bytes + @tag_bytes), rest::binary>> <- message,
         {:ok, kem_ciphertext, ss} <- decrypt_and_hash(ss, ciphertext),
         {:ok, shared} <- MlKem1024.decapsulate(dk, kem_ciphertext) do
      {:ok, mix_key(ss, shared), rest}
    else
      _ -> {:error, :handshake_failed}
    end
  end

  # --- Responder ---------------------------------------------------------

  @doc """
  Reads handshake message 1 with the responder static private key `s`.

  Options: `:hfs` (default true) and `:prologue` (default empty). Returns
  `{:ok, payload, handshake}` or `{:error, :handshake_failed}`.
  """
  @spec responder_read(binary(), binary(), keyword()) ::
          {:ok, binary(), handshake()} | {:error, :handshake_failed}
  def responder_read(<<_::binary-size(@dh_bytes)>> = s, message, opts \\ [])
      when is_binary(message) do
    hfs = Keyword.get(opts, :hfs, true)
    s_public = X25519.public_key(s)
    ss = initialize(hfs, Keyword.get(opts, :prologue, ""), s_public)

    with <<re::binary-size(@dh_bytes), rest::binary>> <- message,
         ss = mix_hash(ss, re),
         {:ok, es} <- dh(s, re),
         ss = mix_key(ss, es),
         {:ok, kem_ek, ss, rest} <- read_e1(hfs, ss, rest),
         {:ok, payload, ss} <- decrypt_and_hash(ss, rest) do
      {:ok, payload, %{role: :responder, hfs: hfs, ss: ss, re: re, kem_ek: kem_ek}}
    else
      _ -> {:error, :handshake_failed}
    end
  end

  defp read_e1(false, ss, rest), do: {:ok, nil, ss, rest}

  defp read_e1(true, ss, message) do
    case message do
      <<ciphertext::binary-size(@kem_bytes + @tag_bytes), rest::binary>> ->
        with {:ok, ek, ss} <- decrypt_and_hash(ss, ciphertext), do: {:ok, ek, ss, rest}

      _ ->
        {:error, :handshake_failed}
    end
  end

  @doc """
  Writes handshake message 2 and splits.

  Options: `:ephemeral` (32-byte X25519 private key, required),
  `:kem_randomness` (32 bytes for the ML-KEM encapsulation, required unless
  `hfs: false`) and `:payload` (default empty). Returns
  `{:ok, message, %Transport{}}` or `{:error, :handshake_failed}`.
  """
  @spec responder_write(handshake(), keyword()) ::
          {:ok, binary(), Transport.t()} | {:error, :handshake_failed}
  def responder_write(%{role: :responder} = hs, opts) do
    {e_public, e_private} = X25519.keypair(Keyword.fetch!(opts, :ephemeral))
    ss = mix_hash(hs.ss, e_public)

    with {:ok, ee} <- dh(e_private, hs.re),
         ss = mix_key(ss, ee),
         {:ok, kem_part, ss} <- write_ekem1(hs, ss, opts) do
      {payload, ss} = encrypt_and_hash(ss, Keyword.get(opts, :payload, ""))
      {c1, c2} = split(ss)

      {:ok, e_public <> kem_part <> payload,
       %Transport{send: c2, receive: c1, handshake_hash: ss.h}}
    end
  end

  defp write_ekem1(%{hfs: false}, ss, _opts), do: {:ok, "", ss}

  defp write_ekem1(%{hfs: true, kem_ek: ek}, ss, opts) do
    case MlKem1024.encapsulate(ek, Keyword.fetch!(opts, :kem_randomness)) do
      {:ok, {shared, kem_ciphertext}} ->
        {ciphertext, ss} = encrypt_and_hash(ss, kem_ciphertext)
        {:ok, ciphertext, mix_key(ss, shared)}

      {:error, _} ->
        {:error, :handshake_failed}
    end
  end

  # --- Transport ---------------------------------------------------------

  @doc """
  Encrypts one application message for a WebSocket binary message (CRS-11
  §4.3): chunks of at most 65,519 bytes, each one Noise transport message
  with its own nonce, concatenated. An empty message is one empty chunk.
  """
  @spec seal(Transport.t(), binary()) ::
          {:ok, binary(), Transport.t()} | {:error, :nonce_exhausted}
  def seal(%Transport{send: cipher} = transport, plaintext) when is_binary(plaintext) do
    plaintext
    |> chunks(@max_chunk)
    |> Enum.reduce_while({:ok, [], cipher}, fn chunk, {:ok, acc, cipher} ->
      case encrypt(cipher, "", chunk) do
        {:ok, ciphertext, cipher} -> {:cont, {:ok, [acc, ciphertext], cipher}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, iodata, cipher} -> {:ok, IO.iodata_to_binary(iodata), %{transport | send: cipher}}
      error -> error
    end
  end

  @doc """
  Decrypts one WebSocket binary message: pieces of 65,535 bytes (the last
  may be shorter), each one Noise transport message, decrypted in order and
  concatenated. Returns `{:error, :decrypt_failed}` when a piece does not
  authenticate or is shorter than a tag.
  """
  @spec open(Transport.t(), binary()) ::
          {:ok, binary(), Transport.t()} | {:error, :decrypt_failed | :nonce_exhausted}
  def open(%Transport{receive: cipher} = transport, payload) when is_binary(payload) do
    payload
    |> chunks(@max_message)
    |> Enum.reduce_while({:ok, [], cipher}, fn piece, {:ok, acc, cipher} ->
      case decrypt(cipher, "", piece) do
        {:ok, plaintext, cipher} -> {:cont, {:ok, [acc, plaintext], cipher}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, iodata, cipher} -> {:ok, IO.iodata_to_binary(iodata), %{transport | receive: cipher}}
      error -> error
    end
  end

  @doc """
  Encrypts one Noise transport message (at most 65,519 bytes of plaintext).
  """
  @spec encrypt_transport(Transport.t(), binary()) ::
          {:ok, binary(), Transport.t()} | {:error, :nonce_exhausted | :too_long}
  def encrypt_transport(%Transport{send: cipher} = transport, plaintext)
      when byte_size(plaintext) <= @max_chunk do
    with {:ok, ciphertext, cipher} <- encrypt(cipher, "", plaintext),
         do: {:ok, ciphertext, %{transport | send: cipher}}
  end

  def encrypt_transport(%Transport{}, _plaintext), do: {:error, :too_long}

  @doc "Decrypts one Noise transport message."
  @spec decrypt_transport(Transport.t(), binary()) ::
          {:ok, binary(), Transport.t()} | {:error, :decrypt_failed | :nonce_exhausted}
  def decrypt_transport(%Transport{receive: cipher} = transport, ciphertext) do
    with {:ok, plaintext, cipher} <- decrypt(cipher, "", ciphertext),
         do: {:ok, plaintext, %{transport | receive: cipher}}
  end

  defp chunks("", _size), do: [""]
  defp chunks(bytes, size), do: do_chunks(bytes, size, [])

  defp do_chunks(<<>>, _size, acc), do: Enum.reverse(acc)

  defp do_chunks(bytes, size, acc) when byte_size(bytes) <= size,
    do: Enum.reverse([bytes | acc])

  defp do_chunks(bytes, size, acc) do
    <<chunk::binary-size(^size), rest::binary>> = bytes
    do_chunks(rest, size, [chunk | acc])
  end

  # --- Symmetric state (Noise Protocol Framework §5.2) --------------------

  defp initialize(hfs, prologue, responder_static) do
    name = if hfs, do: @hfs_name, else: @nk_name

    h =
      if byte_size(name) <= 32,
        do: name <> :binary.copy(<<0>>, 32 - byte_size(name)),
        else: :crypto.hash(:sha256, name)

    %{ck: h, h: h, cipher: nil}
    |> mix_hash(prologue)
    # Pre-message pattern `<- s`.
    |> mix_hash(responder_static)
  end

  defp mix_hash(ss, data), do: %{ss | h: :crypto.hash(:sha256, [ss.h, data])}

  defp mix_key(ss, ikm) do
    <<ck::binary-size(32), k::binary-size(32)>> = Hkdf.derive(ikm, ss.ck, "", 64)
    %{ss | ck: ck, cipher: %Cipher{k: k}}
  end

  defp encrypt_and_hash(%{cipher: nil} = ss, plaintext), do: {plaintext, mix_hash(ss, plaintext)}

  defp encrypt_and_hash(ss, plaintext) do
    # A handshake nonce never approaches the limit.
    {:ok, ciphertext, cipher} = encrypt(ss.cipher, ss.h, plaintext)
    {ciphertext, mix_hash(%{ss | cipher: cipher}, ciphertext)}
  end

  defp decrypt_and_hash(%{cipher: nil} = ss, ciphertext),
    do: {:ok, ciphertext, mix_hash(ss, ciphertext)}

  defp decrypt_and_hash(ss, ciphertext) do
    with {:ok, plaintext, cipher} <- decrypt(ss.cipher, ss.h, ciphertext),
         do: {:ok, plaintext, mix_hash(%{ss | cipher: cipher}, ciphertext)}
  end

  defp split(ss) do
    <<k1::binary-size(32), k2::binary-size(32)>> = Hkdf.derive("", ss.ck, "", 64)
    {%Cipher{k: k1}, %Cipher{k: k2}}
  end

  defp dh(private, public) do
    case X25519.dh(private, public) do
      {:ok, shared} -> {:ok, shared}
      {:error, _} -> {:error, :handshake_failed}
    end
  end

  # --- Cipher state (ChaChaPoly) ------------------------------------------

  defp encrypt(%Cipher{n: n}, _ad, _plaintext) when n >= @max_nonce,
    do: {:error, :nonce_exhausted}

  defp encrypt(%Cipher{k: k, n: n} = cipher, ad, plaintext) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, k, nonce(n), plaintext, ad, true)

    {:ok, ciphertext <> tag, %{cipher | n: n + 1}}
  end

  defp decrypt(%Cipher{n: n}, _ad, _ciphertext) when n >= @max_nonce,
    do: {:error, :nonce_exhausted}

  defp decrypt(%Cipher{k: k, n: n} = cipher, ad, ciphertext)
       when byte_size(ciphertext) >= @tag_bytes do
    body_size = byte_size(ciphertext) - @tag_bytes
    <<body::binary-size(^body_size), tag::binary-size(@tag_bytes)>> = ciphertext

    case :crypto.crypto_one_time_aead(:chacha20_poly1305, k, nonce(n), body, ad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext, %{cipher | n: n + 1}}
      :error -> {:error, :decrypt_failed}
    end
  end

  defp decrypt(%Cipher{}, _ad, _ciphertext), do: {:error, :decrypt_failed}

  defp nonce(n), do: <<0::32, n::little-64>>
end
