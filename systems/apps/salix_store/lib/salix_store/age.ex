defmodule SalixStore.Age do
  @moduledoc """
  The age v1 file format (https://age-encryption.org/v1), X25519 recipients only.

  Output of `encrypt/2` is a byte-for-byte valid age file: `age -d -i key.txt`
  opens it, and so does any other age implementation. That compatibility is the
  point — the archive's read path is a tool the team already has and can audit,
  not a bespoke decryptor that ships only with this repo.

  ## Format

      age-encryption.org/v1
      -> X25519 <base64 ephemeral share>
      <base64 wrapped file key>
      --- <base64 header HMAC>
      <16-byte nonce><STREAM chunks>

  A random 16-byte *file key* encrypts the payload; one stanza per recipient
  wraps that file key to a recipient's X25519 public key. Adding a recipient
  adds a stanza — it never re-encrypts the payload, which is what makes key
  rotation cheap for the event archive.

  All base64 here is the standard alphabet, UNPADDED. The header MAC covers
  every byte from `age-encryption.org/v1` through the literal `---`, so a
  stanza cannot be added, dropped, or edited without detection.

  ## Decryption

  `decrypt/2` exists for tests and the `mix salix.archive.open` tooling. No
  runtime path calls it, and none could usefully: no archive recipient's
  private key is ever configured in the cluster — see
  `SalixAnalytics.EventArchive.Recipients`. There is no boot self-check that
  round-trips a payload; boot only validates the PUBLIC keys and logs their
  fingerprints.
  """

  alias SalixStore.Age.Bech32

  @version_line "age-encryption.org/v1\n"
  @x25519_info "age-encryption.org/v1/X25519"
  @recipient_hrp "age"
  @identity_hrp "age-secret-key-"

  # age fixes both of these; they are not tunable.
  @file_key_bytes 16
  @chunk_bytes 65_536
  @payload_nonce_bytes 16

  @type recipient :: <<_::256>>
  @type identity :: <<_::256>>

  # ---------------------------------------------------------------- keys ----

  @doc """
  Parse an `age1…` recipient string into its 32-byte X25519 public key.

  Rejects the all-zero key here, but that is only the cheapest of nine
  degenerate inputs — the rest are caught at `shared_secret/2`, because
  `:crypto.compute_key/4` raises on them rather than returning a detectable
  all-zero secret.
  """
  @spec parse_recipient(String.t()) :: {:ok, recipient()} | {:error, atom()}
  def parse_recipient(string) when is_binary(string) do
    case Bech32.decode(String.trim(string)) do
      {:ok, @recipient_hrp, <<key::binary-size(32)>>} -> validate_public_key(key)
      {:ok, @recipient_hrp, _} -> {:error, :bad_recipient_length}
      {:ok, _other_hrp, _} -> {:error, :not_a_recipient}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Parse an `AGE-SECRET-KEY-1…` identity string into its 32-byte scalar."
  @spec parse_identity(String.t()) :: {:ok, identity()} | {:error, atom()}
  def parse_identity(string) when is_binary(string) do
    case Bech32.decode(String.trim(string)) do
      {:ok, @identity_hrp, <<key::binary-size(32)>>} -> {:ok, key}
      {:ok, @identity_hrp, _} -> {:error, :bad_identity_length}
      {:ok, _other_hrp, _} -> {:error, :not_an_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Render a 32-byte X25519 public key as an `age1…` recipient string."
  @spec encode_recipient(recipient()) :: {:ok, String.t()} | {:error, atom()}
  def encode_recipient(<<key::binary-size(32)>>), do: Bech32.encode(@recipient_hrp, key)
  def encode_recipient(_), do: {:error, :bad_recipient_length}

  @doc """
  Generate an X25519 keypair as `{recipient_string, identity_string}`.

  Used by tests. Never call this to mint an archive recipient — the private
  half must be generated outside the cluster.
  """
  @spec generate_keypair() :: {String.t(), String.t()}
  def generate_keypair do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    {:ok, recipient} = Bech32.encode(@recipient_hrp, public)
    {:ok, identity} = Bech32.encode(@identity_hrp, private)
    {recipient, String.upcase(identity)}
  end

  defp validate_public_key(key) do
    if :crypto.hash_equals(key, <<0::256>>), do: {:error, :zero_public_key}, else: {:ok, key}
  end

  # ------------------------------------------------------------- encrypt ----

  @doc """
  Encrypt `plaintext` to one or more 32-byte X25519 recipient keys.

  Returns the complete age file. Recipients must be raw 32-byte keys — use
  `parse_recipient/1` on the `age1…` string first, at config-load time rather
  than per item.
  """
  @spec encrypt(iodata(), [recipient(), ...]) :: {:ok, binary()} | {:error, atom()}
  def encrypt(_plaintext, []), do: {:error, :no_recipients}

  def encrypt(plaintext, recipients) when is_list(recipients) do
    file_key = :crypto.strong_rand_bytes(@file_key_bytes)

    case wrap_all(file_key, recipients) do
      {:ok, stanzas} ->
        header = header(stanzas, file_key)
        nonce = :crypto.strong_rand_bytes(@payload_nonce_bytes)
        stream_key = hkdf(file_key, nonce, "payload", 32)
        body = encrypt_stream(IO.iodata_to_binary(plaintext), stream_key)
        {:ok, IO.iodata_to_binary([header, nonce, body])}

      {:error, _} = error ->
        error
    end
  end

  defp wrap_all(file_key, recipients) do
    Enum.reduce_while(recipients, {:ok, []}, fn recipient, {:ok, acc} ->
      case wrap(file_key, recipient) do
        {:ok, stanza} -> {:cont, {:ok, [stanza | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp wrap(file_key, <<recipient::binary-size(32)>>) do
    {ephemeral_public, ephemeral_secret} = :crypto.generate_key(:ecdh, :x25519)

    case shared_secret(recipient, ephemeral_secret) do
      :error ->
        {:error, :degenerate_shared_secret}

      {:ok, shared} ->
        salt = ephemeral_public <> recipient
        wrap_key = hkdf(shared, salt, @x25519_info, 32)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(
            :chacha20_poly1305,
            wrap_key,
            <<0::96>>,
            file_key,
            "",
            true
          )

        {:ok,
         [
           "-> X25519 ",
           b64(ephemeral_public),
           "\n",
           wrap_columns(ciphertext <> tag),
           "\n"
         ]}
    end
  end

  defp wrap(_file_key, _), do: {:error, :bad_recipient_length}

  @doc false
  # X25519 against a low-order or otherwise degenerate point produces a shared
  # secret an attacker knows. `:crypto.compute_key/4` RAISES on those rather
  # than returning the all-zero secret an equality check would catch — so the
  # zero check alone never fired, and a single bad recipient in operator config
  # crashed the archive's WRITE path.
  def shared_secret(peer_public, own_secret) do
    shared = :crypto.compute_key(:ecdh, peer_public, own_secret, :x25519)
    if :crypto.hash_equals(shared, <<0::256>>), do: :error, else: {:ok, shared}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp header(stanzas, file_key) do
    without_mac = IO.iodata_to_binary([@version_line, stanzas, "---"])
    mac = :crypto.mac(:hmac, :sha256, hkdf(file_key, "", "header", 32), without_mac)
    [without_mac, " ", b64(mac), "\n"]
  end

  # ------------------------------------------------------------- decrypt ----

  @doc """
  Decrypt an age file with a 32-byte X25519 identity scalar.

  Every stanza is tried; the first that unwraps wins. The header MAC is
  verified before any payload byte is touched, so a tampered header fails
  closed rather than yielding a partial read.
  """
  @spec decrypt(binary(), identity()) :: {:ok, binary()} | {:error, atom()}
  def decrypt(file, <<identity::binary-size(32)>>) when is_binary(file) do
    with {:ok, stanzas, mac, rest} <- parse_header(file),
         {:ok, file_key} <- unwrap_any(stanzas, identity),
         :ok <- verify_header_mac(file, mac, file_key, rest),
         <<nonce::binary-size(@payload_nonce_bytes), body::binary>> <- rest do
      decrypt_stream(body, hkdf(file_key, nonce, "payload", 32))
    else
      {:error, _} = error -> error
      _ -> {:error, :truncated_payload}
    end
  end

  def decrypt(_file, _identity), do: {:error, :bad_identity_length}

  # A real age header is a few hundred bytes per recipient. Bounding it stops a
  # hostile file from making the parser accumulate (and re-encode, for the
  # canonical-base64 check) an unbounded stanza body before anything is
  # authenticated.
  @max_stanza_body_lines 4096
  @max_stanzas 64

  defp parse_header(@version_line <> rest), do: parse_stanzas(rest, [])
  defp parse_header(_), do: {:error, :bad_version_line}

  defp parse_stanzas("-> " <> _rest, acc) when length(acc) >= @max_stanzas,
    do: {:error, :too_many_stanzas}

  defp parse_stanzas("-> " <> rest, acc) do
    with [args_line, rest] <- :binary.split(rest, "\n"),
         {:ok, body, rest} <- take_stanza_body(rest, []) do
      parse_stanzas(rest, [{String.split(args_line, " "), body} | acc])
    else
      {:error, _} = error -> error
      _ -> {:error, :malformed_stanza}
    end
  end

  defp parse_stanzas("--- " <> rest, acc) do
    case :binary.split(rest, "\n") do
      [mac_b64, payload] ->
        case unb64(mac_b64) do
          {:ok, mac} -> {:ok, Enum.reverse(acc), mac, payload}
          :error -> {:error, :bad_header_mac_encoding}
        end

      _ ->
        {:error, :missing_header_mac}
    end
  end

  defp parse_stanzas(_, _), do: {:error, :malformed_header}

  # A stanza body is base64 wrapped at 64 columns, terminated by the first
  # line SHORTER than 64 characters — which may be an empty line when the
  # body length is an exact multiple of 48 bytes.
  defp take_stanza_body(_rest, acc) when length(acc) >= @max_stanza_body_lines,
    do: {:error, :stanza_body_too_long}

  defp take_stanza_body(rest, acc) do
    case :binary.split(rest, "\n") do
      [line, tail] when byte_size(line) < 64 ->
        case unb64(Enum.reverse([line | acc]) |> Enum.join()) do
          {:ok, body} -> {:ok, body, tail}
          :error -> {:error, :bad_stanza_encoding}
        end

      [line, tail] when byte_size(line) == 64 ->
        take_stanza_body(tail, [line | acc])

      _ ->
        {:error, :malformed_stanza_body}
    end
  end

  defp unwrap_any(stanzas, identity) do
    stanzas
    |> Enum.reduce_while({:error, :no_matching_recipient}, fn stanza, acc ->
      case unwrap(stanza, identity) do
        {:ok, _} = ok -> {:halt, ok}
        # A structurally broken X25519 block fails the whole file.
        {:error, :malformed_x25519_stanza} = error -> {:halt, error}
        {:error, _} -> {:cont, acc}
      end
    end)
  end

  defp unwrap({["X25519", share_b64], body}, identity) when byte_size(body) == 32 do
    # Two failure classes, deliberately distinct:
    #   * STRUCTURAL (bad base64, wrong share length, degenerate point) — the
    #     file is broken, and skipping it would hide corruption behind "no
    #     matching recipient". age errors on these too.
    #   * AEAD tag mismatch — this stanza simply is not for us, which is the
    #     normal multi-recipient case; try the next one.
    with {:ok, <<share::binary-size(32)>>} <- unb64_ok(share_b64),
         {public, _} = :crypto.generate_key(:ecdh, :x25519, identity),
         {:ok, shared} <- shared_secret(share, identity) do
      wrap_key = hkdf(shared, share <> public, @x25519_info, 32)
      <<ciphertext::binary-size(16), tag::binary-size(16)>> = body

      case :crypto.crypto_one_time_aead(
             :chacha20_poly1305,
             wrap_key,
             <<0::96>>,
             ciphertext,
             "",
             tag,
             false
           ) do
        file_key when is_binary(file_key) -> {:ok, file_key}
        _ -> {:error, :unwrap_failed}
      end
    else
      _ -> {:error, :malformed_x25519_stanza}
    end
  end

  # A malformed X25519 stanza is an error, not an unknown recipient type. Only
  # genuinely UNKNOWN stanza types may be skipped (age does the same), because
  # skipping a broken X25519 block hides corruption behind "no matching
  # recipient".
  defp unwrap({["X25519" | _], _body}, _identity), do: {:error, :malformed_x25519_stanza}
  defp unwrap(_stanza, _identity), do: {:error, :unsupported_stanza}

  # The MAC boundary is derived from what the parser ALREADY consumed, not by
  # rescanning the file for the first "\n--- ". Rescanning parsed
  # security-critical attacker bytes twice under two different rules; no split
  # between them was reachable, but deriving it once removes the class.
  defp verify_header_mac(file, mac, file_key, payload) do
    without_mac = binary_part(file, 0, byte_size(file) - byte_size(payload) - mac_suffix(mac))
    expected = :crypto.mac(:hmac, :sha256, hkdf(file_key, "", "header", 32), without_mac)
    if constant_time_equal?(mac, expected), do: :ok, else: {:error, :header_mac_mismatch}
  end

  # " " + base64(mac) + "\n" follows the literal "---".
  defp mac_suffix(mac), do: 1 + byte_size(b64(mac)) + 1

  # -------------------------------------------------------------- STREAM ----

  # age's STREAM: 64 KiB plaintext chunks, each sealed with a 12-byte nonce of
  # an 11-byte big-endian counter plus a final byte that is 1 on the last
  # chunk and 0 otherwise. Empty input is still one (empty) last chunk.
  defp encrypt_stream(plaintext, key) do
    chunks = split_chunks(plaintext)
    last = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          key,
          stream_nonce(index, index == last),
          chunk,
          "",
          true
        )

      [ciphertext, tag]
    end)
    |> IO.iodata_to_binary()
  end

  defp decrypt_stream(body, key), do: decrypt_stream(body, key, 0, [])

  defp decrypt_stream(body, key, index, acc) do
    sealed = @chunk_bytes + 16
    final? = byte_size(body) <= sealed

    case body do
      <<chunk::binary-size(^sealed), rest::binary>> when not final? ->
        case open_chunk(chunk, key, index, false) do
          {:ok, plain} -> decrypt_stream(rest, key, index + 1, [plain | acc])
          error -> error
        end

      <<chunk::binary>> when byte_size(chunk) >= 16 ->
        case open_chunk(chunk, key, index, true) do
          {:ok, ""} when acc != [] ->
            {:error, :empty_final_chunk}

          {:ok, plain} ->
            {:ok, IO.iodata_to_binary(Enum.reverse([plain | acc]))}

          error ->
            error
        end

      _ ->
        {:error, :truncated_payload}
    end
  end

  defp open_chunk(chunk, key, index, last?) do
    size = byte_size(chunk) - 16
    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = chunk

    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           key,
           stream_nonce(index, last?),
           ciphertext,
           "",
           tag,
           false
         ) do
      plain when is_binary(plain) -> {:ok, plain}
      _ -> {:error, :payload_auth_failed}
    end
  end

  defp stream_nonce(counter, last?),
    do: <<counter::unsigned-big-88, if(last?, do: 1, else: 0)>>

  defp split_chunks(""), do: [""]

  defp split_chunks(binary) do
    full = for <<chunk::binary-size(@chunk_bytes) <- binary>>, do: chunk
    consumed = length(full) * @chunk_bytes
    remainder = binary_part(binary, consumed, byte_size(binary) - consumed)

    # No trailing empty chunk: a payload that is an exact multiple of the
    # chunk size ends on a full chunk carrying the last-chunk flag.
    if remainder == "", do: full, else: full ++ [remainder]
  end

  # ------------------------------------------------------------- helpers ----

  @doc false
  def hkdf(ikm, salt, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    expand(prk, info, length, 1, "", [])
  end

  defp expand(_prk, _info, length, _counter, _previous, acc)
       when length <= 0 do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp expand(prk, info, length, counter, previous, acc) do
    block = :crypto.mac(:hmac, :sha256, prk, previous <> info <> <<counter>>)
    take = min(length, byte_size(block))
    expand(prk, info, length - take, counter + 1, block, [binary_part(block, 0, take) | acc])
  end

  # :crypto.hash_equals/2 RAISES on a length mismatch rather than returning
  # false, and the header MAC's length is attacker-controlled — it comes from
  # base64 in the file being opened. Compare lengths first so a malformed file
  # fails closed with an error tuple instead of an ArgumentError.
  defp constant_time_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp constant_time_equal?(_left, _right), do: false

  defp b64(data), do: Base.encode64(data, padding: false)

  @doc """
  Strictly canonical unpadded base64.

  `Base.decode64/2` ACCEPTS non-canonical input: a 43-character string encodes
  258 bits but carries only 32 bytes, and Elixir silently discards the two
  unused trailing bits. So `…AAB` and `…AAC` both decode to the same 32 bytes.

  age rejects that ("illegal base64 data at input byte 42"), and so must this:
  otherwise distinct byte sequences would decode to the same archive item,
  which for an audit archive — where the stored object IS the evidence — means
  a segment could be altered without changing what it decodes to. Re-encoding
  and comparing is the whole check.
  """
  @spec decode64_canonical(binary()) :: {:ok, binary()} | :error
  def decode64_canonical(string) when is_binary(string) do
    case Base.decode64(string, padding: false) do
      {:ok, value} ->
        if Base.encode64(value, padding: false) == string, do: {:ok, value}, else: :error

      :error ->
        :error
    end
  end

  def decode64_canonical(_), do: :error

  defp unb64(string), do: decode64_canonical(string)

  defp unb64_ok(string) do
    case decode64_canonical(string) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :bad_base64}
    end
  end

  defp wrap_columns(data) do
    encoded = b64(data)

    lines =
      for <<line::binary-size(64) <- encoded>>, do: line

    consumed = length(lines) * 64
    remainder = binary_part(encoded, consumed, byte_size(encoded) - consumed)

    # The body terminates on the first line shorter than 64 characters, so an
    # exact multiple of 64 needs an explicit empty line or the parser would
    # swallow whatever follows.
    Enum.join(lines ++ [remainder], "\n")
  end
end
