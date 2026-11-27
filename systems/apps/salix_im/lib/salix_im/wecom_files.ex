defmodule SalixIM.WeComFiles do
  @moduledoc """
  Downloads one WeCom message attachment into Blob for provider attachment
  staging.

  A WeCom message carries a download URL for each image, file or video,
  valid for 5 minutes, and an `aeskey` of its own. The bytes behind the URL
  are encrypted with AES-256-CBC: the key is the `aeskey` (Base64, as the
  official SDKs read it; 32 bytes), the IV its first 16 bytes, and the
  plaintext is padded with PKCS#7 to a multiple of 32 bytes. The download
  streams through the cipher into Blob and never holds the whole file.

  WeCom names neither the file nor its type in the message. The download
  answers both: `Content-Disposition` carries the file name, and the first
  bytes of the plaintext say whether it is an image the model can read.

  The URL comes from the provider, so only HTTPS hosts WeCom serves
  attachments from are fetched (its own domains and the Tencent Cloud object
  storage it keeps them in), and redirects are not followed.
  """

  require Logger

  alias SalixStore.Blob

  # Measured 2026-11-17: images and files come from
  # `ww-aibot-img-<n>.cos.ap-guangzhou.myqcloud.com`.
  @media_host_suffixes ~w(.qq.com .qpic.cn .myqcloud.com)
  # The largest attachment WeCom delivers to a bot: a video of 100 MB.
  @default_max_bytes 100 * 1024 * 1024
  @pad_block 32

  @doc "Configured max size of one attachment to download."
  @spec max_bytes() :: pos_integer()
  def max_bytes,
    do: SystemsRuntime.get_env(:salix_im, :wecom_file_max_bytes, @default_max_bytes)

  @doc """
  Downloads and decrypts one attachment into Blob: `{:ok, %{ref:, size:,
  file_name:, mime_type:}}`, the name and type when WeCom's answer or the
  bytes tell them.
  """
  @spec download(String.t(), term(), term(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def download(agent_id, url, aeskey, max_bytes)
      when is_binary(url) and is_binary(aeskey) and is_integer(max_bytes) do
    with {:ok, key} <- key(aeskey) do
      if allowed?(url) do
        stream(agent_id, url, key, max_bytes)
      else
        # The host alone: the address carries a signed key.
        Logger.warning("wecom_file_host_refused", host: inspect(URI.parse(url).host))
        {:error, :missing_download_url}
      end
    end
  end

  def download(_agent_id, _url, _aeskey, _max_bytes), do: {:error, :missing_download_url}

  @doc "The 32-byte AES key of an `aeskey`."
  @spec key(String.t()) :: {:ok, binary()} | {:error, :bad_aeskey}
  def key(aeskey) do
    case Base.decode64(aeskey, padding: false) do
      {:ok, <<_::binary-size(32)>> = key} ->
        {:ok, key}

      _other ->
        case Base.decode64(aeskey) do
          {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
          _other when byte_size(aeskey) == 32 -> {:ok, aeskey}
          _other -> {:error, :bad_aeskey}
        end
    end
  end

  @doc "True when `url` is an address of WeCom's own hosts."
  @spec allowed?(term()) :: boolean()
  def allowed?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host = String.downcase(host)
        Enum.any?(@media_host_suffixes, &String.ends_with?(host, &1))

      %URI{scheme: "http", host: host} when is_binary(host) ->
        host in test_hosts()

      _other ->
        false
    end
  end

  def allowed?(_url), do: false

  # Tests serve attachments from a local HTTP stub.
  defp test_hosts, do: List.wrap(SystemsRuntime.get_env(:salix_im, :wecom_media_test_hosts, []))

  @doc """
  Decrypts a whole attachment held in memory: what `download/4` does to the
  stream, for a caller that has the bytes.
  """
  @spec decrypt(binary(), binary()) :: {:ok, binary()} | {:error, :bad_padding}
  def decrypt(ciphertext, key) do
    state = cipher(key)
    plain = :crypto.crypto_update(state, ciphertext) <> :crypto.crypto_final(state)
    unpad(plain)
  end

  defp cipher(<<iv::binary-size(16), _::binary>> = key),
    do: :crypto.crypto_init(:aes_256_cbc, key, iv, encrypt: false, padding: :none)

  defp unpad(plain) when byte_size(plain) > 0 do
    pad = :binary.last(plain)

    if pad in 1..@pad_block and pad <= byte_size(plain) and
         binary_part(plain, byte_size(plain) - pad, pad) == :binary.copy(<<pad>>, pad),
       do: {:ok, binary_part(plain, 0, byte_size(plain) - pad)},
       else: {:error, :bad_padding}
  end

  defp unpad(_plain), do: {:error, :bad_padding}

  # The plaintext goes to Blob as it is decrypted, all but its last
  # `@pad_block` bytes, which may be padding and wait for the end.
  defp stream(agent_id, url, key, max_bytes) do
    state_key = {__MODULE__, SystemsRuntime.Proc.make_ref()}

    Process.put(state_key, %{
      blob: Blob.put_stream_init(agent_id),
      cipher: cipher(key),
      tail: "",
      head: "",
      bytes: 0,
      error: nil
    })

    try do
      result =
        Req.get(url,
          retry: false,
          redirect: false,
          decode_body: false,
          into: fn {:data, chunk}, {req, resp} ->
            acc = Process.get(state_key)
            size = acc.bytes + byte_size(chunk)

            cond do
              resp.status != 200 ->
                {:halt, {req, resp}}

              size > max_bytes ->
                Process.put(state_key, %{acc | error: {:size_limit, size, max_bytes}})
                {:halt, {req, resp}}

              true ->
                plain = acc.tail <> :crypto.crypto_update(acc.cipher, chunk)
                ready = max(byte_size(plain) - @pad_block, 0)
                <<out::binary-size(^ready), tail::binary>> = plain

                head =
                  if byte_size(acc.head) < 16,
                    do: binary_part(acc.head <> out, 0, min(16, byte_size(acc.head <> out))),
                    else: acc.head

                case put(acc.blob, out) do
                  {:ok, blob} ->
                    Process.put(state_key, %{
                      acc
                      | blob: blob,
                        tail: tail,
                        head: head,
                        bytes: size
                    })

                    {:cont, {req, resp}}

                  {:error, blob} ->
                    Process.put(state_key, %{
                      acc
                      | blob: blob,
                        error: :wecom_file_storage_unavailable
                    })

                    {:halt, {req, resp}}
                end
            end
          end
        )

      acc = Process.get(state_key)

      case result do
        {:ok, %{status: 200} = resp} when is_nil(acc.error) ->
          finish(acc, file_name(resp))

        {:ok, %{status: 200}} ->
          Blob.put_stream_abort(acc.blob)
          {:error, acc.error}

        _other ->
          Blob.put_stream_abort(acc.blob)
          {:error, :wecom_file_unavailable}
      end
    rescue
      _error ->
        Blob.put_stream_abort(Process.get(state_key).blob)
        {:error, :wecom_file_unavailable}
    after
      Process.delete(state_key)
    end
  end

  defp finish(acc, file_name) do
    with {:ok, last} <- unpad(acc.tail <> :crypto.crypto_final(acc.cipher)),
         {:ok, blob} <- put(acc.blob, last),
         {:ok, ref} <- Blob.put_stream_finish(blob) do
      head = binary_part(acc.head <> last, 0, min(16, byte_size(acc.head <> last)))

      {:ok,
       %{ref: ref, size: acc.bytes, file_name: file_name, mime_type: sniff(head)}
       |> Map.reject(fn {_key, value} -> is_nil(value) end)}
    else
      {:error, %{} = blob} ->
        Blob.put_stream_abort(blob)
        {:error, :wecom_file_storage_unavailable}

      {:error, :bad_padding} ->
        Blob.put_stream_abort(acc.blob)
        {:error, :wecom_file_undecryptable}

      {:error, _reason} = error ->
        error
    end
  end

  # `attachment; filename=%E6%B7%98%E5%AE%9D.png`, or RFC 5987's
  # `filename*=UTF-8''...`, as the official SDKs read it.
  defp file_name(resp) do
    disposition =
      resp
      |> Req.Response.get_header("content-disposition")
      |> List.first()
      |> to_string()

    raw =
      case Regex.run(~r/filename\*=UTF-8''([^;\s]+)/i, disposition) do
        [_all, name] ->
          name

        nil ->
          case Regex.run(~r/filename="?([^";]+)"?/i, disposition) do
            [_all, name] -> name
            nil -> ""
          end
      end

    name = raw |> URI.decode() |> Path.basename() |> String.trim()
    if name in ["", ".", ".."] or not String.valid?(name), do: nil, else: name
  rescue
    _error -> nil
  end

  @doc false
  # The types the model reads as images, by their first bytes.
  def sniff(<<0x89, "PNG", _::binary>>), do: "image/png"
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff(<<"GIF8", _::binary>>), do: "image/gif"
  def sniff(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def sniff(<<"%PDF", _::binary>>), do: "application/pdf"
  def sniff(<<_size::binary-size(4), "ftyp", _::binary>>), do: "video/mp4"
  def sniff(_head), do: nil

  defp put(blob, ""), do: {:ok, blob}

  defp put(blob, data) do
    case Blob.put_stream_step(blob, data) do
      {:ok, blob} -> {:ok, blob}
      {:error, _reason, blob} -> {:error, blob}
    end
  end
end
