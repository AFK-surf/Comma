defmodule SalixIM.Provider.WeChat do
  @moduledoc false

  import SalixIM.Provider.Util

  alias SalixIM.ProviderConnects

  @wechat_cdn_base_url "https://novac2c.cdn.weixin.qq.com/c2c"
  @wechat_message_type_bot 2
  @wechat_message_state_finish 2
  @wechat_item_type_text 1
  @wechat_item_type_image 2
  @wechat_item_type_file 4
  @wechat_item_type_video 5
  @wechat_upload_media_type_image 1
  @wechat_upload_media_type_video 2
  @wechat_upload_media_type_file 3
  @wechat_session_expired_errcode -14
  @wechat_api_timeout_ms 15_000
  # Connection-level failures (a stale pooled socket, a reset, a refused
  # connect) are retried with the same request body, so a replayed
  # sendmessage keeps its client_id. Receive timeouts are not retried: the
  # provider may already have accepted the message.
  @wechat_retryable_transport_reasons [:closed, :econnreset, :econnrefused]
  @wechat_max_retries 2

  # ---- WeChat dispatch ----

  def call(_agent_id, connect, "wechat.reply_text", params) do
    with :ok <- ensure_connected(connect),
         {:ok, ctx} <- wechat_reply_context(connect),
         {:ok, text} <- SalixIM.WeChatMarkdown.render(to_string_safe(params["text"])) do
      if text == "" do
        {:error, "text is required"}
      else
        wechat_deliver(connect, fn ->
          wechat_send_text(
            connect["base_url"],
            connect["token"],
            connect["wechat_id"],
            ctx,
            text,
            connect
          )
        end)
      end
    end
  end

  def call(agent_id, connect, api, params)
      when api in ["wechat.reply_image", "wechat.reply_file", "wechat.reply_video"] do
    with :ok <- ensure_connected(connect),
         {:ok, ctx} <- wechat_reply_context(connect),
         {:ok, caption} <- SalixIM.WeChatMarkdown.render(to_string_safe(params["caption"])),
         {:ok, upload} <- read_agent_upload(agent_id, params["path"], params["title"]) do
      send_fun =
        cond do
          api == "wechat.reply_image" and not wechat_image_upload?(upload.filename, upload.data) ->
            fn -> {:error, "path must point to an image file for wechat.reply_image"} end

          api == "wechat.reply_video" and not wechat_video_path?(params["path"]) ->
            fn -> {:error, "path must point to a video file for wechat.reply_video"} end

          api == "wechat.reply_video" ->
            fn ->
              wechat_send_media(
                connect["base_url"],
                connect["token"],
                connect["wechat_id"],
                ctx,
                caption,
                upload.filename,
                upload.data,
                @wechat_upload_media_type_video,
                @wechat_item_type_video,
                connect
              )
            end

          api == "wechat.reply_image" ->
            fn ->
              wechat_send_image(
                connect["base_url"],
                connect["token"],
                connect["wechat_id"],
                ctx,
                caption,
                upload.data,
                connect
              )
            end

          true ->
            fn ->
              wechat_send_file(
                connect["base_url"],
                connect["token"],
                connect["wechat_id"],
                ctx,
                upload.filename,
                caption,
                upload.data,
                connect
              )
            end
        end

      case wechat_deliver(connect, send_fun) do
        {:ok, result} -> {:ok, Map.put(result, "filename", upload.filename)}
        other -> other
      end
    end
  end

  def call(_agent_id, _connect, _api, _params),
    do: {:error, "unsupported WeChat provider api"}

  defp wechat_reply_context(connect) do
    case str(connect["latest_context_token"]) do
      "" -> {:error, "WeChat context_token is not available yet"}
      token -> {:ok, token}
    end
  end

  defp wechat_deliver(connect, fun) do
    case fun.() do
      {:ok, message_id} ->
        {:ok, %{"message_id" => message_id}}

      {:error, %Req.TransportError{reason: :timeout} = reason} ->
        {:error,
         %{
           "error_class" => "delivery_outcome_unknown",
           "message" => wechat_error_message(reason)
         }}

      {:error, reason} ->
        maybe_mark_wechat_error(connect, reason)
        {:error, wechat_error_message(reason)}
    end
  end

  defp maybe_mark_wechat_error(connect, reason) do
    if wechat_session_expired_error?(reason) do
      _ =
        ProviderConnects.mark_im_connect_error(
          connect["group_id"],
          connect["connect_id"],
          wechat_error_message(reason)
        )
    end

    :ok
  end

  defp wechat_send_text(base_url, token, to_user_id, context_token, text, connect) do
    client_id = random_id()

    msg = %{
      "to_user_id" => to_user_id,
      "client_id" => client_id,
      "message_type" => @wechat_message_type_bot,
      "message_state" => @wechat_message_state_finish,
      "context_token" => String.trim(to_string(context_token)),
      "item_list" => [%{"type" => @wechat_item_type_text, "text_item" => %{"text" => text}}]
    }

    with {:ok, response} <-
           wechat_api_post(
             base_url,
             "ilink/bot/sendmessage",
             %{"msg" => msg, "base_info" => wechat_base_info()},
             token
           ) do
      remember_sent(connect, response, msg)
      {:ok, client_id}
    end
  end

  defp remember_sent(connect, response, msg) do
    id = SalixIM.WeChatMessages.message_id(response)
    id = if id == "", do: msg["client_id"], else: id
    _ = SalixIM.WeChatMessages.remember(connect, Map.put(msg, "message_id", id))
    :ok
  end

  defp wechat_send_image(base_url, token, to_user_id, context_token, caption, data, connect),
    do:
      wechat_send_media(
        base_url,
        token,
        to_user_id,
        context_token,
        caption,
        "",
        data,
        @wechat_upload_media_type_image,
        @wechat_item_type_image,
        connect
      )

  defp wechat_send_file(
         base_url,
         token,
         to_user_id,
         context_token,
         filename,
         caption,
         data,
         connect
       ),
       do:
         wechat_send_media(
           base_url,
           token,
           to_user_id,
           context_token,
           caption,
           filename,
           data,
           @wechat_upload_media_type_file,
           @wechat_item_type_file,
           connect
         )

  defp wechat_send_media(
         base_url,
         token,
         to_user_id,
         context_token,
         caption,
         filename,
         data,
         upload_type,
         item_type,
         connect
       ) do
    context_token = String.trim(to_string(context_token))

    cond do
      context_token == "" ->
        {:error, "clawbot context_token is required"}

      byte_size(data) == 0 ->
        {:error, "clawbot media data is empty"}

      true ->
        aes_key = :crypto.strong_rand_bytes(16)
        file_key_hex = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        raw_md5_hex = Base.encode16(:crypto.hash(:md5, data), case: :lower)
        cipher_size = wechat_aes_ecb_padded_size(byte_size(data))

        upload_req = %{
          "filekey" => file_key_hex,
          "media_type" => upload_type,
          "to_user_id" => to_user_id,
          "rawsize" => byte_size(data),
          "rawfilemd5" => raw_md5_hex,
          "filesize" => cipher_size,
          "no_need_thumb" => true,
          "aeskey" => Base.encode16(aes_key, case: :lower),
          "base_info" => wechat_base_info()
        }

        with {:ok, upload_resp} <-
               wechat_api_post(base_url, "ilink/bot/getuploadurl", upload_req, token),
             {:ok, download_param} <-
               wechat_upload_to_cdn(upload_resp, file_key_hex, data, aes_key) do
          media_aes_key = Base.encode64(Base.encode16(aes_key, case: :lower))

          media = %{
            "encrypt_query_param" => download_param,
            "aes_key" => media_aes_key,
            "encrypt_type" => 1
          }

          media_item =
            case item_type do
              @wechat_item_type_image ->
                %{
                  "type" => @wechat_item_type_image,
                  "image_item" => %{"media" => media, "mid_size" => cipher_size}
                }

              @wechat_item_type_video ->
                %{
                  "type" => @wechat_item_type_video,
                  "video_item" => %{"media" => media, "video_size" => cipher_size}
                }

              @wechat_item_type_file ->
                %{
                  "type" => @wechat_item_type_file,
                  "file_item" => %{
                    "media" => media,
                    "file_name" => filename,
                    "len" => Integer.to_string(byte_size(data))
                  }
                }
            end

          items =
            if str(caption) != "" do
              [
                %{"type" => @wechat_item_type_text, "text_item" => %{"text" => str(caption)}},
                media_item
              ]
            else
              [media_item]
            end

          Enum.reduce_while(items, {:ok, ""}, fn item, _acc ->
            client_id = random_id()

            msg = %{
              "to_user_id" => to_user_id,
              "client_id" => client_id,
              "message_type" => @wechat_message_type_bot,
              "message_state" => @wechat_message_state_finish,
              "context_token" => context_token,
              "item_list" => [item]
            }

            case wechat_api_post(
                   base_url,
                   "ilink/bot/sendmessage",
                   %{"msg" => msg, "base_info" => wechat_base_info()},
                   token
                 ) do
              {:ok, response} ->
                remember_sent(connect, response, msg)
                {:cont, {:ok, client_id}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
        end
    end
  end

  defp wechat_upload_to_cdn(upload_resp, file_key_hex, data, aes_key) do
    upload_full_url = str(upload_resp["upload_full_url"])
    upload_param = str(upload_resp["upload_param"])

    url =
      cond do
        upload_full_url != "" ->
          upload_full_url

        upload_param != "" ->
          wechat_cdn_base_url() <>
            "/upload?encrypted_query_param=" <>
            URI.encode_www_form(upload_param) <> "&filekey=" <> URI.encode_www_form(file_key_hex)

        true ->
          nil
      end

    if url == nil do
      {:error, "clawbot get upload url returned no upload URL"}
    else
      ciphertext = wechat_encrypt_aes_ecb(data, aes_key)

      case Req.post(
             url,
             [
               body: ciphertext,
               headers: [{"content-type", "application/octet-stream"}],
               receive_timeout: 30_000
             ] ++ wechat_retry_options()
           ) do
        {:ok, %{status: 200} = resp} ->
          case Req.Response.get_header(resp, "x-encrypted-param") do
            [param | _] when param != "" -> {:ok, param}
            _ -> {:error, "clawbot cdn upload: missing x-encrypted-param header"}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, "cdn upload", status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp wechat_api_post(base_url, endpoint, payload, token) do
    url = ensure_slash(base_url) <> endpoint

    case Req.post(
           url,
           [
             json: payload,
             headers: wechat_api_headers(token),
             redirect: false,
             receive_timeout: @wechat_api_timeout_ms
           ] ++ wechat_retry_options()
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        with {:ok, body} <- SalixIM.WeChatAPI.decode_body(body) do
          wechat_check_api_error(endpoint, body)
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, endpoint, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wechat_check_api_error(endpoint, body) when is_map(body) do
    ret = int_or_zero(body["ret"])
    errcode = int_or_zero(body["errcode"])

    if ret == 0 and errcode == 0 do
      {:ok, body}
    else
      code = if errcode != 0, do: errcode, else: ret

      {:error,
       {:clawbot_api_error, short_wechat_endpoint(endpoint), code,
        to_string(body["errmsg"] || "")}}
    end
  end

  defp wechat_retry_options do
    [
      retry: &wechat_retry?/2,
      max_retries: @wechat_max_retries,
      retry_delay: &(250 * Integer.pow(2, &1))
    ]
  end

  defp wechat_retry?(_request, %Req.TransportError{reason: reason}),
    do: reason in @wechat_retryable_transport_reasons

  defp wechat_retry?(_request, _response_or_exception), do: false

  defp short_wechat_endpoint("ilink/bot/" <> rest), do: rest
  defp short_wechat_endpoint(endpoint), do: endpoint

  defp wechat_api_headers(token), do: SalixIM.WeChatAPI.headers(str(token))

  defp wechat_base_info, do: SalixIM.WeChatAPI.base_info()

  defp wechat_cdn_base_url do
    :salix_im
    |> Application.get_env(:wechat_cdn_base_url, @wechat_cdn_base_url)
    |> str()
    |> default_base(@wechat_cdn_base_url)
  end

  defp wechat_session_expired_error?(
         {:clawbot_api_error, _endpoint, @wechat_session_expired_errcode, _msg}
       ),
       do: true

  defp wechat_session_expired_error?(_), do: false

  defp wechat_error_message({:clawbot_api_error, endpoint, code, msg}),
    do: "clawbot #{endpoint} api error: errcode=#{code} errmsg=#{inspect(msg)}"

  defp wechat_error_message({:http, endpoint, status, body}),
    do: "clawbot api #{endpoint} #{status}: #{inspect(body)}"

  defp wechat_error_message(%Req.TransportError{reason: :timeout}),
    do: "WeChat did not respond in time; the message may or may not have been delivered."

  defp wechat_error_message(%Req.TransportError{}),
    do: "WeChat is temporarily unreachable. Try again later."

  defp wechat_error_message(reason) when is_binary(reason), do: reason
  defp wechat_error_message(reason), do: inspect(reason)

  # Match Tencent's filename-based video MIME routing; this does not inspect codecs.
  defp wechat_video_path?(path) do
    ext = path |> str() |> Path.extname() |> String.downcase()
    ext in [".mp4", ".mov", ".webm", ".mkv", ".avi"]
  end

  defp wechat_image_upload?(filename, data), do: image_magic?(data) or image_ext?(filename)

  defp image_magic?(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: true
  defp image_magic?(<<0xFF, 0xD8, 0xFF, _::binary>>), do: true
  defp image_magic?(<<"GIF87a", _::binary>>), do: true
  defp image_magic?(<<"GIF89a", _::binary>>), do: true
  defp image_magic?(<<"BM", _::binary>>), do: true
  defp image_magic?(<<"RIFF", _::binary-4, "WEBP", _::binary>>), do: true
  defp image_magic?(_), do: false

  defp image_ext?(filename) do
    ext = filename |> Path.extname() |> String.downcase()

    ext in [
      ".png",
      ".jpg",
      ".jpeg",
      ".gif",
      ".webp",
      ".bmp",
      ".ico",
      ".tif",
      ".tiff",
      ".avif",
      ".svg"
    ]
  end

  defp wechat_encrypt_aes_ecb(plaintext, key),
    do: :crypto.crypto_one_time(:aes_128_ecb, key, pkcs7_pad(plaintext), true)

  defp pkcs7_pad(data) do
    pad = 16 - rem(byte_size(data), 16)
    data <> :binary.copy(<<pad>>, pad)
  end

  defp wechat_aes_ecb_padded_size(plaintext_size), do: div(plaintext_size + 1 + 15, 16) * 16
end
