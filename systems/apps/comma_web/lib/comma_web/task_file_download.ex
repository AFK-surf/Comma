defmodule CommaWeb.TaskFileDownload do
  @moduledoc """
  Range-enabled streaming download for files in a Collaborative Task's `/task/`
  folder, shared by authenticated (`/v1/comma/collaborations/:group_id/:task_id/files?path=...`)
  and external guest (`/v1/comma/public/collaborations/task/files/download?path=...`)
  endpoints.

  Reuses `CommaWeb.AttachmentDownload.byte_range/2` and streams directly from
  `SalixStore.Blob.stream/2,3` without loading the file into RAM.
  """

  import Plug.Conn

  alias CommaWeb.AttachmentDownload
  alias SalixStore.Blob

  @spec send(Plug.Conn.t(), %{
          agent_id: String.t(),
          ref: map(),
          size: non_neg_integer(),
          path: String.t()
        }) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def send(conn, %{agent_id: agent_id, ref: ref, size: size, path: path} = file) do
    case AttachmentDownload.byte_range(get_req_header(conn, "range"), size) do
      :unsatisfiable ->
        {:ok,
         conn
         |> put_security_headers(path)
         |> put_resp_header("accept-ranges", "bytes")
         |> put_resp_header("content-range", "bytes */#{size}")
         |> send_resp(416, "")}

      nil ->
        with {:ok, stream, _total} <- Blob.stream(agent_id, ref) do
          {:ok, conn |> put_headers(file, nil) |> send_stream(200, stream)}
        end

      {first, last} = range ->
        with {:ok, stream, _total} <- Blob.stream(agent_id, ref, {first, last - first + 1}) do
          {:ok, conn |> put_headers(file, range) |> send_stream(206, stream)}
        end
    end
  end

  defp put_headers(conn, %{path: path, size: size}, range) do
    type = MIME.from_path(path)
    inline? = type in ~w(image/png image/jpeg image/gif image/webp)

    conn =
      conn
      |> put_security_headers(path)
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_content_type(if(inline?, do: type, else: "application/octet-stream"), nil)

    case range do
      nil ->
        put_resp_header(conn, "content-length", Integer.to_string(size))

      {first, last} ->
        conn
        |> put_resp_header("content-length", Integer.to_string(last - first + 1))
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
    end
  end

  defp put_security_headers(conn, path) do
    type = MIME.from_path(path)
    inline? = type in ~w(image/png image/jpeg image/gif image/webp)

    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> put_resp_header(
      "content-disposition",
      if(inline?, do: "inline", else: "attachment") <>
        "; filename*=UTF-8''" <> URI.encode(Path.basename(path), &URI.char_unreserved?/1)
    )
  end

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
