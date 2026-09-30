defmodule SalixIM.ConversationAttachments do
  @moduledoc """
  Owner-bound file references and receiving Agent workspace projections.

  Delivery preparation and its bounded retry outcome are modeled in
  tla/salix/AttachmentMaterialization.tla; ParticipantActor remains the owner.
  """

  alias SalixIM.Conversations
  alias SalixIM.Ports.AgentWorkspace

  @max_download_bytes 10_000_000
  @max_file_name_bytes 1_024

  @doc """
  Reads one immutable attachment from an already authorized group's Message.

  Only Agent messages carry the agent-send binding authority. Other senders
  may persist arbitrary content metadata, including blob_ref and agent_id.
  The exact canonical Message is the capability; an Agent workspace path or
  a caller-supplied ref is never a download target. Bytes are consumed here
  before crossing a product RPC boundary. No storage or lifecycle is mutated.
  """
  def fetch(group_id, conversation_id, message_id, index)
      when is_binary(group_id) and is_binary(conversation_id) and is_binary(message_id) and
             is_integer(index) and index >= 0 do
    with {:ok, message} <-
           Conversations.get_group_conversation_message(group_id, conversation_id, message_id),
         %{"actor_type" => "agent", "agent_id" => agent_id, "content" => content}
         when is_binary(agent_id) and agent_id != "" and is_list(content) <- message,
         %{"type" => type, "blob_ref" => %{"size" => size} = ref} = block
         when type in ["file", "image", "dynamic_ui"] and is_integer(size) and size >= 0 <-
           Enum.at(content, index),
         :ok <- download_size(size),
         {:ok, filename} <- download_filename(block),
         {:ok, stream, actual_size, _filename} <-
           AgentWorkspace.read_ref_stream(agent_id, ref, filename),
         :ok <- download_size(actual_size),
         {:ok, body} <- read_download_stream(stream) do
      {:ok, %{filename: filename, body: body}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def fetch(_group_id, _conversation_id, _message_id, _index), do: {:error, :not_found}

  defp download_size(size) when is_integer(size) and size >= 0 and size <= @max_download_bytes,
    do: :ok

  defp download_size(size) when is_integer(size) and size > @max_download_bytes,
    do: {:error, :too_large}

  defp download_size(_), do: {:error, :not_found}

  defp download_filename(block) do
    filename =
      [block["file_name"], block["title"], path(block)]
      |> Enum.find("attachment", &(is_binary(&1) and String.trim(&1) != ""))
      |> Path.basename()

    if filename not in ["", ".", "..", "/"] and byte_size(filename) <= @max_file_name_bytes,
      do: {:ok, filename},
      else: {:error, :not_found}
  end

  defp read_download_stream(stream) do
    stream
    |> Enum.reduce_while({[], 0}, fn
      chunk, {chunks, total} when is_binary(chunk) ->
        case download_size(total + byte_size(chunk)) do
          :ok -> {:cont, {[chunk | chunks], total + byte_size(chunk)}}
          error -> {:halt, error}
        end

      _chunk, _acc ->
        {:halt, {:error, :attachment_unavailable}}
    end)
    |> case do
      {:error, _reason} = error -> error
      {chunks, _size} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  rescue
    _error -> {:error, :attachment_unavailable}
  catch
    _kind, _reason -> {:error, :attachment_unavailable}
  end

  def bind_sender_files(agent_id, content) when is_list(content),
    do: map(content, fn block, _index -> bind(agent_id, block) end)

  def bind_sender_files(_agent_id, content), do: {:ok, content}

  def materialize_messages(agent_id, messages) when is_list(messages),
    do: map(messages, fn message, _index -> materialize_message(agent_id, message, :read) end)

  def materialize_delivery(agent_id, %{
        "source_actor_type" => "agent",
        "source_agent_id" => source_agent_id,
        "message_id" => message_id,
        "message_content" => content
      }) do
    message = %{
      "actor_type" => "agent",
      "agent_id" => source_agent_id,
      "message_id" => message_id,
      "content" => content
    }

    with {:ok, message} <- materialize_message(agent_id, message, :delivery),
         do: {:ok, message["content"]}
  end

  def materialize_delivery(_agent_id, %{"message_content" => content}), do: {:ok, content}

  defp bind(_agent_id, block) when not is_map(block), do: {:ok, block}

  # ui_ref projects the original blob identity. A mutable VFS path must not
  # silently substitute another version between creation and explicit send.
  # The owning workspace still authorizes the read; the reference grants nothing.
  defp bind(agent_id, %{"type" => "dynamic_ui"} = block) do
    with {:ok, %{"uuid" => uuid} = ref} <- AgentWorkspace.file_ref(agent_id, path(block)),
         true <- uuid == block["ui_ref"] do
      {:ok, Map.put(block, "blob_ref", ref)}
    else
      false -> {:error, "UI content changed. Create a new UI version before sending it."}
      {:error, reason} -> error(path(block), reason)
      _ -> {:error, "UI content requires its original file in the sender workspace."}
    end
  end

  defp bind(agent_id, %{"type" => "file"} = block) do
    case path(block) do
      "" ->
        {:error,
         "File attachments require a non-empty top-level path in the Agent VFS. " <>
           ~s(Use {"type":"file","path":"/artifacts/report.pdf","file_name":"report.pdf"}. ) <>
           "Copy files from a host or remote environment into your own Agent VFS first. " <>
           "file_ref and a supplied blob_ref cannot replace path."}

      _path ->
        bind_path(agent_id, block)
    end
  end

  defp bind(agent_id, block), do: bind_path(agent_id, block)

  defp bind_path(agent_id, block) do
    case path(block) do
      "" ->
        {:ok, Map.delete(block, "blob_ref")}

      path ->
        case AgentWorkspace.file_ref(agent_id, path) do
          {:ok, ref} -> {:ok, Map.put(block, "blob_ref", ref)}
          {:error, reason} -> error(path, reason)
        end
    end
  end

  defp materialize_message(
         agent_id,
         %{
           "actor_type" => "agent",
           "agent_id" => source_agent_id,
           "message_id" => message_id,
           "content" => content
         } = message,
         mode
       )
       when is_list(content) do
    with {:ok, content} <-
           map(content, fn block, index ->
             materialize(agent_id, source_agent_id, message_id, index, block, mode)
           end),
         do: {:ok, Map.put(message, "content", content)}
  end

  defp materialize_message(_agent_id, message, _mode), do: {:ok, message}

  defp materialize(agent_id, source_agent_id, message_id, index, block, mode) do
    source_path = path(block)

    cond do
      source_path == "" or source_agent_id == agent_id ->
        {:ok, Map.delete(block, "blob_ref")}

      true ->
        immutable_ref? = is_map(block["blob_ref"])

        with {:ok, ref} <- ref(source_agent_id, source_path, block["blob_ref"]),
             target_path = target_path(message_id, index, block, source_path),
             {:ok, _file} <-
               AgentWorkspace.put_ref(agent_id, target_path, ref, preserve_error: true) do
          {:ok, block |> put_path(target_path) |> Map.delete("blob_ref")}
        else
          {:error, _reason} when not immutable_ref? ->
            {:ok, Map.delete(block, "blob_ref")}

          {:error, reason} when mode == :delivery ->
            {:error, {:conversation_attachment, source_path, reason}}

          {:error, reason} ->
            error(source_path, reason)
        end
    end
  end

  defp ref(_agent_id, _path, %{} = ref), do: {:ok, ref}
  defp ref(agent_id, path, _ref), do: AgentWorkspace.file_ref(agent_id, path)

  defp path(%{"type" => type, "path" => path})
       when type in ["file", "dynamic_ui"] and is_binary(path),
       do: String.trim(path)

  defp path(%{
         "type" => "image",
         "file_ref" => %{"environment_id" => "vfs", "path" => path}
       })
       when is_binary(path),
       do: String.trim(path)

  defp path(%{"type" => "image", "path" => path}) when is_binary(path),
    do: String.trim(path)

  defp path(_block), do: ""

  defp put_path(%{"type" => "image"} = block, path),
    do:
      block
      |> Map.put("file_ref", %{"environment_id" => "vfs", "path" => path})
      |> Map.delete("path")

  defp put_path(block, path), do: Map.put(block, "path", path)

  defp target_path(message_id, index, block, source_path) do
    filename =
      (block["file_name"] || block["title"] || Path.basename(source_path))
      |> to_string()
      |> Path.basename()
      |> String.replace(~r/[^\p{L}\p{N}._ -]+/u, "_")
      |> String.slice(0, 120)

    filename = if filename == "", do: "attachment", else: filename
    "/.conversation-attachments/#{message_id}/#{index}-#{filename}"
  end

  @doc false
  def error_message(path, reason),
    do: "cannot share Conversation attachment #{path}: #{inspect(reason)}"

  defp error(path, reason), do: {:error, error_message(path, reason)}

  defp map(items, fun) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case fun.(item, index) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      error -> error
    end
  end
end
