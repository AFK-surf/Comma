defmodule SalixIM.FeishuFiles do
  @moduledoc """
  Streams Feishu message resources into the agent VFS.

  Feishu limits message resources to 100 MB. Downloads are streamed through
  SalixStore.Blob with backpressure and never buffered as one BEAM binary.
  """

  alias SalixStore.Blob
  alias SalixIM.Ports.AgentWorkspace
  alias SalixIM.Provider.Feishu.API

  @default_max_bytes 100 * 1024 * 1024
  @max_error_body_bytes 64 * 1024

  @spec max_bytes() :: pos_integer()
  def max_bytes,
    do: Application.get_env(:salix_im, :feishu_file_max_bytes, @default_max_bytes)

  @spec inbound_path(String.t(), String.t(), map()) :: String.t()
  def inbound_path(chat_id, message_id, attachment) do
    source = opaque_id([chat_id, message_id, attachment["file_key"]])
    "/feishu/attachments/#{source}-#{basename(attachment)}"
  end

  @spec file_vfs_path(String.t(), String.t(), map(), String.t()) :: String.t()
  def file_vfs_path(message_id, file_key, attachment, mime_type \\ "") do
    source = opaque_id([message_id, file_key])

    attachment =
      if String.trim(to_string(mime_type || "")) == "",
        do: attachment,
        else: Map.put(attachment, "mime_type", mime_type)

    "/feishu/files/#{source}-#{basename(attachment)}"
  end

  @spec stage(
          String.t(),
          map(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:ok, map()} | {:error, term()}
  def stage(agent_id, connect, message_id, file_key, resource_type, attachment) do
    with {:ok, resource} <-
           stream_to_blob(agent_id, connect, message_id, file_key, resource_type),
         path <-
           file_vfs_path(
             message_id,
             file_key,
             Map.put(
               attachment,
               "file_name",
               first([resource.file_name, attachment["file_name"]])
             ),
             resource.mime_type
           ),
         {:ok, _} <- AgentWorkspace.put_ref(agent_id, path, resource.ref) do
      {:ok,
       %{
         "vfs_path" => path,
         "file_name" =>
           first([
             resource.file_name,
             attachment["file_name"],
             attachment["name"],
             Path.basename(path)
           ]),
         "mime_type" => resource.mime_type,
         "size" => resource.size
       }}
    end
  end

  @spec stream_to_blob(
          String.t(),
          map(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok,
           %{
             ref: Blob.ref(),
             mime_type: String.t(),
             file_name: String.t(),
             size: non_neg_integer()
           }}
          | {:error, term()}
  def stream_to_blob(agent_id, connect, message_id, file_key, resource_type) do
    init = Blob.put_stream_init(agent_id)
    state_key = {__MODULE__, :blob_state, make_ref()}
    Process.put(state_key, init)

    try do
      result =
        API.stream_message_resource(
          connect,
          message_id,
          file_key,
          resource_type,
          fn {:data, chunk}, {req, resp} ->
            state = resp.private[:blob_state] || Process.get(state_key) || init
            bytes = resp.private[:feishu_download_bytes] || 0
            next_bytes = bytes + byte_size(chunk)

            cond do
              resp.status not in 200..299 ->
                error_body =
                  (resp.private[:feishu_error_body] || "")
                  |> Kernel.<>(chunk)
                  |> binary_part(
                    0,
                    min(
                      byte_size((resp.private[:feishu_error_body] || "") <> chunk),
                      @max_error_body_bytes
                    )
                  )

                {:cont, {req, Req.Response.put_private(resp, :feishu_error_body, error_body)}}

              resp.private[:blob_error] != nil ->
                {:halt, {req, resp}}

              next_bytes > max_bytes() ->
                Process.put(state_key, state)

                resp =
                  resp
                  |> Req.Response.put_private(:blob_state, state)
                  |> Req.Response.put_private(
                    :blob_error,
                    "Feishu message resource exceeds the #{max_bytes()} byte staging limit"
                  )

                {:halt, {req, resp}}

              true ->
                case Blob.put_stream_step(state, chunk) do
                  {:ok, state} ->
                    Process.put(state_key, state)

                    resp =
                      resp
                      |> Req.Response.put_private(:blob_state, state)
                      |> Req.Response.put_private(:feishu_download_bytes, next_bytes)

                    {:cont, {req, resp}}

                  {:error, reason, state} ->
                    Process.put(state_key, state)

                    resp =
                      resp
                      |> Req.Response.put_private(:blob_state, state)
                      |> Req.Response.put_private(:blob_error, reason)

                    {:halt, {req, resp}}
                end
            end
          end
        )

      finish_stream(result, Process.get(state_key) || init)
    after
      Process.delete(state_key)
    end
  end

  defp finish_stream({:ok, resp}, latest_state) do
    state = resp.private[:blob_state] || latest_state
    bytes = resp.private[:feishu_download_bytes] || 0

    cond do
      resp.status not in 200..299 ->
        Blob.put_stream_abort(state)
        {:error, download_error(resp)}

      resp.private[:blob_error] != nil ->
        Blob.put_stream_abort(state)
        {:error, resp.private[:blob_error]}

      true ->
        case Blob.put_stream_finish(state) do
          {:ok, ref} ->
            {:ok,
             %{
               ref: ref,
               mime_type: response_header(resp, "content-type", "application/octet-stream"),
               file_name: response_filename(resp),
               size: bytes
             }}

          {:error, _} = error ->
            error
        end
    end
  end

  defp finish_stream({:error, reason}, latest_state) do
    Blob.put_stream_abort(latest_state)
    {:error, "Feishu resource download failed: #{inspect(reason)}"}
  end

  defp download_error(resp) do
    body = decode_error_body(resp.private[:feishu_error_body] || resp.body)

    case body do
      %{"code" => code, "msg" => msg} -> API.provider_error(code, msg, resp.status)
      _ -> "Feishu resource download HTTP #{resp.status}"
    end
  end

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_error_body(body), do: body

  defp response_header(resp, name, fallback) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> value |> String.split(";") |> hd() |> String.trim()
      _ -> fallback
    end
  end

  defp response_filename(resp) do
    disposition = response_header_raw(resp, "content-disposition", "")

    cond do
      match = Regex.run(~r/filename\*=UTF-8''([^;]+)/i, disposition) ->
        match |> List.last() |> URI.decode() |> Path.basename()

      match = Regex.run(~r/filename="([^"]+)"/i, disposition) ->
        match |> List.last() |> Path.basename()

      match = Regex.run(~r/filename=([^;]+)/i, disposition) ->
        match |> List.last() |> String.trim() |> Path.basename()

      true ->
        ""
    end
  end

  defp response_header_raw(resp, name, fallback) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> String.trim(value)
      _ -> fallback
    end
  end

  defp basename(attachment) do
    raw = first([attachment["file_name"], attachment["name"], "attachment"])
    base = raw |> Path.rootname() |> path_segment("attachment")
    mime_extension = mime_ext(attachment["mime_type"])
    file_extension = raw |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    # Feishu image events use a synthetic `image.png` name even when the
    # resource response says WebP/JPEG. The authenticated response MIME is the
    # stronger signal; retain the filename suffix only for unknown MIME types.
    ext = mime_extension || file_extension

    if ext in [nil, ""], do: base, else: base <> "." <> path_segment(ext, "bin")
  end

  defp mime_ext("image/png"), do: "png"
  defp mime_ext("image/jpeg"), do: "jpg"
  defp mime_ext("image/gif"), do: "gif"
  defp mime_ext("image/webp"), do: "webp"
  defp mime_ext("image/bmp"), do: "bmp"
  defp mime_ext("application/pdf"), do: "pdf"
  defp mime_ext("audio/mpeg"), do: "mp3"
  defp mime_ext("audio/wav"), do: "wav"
  defp mime_ext("video/mp4"), do: "mp4"
  defp mime_ext(_mime), do: nil

  defp opaque_id(parts) do
    parts
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 20)
  end

  defp path_segment(value, fallback) do
    cleaned =
      value
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.trim("_")

    if cleaned == "", do: fallback, else: cleaned
  end

  defp first(values) do
    values
    |> Enum.map(&(to_string(&1 || "") |> String.trim()))
    |> Enum.find("", &(&1 != ""))
  end
end
