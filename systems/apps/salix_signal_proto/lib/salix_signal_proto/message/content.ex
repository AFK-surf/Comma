defmodule SalixSignalProto.Message.Content do
  @moduledoc """
  The content container (CRS-05 §5, §6): the plaintext that is padded and
  encrypted for one recipient device or a sender-key group.

  `decode/1` returns the wire struct (`SalixSignalProto.Message.Wire.Content`)
  with its main field classified. `validate/2` applies the receiver validity
  rules of CRS-05 §5.1 and §6. The builders return serialized content
  containers for the messages that Comma sends; their field order is ascending,
  as in `vectors/CRS-05/content-encoding.json`.

  ## Main field

  Fields 1, 2, 3, 4, 5, 6, 8, 9 and 11 are mutually exclusive. Field 7
  (sender key distribution) and field 10 (PNI signature) may accompany any of
  them or appear alone. A container without any field 1 to 11 is invalid,
  and Comma treats a container with more than one exclusive field as invalid.
  """

  import Bitwise

  alias SalixSignalProto.Attachment.Pointer
  alias SalixSignalProto.Message.Wire
  alias SalixSignalProto.ServiceId

  @body_limit 2048
  @long_text_type "text/x-signal-plain"

  @doc "The feature level Comma declares for received data messages (CRS-05 §5.3)."
  def protocol_version, do: 8

  @typedoc """
  The main field of a content container.
  """
  @type kind ::
          :data
          | :sync
          | :call
          | :null
          | :receipt
          | :typing
          | :decryption_error
          | :story
          | :edit
          | nil

  @exclusive [
    data: :data_message,
    sync: :sync_message,
    call: :call_message,
    null: :null_message,
    receipt: :receipt_message,
    typing: :typing_message,
    decryption_error: :decryption_error,
    story: :story_message,
    edit: :edit_message
  ]

  @doc """
  Decodes a content container. Returns `{:ok, kind, wire}` where `kind` is
  the main field (nil when only fields 7 or 10 are present).

  Errors: `:malformed` (not a protocol buffer of this schema), `:empty`
  (none of fields 1 to 11), `:conflicting` (more than one exclusive field).
  """
  @spec decode(binary()) ::
          {:ok, kind(), Wire.Content.t()} | {:error, :malformed | :empty | :conflicting}
  def decode(bytes) when is_binary(bytes) do
    case safe_decode(Wire.Content, bytes) do
      {:ok, wire} -> classify(wire)
      :error -> {:error, :malformed}
    end
  end

  defp classify(wire) do
    present = for {kind, field} <- @exclusive, Map.fetch!(wire, field) != nil, do: kind

    case present do
      [kind] ->
        {:ok, kind, wire}

      [] when wire.sender_key_distribution != nil or wire.pni_signature != nil ->
        {:ok, nil, wire}

      [] ->
        {:error, :empty}

      _more ->
        {:error, :conflicting}
    end
  end

  @doc false
  def safe_decode(module, bytes) do
    {:ok, module.decode(bytes)}
  rescue
    # The protobuf decoder raises on malformed input.
    _error -> :error
  end

  # --- validation ---------------------------------------------------------

  @doc """
  Applies the receiver validity rules (CRS-05 §5.1, §5.8, §6, CRS-07 §2) to
  a decoded container. `context`:

    * `:timestamp`: the envelope client timestamp;
    * `:from_self?`: true when the sender is the receiving account's own ACI
      (a sync message is valid only then, §6.4).

  Returns `:ok` or `{:error, reason}`; a receiver drops an invalid message.
  """
  @spec validate(kind(), Wire.Content.t(), %{
          timestamp: non_neg_integer() | nil,
          from_self?: boolean()
        }) ::
          :ok | {:error, atom()}
  def validate(kind, wire, context)

  def validate(nil, _wire, _context), do: :ok

  def validate(:data, %Wire.Content{data_message: data}, context),
    do: validate_data(data, context.timestamp)

  def validate(:edit, %Wire.Content{edit_message: edit}, context) do
    case edit do
      %Wire.EditMessage{
        original_message_timestamp: original,
        data_message: %Wire.DataMessage{} = data
      }
      when is_integer(original) ->
        validate_data(data, context.timestamp)

      _ ->
        {:error, :invalid_edit}
    end
  end

  def validate(:receipt, %Wire.Content{receipt_message: receipt}, _context) do
    if is_integer(receipt.kind), do: :ok, else: {:error, :invalid_receipt}
  end

  def validate(:typing, %Wire.Content{typing_message: typing}, context) do
    cond do
      typing.timestamp == nil or typing.action == nil -> {:error, :invalid_typing}
      typing.timestamp != context.timestamp -> {:error, :timestamp_mismatch}
      typing.group_id != nil and byte_size(typing.group_id) != 32 -> {:error, :invalid_typing}
      true -> :ok
    end
  end

  def validate(:sync, _wire, %{from_self?: true}), do: :ok
  def validate(:sync, _wire, _context), do: {:error, :sync_from_other_account}

  def validate(:decryption_error, %Wire.Content{decryption_error: bytes}, _context) do
    case SalixSignalProto.Message.DecryptionError.decode(bytes) do
      {:ok, _message} -> :ok
      {:error, _reason} -> {:error, :invalid_decryption_error}
    end
  end

  def validate(_kind, _wire, _context), do: :ok

  defp validate_data(%Wire.DataMessage{} = data, timestamp) do
    body = data.body || ""

    cond do
      data.timestamp == nil or data.timestamp != timestamp ->
        {:error, :timestamp_mismatch}

      byte_size(body) > @body_limit or not String.valid?(body) ->
        {:error, :invalid_body}

      not Enum.all?(data.attachments, &attachment_located?/1) ->
        {:error, :invalid_attachment}

      not acis_parse?(data) ->
        {:error, :invalid_aci}

      data.reaction != nil and data.reaction.target_message_timestamp == nil ->
        {:error, :invalid_reaction}

      data.remote_delete != nil and data.remote_delete.target_message_timestamp == nil ->
        {:error, :invalid_delete}

      data.group_v2 != nil and not valid_group_context?(data.group_v2) ->
        {:error, :invalid_group}

      not ranges_valid?(data, body) ->
        {:error, :invalid_body_range}

      true ->
        :ok
    end
  end

  defp attachment_located?(pointer), do: Pointer.valid?(pointer)

  defp acis_parse?(data) do
    quote_ok =
      case data.quote do
        nil ->
          true

        quote ->
          aci_ok?(quote.author_aci, quote.author_aci_string) and ranges_aci_ok?(quote.body_ranges)
      end

    reaction_ok =
      case data.reaction do
        nil -> true
        reaction -> aci_ok?(reaction.target_author_aci, reaction.target_author_aci_string)
      end

    story_ok =
      case data.story_context do
        nil -> true
        story -> aci_ok?(story.author_aci, story.author_aci_string)
      end

    quote_ok and reaction_ok and story_ok and ranges_aci_ok?(data.body_ranges)
  end

  defp ranges_aci_ok?(ranges),
    do: Enum.all?(ranges, &aci_ok?(&1.mention_aci, &1.mention_aci_string))

  # An absent ACI is not checked; a present one must parse.
  defp aci_ok?(nil, nil), do: true

  defp aci_ok?(binary, _string) when is_binary(binary),
    do: ServiceId.aci_from_binary(binary) != :error

  defp aci_ok?(nil, string), do: ServiceId.aci_from_string(string) != :error

  defp valid_group_context?(%Wire.GroupContext{master_key: <<_::binary-size(32)>>, revision: rev})
       when is_integer(rev),
       do: true

  defp valid_group_context?(_context), do: false

  defp ranges_valid?(data, body) do
    long_text? = Enum.any?(data.attachments, &(&1.content_type == @long_text_type))
    body_units = utf16_length(body)

    Enum.all?(data.body_ranges, fn range ->
      style_ok = range.style == nil or (range.start != nil and range.length != nil)
      bounds_ok = long_text? or (range.start || 0) + (range.length || 0) <= body_units
      style_ok and bounds_ok
    end)
  end

  @doc "The length of a UTF-8 string in UTF-16 code units."
  @spec utf16_length(String.t()) :: non_neg_integer()
  def utf16_length(string) do
    for <<codepoint::utf8 <- string>>, reduce: 0 do
      acc -> acc + if(codepoint > 0xFFFF, do: 2, else: 1)
    end
  end

  @doc """
  True when the data message needs a feature level above the one Comma
  declares (CRS-05 §5.3). The receiver then shows an "unsupported message"
  notice instead of processing it.
  """
  @spec unsupported?(Wire.DataMessage.t()) :: boolean()
  def unsupported?(%Wire.DataMessage{required_protocol_version: level}),
    do: is_integer(level) and level > protocol_version()

  # --- flags --------------------------------------------------------------

  @doc "Data message flag bit values (CRS-05 §5.2)."
  def flag(:expire_timer_update), do: 2
  def flag(:profile_key_update), do: 4
  def flag(:forwarded), do: 8

  @doc "True when data message `flags` has the flag set."
  @spec flag?(Wire.DataMessage.t(), atom()) :: boolean()
  def flag?(%Wire.DataMessage{flags: flags}, name), do: band(flags || 0, flag(name)) != 0

  # --- builders -----------------------------------------------------------

  @typedoc """
  Options shared by the data message builders:

    * `:profile_key`: the sender's 32-byte profile key (field 6);
    * `:expire_timer` and `:expire_timer_version`: the 1:1 conversation
      timer in seconds (0 = off, field 5 omitted) and its version (field 23);
      give both for 1:1 messages and neither for group messages;
    * `:group`: `%{master_key: 32 bytes, revision: n}` (field 15);
    * `:quote`: `%{timestamp, author_aci (16 bytes), text}` (field 8);
    * `:mentions`: `[%{start, length, aci}]` in UTF-16 code units;
    * `:styles`: `[%{start, length, style}]`, style 1 bold, 2 italic,
      3 spoiler, 4 strikethrough, 5 monospace;
    * `:attachments`: `SalixSignalProto.Attachment.Pointer` structs.
  """
  @type data_opts :: keyword()

  @doc "A text message. `body` is at most 2,048 bytes of UTF-8."
  @spec text(non_neg_integer(), String.t(), data_opts()) :: binary()
  def text(timestamp, body, opts \\ []) when is_binary(body) do
    %Wire.DataMessage{body: body, timestamp: timestamp}
    |> data_options(opts)
    |> data_content()
  end

  @doc """
  A reaction to the message `(target_author_aci, target_timestamp)`. With
  `remove: true` it removes this sender's earlier reaction.
  """
  @spec reaction(non_neg_integer(), String.t(), <<_::128>>, non_neg_integer(), data_opts()) ::
          binary()
  def reaction(
        timestamp,
        emoji,
        <<_::binary-size(16)>> = target_author_aci,
        target_timestamp,
        opts \\ []
      ) do
    {remove, opts} = Keyword.pop(opts, :remove, false)

    %Wire.DataMessage{
      timestamp: timestamp,
      reaction: %Wire.Reaction{
        emoji: emoji,
        remove: remove,
        target_message_timestamp: target_timestamp,
        target_author_aci: target_author_aci
      }
    }
    |> data_options(opts)
    |> data_content()
  end

  @doc "A remote delete of this sender's message sent at `target_timestamp`."
  @spec remote_delete(non_neg_integer(), non_neg_integer(), data_opts()) :: binary()
  def remote_delete(timestamp, target_timestamp, opts \\ []) do
    %Wire.DataMessage{
      timestamp: timestamp,
      remote_delete: %Wire.RemoteDelete{target_message_timestamp: target_timestamp}
    }
    |> data_options(opts)
    |> data_content()
  end

  @doc """
  An edit of the original message sent at `original_timestamp`: a
  replacement text message with its own new `timestamp` (CRS-05 §5.8).
  """
  @spec edit(non_neg_integer(), non_neg_integer(), String.t(), data_opts()) :: binary()
  def edit(timestamp, original_timestamp, body, opts \\ []) do
    data = data_options(%Wire.DataMessage{body: body, timestamp: timestamp}, opts)

    Wire.Content.encode(%Wire.Content{
      edit_message: %Wire.EditMessage{
        original_message_timestamp: original_timestamp,
        data_message: data
      }
    })
  end

  @doc """
  An expire timer update (flags bit 2) that sets the 1:1 timer to
  `seconds` (0 = off) with `version` (CRS-05 §5.2).
  """
  @spec expire_timer_update(non_neg_integer(), non_neg_integer(), non_neg_integer(), data_opts()) ::
          binary()
  def expire_timer_update(timestamp, seconds, version, opts \\ []) do
    %Wire.DataMessage{flags: flag(:expire_timer_update), timestamp: timestamp}
    |> data_options(Keyword.merge(opts, expire_timer: seconds, expire_timer_version: version))
    |> data_content()
  end

  @doc "A profile key update (flags bit 4) that delivers the 32-byte `profile_key`."
  @spec profile_key_update(non_neg_integer(), <<_::256>>) :: binary()
  def profile_key_update(timestamp, <<_::binary-size(32)>> = profile_key) do
    data_content(%Wire.DataMessage{
      flags: flag(:profile_key_update),
      profile_key: profile_key,
      timestamp: timestamp
    })
  end

  @doc "A receipt of `kind` (`:delivery`, `:read` or `:viewed`) for `timestamps`."
  @spec receipt(:delivery | :read | :viewed, [non_neg_integer()]) :: binary()
  def receipt(kind, timestamps) when is_list(timestamps) do
    Wire.Content.encode(%Wire.Content{
      receipt_message: %Wire.ReceiptMessage{kind: receipt_kind(kind), timestamps: timestamps}
    })
  end

  @doc "The receipt kind number (CRS-05 §6.1)."
  def receipt_kind(:delivery), do: 0
  def receipt_kind(:read), do: 1
  def receipt_kind(:viewed), do: 2

  @doc "A typing message: `:started` or `:stopped`, in a group when `group_id` is given."
  @spec typing(non_neg_integer(), :started | :stopped, <<_::256>> | nil) :: binary()
  def typing(timestamp, action, group_id \\ nil) do
    Wire.Content.encode(%Wire.Content{
      typing_message: %Wire.TypingMessage{
        timestamp: timestamp,
        action: if(action == :started, do: 0, else: 1),
        group_id: group_id
      }
    })
  end

  @doc "A null message with `padding` (CRS-05 §6.5)."
  @spec null_message(binary()) :: binary()
  def null_message(padding \\ :crypto.strong_rand_bytes(16)) when is_binary(padding) do
    Wire.Content.encode(%Wire.Content{null_message: %Wire.NullMessage{padding: padding}})
  end

  @doc """
  The feature level a sender declares for a data message (CRS-05 §5.3): 6
  with mention body ranges, 4 for a reaction, 3 for view once, otherwise 0.
  """
  @spec required_protocol_version(Wire.DataMessage.t()) :: non_neg_integer()
  def required_protocol_version(%Wire.DataMessage{} = data) do
    [
      if(Enum.any?(data.body_ranges, &(&1.mention_aci != nil or &1.mention_aci_string != nil)),
        do: 6,
        else: 0
      ),
      if(data.reaction != nil, do: 4, else: 0),
      if(data.view_once == true, do: 3, else: 0)
    ]
    |> Enum.max()
  end

  defp data_content(data), do: Wire.Content.encode(%Wire.Content{data_message: data})

  defp data_options(data, opts) do
    data = %{
      data
      | profile_key: Keyword.get(opts, :profile_key),
        attachments: Keyword.get(opts, :attachments, []),
        quote: quote_message(Keyword.get(opts, :quote)),
        group_v2: group(Keyword.get(opts, :group)),
        body_ranges: body_ranges(opts)
    }

    data =
      case Keyword.fetch(opts, :expire_timer_version) do
        {:ok, version} ->
          seconds = Keyword.get(opts, :expire_timer, 0)
          %{data | expire_timer: if(seconds > 0, do: seconds), expire_timer_version: version}

        :error ->
          data
      end

    case required_protocol_version(data) do
      0 -> data
      level -> %{data | required_protocol_version: level}
    end
  end

  defp quote_message(nil), do: nil

  defp quote_message(%{timestamp: timestamp, author_aci: <<_::binary-size(16)>> = author} = given) do
    %Wire.Quote{
      quoted_message_timestamp: timestamp,
      text: Map.get(given, :text),
      kind: 0,
      author_aci: author
    }
  end

  defp group(nil), do: nil

  defp group(%{master_key: <<_::binary-size(32)>> = key, revision: revision}),
    do: %Wire.GroupContext{master_key: key, revision: revision}

  defp body_ranges(opts) do
    mentions =
      for %{start: start, length: length, aci: <<_::binary-size(16)>> = aci} <-
            Keyword.get(opts, :mentions, []),
          do: %Wire.BodyRange{start: start, length: length, mention_aci: aci}

    styles =
      for %{start: start, length: length, style: style} <- Keyword.get(opts, :styles, []),
          do: %Wire.BodyRange{start: start, length: length, style: style}

    mentions ++ styles
  end
end
