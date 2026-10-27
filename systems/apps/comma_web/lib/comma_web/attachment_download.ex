defmodule CommaWeb.AttachmentDownload do
  @moduledoc """
  Sends a message attachment that `Comma.ConversationAttachments` opened: whole,
  or the one byte range a `Range` header names. A media element reads a video in
  ranges, so it plays and seeks without the whole file. The bytes stream from
  the blob store as they are read; nothing holds the file in memory.

  The caller authorizes the read and adds its own caching and policy headers
  first. A failure before the first byte is returned for the caller to answer;
  one after the headers went can only end the response early, short of its
  `content-length`.
  """

  import Plug.Conn

  alias Comma.ConversationAttachments

  @spec send(Plug.Conn.t(), map()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def send(conn, %{size: size} = attachment) do
    case byte_range(get_req_header(conn, "range"), size) do
      :unsatisfiable ->
        {:ok,
         conn
         |> put_resp_header("content-range", "bytes */#{size}")
         |> send_resp(416, "")}

      nil ->
        with {:ok, stream} <- ConversationAttachments.stream(attachment, nil) do
          {:ok, conn |> put_headers(attachment, nil) |> send_stream(200, stream)}
        end

      {first, last} = range ->
        with {:ok, stream} <-
               ConversationAttachments.stream(attachment, {first, last - first + 1}) do
          {:ok, conn |> put_headers(attachment, range) |> send_stream(206, stream)}
        end
    end
  end

  @doc """
  The one `bytes=` range of a body of `size` bytes a `Range` header names, as
  `{first, last}` inclusive. No header, or one this does not serve (several
  ranges, another unit), is the whole body (`nil`), as HTTP allows.
  """
  @spec byte_range([String.t()], non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil | :unsatisfiable
  def byte_range([header], size) do
    case Regex.run(~r/\Abytes=(\d*)-(\d*)\z/, String.trim(header)) do
      [_, "", ""] -> nil
      [_, "", suffix] -> suffix_range(String.to_integer(suffix), size)
      [_, first, last] -> first_range(String.to_integer(first), last, size)
      nil -> nil
    end
  end

  def byte_range(_headers, _size), do: nil

  defp suffix_range(0, _size), do: :unsatisfiable
  defp suffix_range(_suffix, 0), do: :unsatisfiable
  defp suffix_range(suffix, size), do: {max(size - suffix, 0), size - 1}

  defp first_range(first, _last, size) when first >= size, do: :unsatisfiable
  defp first_range(first, "", size), do: {first, size - 1}

  defp first_range(first, last, size) do
    case String.to_integer(last) do
      last when last < first -> nil
      last -> {first, min(last, size - 1)}
    end
  end

  defp put_headers(conn, attachment, range) do
    conn =
      conn
      |> put_resp_header("content-type", attachment.content_type)
      |> put_resp_header("x-content-type-options", "nosniff")
      # The type is the sender's: opened as a page (a media URL any origin
      # reads), the body runs no script and reaches no origin.
      |> put_resp_header("content-security-policy", "sandbox")
      |> put_resp_header(
        "content-disposition",
        ConversationAttachments.content_disposition(attachment.file_name)
      )
      |> put_resp_header("accept-ranges", "bytes")

    case range do
      nil ->
        put_resp_header(conn, "content-length", Integer.to_string(attachment.size))

      {first, last} ->
        conn
        |> put_resp_header("content-length", Integer.to_string(last - first + 1))
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{attachment.size}")
    end
  end

  # With `content-length` set, Bandit streams the chunks as one sized body.
  defp send_stream(conn, status, stream) do
    conn = send_chunked(conn, status)

    try do
      Enum.reduce_while(stream, conn, fn bytes, conn ->
        case chunk(conn, bytes) do
          {:ok, conn} -> {:cont, conn}
          {:error, _closed} -> {:halt, conn}
        end
      end)
    rescue
      _error -> conn
    end
  end
end
