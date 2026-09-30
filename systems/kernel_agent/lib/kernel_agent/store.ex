defmodule KernelAgent.Store do
  @moduledoc """
  Local-filesystem storage: one compare-and-swap object store for the session
  snapshot, and one append-only log per conversation for delivered messages.

  The kernel names the snapshot key and encodes the bytes. This module only
  reads and writes files. The ETag is the SHA-256 of the stored bytes.
  """

  @doc "`{:ok, bytes, etag}` or `{:error, :not_found}`."
  def read(root, key) do
    case File.read(object_path(root, key)) do
      {:ok, bytes} -> {:ok, bytes, etag(bytes)}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes `bytes` at `key` when the current ETag is `base` (`nil` for absent).
  Returns `{:ok, etag, :written}` or `{:error, :precondition_failed}`.
  """
  def cas(root, key, bytes, base) do
    path = object_path(root, key)

    case File.read(path) do
      {:ok, stored} -> write_if(path, bytes, etag(stored) == base)
      {:error, :enoent} -> write_if(path, bytes, base == nil)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_if(_path, _bytes, false), do: {:error, :precondition_failed}

  defp write_if(path, bytes, true) do
    atomic_write(path, bytes)
    {:ok, etag(bytes), :written}
  end

  @doc "Appends one JSON line to the conversation's outbound log."
  def append_message(root, conversation_id, message) do
    path = conversation_path(root, conversation_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [JSON.encode!(message), ?\n], [:append])
  end

  @doc "The conversation's outbound messages, oldest first."
  def messages(root, conversation_id) do
    case File.read(conversation_path(root, conversation_id)) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  def workspace(root), do: Path.join(root, "workspace")

  defp object_path(root, key), do: Path.join([root, "objects", key])

  defp conversation_path(root, conversation_id),
    do:
      Path.join([
        root,
        "conversations",
        Base.url_encode64(conversation_id, padding: false) <> ".jsonl"
      ])

  defp atomic_write(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, bytes, [:sync])
    File.rename!(tmp, path)
  end

  defp etag(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
