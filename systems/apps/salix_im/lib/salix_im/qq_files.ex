defmodule SalixIM.QQFiles do
  @moduledoc """
  Downloads one QQ message attachment into Blob for provider attachment staging.

  A QQ message event carries a signed download URL for each attachment. The
  URL comes from the provider, so only HTTPS hosts of QQ's own media domains
  are fetched, and redirects are not followed.
  """

  require Logger

  alias SalixStore.Blob

  @media_host_suffixes ~w(.qq.com .qq.com.cn .qpic.cn)

  # Default ceiling for one attachment. The download streams into Blob (never
  # buffering the whole file), so this can be large; 200 MiB is the largest
  # file QQ lets a bot send. Override via :salix_im, :qq_file_max_bytes.
  @default_max_bytes 200 * 1024 * 1024

  @doc "Configured max size of one attachment to download."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: SystemsRuntime.get_env(:salix_im, :qq_file_max_bytes, @default_max_bytes)

  @spec download(String.t(), term(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def download(agent_id, url, max_bytes) when is_binary(url) and is_integer(max_bytes) do
    if allowed?(url) do
      stream(agent_id, url, max_bytes)
    else
      # The host alone: the address carries a signed key.
      Logger.warning("qq_file_host_refused", host: inspect(URI.parse(url).host))
      {:error, :missing_download_url}
    end
  end

  def download(_agent_id, _url, _max_bytes), do: {:error, :missing_download_url}

  @doc "True when `url` is an address of QQ's own media hosts."
  @spec allowed?(term()) :: boolean()
  def allowed?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host = String.downcase(host)
        Enum.any?(media_host_suffixes(), &String.ends_with?(host, &1))

      %URI{scheme: "http", host: host} when is_binary(host) ->
        host in test_hosts()

      _other ->
        false
    end
  end

  def allowed?(_url), do: false

  defp media_host_suffixes, do: @media_host_suffixes

  # Tests serve attachments from a local HTTP stub.
  defp test_hosts, do: List.wrap(SystemsRuntime.get_env(:salix_im, :qq_media_test_hosts, []))

  defp stream(agent_id, url, max_bytes) do
    state_key = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    Process.put(state_key, Blob.put_stream_init(agent_id))

    try do
      result =
        Req.get(url,
          retry: false,
          redirect: false,
          decode_body: false,
          into: fn {:data, chunk}, {req, resp} ->
            size = (resp.private[:qq_bytes] || 0) + byte_size(chunk)

            cond do
              resp.status != 200 ->
                {:halt, {req, resp}}

              size > max_bytes ->
                {:halt,
                 {req, Req.Response.put_private(resp, :qq_error, {:size_limit, size, max_bytes})}}

              true ->
                case Blob.put_stream_step(Process.get(state_key), chunk) do
                  {:ok, state} ->
                    Process.put(state_key, state)
                    {:cont, {req, Req.Response.put_private(resp, :qq_bytes, size)}}

                  {:error, _reason, state} ->
                    Process.put(state_key, state)

                    {:halt,
                     {req,
                      Req.Response.put_private(resp, :qq_error, :qq_file_storage_unavailable)}}
                end
            end
          end
        )

      case result do
        {:ok, %{status: 200} = resp} ->
          if error = resp.private[:qq_error] do
            Blob.put_stream_abort(Process.get(state_key))
            {:error, error}
          else
            with {:ok, ref} <- Blob.put_stream_finish(Process.get(state_key)) do
              {:ok, %{ref: ref, size: resp.private[:qq_bytes] || 0}}
            end
          end

        _other ->
          Blob.put_stream_abort(Process.get(state_key))
          {:error, :qq_file_unavailable}
      end
    rescue
      _error ->
        Blob.put_stream_abort(Process.get(state_key))
        {:error, :qq_file_unavailable}
    after
      Process.delete(state_key)
    end
  end
end
