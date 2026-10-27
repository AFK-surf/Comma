defmodule Comma.ConversationAttachments do
  @moduledoc """
  Downloads for the files an agent attached to a conversation message.

  A caller names a message it can already read and the attachment's position in
  that message. Comma returns authorized canonical Salix Message content,
  including its workspace path and owner-bound immutable blob ref. This endpoint
  authorizes the Conversation and resolves the exact sent attachment; it does
  not turn a caller-supplied workspace path into a download capability.

  The bytes are streamed from the blob store in bounded chunks, whole or one
  byte range of them, so an attachment of any size downloads without being held
  in memory.
  """

  @max_file_name_bytes 1_024
  @media_ttl_seconds 60 * 60
  @default_content_type "application/octet-stream"
  @downloadable_types ["file", "image", "dynamic_ui"]

  @doc """
  Attachment `index` of `message_id`, ready to `stream/2`: its content type,
  file name and size. `{:error, :not_found}` when that position holds no
  attachment the sender made downloadable.
  """
  def open(group_scope, conversation_id, message_id, index)
      when is_map(group_scope) and is_binary(conversation_id) and is_binary(message_id) and
             is_integer(index) and index >= 0 do
    # One indexed read of the message, at any depth of the history: every media
    # URL and every ranged read opens the attachment again.
    case Comma.Salix.Client.get_group_conversation_message(
           group_scope,
           conversation_id,
           message_id
         ) do
      {:ok, %{"message_id" => ^message_id} = message} -> open_message(group_scope, message, index)
      {:ok, _other} -> {:error, :not_found}
      {:error, {:bad_request, _reason}} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def open(_group_scope, _conversation_id, _message_id, _index), do: {:error, :not_found}

  @doc """
  Attachment `index` of one canonical `message` the caller already read under
  its own authorization, ready to `stream/2`.
  """
  def open_message(group_scope, message, index)
      when is_map(group_scope) and is_map(message) and is_integer(index) and index >= 0 do
    with {:ok, block} <- attachment_block(message, index),
         {:ok, agent_id} <- sender_agent(message) do
      {:ok,
       %{
         content_type: content_type(block),
         file_name: file_name(block),
         size: block["blob_ref"]["size"],
         source: {group_scope, agent_id, block["blob_ref"]}
       }}
    end
  end

  def open_message(_group_scope, _message, _index), do: {:error, :not_found}

  @doc """
  The bytes of an attachment `open/4` gave, as they are read: all of them
  (`nil`), or `length` bytes from `offset`.
  """
  def stream(%{source: {group_scope, agent_id, blob_ref}}, range) do
    case Comma.Salix.Client.impl().stream_agent_blob(group_scope, agent_id, blob_ref, range) do
      {:ok, stream, _size} -> {:ok, stream}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  How long an attachment's media URL (`presign/2`) reads it. The store checks
  no session, so a URL keeps reading it this long after a sign-out, a
  revocation or lost membership; a client mints it again before it expires,
  while shown.
  """
  def media_ttl_seconds, do: @media_ttl_seconds

  @doc """
  A URL a client reads an attachment `open/4` gave from, straight from the
  blob store and in any byte ranges, for `expires_in` seconds: served as its
  content type and as a download under its file name.
  """
  def presign(%{source: {group_scope, agent_id, blob_ref}} = attachment, expires_in) do
    Comma.Salix.Client.presign_agent_blob(group_scope, agent_id, blob_ref,
      expires_in: expires_in,
      content_type: attachment.content_type,
      content_disposition: content_disposition(attachment.file_name)
    )
  end

  @doc "`Content-Disposition` of an attachment downloaded under `file_name`."
  def content_disposition(file_name),
    do: "attachment; filename*=UTF-8''" <> URI.encode(file_name, &URI.char_unreserved?/1)

  @doc "Download metadata of a block that `downloadable?/1` accepts."
  def describe(block) when is_map(block) do
    %{
      "file_name" => file_name(block),
      "mime_type" => content_type(block),
      "size" => block["blob_ref"]["size"]
    }
  end

  @doc """
  Whether this stored block meets the download metadata contract.

  The client mirrors this contract when offering a download. Passing these
  metadata checks does not prove the blob is currently readable; authorization
  and storage availability are still evaluated on the download request.
  """
  def downloadable?(%{"type" => type} = block) when type in @downloadable_types,
    do: valid_blob_ref?(block["blob_ref"]) and valid_file_name?(block)

  def downloadable?(_block), do: false

  @doc "Parses the `:index` path segment; anything else names no attachment."
  def parse_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {index, ""} when index >= 0 -> {:ok, index}
      _other -> {:error, :not_found}
    end
  end

  def parse_index(_value), do: {:error, :not_found}

  # Comma returns canonical Salix Message resources unchanged, so the client uses
  # the exact message id it was shown. Authorization of the Conversation read is
  # performed before this lookup.
  defp attachment_block(%{"content" => content}, index) when is_list(content) do
    case Enum.at(content, index) do
      block when is_map(block) ->
        if downloadable?(block), do: {:ok, block}, else: {:error, :not_found}

      _other ->
        {:error, :not_found}
    end
  end

  defp attachment_block(_message, _index), do: {:error, :not_found}

  # Blob storage uses global UUID keys. The sender Agent supplies the existing
  # group/Agent authorization context for this owner-bound ref, not a namespace.
  defp sender_agent(message) do
    case message["agent_id"] do
      agent_id when is_binary(agent_id) and agent_id != "" -> {:ok, agent_id}
      _missing -> {:error, :not_found}
    end
  end

  # A ref whose size or identity is missing would stream zero bytes rather than
  # fail, so an incomplete ref is not an attachment.
  defp valid_blob_ref?(ref) when is_map(ref) do
    is_binary(ref["uuid"]) and ref["uuid"] != "" and
      is_binary(ref["hash"]) and ref["hash"] != "" and
      is_integer(ref["size"]) and ref["size"] >= 0
  end

  defp valid_blob_ref?(_ref), do: false

  defp valid_file_name?(block), do: byte_size(file_name(block)) <= @max_file_name_bytes

  defp content_type(block) do
    case block["mime_type"] do
      mime when is_binary(mime) ->
        case String.trim(mime) do
          "" -> @default_content_type
          trimmed -> trimmed
        end

      _other ->
        @default_content_type
    end
  end

  defp file_name(block), do: SalixIM.ConversationAttachments.file_name(block)
end
