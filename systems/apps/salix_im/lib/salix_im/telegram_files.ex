defmodule SalixIM.TelegramFiles do
  @moduledoc """
  Telegram Bot API media -> existing provider attachment staging boundary.

  The Bot API has no official Elixir SDK. This narrow Req adapter follows the
  existing Telegram adapter and streams through Blob, which SDK download helpers
  do not own. Neither bot-token URLs nor provider errors enter model metadata.
  One message stages one original resource (photo sizes are alternatives).
  """

  alias SalixStore.Blob

  @max_bytes 20 * 1024 * 1024

  def attachments(connect, message) do
    case resource(message) do
      nil ->
        []

      {file, fallback, mime} ->
        name = file["file_name"] || fallback

        safe_name =
          name
          |> Path.basename()
          |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
          |> String.slice(0, 160)

        # Distinct messages/files with identical display names must not overwrite
        # one another. This storage locator is not an authorization credential.
        source = [
          connect["connect_id"],
          get_in(message, ["chat", "id"]),
          message["message_id"],
          file["file_id"]
        ]

        digest =
          source
          |> Jason.encode!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.url_encode64(padding: false)

        [
          %{
            "path" => "/telegram/attachments/#{digest}-#{safe_name}",
            "file_name" => safe_name,
            "mime" => file["mime_type"] || mime,
            "size" => file["file_size"],
            "to_blob" => fn agent_id -> download(agent_id, connect["bot_token"], file) end
          }
        ]
    end
  end

  defp resource(message) do
    photo = message["photo"] |> List.wrap() |> Enum.filter(&is_map/1)

    cond do
      photo != [] ->
        {Enum.max_by(photo, &((&1["width"] || 0) * (&1["height"] || 0))), "photo.jpg",
         "image/jpeg"}

      is_map(message["voice"]) ->
        {message["voice"], "voice.ogg", "audio/ogg"}

      is_map(message["audio"]) ->
        {message["audio"], "audio.mp3", "audio/mpeg"}

      is_map(message["document"]) ->
        {message["document"], "document", "application/octet-stream"}

      is_map(message["video"]) ->
        {message["video"], "video.mp4", "video/mp4"}

      is_map(message["video_note"]) ->
        {message["video_note"], "video.mp4", "video/mp4"}

      is_map(message["animation"]) ->
        {message["animation"], "animation.mp4", "video/mp4"}

      true ->
        nil
    end
  end

  defp download(agent_id, token, file) do
    with :ok <- size_allowed(file["file_size"]),
         {:ok, info} <- get_file(token, file["file_id"]),
         :ok <- size_allowed(info["file_size"]),
         {:ok, path} <- download_path(info["file_path"]) do
      stream(agent_id, "#{api_base()}/file/bot#{token}/#{path}")
    end
  end

  defp get_file(token, id) when is_binary(token) and is_binary(id) and id != "" do
    case Req.post("#{api_base()}/bot#{token}/getFile",
           json: %{"file_id" => id},
           retry: false,
           redirect: false
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => info}}} when is_map(info) ->
        {:ok, info}

      _ ->
        {:error, :telegram_file_unavailable}
    end
  end

  defp get_file(_token, _id), do: {:error, :telegram_file_unavailable}

  # The authenticated provider supplies a relative path, never a redirect or
  # arbitrary URL. Reject absolute/escaped/traversal paths before adding token.
  defp download_path(path) when is_binary(path) and path != "" do
    segments = String.split(path, "/")

    if Enum.all?(
         segments,
         &(&1 not in ["", ".", ".."] and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, &1))
       ), do: {:ok, path}, else: {:error, :invalid_telegram_file_path}
  end

  defp download_path(_), do: {:error, :invalid_telegram_file_path}

  defp size_allowed(size) when is_integer(size) and size > @max_bytes,
    do: {:error, {:size_limit, size, @max_bytes}}

  defp size_allowed(_), do: :ok

  defp stream(agent_id, url) do
    state_key = {__MODULE__, make_ref()}
    Process.put(state_key, Blob.put_stream_init(agent_id))

    try do
      result =
        Req.get(url,
          retry: false,
          redirect: false,
          decode_body: false,
          into: fn {:data, chunk}, {req, resp} ->
            size = (resp.private[:telegram_bytes] || 0) + byte_size(chunk)

            cond do
              resp.status != 200 ->
                {:halt, {req, resp}}

              size > @max_bytes ->
                {:halt,
                 {req,
                  Req.Response.put_private(resp, :telegram_error, {:size_limit, size, @max_bytes})}}

              true ->
                case Blob.put_stream_step(Process.get(state_key), chunk) do
                  {:ok, state} ->
                    Process.put(state_key, state)
                    {:cont, {req, Req.Response.put_private(resp, :telegram_bytes, size)}}

                  {:error, _reason, state} ->
                    Process.put(state_key, state)

                    {:halt,
                     {req,
                      Req.Response.put_private(
                        resp,
                        :telegram_error,
                        :telegram_file_storage_unavailable
                      )}}
                end
            end
          end
        )

      case result do
        {:ok, %{status: 200} = resp} ->
          if error = resp.private[:telegram_error] do
            Blob.put_stream_abort(Process.get(state_key))
            {:error, error}
          else
            with {:ok, ref} <- Blob.put_stream_finish(Process.get(state_key)) do
              {:ok, %{ref: ref, size: resp.private[:telegram_bytes] || 0}}
            end
          end

        _ ->
          Blob.put_stream_abort(Process.get(state_key))
          {:error, :telegram_file_unavailable}
      end
    rescue
      _ ->
        Blob.put_stream_abort(Process.get(state_key))
        {:error, :telegram_file_unavailable}
    after
      Process.delete(state_key)
    end
  end

  defp api_base do
    Application.get_env(:salix_im, :telegram_api_base_url, "https://api.telegram.org")
    |> String.trim_trailing("/")
  end
end
