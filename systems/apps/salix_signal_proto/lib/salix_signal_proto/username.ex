defmodule SalixSignalProto.Username do
  @moduledoc """
  Usernames (CRS-02 §10): syntax, the 32-byte username hash, the proof that
  confirms a reserved hash, and the encrypted username link.

  A username is `nickname.discriminator`. The service stores only the hash
  and checks the proof at confirmation. Hashing folds the nickname to
  lowercase; the displayed username keeps the case.

  ## Hash (CRS-02 §10.2)

  With the lowercase nickname bytes `n` and the discriminator `d`:

    * `s1 = SHA512(n || 0x00 || BE(d, 8))` as a 512-bit little-endian integer mod ℓ;
    * `s2 = v0 + 27 × Σ_{i≥1} v_i × 37^(i-1)` mod ℓ, where `_` is 1, `a`-`z`
      are 2-27 and `0`-`9` are 28-37;
    * `s3 = d` mod ℓ;
    * hash = `enc(s1·G1 + s2·G2 + s3·G3)` in the ristretto255 group (RFC 9496).

  ## Proof (CRS-02 §10.4)

  A 128-byte Schnorr-style proof of knowledge of `s1, s2, s3`, with the
  challenge and nonces taken from the keyed hash state of CRS-02 §10.3. That
  state is the same construction as `SalixSignalProto.Group.Sho` (SHO-HMAC).

  Point and scalar arithmetic runs in the libsodium NIF
  (`SalixSignalProto.Crypto.Ristretto255`). Parsing a username and computing
  `s2` run in Elixir in variable time; they depend only on the username.
  """

  import Bitwise

  alias SalixSignalProto.Crypto.{AesCbc, Hkdf, Hmac, Ristretto255}
  alias SalixSignalProto.Group.Sho

  defmodule LinkPlaintext do
    @moduledoc false
    # Username link plaintext (CRS-02 §10.6 item 3), proto3.
    use Protobuf, syntax: :proto3

    field(:username, 1, type: :string)
    field(:padding, 2, type: :bytes)
  end

  @l 7_237_005_577_332_262_213_973_186_563_042_994_240_857_116_359_379_907_606_001_950_938_285_454_250_989

  @g1 Base.decode16!("60b993663a3daecc4c852f533547e305388c2a50a58393ea277de4abf3de543a",
        case: :lower
      )
  @g2 Base.decode16!("f2b6f1c826fa3640206f3b58b2286bdefdfda6a54ff902f204a72de737d26157",
        case: :lower
      )
  @g3 Base.decode16!("0606bd3abfce4e9617d448fb2caeb6cc028ec9a2b62b10b3d9eb2948da6f3f53",
        case: :lower
      )

  @statement Base.decode16!("010103000201030204", case: :lower)
  @proof_label "POKSHO_Ristretto_SHOHMACSHA256"

  @hash_max_nickname 48
  @max_discriminator (1 <<< 64) - 1

  @link_encryption_info "Signal Username Link Encryption Key"
  @link_authentication_info "Signal Username Link Authentication Key"
  @link_padded_length 48
  @link_max_plaintext 63
  @link_url_prefix "signal.me/#eu/"

  @typedoc """
  Why a username or its parts are rejected. Each value names the CRS-02 rule
  that the input breaks: rule 0 is the `nickname.discriminator` form (§10),
  rules 1, 3 and 4 are those of §10.1, and the letter orders the clauses of
  the rule's text. The oracle interface uses the same codes.

    * `:username_rule_0` - no `.` separator
    * `:username_rule_1a` - a nickname character outside `a-z`, `A-Z`, `0-9`, `_`
    * `:username_rule_1b` - the nickname starts with a digit
    * `:username_rule_1c` - the nickname is empty
    * `:username_rule_3a` - the nickname is shorter than the minimum
    * `:username_rule_3b` - the nickname is longer than the maximum
    * `:username_rule_4a` - a discriminator character that is not a digit
    * `:username_rule_4b` - the discriminator value is zero
    * `:username_rule_4c` - the discriminator value is above 2^64 - 1
    * `:username_rule_4d` - the discriminator is empty
    * `:username_rule_4e` - the discriminator has one digit
    * `:username_rule_4f` - a discriminator of 3 or more digits starts with `0`
  """
  @type syntax_error ::
          :username_rule_0
          | :username_rule_1a
          | :username_rule_1b
          | :username_rule_1c
          | :username_rule_3a
          | :username_rule_3b
          | :username_rule_4a
          | :username_rule_4b
          | :username_rule_4c
          | :username_rule_4d
          | :username_rule_4e
          | :username_rule_4f

  @type hash :: <<_::256>>
  @type proof :: <<_::1024>>

  # --- Syntax (CRS-02 §10.1) ---

  @doc """
  Splits a username at its first `.` and checks both parts. The nickname may
  have 1 to 48 characters here, the limit of the hash function.
  """
  @spec parse(String.t()) ::
          {:ok, %{nickname: String.t(), discriminator: pos_integer()}} | {:error, syntax_error()}
  def parse(username) when is_binary(username) do
    case :binary.split(username, ".") do
      [nickname, discriminator] ->
        with {:ok, d} <- check_discriminator(discriminator),
             :ok <- check_nickname(nickname, 1, @hash_max_nickname) do
          {:ok, %{nickname: nickname, discriminator: d}}
        end

      [_no_separator] ->
        {:error, :username_rule_0}
    end
  end

  @doc """
  Builds `nickname.discriminator` with the nickname length limits of the
  caller. First-party clients use 3 to 32 (CRS-02 §10.1 item 3).
  """
  @spec from_parts(String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, syntax_error()}
  def from_parts(nickname, discriminator, min_length \\ 3, max_length \\ 32)
      when is_binary(nickname) and is_binary(discriminator) do
    with :ok <- check_nickname(nickname, min_length, min(max_length, @hash_max_nickname)),
         {:ok, _d} <- check_discriminator(discriminator) do
      {:ok, nickname <> "." <> discriminator}
    end
  end

  defp check_nickname("", _min, _max), do: {:error, :username_rule_1c}

  defp check_nickname(<<first, _::binary>>, _min, _max) when first in ?0..?9,
    do: {:error, :username_rule_1b}

  defp check_nickname(nickname, min, max) do
    cond do
      not nickname_characters?(nickname) -> {:error, :username_rule_1a}
      byte_size(nickname) < min -> {:error, :username_rule_3a}
      byte_size(nickname) > max -> {:error, :username_rule_3b}
      true -> :ok
    end
  end

  defp nickname_characters?(nickname) do
    for(<<c <- nickname>>, not (c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_), do: c) ==
      []
  end

  defp check_discriminator(""), do: {:error, :username_rule_4d}

  defp check_discriminator(discriminator) do
    cond do
      for(<<c <- discriminator>>, c not in ?0..?9, do: c) != [] ->
        {:error, :username_rule_4a}

      String.to_integer(discriminator) == 0 ->
        {:error, :username_rule_4b}

      byte_size(discriminator) == 1 ->
        {:error, :username_rule_4e}

      byte_size(discriminator) > 2 and binary_part(discriminator, 0, 1) == "0" ->
        {:error, :username_rule_4f}

      String.to_integer(discriminator) > @max_discriminator ->
        {:error, :username_rule_4c}

      true ->
        {:ok, String.to_integer(discriminator)}
    end
  end

  # --- Hash (CRS-02 §10.2) ---

  @doc "The 32-byte username hash."
  @spec hash(String.t()) :: {:ok, hash()} | {:error, syntax_error()}
  def hash(username) do
    with {:ok, parts} <- parse(username) do
      {:ok, parts |> scalars() |> commit()}
    end
  end

  defp scalars(%{nickname: nickname, discriminator: d}) do
    n = String.downcase(nickname, :ascii)
    s1 = Ristretto255.scalar_from_wide_bytes(:crypto.hash(:sha512, [n, 0, <<d::64>>]))
    {s1, scalar(character_sum(n)), scalar(d)}
  end

  defp character_sum(<<first, rest::binary>>) do
    {sum, _power} =
      for <<c <- rest>>, reduce: {0, 1} do
        {sum, power} -> {sum + character_value(c) * power, power * 37}
      end

    character_value(first) + 27 * sum
  end

  defp character_value(?_), do: 1
  defp character_value(c) when c in ?a..?z, do: c - ?a + 2
  defp character_value(c) when c in ?0..?9, do: c - ?0 + 28

  defp scalar(integer), do: <<rem(integer, @l)::little-size(256)>>

  defp commit({x1, x2, x3}) do
    Ristretto255.mul(x1, @g1)
    |> Ristretto255.add(Ristretto255.mul(x2, @g2))
    |> Ristretto255.add(Ristretto255.mul(x3, @g3))
  end

  # --- Proof (CRS-02 §10.4) ---

  @doc """
  The 128-byte proof for `username` with 32 bytes of randomness. The
  randomness changes the proof bytes, never its validity; pass fresh random
  bytes (the default).
  """
  @spec proof(String.t(), <<_::256>>) :: {:ok, proof()} | {:error, syntax_error()}
  def proof(username, randomness \\ :crypto.strong_rand_bytes(32))

  def proof(username, <<_::binary-size(32)>> = randomness) do
    with {:ok, parts} <- parse(username) do
      {s1, s2, s3} = secrets = scalars(parts)
      h = commit(secrets)
      t0 = transcript(h)

      {nonces, _state} =
        t0
        |> Sho.absorb(randomness)
        |> Sho.absorb([s1, s2, s3])
        |> Sho.ratchet()
        |> Sho.absorb(h)
        |> Sho.ratchet()
        |> Sho.squeeze(192)

      [k1, k2, k3] =
        for <<wide::binary-size(64) <- nonces>>, do: Ristretto255.scalar_from_wide_bytes(wide)

      c = challenge(t0, commit({k1, k2, k3}), h)

      responses =
        for {k, s} <- [{k1, s1}, {k2, s2}, {k3, s3}],
            do: Ristretto255.scalar_add(k, Ristretto255.scalar_mul(c, s))

      {:ok, IO.iodata_to_binary([c | responses])}
    end
  end

  @doc "Verifies a proof against a 32-byte username hash."
  @spec verify_proof(binary(), binary()) :: boolean()
  def verify_proof(proof, hash) when is_binary(proof) and is_binary(hash) do
    with <<c::binary-size(32), r1::binary-size(32), r2::binary-size(32), r3::binary-size(32)>> <-
           proof,
         true <- Enum.all?([c, r1, r2, r3], &match?({:ok, _}, Ristretto255.decode_scalar(&1))),
         {:ok, h} <- Ristretto255.decode(hash) do
      commitment = Ristretto255.sub(commit({r1, r2, r3}), Ristretto255.mul(c, h))
      Hmac.equal?(challenge(transcript(h), commitment, h), c)
    else
      _ -> false
    end
  end

  defp transcript(h) do
    points = [Ristretto255.generator(), h, @g1, @g2, @g3]

    @proof_label
    |> Sho.new()
    |> Sho.absorb(@statement)
    |> Sho.absorb(points)
    |> Sho.ratchet()
  end

  defp challenge(t0, commitment, message) do
    {bytes, _state} =
      t0 |> Sho.absorb(commitment) |> Sho.absorb(message) |> Sho.ratchet() |> Sho.squeeze(64)

    Ristretto255.scalar_from_wide_bytes(bytes)
  end

  # --- Username link (CRS-02 §10.6) ---

  @doc """
  Encrypts `username` for a username link with the 32-byte link entropy and
  a 16-byte IV (random by default). The result is `IV || ciphertext || MAC`,
  112 bytes for usernames of up to 48 bytes.
  """
  @spec encrypt_link(String.t(), <<_::256>>, <<_::128>>) ::
          {:ok, binary()} | {:error, syntax_error() | :too_long}
  def encrypt_link(username, entropy, iv \\ :crypto.strong_rand_bytes(16))

  def encrypt_link(username, <<_::binary-size(32)>> = entropy, <<_::binary-size(16)>> = iv) do
    padding = :binary.copy(<<0>>, max(0, @link_padded_length - byte_size(username)))
    plaintext = LinkPlaintext.encode(%LinkPlaintext{username: username, padding: padding})

    with {:ok, _parts} <- parse(username) do
      if byte_size(plaintext) > @link_max_plaintext do
        {:error, :too_long}
      else
        {encryption_key, mac_key} = link_keys(entropy)
        body = iv <> AesCbc.encrypt(encryption_key, iv, plaintext)
        {:ok, body <> Hmac.sha256(mac_key, body)}
      end
    end
  end

  @doc """
  Decrypts a username link value. A value of 48 bytes or less, or one whose
  MAC does not verify, is rejected before decryption.
  """
  @spec decrypt_link(<<_::256>>, binary()) :: {:ok, String.t()} | {:error, :invalid}
  def decrypt_link(<<_::binary-size(32)>> = entropy, value) when is_binary(value) do
    body_size = byte_size(value) - 32

    with true <- byte_size(value) > 48,
         <<body::binary-size(^body_size), mac::binary-size(32)>> <- value,
         {encryption_key, mac_key} = link_keys(entropy),
         true <- Hmac.equal?(Hmac.sha256(mac_key, body), mac),
         <<iv::binary-size(16), ciphertext::binary>> <- body,
         {:ok, plaintext} <- AesCbc.decrypt(encryption_key, iv, ciphertext),
         {:ok, %LinkPlaintext{username: username}} <- decode_plaintext(plaintext),
         true <- String.valid?(username) do
      {:ok, username}
    else
      _ -> {:error, :invalid}
    end
  end

  defp decode_plaintext(plaintext) do
    {:ok, LinkPlaintext.decode(plaintext)}
  rescue
    _ -> :error
  end

  defp link_keys(entropy) do
    {Hkdf.derive(entropy, "", @link_encryption_info, 32),
     Hkdf.derive(entropy, "", @link_authentication_info, 32)}
  end

  @doc """
  The shareable link: `https://signal.me/#eu/` and base64url without padding
  of the entropy (32 bytes) and the link handle (16 UUID bytes).
  """
  @spec link_url(<<_::256>>, <<_::128>>) :: String.t()
  def link_url(<<_::binary-size(32)>> = entropy, <<_::binary-size(16)>> = handle),
    do: "https://" <> @link_url_prefix <> Base.url_encode64(entropy <> handle, padding: false)

  @doc "Parses a link, with or without `https://`, into `{entropy, handle}`."
  @spec parse_link_url(String.t()) :: {:ok, {<<_::256>>, <<_::128>>}} | :error
  def parse_link_url("https://" <> rest), do: parse_link_url(rest)

  def parse_link_url(@link_url_prefix <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, <<entropy::binary-size(32), handle::binary-size(16)>>} -> {:ok, {entropy, handle}}
      _ -> :error
    end
  end

  def parse_link_url(_url), do: :error
end
