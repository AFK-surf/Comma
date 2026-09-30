defmodule SalixIM.WeChatFiles do
  @moduledoc """
  Tencent CDN media enters the existing provider attachment staging boundary.
  The official SDK needs OpenClaw's Node runtime. This adapter uses Req and OTP
  AES, following its media-download/pic-decrypt wire contract. CDN locations
  and keys stay inside download closures, never in model or VFS metadata.
  """

  alias SalixStore.Blob

  @cdn "https://novac2c.cdn.weixin.qq.com/c2c"
  @max_bytes 10 * 1024 * 1024
  @max_items 4
  @budget_ms 15_000

  def attachments(connect, message) when is_map(message) do
    deadline = now() + @budget_ms

    SalixIM.WeChatMessages.media_items(message)
    |> Enum.reject(fn {item, _, _} ->
      item["type"] == 3 and is_map(item["voice_item"]) and
        is_binary(item["voice_item"]["text"]) and item["voice_item"]["text"] != "" and
        not is_map(item["voice_item"]["media"])
    end)
    |> Enum.map(fn {item, index, quoted?} ->
      resource = item[resource_field(item["type"])]
      resource = if is_map(resource), do: resource, else: %{}
      image? = item["type"] == 2
      name = safe_name(media_name(item["type"], resource))
      name = if quoted?, do: "quoted-" <> name, else: name

      # A locator, not an authority: keep repeated filenames from overwriting
      # another accepted message. The existing ingress owns peer authorization.
      locator =
        [connect["connect_id"], message["message_id"], index]
        |> Jason.encode!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      path = "/wechat/attachments/#{locator}-#{name}"

      %{
        "path" => path,
        "file_name" => name,
        "mime" => if(image?, do: "application/octet-stream", else: MIME.from_path(name)),
        "quoted" => quoted?,
        "to_blob" => fn agent_id ->
          download(agent_id, resource, image?, path, name, deadline)
        end
      }
    end)
    |> limit_items()
  end

  def attachments(_, _), do: []

  defp limit_items(items) do
    {kept, excess} = Enum.split(items, @max_items)

    case excess do
      [] ->
        kept

      [first | _] ->
        kept ++
          [
            Map.put(first, "to_blob", fn _ ->
              {:error, {:size_limit, :attachments, @max_items}}
            end)
          ]
    end
  end

  defp download(agent_id, resource, image?, path, name, deadline) do
    media = resource["media"] || %{}

    with :ok <- declared_size(resource, image?),
         true <- is_map(media) and media["encrypt_type"] in [nil, 0, 1],
         {:ok, key} <- key(resource, image?),
         {:ok, url} <- download_url(media),
         {:ok, encrypted} <- fetch(url, deadline),
         {:ok, body} <- decrypt(encrypted, key),
         :ok <- plaintext_size(body),
         {:ok, ref} <- Blob.put(agent_id, body) do
      {mime, extension} = if image?, do: image_type(body), else: {MIME.from_path(name), ""}

      {:ok,
       %{
         ref: ref,
         size: byte_size(body),
         path: path <> extension,
         file_name: name <> extension,
         mime_type: mime
       }}
    else
      false -> {:error, :invalid_wechat_media}
      {:error, _} = error -> error
      _ -> {:error, :wechat_file_unavailable}
    end
  rescue
    _ -> {:error, :wechat_file_unavailable}
  end

  defp plaintext_size(body) when byte_size(body) <= @max_bytes, do: :ok
  defp plaintext_size(_), do: {:error, {:size_limit, :plaintext, @max_bytes}}

  defp resource_field(2), do: "image_item"
  defp resource_field(3), do: "voice_item"
  defp resource_field(4), do: "file_item"
  defp resource_field(5), do: "video_item"

  defp media_name(2, _), do: "image"
  defp media_name(4, resource), do: resource["file_name"]
  defp media_name(5, _), do: "video.mp4"

  defp media_name(3, resource) do
    suffix =
      %{1 => "pcm", 2 => "adpcm", 4 => "speex", 5 => "amr", 6 => "silk", 7 => "mp3", 8 => "ogg"}[
        resource["encode_type"]
      ] || "bin"

    "voice." <> suffix
  end

  defp declared_size(resource, image?) do
    size = if image?, do: resource["mid_size"], else: resource["len"] || resource["video_size"]
    max = if image?, do: @max_bytes + 16, else: @max_bytes

    case Integer.parse(to_string(size || "")) do
      {n, ""} when n > max -> {:error, {:size_limit, n, max}}
      _ -> :ok
    end
  end

  defp key(%{"aeskey" => hex}, true) when is_binary(hex) and hex != "", do: hex_key(hex)

  defp key(resource, image?) do
    encoded = get_in(resource, ["media", "aes_key"])

    cond do
      encoded in [nil, ""] and image? ->
        {:ok, nil}

      is_binary(encoded) ->
        case Base.decode64(encoded) do
          {:ok, key} when byte_size(key) == 16 -> {:ok, key}
          {:ok, hex} when byte_size(hex) == 32 -> hex_key(hex)
          _ -> {:error, :invalid_wechat_media_key}
        end

      true ->
        {:error, :invalid_wechat_media_key}
    end
  end

  defp hex_key(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, key} when byte_size(key) == 16 -> {:ok, key}
      _ -> {:error, :invalid_wechat_media_key}
    end
  end

  defp download_url(media) do
    base = Application.get_env(:salix_im, :wechat_cdn_base_url, @cdn) |> String.trim_trailing("/")
    full = media["full_url"]
    param = media["encrypt_query_param"]

    url =
      cond do
        is_binary(full) and full != "" ->
          full

        is_binary(param) and param != "" ->
          base <> "/download?encrypted_query_param=" <> URI.encode_www_form(param)

        true ->
          nil
      end

    # Provider URLs cannot select arbitrary network destinations. The configured
    # CDN origin is operator-owned; tests use an isolated loopback origin.
    with true <- is_binary(url),
         %URI{} = uri <- URI.parse(url),
         %URI{} = allowed <- URI.parse(base),
         true <- {uri.scheme, uri.host, uri.port} == {allowed.scheme, allowed.host, allowed.port},
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         true <- uri.path == (allowed.path || "") <> "/download" do
      {:ok, url}
    else
      _ -> {:error, :invalid_wechat_media_url}
    end
  end

  defp fetch(url, deadline, retries_left \\ 1) do
    result = fetch_once(url, deadline)

    if retries_left > 0 and retryable?(result) and deadline - now() > 100 do
      Process.sleep(100)
      fetch(url, deadline, retries_left - 1)
    else
      result
    end
  end

  defp retryable?({:error, {:wechat_file_http, status}}),
    do: status in [408, 429, 500, 502, 503, 504]

  defp retryable?({:error, {:wechat_file_transport, reason}}),
    do: reason in [:timeout, :closed, :econnrefused, :enetunreach, :ehostunreach]

  defp retryable?(_), do: false

  defp fetch_once(url, deadline) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, :wechat_file_timeout}
    else
      result =
        Req.get(url,
          retry: false,
          redirect: false,
          raw: true,
          receive_timeout: remaining,
          connect_options: [timeout: min(remaining, 5_000)],
          into: fn {:data, chunk}, {req, resp} ->
            bytes = (resp.private[:wechat_bytes] || 0) + byte_size(chunk)

            error =
              cond do
                resp.status != 200 -> :wechat_file_unavailable
                now() >= deadline -> :wechat_file_timeout
                bytes > @max_bytes + 16 -> {:size_limit, bytes, @max_bytes}
                true -> nil
              end

            if error do
              {:halt, {req, Req.Response.put_private(resp, :wechat_error, error)}}
            else
              resp =
                resp
                |> Req.Response.put_private(:wechat_bytes, bytes)
                |> Req.Response.put_private(:wechat_chunks, [
                  chunk | resp.private[:wechat_chunks] || []
                ])

              {:cont, {req, resp}}
            end
          end
        )

      case result do
        {:ok, %{status: 200} = resp} ->
          if error = resp.private[:wechat_error],
            do: {:error, error},
            else:
              {:ok,
               resp.private[:wechat_chunks]
               |> List.wrap()
               |> Enum.reverse()
               |> IO.iodata_to_binary()}

        {:ok, %{status: status}} ->
          {:error, {:wechat_file_http, status}}

        {:error, %Req.TransportError{reason: reason}} ->
          # Keep only a closed set of transport classes; exceptions can contain CDN secrets.
          reason =
            if reason in [
                 :timeout,
                 :closed,
                 :econnrefused,
                 :enetunreach,
                 :ehostunreach,
                 :nxdomain
               ], do: reason, else: :other

          {:error, {:wechat_file_transport, reason}}

        _ ->
          {:error, :wechat_file_unavailable}
      end
    end
  end

  defp decrypt(body, nil), do: {:ok, body}

  defp decrypt(body, key) when byte_size(body) > 0 and rem(byte_size(body), 16) == 0 do
    plain = :crypto.crypto_one_time(:aes_128_ecb, key, body, false)
    pad = :binary.last(plain)
    size = byte_size(plain)

    if pad in 1..16 and binary_part(plain, size - pad, pad) == :binary.copy(<<pad>>, pad),
      do: {:ok, binary_part(plain, 0, size - pad)},
      else: {:error, :invalid_wechat_media_padding}
  end

  defp decrypt(_, _), do: {:error, :invalid_wechat_media_ciphertext}

  defp image_type(<<0x89, "PNG", 13, 10, 26, 10, _::binary>>), do: {"image/png", ".png"}
  defp image_type(<<255, 216, 255, _::binary>>), do: {"image/jpeg", ".jpg"}
  defp image_type(<<"GIF", _::binary>>), do: {"image/gif", ".gif"}
  defp image_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {"image/webp", ".webp"}
  defp image_type(_), do: {"application/octet-stream", ".bin"}

  defp safe_name(name) do
    name = if is_binary(name) and name != "", do: name, else: "file.bin"

    name
    |> String.replace("\\", "/")
    |> Path.basename()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> String.slice(0, 160)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
