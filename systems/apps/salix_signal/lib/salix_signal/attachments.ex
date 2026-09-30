defmodule SalixSignal.Attachments do
  @moduledoc """
  Attachment upload and download (CRS-10 sections 2 to 5 and 11).

  Upload: the plaintext is padded and encrypted
  (`SalixSignalProto.Attachment`), an upload form for the exact blob size is
  requested over the chat socket, and the blob is uploaded with the protocol
  that the form's CDN number selects:

    * CDN 2: a resumable upload session. The client starts the session,
      then sends the blob; after a failure it asks the session for the
      stored offset and sends the rest.
    * CDN 3: TUS 1.0.0. The client creates the upload with the whole blob;
      after a failure it asks for the stored offset and sends the rest.

  Each upload makes at most `:max_attempts` attempts to send bytes (default
  3). A CDN 2 session that the storage no longer knows restarts with a new
  form, within the same attempt budget. The result is an attachment pointer
  for the content message.

  Download: the blob is fetched without account credentials from the host
  of the pointer's CDN number, its size is bounded, the incremental MAC (if
  present), the MAC and the digest are checked, and the plaintext is
  returned. Message attachments require a digest.

  Upload form URLs can point outside the Signal hosts (CRS-10 section 4.1).
  Hosts in the Signal host table are verified against the pinned Signal
  roots; other hosts use the public web trust store. `:http` options passed
  by the caller (for example `roots:` in tests) apply to every CDN request.
  """

  import Bitwise

  alias SalixSignal.Service.{Chat, Endpoints, Http, Response}
  alias SalixSignalProto.Attachment
  alias SalixSignalProto.Attachment.{IncrementalMac, Pointer}

  # CRS-10 section 11.2: Android's defaults for the largest blob a client
  # uploads (remote configuration `global.attachments.maxBytes`) and
  # downloads (1.25 times that).
  @max_upload_blob_bytes 104_857_600
  @max_download_blob_bytes 131_072_000
  @max_attempts 3

  @cdn_services %{0 => :cdn0, 2 => :cdn2, 3 => :cdn3}

  @type upload_error ::
          :too_large
          | :bad_request
          | {:rate_limited, non_neg_integer() | nil}
          | {:invalid_form, term()}
          | {:upload_failed, term()}
          | term()

  @doc """
  Encrypts and uploads `plaintext`. Returns the attachment pointer.

  Options: `:content_type` (required), `:file_name`, `:voice_note` (sets
  flag 1), `:flags`, `:width`, `:height`, `:caption`, `:incremental_mac`
  (default: true for `video/mp4`, as senders do at the pin), `:environment`,
  `:http` (options for `SalixSignal.Service.Http`), `:max_attempts`,
  `:timeout` (chat request timeout), and for tests `:keys`, `:iv`,
  `:client_uuid` and `:now_ms`.
  """
  @spec upload(GenServer.server(), binary(), keyword()) ::
          {:ok, Pointer.t()} | {:error, upload_error()}
  def upload(chat, plaintext, opts) when is_binary(plaintext) do
    content_type = Keyword.fetch!(opts, :content_type)
    keys = Keyword.get_lazy(opts, :keys, &Attachment.generate_keys/0)
    iv = Keyword.get_lazy(opts, :iv, &Attachment.generate_iv/0)
    %{blob: blob, digest: digest, size: size} = Attachment.encrypt(plaintext, keys, iv)

    if byte_size(blob) > @max_upload_blob_bytes do
      {:error, :too_large}
    else
      budget = Keyword.get(opts, :max_attempts, @max_attempts)

      with {:ok, form} <- upload_blob(chat, blob, budget, opts) do
        {:ok, pointer(form, content_type, keys, size, digest, blob, opts)}
      end
    end
  end

  @doc """
  Requests an upload form for a blob of `blob_size` bytes
  (`GET /v4/attachments/form/upload`, CRS-10 section 3).
  """
  @spec upload_form(GenServer.server(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, upload_error()}
  def upload_form(chat, blob_size, opts \\ []) when is_integer(blob_size) and blob_size > 0 do
    path = "/v4/attachments/form/upload?uploadLength=#{blob_size}"

    case Chat.request(chat, "GET", path, Keyword.take(opts, [:timeout])) do
      {:ok, %Response{status: 200} = response} -> parse_form(response)
      {:ok, %Response{status: 400}} -> {:error, :bad_request}
      {:ok, %Response{status: 413}} -> {:error, :too_large}
      {:ok, %Response{} = response} -> {:error, form_error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Downloads, verifies and decrypts the attachment that `pointer` names.

  Options: `:environment`, `:http`, `:max_bytes` (default 131,072,000, the
  receive limit of CRS-10 section 11.2), `:sticker` (true for sticker
  images, which carry no digest), and `:base_urls` (a map from CDN number
  to base URL, for tests).
  """
  @spec download(Pointer.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def download(%Pointer{} = pointer, opts \\ []) do
    with {:ok, url} <- download_url(pointer, opts),
         {:ok, keys, size, digest} <- pointer_secrets(pointer, opts),
         {:ok, blob} <- fetch(url, opts),
         :ok <- check_incremental_mac(pointer, keys, blob) do
      Attachment.decrypt(blob, keys, digest, size)
    end
  end

  @doc """
  The download URL of a pointer (CRS-10 section 5): the CDN key under
  `/attachments/` on the host of the pointer's CDN number (absent means 0),
  or the legacy numeric id on CDN 0. Unknown CDN numbers are refused.
  """
  @spec download_url(Pointer.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_pointer | :unknown_cdn}
  def download_url(%Pointer{} = pointer, opts \\ []) do
    cdn = Pointer.cdn(pointer)

    cond do
      not Pointer.valid?(pointer) ->
        {:error, :invalid_pointer}

      is_binary(pointer.cdn_key) ->
        with {:ok, base} <- base_url(cdn, opts) do
          {:ok, base <> "/attachments/" <> URI.encode(pointer.cdn_key, &URI.char_unreserved?/1)}
        end

      true ->
        with {:ok, base} <- base_url(0, opts) do
          {:ok, base <> "/attachments/" <> Integer.to_string(pointer.cdn_id)}
        end
    end
  end

  # --- Upload ----------------------------------------------------------

  defp upload_blob(_chat, _blob, budget, _opts) when budget <= 0,
    do: {:error, {:upload_failed, :attempts_exhausted}}

  defp upload_blob(chat, blob, budget, opts) do
    with {:ok, form} <- upload_form(chat, byte_size(blob), opts) do
      case send_blob(form, blob, budget, opts) do
        :ok -> {:ok, form}
        {:restart, budget} -> upload_blob(chat, blob, budget, opts)
        {:error, reason} -> {:error, {:upload_failed, reason}}
      end
    end
  end

  defp send_blob(%{cdn: 2} = form, blob, budget, opts) do
    headers = Enum.to_list(form.headers)

    start =
      http(:post, form.location, opts,
        headers: headers ++ [{"content-type", "application/octet-stream"}],
        body: ""
      )

    case start do
      {:ok, %Response{status: status} = response} when status in 200..299 ->
        case Response.header(response, "location") do
          "https://" <> _ = session -> cdn2_send(session, blob, 0, budget, opts)
          _ -> {:error, :no_session_location}
        end

      {:ok, %Response{status: status}} ->
        {:error, {:session_start, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_blob(%{cdn: 3} = form, blob, budget, opts) do
    headers = Enum.to_list(form.headers) ++ [{"tus-resumable", "1.0.0"}]
    size = byte_size(blob)

    create =
      http(:post, form.location, opts,
        headers:
          headers ++
            [
              {"upload-length", Integer.to_string(size)},
              {"content-type", "application/offset+octet-stream"}
            ],
        body: blob
      )

    case create do
      {:ok, %Response{status: status}} when status in 200..299 -> :ok
      _failed -> tus_resume(form.location <> "/" <> form.key, headers, blob, budget - 1, opts)
    end
  end

  # CRS-10 section 4.2: send from `offset`; after a failure ask the session
  # for the stored range. When the session already holds every byte, no
  # byte range is left to send: ask for the status again instead.
  defp cdn2_send(_session, _blob, _offset, budget, _opts) when budget <= 0,
    do: {:error, :attempts_exhausted}

  defp cdn2_send(session, blob, offset, budget, opts) when offset == byte_size(blob),
    do: cdn2_resume(session, blob, budget, opts)

  defp cdn2_send(session, blob, offset, budget, opts) do
    size = byte_size(blob)

    result =
      http(:put, session, opts,
        headers: [{"content-range", "bytes #{offset}-#{size - 1}/#{size}"}],
        body: binary_part(blob, offset, size - offset)
      )

    case result do
      {:ok, %Response{status: status}} when status in 200..299 -> :ok
      _failed -> cdn2_resume(session, blob, budget, opts)
    end
  end

  defp cdn2_resume(session, blob, budget, opts) do
    case cdn2_offset(session, byte_size(blob), opts) do
      :complete -> :ok
      {:offset, next} -> cdn2_send(session, blob, next, budget - 1, opts)
      :session_gone -> {:restart, budget - 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cdn2_offset(session, size, opts) do
    case http(:put, session, opts, headers: [{"content-range", "bytes */#{size}"}], body: "") do
      {:ok, %Response{status: status}} when status in [200, 201] ->
        :complete

      {:ok, %Response{status: 308} = response} ->
        case Response.header(response, "range") do
          nil -> {:offset, 0}
          range -> parse_range(range, size)
        end

      {:ok, %Response{status: 404}} ->
        :session_gone

      {:ok, %Response{status: status}} ->
        {:error, {:status_query, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_range("bytes=0-" <> last, size) do
    case Integer.parse(last) do
      {last, ""} when last >= 0 and last < size -> {:offset, last + 1}
      _ -> {:error, {:bad_range, last}}
    end
  end

  defp parse_range(other, _size), do: {:error, {:bad_range, other}}

  # CRS-10 section 4.3: get the stored offset, then send the rest.
  defp tus_resume(_object, _headers, _blob, budget, _opts) when budget <= 0,
    do: {:error, :attempts_exhausted}

  defp tus_resume(object, headers, blob, budget, opts) do
    size = byte_size(blob)

    with {:ok, %Response{status: status} = response} when status in 200..299 <-
           http(:head, object, opts, headers: headers),
         {:ok, offset} <- upload_offset(response, size) do
      patch =
        http(:patch, object, opts,
          headers:
            headers ++
              [
                {"upload-offset", Integer.to_string(offset)},
                {"upload-length", Integer.to_string(size)},
                {"content-type", "application/offset+octet-stream"}
              ],
          body: binary_part(blob, offset, size - offset)
        )

      case patch do
        {:ok, %Response{status: status}} when status in 200..299 -> :ok
        _failed -> tus_resume(object, headers, blob, budget - 1, opts)
      end
    else
      {:error, :bad_offset} = error -> error
      _failed -> tus_resume(object, headers, blob, budget - 1, opts)
    end
  end

  defp upload_offset(response, size) do
    with value when is_binary(value) <- Response.header(response, "upload-offset"),
         {offset, ""} when offset >= 0 and offset <= size <- Integer.parse(String.trim(value)) do
      {:ok, offset}
    else
      _ -> {:error, :bad_offset}
    end
  end

  defp parse_form(response) do
    with {:ok, %{} = body} <- Response.json(response),
         {:ok, cdn} <- form_cdn(body["cdn"]),
         key when is_binary(key) and key != "" <- body["key"],
         %{} = headers <- body["headers"] || %{},
         true <- Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end),
         "https://" <> _ = location <- body["signedUploadLocation"] do
      {:ok, %{cdn: cdn, key: key, headers: headers, location: location}}
    else
      _ -> {:error, {:invalid_form, response.body}}
    end
  end

  defp form_cdn(cdn) when cdn in [2, 3], do: {:ok, cdn}
  defp form_cdn(_), do: :error

  defp form_error(response) do
    case Response.outcome(response) do
      {:rate_limited, seconds} -> {:rate_limited, seconds}
      other -> other
    end
  end

  defp pointer(form, content_type, keys, size, digest, blob, opts) do
    flags =
      Keyword.get(opts, :flags, 0) |||
        if(Keyword.get(opts, :voice_note, false), do: Pointer.flag_voice_message(), else: 0)

    <<_aes::binary-size(32), mac_key::binary-size(32)>> = keys

    {chunk_size, macs} =
      if Keyword.get(opts, :incremental_mac, content_type == "video/mp4") do
        chunk_size = IncrementalMac.chunk_size(byte_size(blob))
        {chunk_size, IncrementalMac.compute(mac_key, blob, chunk_size)}
      else
        {nil, nil}
      end

    %Pointer{
      cdn_key: form.key,
      cdn_number: form.cdn,
      content_type: content_type,
      keys: keys,
      size: size,
      digest: digest,
      file_name: opts[:file_name],
      flags: if(flags == 0, do: nil, else: flags),
      width: opts[:width],
      height: opts[:height],
      caption: opts[:caption],
      upload_timestamp:
        Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end),
      incremental_mac_chunk_size: chunk_size,
      incremental_mac: macs,
      client_uuid: Keyword.get_lazy(opts, :client_uuid, &random_uuid/0)
    }
  end

  defp random_uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<a::48, 4::4, b::12, 2::2, c::62>>
  end

  # --- Download ----------------------------------------------------------

  defp pointer_secrets(%Pointer{keys: <<_::binary-size(64)>> = keys, size: size} = pointer, opts)
       when is_integer(size) do
    cond do
      Keyword.get(opts, :sticker, false) -> {:ok, keys, size, :none}
      match?(<<_::binary-size(32)>>, pointer.digest) -> {:ok, keys, size, pointer.digest}
      true -> {:error, :missing_digest}
    end
  end

  defp pointer_secrets(_pointer, _opts), do: {:error, :invalid_pointer}

  defp fetch(url, opts) do
    max = Keyword.get(opts, :max_bytes, @max_download_blob_bytes)

    case http(:get, url, opts, max_body_bytes: max) do
      {:ok, %Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Response{status: 404}} -> {:error, :not_found}
      {:ok, %Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_incremental_mac(
         %Pointer{incremental_mac: macs, incremental_mac_chunk_size: chunk},
         keys,
         blob
       )
       when is_binary(macs) and is_integer(chunk) do
    <<_aes::binary-size(32), mac_key::binary-size(32)>> = keys

    case IncrementalMac.verify(mac_key, blob, chunk, macs) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :bad_incremental_mac}
    end
  end

  defp check_incremental_mac(_pointer, _keys, _blob), do: :ok

  defp base_url(cdn, opts) do
    case opts[:base_urls] do
      %{^cdn => url} ->
        {:ok, url}

      _ when is_map_key(@cdn_services, cdn) ->
        environment = Keyword.get(opts, :environment, :production)
        {:ok, "https://" <> Endpoints.host(environment, Map.fetch!(@cdn_services, cdn))}

      _ ->
        {:error, :unknown_cdn}
    end
  end

  # --- HTTP --------------------------------------------------------------

  defp http(method, url, opts, request_opts) do
    trust = if signal_host?(url), do: :signal, else: :public

    Http.request(
      method,
      url,
      Keyword.merge([trust: trust] ++ request_opts, Keyword.get(opts, :http, []))
    )
  end

  @signal_hosts for env <- [:production, :staging],
                    service <- [:chat, :storage, :cdn0, :cdn2, :cdn3],
                    do: Endpoints.host(env, service)

  defp signal_host?(url), do: URI.parse(url).host in @signal_hosts
end
