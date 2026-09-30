defmodule SalixSignalProto.Receive do
  @moduledoc """
  Opens one server envelope for the receiving account (CRS-05, CRS-06 §9,
  CRS-07 §5 and §6): envelope checks, the sealed layer, 1:1 or sender-key
  decryption, unpadding, content parsing and content validation.

  `open/2` is pure. It reads the account's stored state through the
  functions in the context and returns a `SalixSignalProto.Receive.Result`
  that says what happened and which state changes the caller must commit.
  The caller commits the session update together with the admission of the
  envelope, then acknowledges the envelope (PLAN "Durable state").

  ## Outcomes

  | Outcome | Meaning | Caller action |
  | --- | --- | --- |
  | `:message` | A valid content container. | Store it, then acknowledge. |
  | `:server_receipt` | A server delivery receipt (envelope kind 5). | Record it, then acknowledge. |
  | `:failed` | The sender is known, but its message did not decrypt, unpad or parse. | Apply the retry rules of CRS-07 §6, then acknowledge. |
  | `:unsupported` | An unknown or legacy message version, or a data message that needs a newer feature level. | Show an "unsupported" notice, then acknowledge. No retry request. |
  | `:drop` | An invalid envelope, a sealed-layer failure, an invalid certificate, a self-send, a duplicate, or content that fails the validity rules. | Acknowledge. No retry request. |

  A result can carry a session update even when the outcome is not
  `:message`: once a 1:1 message decrypts, its message key is used, and the
  new session record must be kept.

  ## Context

  | Key | Value |
  | --- | --- |
  | `:aci`, `:pni` | 16 UUID bytes of the account's ACI and PNI (PNI may be nil) |
  | `:e164` | optional, the account's E.164 number; a sealed certificate that names it and the local device ID is a self-send (CRS-06 §9) |
  | `:device_id` | the local device ID |
  | `:identities` | `%{aci: key_pair, pni: key_pair | nil}`, `%{public: 33 bytes, private: 32 bytes}` |
  | `:registration_ids` | `%{aci: n, pni: n}` |
  | `:trust_roots` | trust root public keys (CRS-06 §3.5) |
  | `:known_server_certificates` | `%{key_id => server certificate}` (CRS-06 §3.4) |
  | `:now_ms` | the receiver's clock, for certificate validation |
  | `:session` | `(SalixSignalProto.Address.t() -> Record.t() | nil)` |
  | `:pre_keys` | `(:aci | :pni -> SalixSignalProto.Session.pre_keys())` |
  | `:trusted?` | optional trust policy, see `SalixSignalProto.Session` (default: trust every key) |
  | `:sender_key` | optional `(sender_address, message, group_id) -> {:ok, plaintext, update} | {:error, reason}` for sender-key messages (CRS-09); without it a sender-key message fails with `:no_sender_key_state` |
  | `:ratchet_private` | optional 32 bytes, the new ratchet key if a message starts a DH ratchet step |
  | `:sender_allowed?` | optional `(sender_uuid -> boolean)`; checked once the sender is known and before any 1:1 or sender-key decryption. A refused sender's envelope is a `:drop` with reason `:sender_cooling` (the receiver's failure budget; Comma's rule, not a Signal fact) |
  """

  alias SalixSignalProto.Address
  alias SalixSignalProto.Message.Content
  alias SalixSignalProto.Message.DecryptionError
  alias SalixSignalProto.Message.Envelope
  alias SalixSignalProto.Message.Padding
  alias SalixSignalProto.Message.Wire
  alias SalixSignalProto.SealedSender
  alias SalixSignalProto.SealedSender.Certificate
  alias SalixSignalProto.SealedSender.Inner
  alias SalixSignalProto.ServiceId
  alias SalixSignalProto.Session
  alias SalixSignalProto.Session.Message

  defmodule Result do
    @moduledoc """
    The result of opening one envelope. See `SalixSignalProto.Receive`.

    * `sender`, `sender_device`, `sender_e164`: the authenticated sender (the
      envelope source, or the sealed sender certificate), when known.
    * `destination`: `:aci` or `:pni`, the identity the envelope was
      addressed to.
    * `content_kind`, `content`: the main field and the decoded content
      container wire struct (`:message` outcome).
    * `content_hint`, `group_id`: from the sealed inner message (defaults 0
      and nil for identified envelopes).
    * `failed`: `%{type, message}` for a `:failed` outcome: the failed
      ciphertext and its type, the inputs of a retry request (CRS-07 §6.2).
    * `session`: `%{address, record, effects}` to commit, or nil.
    * `sender_key`: the sender-key state update to commit, or nil.
    * `needs_pni_signature?`: the envelope was addressed to the PNI by a
      known sender, who must later receive a PNI signature (CRS-05 §3.1).
    """
    defstruct outcome: :drop,
              reason: nil,
              envelope: nil,
              destination: nil,
              sender: nil,
              sender_device: nil,
              sender_e164: nil,
              sealed?: false,
              content_kind: nil,
              content: nil,
              content_hint: 0,
              group_id: nil,
              failed: nil,
              session: nil,
              sender_key: nil,
              needs_pni_signature?: false

    @type t :: %__MODULE__{}
  end

  @doc "Opens a serialized or decoded envelope. See the module documentation."
  @spec open(binary() | Envelope.t(), map()) :: Result.t()
  def open(bytes, context) when is_binary(bytes) do
    case Envelope.decode(bytes) do
      {:ok, envelope} -> open(envelope, context)
      {:error, :malformed} -> %Result{outcome: :drop, reason: :malformed_envelope}
    end
  end

  def open(%Envelope{} = envelope, context) do
    case Envelope.check(envelope, context.aci, context[:pni]) do
      {:ok, destination} ->
        result = %Result{envelope: envelope, destination: destination}
        open_kind(envelope.kind, envelope, result, context)

      {:drop, reason} ->
        %Result{outcome: :drop, reason: reason, envelope: envelope}
    end
  end

  defp open_kind(5, envelope, result, _context) do
    {_kind, uuid} = envelope.source
    %{result | outcome: :server_receipt, sender: uuid, sender_device: envelope.source_device}
  end

  defp open_kind(kind, envelope, result, context) when kind in [1, 3] do
    {:aci, sender} = envelope.source
    result = identified(result, sender, envelope.source_device)
    type = if kind == 1, do: :whisper, else: :prekey
    one_to_one(type, envelope.payload, result, context)
  end

  defp open_kind(8, envelope, result, context) do
    {:aci, sender} = envelope.source

    result
    |> identified(sender, envelope.source_device)
    |> plaintext(envelope.payload, context)
  end

  defp open_kind(6, envelope, result, context) do
    with {:ok, opened} <- open_sealed(envelope.payload, context),
         inner = opened.inner,
         certificate = inner.certificate,
         :ok <- valid_certificate(certificate, context),
         :ok <- not_self_send(certificate, context) do
      result = %{
        result
        | sealed?: true,
          sender: certificate.aci,
          sender_device: certificate.device_id,
          sender_e164: certificate.e164,
          content_hint: inner.content_hint,
          group_id: inner.group_id
      }

      case inner.type do
        type when type in [:whisper, :prekey] -> one_to_one(type, inner.content, result, context)
        :sender_key -> sender_key(inner.content, result, context)
        :plaintext -> plaintext(result, inner.content, context)
      end
    else
      {:drop, reason} -> %{result | outcome: :drop, reason: reason}
    end
  end

  defp identified(result, sender, device),
    do: %{
      result
      | sender: sender,
        sender_device: device,
        needs_pni_signature?: result.destination == :pni
    }

  # --- sealed layer (CRS-06 §9) -------------------------------------------------

  defp open_sealed(payload, context) do
    case SealedSender.open(payload, context.identities.aci) do
      {:ok, opened} -> {:ok, opened}
      {:error, reason} -> {:drop, {:sealed, reason}}
    end
  end

  defp valid_certificate(certificate, context) do
    known = Map.get(context, :known_server_certificates, %{})

    case Certificate.validate(certificate, context.trust_roots, context.now_ms, known) do
      :ok -> :ok
      {:error, reason} -> {:drop, {:certificate, reason}}
    end
  end

  # The local ACI, or the local E.164 when both sides have one, and the
  # local device ID.
  defp not_self_send(certificate, context) do
    local_e164 = Map.get(context, :e164)

    own_account? =
      certificate.aci == context.aci or
        (local_e164 != nil and certificate.e164 == local_e164)

    if own_account? and certificate.device_id == context.device_id,
      do: {:drop, :self_send},
      else: :ok
  end

  # --- 1:1 (CRS-04) --------------------------------------------------------------

  defp one_to_one(type, bytes, result, context) do
    if sender_allowed?(result, context) do
      case version(bytes) do
        :ok -> decrypt_one_to_one(type, bytes, result, context)
        {:error, reason} -> %{result | outcome: :unsupported, reason: reason}
      end
    else
      %{result | outcome: :drop, reason: :sender_cooling}
    end
  end

  defp sender_allowed?(%Result{sender: sender}, context) do
    case context[:sender_allowed?] do
      nil -> true
      allowed? -> allowed?.(sender)
    end
  end

  # An unknown or legacy version shows an "unsupported" notice and gets no
  # retry request (CRS-07 §6.1).
  defp version(<<v, _rest::binary>>) do
    case Message.version(v) do
      {:ok, _version} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp version(_bytes), do: :ok

  defp decrypt_one_to_one(type, bytes, result, context) do
    remote = Address.new(ServiceId.to_string({:aci, result.sender}), result.sender_device)
    local_uuid = if result.destination == :pni, do: context.pni, else: context.aci
    local = Address.new(ServiceId.to_string({result.destination, local_uuid}), context.device_id)

    session_context = %{
      identity: Map.fetch!(context.identities, result.destination),
      registration_id: Map.fetch!(context.registration_ids, result.destination),
      local_address: local,
      remote_address: remote,
      trusted?: Map.get(context, :trusted?, fn _key, _direction -> true end)
    }

    opts = if key = context[:ratchet_private], do: [ratchet_private: key], else: []
    record = context.session.(remote)

    decrypted =
      case type do
        :whisper ->
          Session.decrypt(record, bytes, session_context, opts)

        :prekey ->
          Session.decrypt_pre_key(
            record,
            bytes,
            session_context,
            context.pre_keys.(result.destination),
            opts
          )
      end

    case decrypted do
      {:ok, padded, record, effects} ->
        result = %{result | session: %{address: remote, record: record, effects: effects}}
        padded_content(padded, result, %{type: type, message: bytes}, context)

      {:error, :duplicate} ->
        %{result | outcome: :drop, reason: :duplicate}

      {:error, reason} ->
        failed(result, reason, type, bytes)
    end
  end

  # --- sender keys (CRS-09, layer C7) -------------------------------------------

  defp sender_key(bytes, result, context) do
    if sender_allowed?(result, context),
      do: sender_key_allowed(bytes, result, context),
      else: %{result | outcome: :drop, reason: :sender_cooling}
  end

  defp sender_key_allowed(bytes, result, context) do
    address = Address.new(ServiceId.to_string({:aci, result.sender}), result.sender_device)

    decrypted =
      case context[:sender_key] do
        nil -> {:error, :no_sender_key_state}
        decrypt -> decrypt.(address, bytes, result.group_id)
      end

    case decrypted do
      {:ok, padded, update} ->
        padded_content(
          padded,
          %{result | sender_key: update},
          %{type: :sender_key, message: bytes},
          context
        )

      {:error, :duplicate} ->
        %{result | outcome: :drop, reason: :duplicate}

      {:error, reason} ->
        failed(result, reason, :sender_key, bytes)
    end
  end

  # --- content ------------------------------------------------------------------

  defp padded_content(padded, result, failed_input, context) do
    with {:ok, content} <- unpad(padded),
         {:ok, kind, wire} <- decode_content(content) do
      validated(kind, wire, result, context)
    else
      {:invalid, reason} -> %{result | outcome: :drop, reason: {:invalid_content, reason}}
      {:error, reason} -> failed(result, reason, failed_input.type, failed_input.message)
    end
  end

  # Malformed padding is an undecryptable message (CRS-05 §4).
  defp unpad(padded) do
    case Padding.unpad(padded) do
      {:ok, content} -> {:ok, content}
      {:error, :malformed} -> {:error, :bad_padding}
    end
  end

  defp decode_content(content) do
    case Content.decode(content) do
      {:ok, kind, wire} -> {:ok, kind, wire}
      {:error, :malformed} -> {:error, :malformed_content}
      # A container with no main field, or with two, is invalid content.
      {:error, reason} -> {:invalid, reason}
    end
  end

  defp validated(kind, wire, result, context) do
    validation = %{
      timestamp: result.envelope.client_timestamp,
      from_self?: result.sender == context.aci
    }

    case Content.validate(kind, wire, validation) do
      :ok ->
        if kind == :data and Content.unsupported?(wire.data_message),
          do: %{
            result
            | outcome: :unsupported,
              reason: :protocol_version,
              content_kind: kind,
              content: wire
          },
          else: %{result | outcome: :message, content_kind: kind, content: wire}

      {:error, reason} ->
        %{result | outcome: :drop, reason: {:invalid_content, reason}}
    end
  end

  # The plaintext wrapper carries only a decryption error message (CRS-05 §7).
  defp plaintext(result, bytes, context) do
    case DecryptionError.unwrap(bytes) do
      {:ok, message} ->
        validated(:decryption_error, %Wire.Content{decryption_error: message}, result, context)

      {:error, :malformed} ->
        %{result | outcome: :drop, reason: {:invalid_content, :plaintext_wrapper}}
    end
  end

  defp failed(result, reason, type, message),
    do: %{result | outcome: :failed, reason: reason, failed: %{type: type, message: message}}

  @doc """
  The decryption error message (CRS-05 §7) that answers a `:failed` result:
  the ratchet key of the failed message, the envelope client timestamp and
  the sender device. Returns `{:error, reason}` when none can be built.
  """
  @spec retry_request(Result.t()) :: {:ok, binary()} | {:error, atom()}
  def retry_request(%Result{outcome: :failed, failed: %{type: type, message: message}} = result) do
    DecryptionError.build(
      message,
      type,
      result.envelope.client_timestamp || 0,
      result.sender_device
    )
  end

  @doc """
  What the original sender does with a received decryption error message
  (CRS-07 §6.3), given its local device ID and its session record with the
  requester's device:

    * `:ignore`: the message names another device of this account;
    * `{:reset_session, record}`: the ratchet key is this device's current
      sending ratchet key; the returned record no longer has that session
      current, and the next message starts a new session;
    * `:keep_session`: a 1:1 failure on a session that is no longer current;
    * `:sender_key`: a sender-key failure; the requester's device no longer
      holds this device's sender key.
  """
  @spec handle_retry_request(DecryptionError.t(), pos_integer(), Session.Record.t() | nil) ::
          :ignore | {:reset_session, Session.Record.t()} | :keep_session | :sender_key
  def handle_retry_request(%DecryptionError{device_id: device}, local_device_id, _record)
      when device != local_device_id,
      do: :ignore

  def handle_retry_request(%DecryptionError{ratchet_key: nil}, _local_device_id, _record),
    do: :sender_key

  def handle_retry_request(%DecryptionError{ratchet_key: key}, _local_device_id, record) do
    case record do
      %Session.Record{current: %{sender: %{public: ^key}}} ->
        {:reset_session, Session.Record.archive_current(record)}

      _ ->
        :keep_session
    end
  end

  @doc "True when `hint` is the implicit content hint (CRS-06 §5.1)."
  @spec implicit?(non_neg_integer()) :: boolean()
  def implicit?(hint), do: hint == Inner.hint(:implicit)
end
