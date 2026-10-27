defmodule Comma.ProfileAvatar.Storage.GCS do
  @moduledoc """
  Google Cloud Storage adapter using Workload Identity/ADC through Goth.

  It speaks the JSON API's resumable-upload protocol directly: the session URL
  is returned before any object bytes are sent, so the caller can durably
  persist it, and completion or cancellation are requests to that URL.
  """

  @behaviour Comma.ProfileAvatar.Storage

  @goth_name Comma.ProfileAvatar.Goth
  @base_url "https://storage.googleapis.com"
  @connect_timeout_ms 5_000
  @request_timeout_ms 30_000

  @impl true
  def start_put(key, content_type) do
    case request(:post, "#{@base_url}/upload/storage/v1/b/#{bucket()}/o",
           params: [uploadType: "resumable", ifGenerationMatch: "0"],
           headers: [{"x-upload-content-type", content_type}],
           json: %{"name" => key, "contentType" => content_type}
         ) do
      {:ok, %{status: 200} = response} ->
        case Req.Response.get_header(response, "location") do
          [session_url | _] -> {:ok, session_url}
          [] -> {:error, :missing_upload_session}
        end

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def finish_put(session_url, path, content_type, byte_size) do
    with {:ok, body} <- File.read(path),
         {:ok, %{status: status}} when status in [200, 201] <-
           request(:put, session_url,
             body: body,
             headers: [
               {"content-type", content_type},
               {"content-range", "bytes 0-#{byte_size - 1}/#{byte_size}"}
             ]
           ) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      other -> other
    end
  end

  @impl true
  def cancel_put(session_url) do
    case request(:delete, session_url) do
      {:ok, %{status: status}} when status in [200, 204, 404, 410, 499] -> :ok
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key) do
    case request(:get, object_url(key), params: [alt: "media"]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case request(:delete, object_url(key)) do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def child_spec do
    Supervisor.child_spec({Goth, name: @goth_name}, id: @goth_name)
  end

  # Bodies are kept as sent: avatars are stored uncompressed and a decoded body
  # would no longer be the object's bytes.
  defp request(method, url, options \\ []) do
    with {:ok, token} <- token() do
      [
        method: method,
        url: url,
        auth: {:bearer, token},
        compressed: false,
        decode_body: false,
        retry: false,
        connect_options: [timeout: @connect_timeout_ms],
        receive_timeout: @request_timeout_ms
      ]
      |> Keyword.merge(options)
      |> Keyword.merge(config()[:request_options] || [])
      |> Req.request()
    end
  end

  defp token do
    case config()[:token] do
      token when is_binary(token) ->
        {:ok, token}

      nil ->
        case Goth.fetch(@goth_name) do
          {:ok, token} -> {:ok, token.token}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp object_url(key),
    do: "#{@base_url}/storage/v1/b/#{bucket()}/o/#{URI.encode(key, &URI.char_unreserved?/1)}"

  defp bucket, do: config() |> Keyword.fetch!(:bucket)

  defp config, do: Comma.ProfileAvatar.Storage.config()
end
