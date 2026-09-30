defmodule SalixSignalProto.SealedSender do
  @moduledoc """
  Sealed sender (CRS-06 §6 to §8): the sender's identity travels inside the
  encrypted payload, so the service does not learn it.

    * v1 (`seal/4`, `open/2`) seals one sealed inner message to one
      recipient identity key.
    * v2 (`seal_multi/4`) encrypts one inner message once for many
      recipients. The service splits the upload (`parse_upload/1`,
      `deliveries/1`) into one delivery per recipient account, which
      `open/2` also opens.

  Every function is pure. Randomness (the v1 ephemeral key, the v2 seed) is
  an option with a secure default.

  `open/2` only opens the sealed layer and checks that the certificate's
  identity key is the sender's. The receiver still validates the certificate
  (`SalixSignalProto.SealedSender.Certificate.validate/4`) and drops
  self-sends (CRS-06 §9).
  """

  import Bitwise

  alias SalixSignalProto.Crypto.AesGcmSiv
  alias SalixSignalProto.Crypto.Hkdf
  alias SalixSignalProto.Crypto.Hmac
  alias SalixSignalProto.Crypto.X25519
  alias SalixSignalProto.Keys
  alias SalixSignalProto.SealedSender.Inner
  alias SalixSignalProto.SealedSender.Wire
  alias SalixSignalProto.ServiceId

  @v1_version 0x11
  @v2_delivery_version 0x22
  @v2_upload_version 0x23
  @v1_salt_prefix "UnidentifiedDelivery"
  @v1_mac_bytes 10
  @info_x "Sealed Sender v2: r (2023-08)"
  @info_k "Sealed Sender v2: K"
  @info_mask "Sealed Sender v2: DH"
  @info_tag "Sealed Sender v2: DH-sender"
  @zero_nonce <<0::96>>
  @max_registration_id 0x3FFF

  @type identity :: %{public: Keys.ec_public(), private: Keys.ec_private()}

  @typedoc """
  Why a sealed message did not open. Every one is a sealed-layer failure:
  the sender is unknown, so no retry request is possible (CRS-07 §6.1).
  """
  @type open_error ::
          :unknown_version
          | :malformed
          | :bad_mac
          | :identity_mismatch
          | :wrong_recipient
          | :bad_tag
          | :decryption_failed
          | :invalid_key

  # --- v1 ----------------------------------------------------------------

  @doc """
  Seals a serialized inner message `inner` from `sender` (identity key pair)
  to the recipient identity public key (CRS-06 §7.3).

  Option: `:ephemeral_private` (32 bytes, default random).
  """
  @spec seal(binary(), identity(), Keys.ec_public(), keyword()) :: binary()
  def seal(inner, %{public: sender_public, private: sender_private}, recipient_public, opts \\ [])
      when is_binary(inner) do
    ephemeral =
      Keys.ec_keypair(Keyword.get_lazy(opts, :ephemeral_private, &X25519.generate_private_key/0))

    {:ok, shared1} = Keys.agree(ephemeral.private, recipient_public)
    stage1 = stage1(shared1, recipient_public, ephemeral.public)
    encrypted_static = ctr_hmac(stage1.cipher_key, stage1.mac_key, sender_public)
    {:ok, shared2} = Keys.agree(sender_private, recipient_public)
    stage2 = stage2(shared2, stage1.chain_key, encrypted_static)

    <<@v1_version>> <>
      Wire.V1.encode(%Wire.V1{
        ephemeral_public: ephemeral.public,
        encrypted_static: encrypted_static,
        encrypted_message: ctr_hmac(stage2.cipher_key, stage2.mac_key, inner)
      })
  end

  @doc false
  # Stage-1 keys of v1 (CRS-06 §7.3 step 2).
  def stage1(shared, recipient_public, ephemeral_public) do
    <<chain::binary-size(32), cipher::binary-size(32), mac::binary-size(32)>> =
      Hkdf.derive(shared, @v1_salt_prefix <> recipient_public <> ephemeral_public, "", 96)

    %{chain_key: chain, cipher_key: cipher, mac_key: mac}
  end

  @doc false
  # Stage-2 keys of v1 (CRS-06 §7.3 step 4).
  def stage2(shared, chain_key, encrypted_static) do
    <<_discarded::binary-size(32), cipher::binary-size(32), mac::binary-size(32)>> =
      Hkdf.derive(shared, chain_key <> encrypted_static, "", 96)

    %{cipher_key: cipher, mac_key: mac}
  end

  defp ctr_hmac(cipher_key, mac_key, plaintext) do
    ciphertext = ctr(cipher_key, plaintext)
    ciphertext <> binary_part(Hmac.sha256(mac_key, ciphertext), 0, @v1_mac_bytes)
  end

  # Verifies the 10-byte MAC before it decrypts (CRS-06 §7.2).
  defp open_ctr_hmac(cipher_key, mac_key, bytes) when byte_size(bytes) >= @v1_mac_bytes do
    size = byte_size(bytes) - @v1_mac_bytes
    <<ciphertext::binary-size(^size), mac::binary-size(@v1_mac_bytes)>> = bytes

    if Hmac.equal?(mac, binary_part(Hmac.sha256(mac_key, ciphertext), 0, @v1_mac_bytes)),
      do: {:ok, ctr(cipher_key, ciphertext)},
      else: {:error, :bad_mac}
  end

  defp open_ctr_hmac(_cipher_key, _mac_key, _bytes), do: {:error, :bad_mac}

  defp ctr(key, data), do: :crypto.crypto_one_time(:aes_256_ctr, key, <<0::128>>, data, true)

  # --- opening -----------------------------------------------------------------

  @doc """
  Opens a sealed message (v1, or a v2 delivery) with the recipient identity
  key pair. The version byte selects the layout: high nibble 0 or 1 is v1,
  high nibble 2 is a v2 delivery, anything else is an unknown version
  (CRS-06 §6).

  Returns the decoded inner message and the sender identity key that the
  sealed layer authenticated (S33). It is equal to the certificate's
  identity key.
  """
  @spec open(binary(), identity()) ::
          {:ok,
           %{
             inner: Inner.t(),
             inner_bytes: binary(),
             sender_identity: Keys.ec_public(),
             version: 1 | 2
           }}
          | {:error, open_error()}
  def open(<<version, rest::binary>>, recipient) do
    case version >>> 4 do
      major when major in [0, 1] -> open_v1(rest, recipient)
      2 -> open_v2(rest, recipient)
      _other -> {:error, :unknown_version}
    end
  end

  def open(_bytes, _recipient), do: {:error, :malformed}

  defp open_v1(proto, %{public: recipient_public, private: recipient_private}) do
    with {:ok, %Wire.V1{ephemeral_public: e, encrypted_static: s, encrypted_message: m}}
         when is_binary(e) and is_binary(s) and is_binary(m) <- decode_v1(proto),
         {:ok, ephemeral} <- parse_key(e),
         {:ok, shared1} <- agree(recipient_private, ephemeral),
         stage1 = stage1(shared1, recipient_public, ephemeral),
         {:ok, static} <- open_ctr_hmac(stage1.cipher_key, stage1.mac_key, s),
         {:ok, sender_public} <- parse_key(static),
         {:ok, shared2} <- agree(recipient_private, sender_public),
         stage2 = stage2(shared2, stage1.chain_key, s),
         {:ok, inner_bytes} <- open_ctr_hmac(stage2.cipher_key, stage2.mac_key, m),
         {:ok, inner} <- decode_inner(inner_bytes),
         :ok <- same_identity(inner, sender_public) do
      {:ok, %{inner: inner, inner_bytes: inner_bytes, sender_identity: sender_public, version: 1}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  defp decode_v1(proto) do
    {:ok, Wire.V1.decode(proto)}
  rescue
    # The protobuf decoder raises on malformed input.
    _error -> {:error, :malformed}
  end

  defp parse_key(bytes) do
    case Keys.parse_ec_public(bytes) do
      {:ok, key} -> {:ok, key}
      {:error, _} -> {:error, :invalid_key}
    end
  end

  defp agree(private, public) do
    case Keys.agree(private, public) do
      {:ok, shared} -> {:ok, shared}
      {:error, _} -> {:error, :invalid_key}
    end
  end

  defp decode_inner(bytes) do
    case Inner.decode(bytes) do
      {:ok, inner} -> {:ok, inner}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp same_identity(%Inner{certificate: %{identity_key: key}}, sender_public) do
    if Hmac.equal?(key, sender_public), do: :ok, else: {:error, :identity_mismatch}
  end

  defp open_v2(
         <<masked::binary-size(32), tag::binary-size(16), q::binary-size(32),
           ciphertext::binary>>,
         %{public: recipient_public, private: recipient_private}
       ) do
    q33 = <<0x05>> <> q

    with {:ok, shared} <- agree(recipient_private, q33),
         seed = xor(masked, Hkdf.derive(shared <> q33 <> recipient_public, "", @info_mask, 32)),
         %{x: x, k: k} = seed_keys(seed),
         :ok <- same_ephemeral(x, q),
         {:ok, inner_bytes} <- aead_open(k, ciphertext),
         {:ok, inner} <- decode_inner(inner_bytes),
         sender_public = inner.certificate.identity_key,
         {:ok, sender_shared} <- agree(recipient_private, sender_public),
         expected = sender_tag(sender_shared, q33, masked, sender_public, recipient_public),
         :ok <- if(Hmac.equal?(expected, tag), do: :ok, else: {:error, :bad_tag}) do
      {:ok, %{inner: inner, inner_bytes: inner_bytes, sender_identity: sender_public, version: 2}}
    end
  end

  defp open_v2(_bytes, _recipient), do: {:error, :malformed}

  defp same_ephemeral(x, q) do
    if Hmac.equal?(X25519.public_key(X25519.clamp(x)), q),
      do: :ok,
      else: {:error, :wrong_recipient}
  end

  defp aead_open(k, ciphertext) do
    case AesGcmSiv.decrypt(k, @zero_nonce, ciphertext) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _} -> {:error, :decryption_failed}
    end
  end

  # --- v2 ----------------------------------------------------------------

  @doc false
  # The ephemeral scalar x and AEAD key k of seed m (CRS-06 §8.2 step 2).
  def seed_keys(<<_::binary-size(32)>> = seed),
    do: %{x: Hkdf.derive(seed, "", @info_x, 32), k: Hkdf.derive(seed, "", @info_k, 32)}

  defp sender_tag(shared, q33, masked, sender_public, recipient_public),
    do:
      Hkdf.derive(shared <> q33 <> masked <> sender_public <> recipient_public, "", @info_tag, 16)

  defp xor(<<a::256>>, <<b::256>>), do: <<bxor(a, b)::256>>

  @typedoc """
  A recipient account of a v2 send: its service ID, identity public key and
  `[{device_id, registration_id}]` from the 1:1 sessions with its devices.
  """
  @type recipient :: %{
          service_id: ServiceId.t(),
          identity_key: Keys.ec_public(),
          devices: [{1..127, 0..0x3FFF}]
        }

  @doc """
  Encrypts `inner` once for many recipient accounts and returns the upload
  for `PUT /v1/messages/multi_recipient` (CRS-06 §8.2, §8.3). `excluded`
  lists service IDs of members that are deliberately not sent to; they go
  after the recipient entries.

  Options: `:seed` (32 bytes, default random).

  Raises `ArgumentError` for a registration ID above 14 bits or a device ID
  outside 1 to 127: the sender must refuse such a session (§8.3).
  """
  @spec seal_multi(binary(), identity(), [recipient()], keyword()) :: binary()
  def seal_multi(inner, %{public: sender_public, private: sender_private}, recipients, opts \\ [])
      when is_binary(inner) and is_list(recipients) do
    excluded = Keyword.get(opts, :excluded, [])
    seed = Keyword.get_lazy(opts, :seed, fn -> :crypto.strong_rand_bytes(32) end)
    %{x: x, k: k} = seed_keys(seed)
    q = X25519.public_key(X25519.clamp(x))
    q33 = <<0x05>> <> q
    ciphertext = AesGcmSiv.encrypt(k, @zero_nonce, inner)

    entries =
      Enum.map(recipients, fn %{service_id: service_id, identity_key: identity, devices: devices} ->
        {:ok, shared} = Keys.agree(x, identity)
        masked = xor(seed, Hkdf.derive(shared <> q33 <> identity, "", @info_mask, 32))
        {:ok, sender_shared} = Keys.agree(sender_private, identity)
        tag = sender_tag(sender_shared, q33, masked, sender_public, identity)
        [ServiceId.fixed_width(service_id), device_records(devices), masked, tag]
      end)

    excluded_entries = Enum.map(excluded, &[ServiceId.fixed_width(&1), <<0>>])

    IO.iodata_to_binary([
      @v2_upload_version,
      varint(length(entries) + length(excluded_entries)),
      entries,
      excluded_entries,
      q,
      ciphertext
    ])
  end

  defp device_records([_ | _] = devices) do
    last = length(devices) - 1

    devices
    |> Enum.with_index()
    |> Enum.map(fn {{device_id, registration_id}, index} ->
      unless device_id in 1..127,
        do: raise(ArgumentError, "device ID #{device_id} is outside 1 to 127")

      unless registration_id in 0..@max_registration_id,
        do: raise(ArgumentError, "registration ID #{registration_id} does not fit in 14 bits")

      more = if index < last, do: 0x8000, else: 0
      <<device_id, bor(more, registration_id)::16>>
    end)
  end

  defp device_records([]), do: raise(ArgumentError, "a recipient entry needs at least one device")

  defp varint(n) when n < 0x80, do: <<n>>
  defp varint(n), do: <<bor(band(n, 0x7F), 0x80)>> <> varint(n >>> 7)

  @typedoc "One parsed recipient entry of an upload (§8.3)."
  @type upload_entry :: %{
          service_id: ServiceId.t(),
          devices: [{1..127, 0..0x3FFF}],
          masked_seed: <<_::256>>,
          sender_tag: <<_::128>>
        }

  @typedoc "A parsed upload."
  @type upload :: %{
          version: 0x22 | 0x23,
          recipients: [upload_entry()],
          excluded: [ServiceId.t()],
          ephemeral_public: <<_::256>>,
          ciphertext: binary()
        }

  @doc """
  Parses an upload (CRS-06 §8.3), as the service does. Entries keep their
  order; repeated recipient entries are kept (see `deliveries/1`).

  Errors: `:empty`, `:unknown_version` (a first byte other than `0x22` or
  `0x23`), `:malformed` (a truncated entry, a device ID byte of 0 after the
  first position, fewer than 32 bytes after the entries), `:conflicting`
  (a service ID both a recipient and excluded).
  """
  @spec parse_upload(binary()) ::
          {:ok, upload()} | {:error, :empty | :unknown_version | :malformed | :conflicting}
  def parse_upload(<<>>), do: {:error, :empty}

  def parse_upload(<<version, rest::binary>>)
      when version in [@v2_delivery_version, @v2_upload_version] do
    id_size = if version == @v2_upload_version, do: 17, else: 16

    with {:ok, count, rest} <- read_varint(rest, 0, 0),
         {:ok, recipients, excluded, rest} <- read_entries(rest, count, id_size, [], []),
         <<q::binary-size(32), ciphertext::binary>> <- rest,
         :ok <- disjoint(recipients, excluded) do
      {:ok,
       %{
         version: version,
         recipients: recipients,
         excluded: excluded,
         ephemeral_public: q,
         ciphertext: ciphertext
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def parse_upload(_bytes), do: {:error, :unknown_version}

  defp read_varint(<<byte, rest::binary>>, shift, acc) when shift < 64 do
    value = bor(acc, band(byte, 0x7F) <<< shift)
    if band(byte, 0x80) == 0, do: {:ok, value, rest}, else: read_varint(rest, shift + 7, value)
  end

  defp read_varint(_bytes, _shift, _acc), do: {:error, :malformed}

  defp read_entries(rest, 0, _id_size, recipients, excluded),
    do: {:ok, Enum.reverse(recipients), Enum.reverse(excluded), rest}

  defp read_entries(bytes, count, id_size, recipients, excluded) do
    with <<id::binary-size(^id_size), rest::binary>> <- bytes,
         {:ok, service_id} <- upload_service_id(id) do
      case rest do
        <<0, rest::binary>> ->
          read_entries(rest, count - 1, id_size, recipients, [service_id | excluded])

        _ ->
          with {:ok, devices, rest} <- read_devices(rest, []),
               <<masked::binary-size(32), tag::binary-size(16), rest::binary>> <- rest do
            entry = %{
              service_id: service_id,
              devices: devices,
              masked_seed: masked,
              sender_tag: tag
            }

            read_entries(rest, count - 1, id_size, [entry | recipients], excluded)
          else
            _ -> {:error, :malformed}
          end
      end
    else
      _ -> {:error, :malformed}
    end
  end

  defp upload_service_id(<<uuid::binary-size(16)>>), do: {:ok, {:aci, uuid}}
  defp upload_service_id(fixed), do: ServiceId.from_fixed_width(fixed)

  defp read_devices(<<device_id, field::16, rest::binary>>, acc) when device_id in 1..127 do
    acc = [{device_id, band(field, @max_registration_id)} | acc]
    if band(field, 0x8000) != 0, do: read_devices(rest, acc), else: {:ok, Enum.reverse(acc), rest}
  end

  defp read_devices(_bytes, _acc), do: {:error, :malformed}

  defp disjoint(recipients, excluded) do
    ids = MapSet.new(recipients, & &1.service_id)
    if Enum.any?(excluded, &MapSet.member?(ids, &1)), do: {:error, :conflicting}, else: :ok
  end

  @doc """
  The per-recipient deliveries of a parsed upload, as the service builds
  them (CRS-06 §8.4): one delivery per recipient account, in the order of
  first appearance, with the device lists of repeated entries merged. A
  repeated entry keeps the masked seed and tag of its first appearance.

  Each delivery is `0x22 || masked seed || tag || Q || ciphertext`, the same
  bytes for every listed device of that account.
  """
  @spec deliveries(upload()) :: [
          %{service_id: ServiceId.t(), devices: [{1..127, 0..0x3FFF}], delivery: binary()}
        ]
  def deliveries(%{recipients: recipients, ephemeral_public: q, ciphertext: ciphertext}) do
    recipients
    |> Enum.reduce({[], %{}}, fn entry, {order, by_id} ->
      case Map.fetch(by_id, entry.service_id) do
        {:ok, first} ->
          {order,
           Map.put(by_id, entry.service_id, %{first | devices: first.devices ++ entry.devices})}

        :error ->
          {[entry.service_id | order], Map.put(by_id, entry.service_id, entry)}
      end
    end)
    |> then(fn {order, by_id} ->
      for service_id <- Enum.reverse(order) do
        entry = Map.fetch!(by_id, service_id)

        %{
          service_id: service_id,
          devices: entry.devices,
          delivery:
            <<@v2_delivery_version>> <> entry.masked_seed <> entry.sender_tag <> q <> ciphertext
        }
      end
    end)
  end
end
