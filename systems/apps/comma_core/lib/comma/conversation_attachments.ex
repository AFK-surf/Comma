defmodule Comma.ConversationAttachments do
  @moduledoc """
  Downloads for the files an agent attached to a conversation message.

  A caller names a message it can already read and the attachment's position in
  that message. Comma returns authorized canonical Salix Message content,
  including its workspace path and owner-bound immutable blob ref. This endpoint
  authorizes the Conversation and resolves the exact sent attachment; it does
  not turn a caller-supplied workspace path into a download capability.
  """

  @max_download_bytes 10_000_000
  @max_file_name_bytes 1_024
  @default_content_type "application/octet-stream"
  @downloadable_types ["file", "image", "dynamic_ui"]

  @doc """
  Bytes for attachment `index` of `message_id`, or `{:error, :not_found}` when
  that position holds no attachment the sender made downloadable.
  """
  def fetch(group_scope, conversation_id, message_id, index)
      when is_map(group_scope) and is_binary(conversation_id) and is_binary(message_id) and
             is_integer(index) and index >= 0 do
    with {:ok, messages} <-
           Comma.Salix.Client.impl().get_group_conversation_messages(group_scope, conversation_id),
         {:ok, message} <- find_message(messages, conversation_id, message_id) do
      fetch_message(group_scope, message, index)
    end
  end

  def fetch(_group_scope, _conversation_id, _message_id, _index), do: {:error, :not_found}

  @doc """
  Bytes for attachment `index` of one canonical `message` the caller already
  read under its own authorization.
  """
  def fetch_message(group_scope, message, index)
      when is_map(group_scope) and is_map(message) and is_integer(index) and index >= 0 do
    with {:ok, block} <- attachment_block(message, index),
         {:ok, body} <- read_blob(group_scope, message, block) do
      {:ok, content_type(block), file_name(block), body}
    end
  end

  def fetch_message(_group_scope, _message, _index), do: {:error, :not_found}

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
  defp find_message(messages, _conversation_id, message_id) when is_list(messages) do
    messages
    |> Enum.find(&(&1["message_id"] == message_id))
    |> case do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  defp find_message(_messages, _conversation_id, _message_id), do: {:error, :not_found}

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
  defp read_blob(group_scope, message, block) do
    case message["agent_id"] do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        Comma.Salix.Client.impl().read_agent_blob(
          group_scope,
          agent_id,
          block["blob_ref"],
          @max_download_bytes
        )

      _missing ->
        {:error, :not_found}
    end
  end

  # A ref whose size or identity is missing would stream zero bytes rather than
  # fail, so an incomplete ref is not an attachment.
  defp valid_blob_ref?(ref) when is_map(ref) do
    is_binary(ref["uuid"]) and ref["uuid"] != "" and
      is_binary(ref["hash"]) and ref["hash"] != "" and
      is_integer(ref["size"]) and ref["size"] >= 0 and
      ref["size"] <= @max_download_bytes
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

  # The HTTP download filename uses the sender's name or workspace basename.
  # Canonical Message content separately retains its original path.
  defp file_name(block) do
    [block["file_name"], block["title"], Path.basename(to_string(block["path"] || ""))]
    |> Enum.map(&String.trim(to_string(&1 || "")))
    |> Enum.find("attachment", &(&1 != "" and &1 not in [".", "..", "/"]))
    |> Path.basename()
  end
end
