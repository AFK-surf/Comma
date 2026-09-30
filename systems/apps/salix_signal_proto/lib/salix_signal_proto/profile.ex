defmodule SalixSignalProto.Profile do
  @moduledoc """
  The account profile key and the values derived from it (CRS-08 sections 2
  to 4 and 8).

  A profile key is any 32-byte value. From it come:

    * the access key (16 bytes), which peers present for sealed-sender sends
      and unidentified profile reads;
    * the access-key checksum (32 bytes), which the service returns in the
      profile as `unidentifiedAccess`;
    * the profile key version (a 64-character lowercase hexadecimal string)
      for a (profile key, ACI) pair.

  Profile fields and the avatar are encrypted with AES-256-GCM under the
  profile key: `nonce (12) || ciphertext || tag (16)`, no associated data.
  Field plaintexts are right-padded with zero bytes to the smallest allowed
  length that fits (section 4.2); the avatar is not padded.

  The profile key commitment (section 3.4) and the expiring profile key
  credential (section 7) use the group credential mathematics of CRS-09.
  They are not in this module.
  """

  alias SalixSignalProto.Crypto.{AesGcm, Hmac}

  @type profile_key :: <<_::256>>
  @type access_key :: <<_::128>>

  @nonce_bytes 12
  @tag_bytes 16
  @overhead @nonce_bytes + @tag_bytes

  # CRS-08 section 3.3.
  @version_label "Signal_ZKGroup_20200424_ProfileKeyAndUid_ProfileKey_GetProfileKeyVersion"

  # CRS-08 section 4.2: padded plaintext lengths per field.
  @padded_lengths %{
    name: [53, 257],
    about: [128, 254, 512],
    about_emoji: [32]
  }

  @doc "A new random profile key (CRS-08 section 2)."
  @spec generate() :: profile_key()
  def generate, do: :crypto.strong_rand_bytes(32)

  @doc """
  The access key: one AES-256 block operation on `0x00 * 15 || 0x02` with
  the profile key (CRS-08 section 3.1).
  """
  @spec access_key(profile_key()) :: access_key()
  def access_key(<<_::binary-size(32)>> = profile_key) do
    :crypto.crypto_one_time(:aes_256_ecb, profile_key, <<0::120, 2>>, true)
  end

  @doc "HMAC-SHA256(access key, 32 zero bytes) (CRS-08 section 3.2)."
  @spec access_key_checksum(access_key()) :: <<_::256>>
  def access_key_checksum(<<_::binary-size(16)>> = access_key) do
    Hmac.sha256(access_key, <<0::256>>)
  end

  @doc """
  Compares the checksum from a profile with the checksum of the access key
  derived from `profile_key`, in constant time.
  """
  @spec checksum_matches?(profile_key(), binary()) :: boolean()
  def checksum_matches?(<<_::binary-size(32)>> = profile_key, checksum)
      when is_binary(checksum) do
    profile_key |> access_key() |> access_key_checksum() |> Hmac.equal?(checksum)
  end

  @doc """
  The profile key version for `profile_key` and the 16 UUID bytes of the
  ACI, as the 64-character lowercase hexadecimal string that the wire uses
  (CRS-08 section 3.3).
  """
  @spec version(profile_key(), <<_::128>>) :: String.t()
  def version(<<_::binary-size(32)>> = profile_key, <<_::binary-size(16)>> = aci_uuid) do
    cv1 = Hmac.sha256(<<0::256>>, [@version_label, 0])
    cv2 = Hmac.sha256(cv1, [profile_key, aci_uuid, 0])
    cv2 |> Hmac.sha256(<<0::64, 1>>) |> Base.encode16(case: :lower)
  end

  # --- Field encryption --------------------------------------------------

  @doc """
  Encrypts `plaintext` as is: `nonce || AES-256-GCM(profile_key, nonce,
  plaintext) || tag`, with no associated data (CRS-08 section 4.1). This is
  the avatar form (section 5.5); fields are padded first (`encrypt_name/4`
  and the other field functions).
  """
  @spec encrypt(profile_key(), binary(), <<_::96>>) :: binary()
  def encrypt(<<_::binary-size(32)>> = profile_key, plaintext, nonce \\ random_nonce())
      when is_binary(plaintext) and byte_size(nonce) == @nonce_bytes do
    {ciphertext, tag} = AesGcm.encrypt(profile_key, nonce, plaintext, "")
    nonce <> ciphertext <> tag
  end

  @doc """
  Decrypts an encrypted field or avatar. Input shorter than 29 bytes is
  refused. A tag failure usually means the reader holds an outdated profile
  key (CRS-08 section 4.1).
  """
  @spec decrypt(profile_key(), binary()) :: {:ok, binary()} | {:error, :too_short | :invalid}
  def decrypt(<<_::binary-size(32)>> = profile_key, encrypted) when is_binary(encrypted) do
    size = byte_size(encrypted)

    if size <= @overhead do
      {:error, :too_short}
    else
      <<nonce::binary-size(@nonce_bytes), rest::binary>> = encrypted
      ciphertext = binary_part(rest, 0, size - @overhead)
      tag = binary_part(rest, size - @overhead, @tag_bytes)
      AesGcm.decrypt(profile_key, nonce, ciphertext, tag, "")
    end
  end

  @doc """
  Encrypts a name. With a non-empty family name the plaintext is the given
  name, one zero byte, and the family name; otherwise the given name alone.
  Names must not contain a zero byte. The plaintext is padded to 53 or 257
  bytes (CRS-08 section 4.2).
  """
  @spec encrypt_name(profile_key(), String.t(), String.t() | nil, <<_::96>>) ::
          {:ok, binary()} | {:error, :too_long | :invalid_text}
  def encrypt_name(profile_key, given, family, nonce \\ random_nonce())
      when is_binary(given) do
    family = family || ""

    cond do
      not text?(given) or not text?(family) -> {:error, :invalid_text}
      family == "" -> encrypt_padded(profile_key, :name, given, nonce)
      true -> encrypt_padded(profile_key, :name, given <> <<0>> <> family, nonce)
    end
  end

  @doc "Encrypts the about text, padded to 128, 254 or 512 bytes."
  @spec encrypt_about(profile_key(), String.t(), <<_::96>>) ::
          {:ok, binary()} | {:error, :too_long | :invalid_text}
  def encrypt_about(profile_key, about, nonce \\ random_nonce()) when is_binary(about),
    do: encrypt_text(profile_key, :about, about, nonce)

  @doc "Encrypts the about emoji, padded to 32 bytes."
  @spec encrypt_about_emoji(profile_key(), String.t(), <<_::96>>) ::
          {:ok, binary()} | {:error, :too_long | :invalid_text}
  def encrypt_about_emoji(profile_key, emoji, nonce \\ random_nonce()) when is_binary(emoji),
    do: encrypt_text(profile_key, :about_emoji, emoji, nonce)

  @doc "Encrypts the phone-number sharing flag: one byte, 0x01 or 0x00, not padded."
  @spec encrypt_phone_number_sharing(profile_key(), boolean(), <<_::96>>) :: binary()
  def encrypt_phone_number_sharing(profile_key, sharing?, nonce \\ random_nonce())
      when is_boolean(sharing?) do
    encrypt(profile_key, if(sharing?, do: <<1>>, else: <<0>>), nonce)
  end

  @doc """
  Decrypts a name into `{given, family}`. The given name is the bytes before
  the first zero byte; the family name is the bytes after it up to the next
  zero byte, or `nil` when there are none.
  """
  @spec decrypt_name(profile_key(), binary()) ::
          {:ok, {String.t(), String.t() | nil}} | {:error, :too_short | :invalid | :invalid_text}
  def decrypt_name(profile_key, encrypted) do
    with {:ok, plaintext} <- decrypt(profile_key, encrypted) do
      {given, family} =
        case :binary.split(plaintext, <<0>>) do
          [given] -> {given, ""}
          [given, rest] -> {given, rest |> :binary.split(<<0>>) |> hd()}
        end

      cond do
        not String.valid?(given) or not String.valid?(family) -> {:error, :invalid_text}
        family == "" -> {:ok, {given, nil}}
        true -> {:ok, {given, family}}
      end
    end
  end

  @doc "Decrypts the about text or emoji and removes all trailing zero bytes."
  @spec decrypt_text(profile_key(), binary()) ::
          {:ok, String.t()} | {:error, :too_short | :invalid | :invalid_text}
  def decrypt_text(profile_key, encrypted) do
    with {:ok, plaintext} <- decrypt(profile_key, encrypted) do
      text = trim_trailing_zeros(plaintext)
      if String.valid?(text), do: {:ok, text}, else: {:error, :invalid_text}
    end
  end

  @doc "Decrypts the phone-number sharing flag; a non-zero first byte means sharing."
  @spec decrypt_phone_number_sharing(profile_key(), binary()) ::
          {:ok, boolean()} | {:error, :too_short | :invalid}
  def decrypt_phone_number_sharing(profile_key, encrypted) do
    with {:ok, <<first, _::binary>>} <- decrypt(profile_key, encrypted) do
      {:ok, first != 0}
    end
  end

  @doc """
  Right-pads `plaintext` with zero bytes to the smallest allowed length of
  `field` (`:name`, `:about` or `:about_emoji`) that is at least its length.
  """
  @spec pad(:name | :about | :about_emoji, binary()) :: {:ok, binary()} | {:error, :too_long}
  def pad(field, plaintext) when is_binary(plaintext) do
    size = byte_size(plaintext)

    case Enum.find(Map.fetch!(@padded_lengths, field), &(&1 >= size)) do
      nil -> {:error, :too_long}
      length -> {:ok, plaintext <> :binary.copy(<<0>>, length - size)}
    end
  end

  # --- Unidentified access -------------------------------------------------

  @doc """
  The access key to present for a contact, from the contact's fetched
  profile and the contact's profile key if held (CRS-08 section 8).

  `profile` is `nil` when no profile was fetched yet, or a map with
  `:unidentified_access` (the 32-byte checksum or `nil`) and
  `:unrestricted_unidentified_access` (boolean).

    * `{:open, <<0::128>>}`: unrestricted access with a checksum present.
    * `{:keyed, access_key}`: the held profile key matches the checksum.
    * `:off`: send authenticated.
    * `{:unknown, key}`: no profile yet; the derived key if the profile key
      is held, otherwise 16 zero bytes.
  """
  @spec unidentified_access(map() | nil, profile_key() | nil) ::
          {:open, access_key()} | {:keyed, access_key()} | {:unknown, access_key()} | :off
  def unidentified_access(nil, nil), do: {:unknown, <<0::128>>}
  def unidentified_access(nil, profile_key), do: {:unknown, access_key(profile_key)}

  def unidentified_access(%{} = profile, profile_key) do
    checksum = Map.get(profile, :unidentified_access)

    cond do
      Map.get(profile, :unrestricted_unidentified_access) == true and is_binary(checksum) ->
        {:open, <<0::128>>}

      is_binary(profile_key) and is_binary(checksum) and
          checksum_matches?(profile_key, checksum) ->
        {:keyed, access_key(profile_key)}

      true ->
        :off
    end
  end

  # --- Helpers -------------------------------------------------------------

  defp encrypt_text(profile_key, field, text, nonce) do
    if text?(text),
      do: encrypt_padded(profile_key, field, text, nonce),
      else: {:error, :invalid_text}
  end

  defp encrypt_padded(profile_key, field, plaintext, nonce) do
    with {:ok, padded} <- pad(field, plaintext) do
      {:ok, encrypt(profile_key, padded, nonce)}
    end
  end

  # A text value must be UTF-8 without zero bytes, because readers split and
  # trim at zero bytes.
  defp text?(text), do: String.valid?(text) and not String.contains?(text, <<0>>)

  defp trim_trailing_zeros(binary) do
    size = byte_size(binary)
    keep = count_kept(binary, size)
    binary_part(binary, 0, keep)
  end

  defp count_kept(_binary, 0), do: 0

  defp count_kept(binary, size) do
    if :binary.at(binary, size - 1) == 0, do: count_kept(binary, size - 1), else: size
  end

  defp random_nonce, do: :crypto.strong_rand_bytes(@nonce_bytes)
end
