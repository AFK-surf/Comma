defmodule Comma.ProfileAvatar.Storage.S3 do
  @moduledoc """
  S3-compatible profile avatar storage for local development.

  A one-part multipart upload preserves the profile lifecycle's durable
  start/finish/cancel boundary: the upload id is persisted before bytes are
  sent, completion publishes the immutable object, and cleanup can abort an
  unfinished session after a crash.
  """

  @behaviour Comma.ProfileAvatar.Storage

  @session_prefix "comma-s3-multipart:"
  @part_number 1

  @impl true
  def start_put(key, content_type) do
    operation = ExAws.S3.initiate_multipart_upload(bucket(), key, content_type: content_type)

    case request(operation) do
      {:ok, %{body: %{upload_id: upload_id}}} when is_binary(upload_id) and upload_id != "" ->
        {:ok, encode_session(key, upload_id)}

      {:ok, _response} ->
        {:error, :invalid_upload_session_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def finish_put(session, path, _content_type, expected_byte_size) do
    with {:ok, key, upload_id} <- decode_session(session),
         {:ok, body} <- File.read(path),
         :ok <- verify_byte_size(body, expected_byte_size),
         {:ok, upload_response} <-
           request(ExAws.S3.upload_part(bucket(), key, upload_id, @part_number, body)),
         {:ok, etag} <- response_header(upload_response, "etag"),
         {:ok, _complete_response} <-
           request(
             ExAws.S3.complete_multipart_upload(
               bucket(),
               key,
               upload_id,
               [{@part_number, etag}]
             )
           ) do
      :ok
    end
  end

  @impl true
  def cancel_put(session) do
    with {:ok, key, upload_id} <- decode_session(session) do
      case request(ExAws.S3.abort_multipart_upload(bucket(), key, upload_id)) do
        {:ok, _response} -> :ok
        {:error, {:http_error, 404, _response}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def get(key) do
    case request(ExAws.S3.get_object(bucket(), key)) do
      {:ok, %{body: body}} when is_binary(body) -> {:ok, body}
      {:error, {:http_error, 404, _response}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case request(ExAws.S3.delete_object(bucket(), key)) do
      {:ok, _response} -> :ok
      {:error, {:http_error, 404, _response}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(operation), do: ExAws.request(operation, request_config())

  defp request_config do
    config = Comma.ProfileAvatar.Storage.config()
    endpoint = config |> Keyword.fetch!(:endpoint) |> URI.parse()

    [
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: Keyword.fetch!(config, :secret_access_key),
      region: Keyword.get(config, :region, "us-east-1"),
      scheme: endpoint.scheme <> "://",
      host: endpoint.host,
      port: endpoint.port,
      virtual_host: false,
      http_client: Keyword.get(config, :http_client, ExAws.Request.Req)
    ]
  end

  defp bucket, do: Comma.ProfileAvatar.Storage.config() |> Keyword.fetch!(:bucket)

  defp encode_session(key, upload_id) do
    payload = Jason.encode!(%{"key" => key, "upload_id" => upload_id})
    @session_prefix <> Base.url_encode64(payload, padding: false)
  end

  defp decode_session(@session_prefix <> encoded) do
    with {:ok, payload} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"key" => key, "upload_id" => upload_id}} <- Jason.decode(payload),
         true <- key != "" and upload_id != "" do
      {:ok, key, upload_id}
    else
      _error -> {:error, :invalid_upload_session}
    end
  end

  defp decode_session(_session), do: {:error, :invalid_upload_session}

  defp verify_byte_size(body, expected) when byte_size(body) == expected, do: :ok
  defp verify_byte_size(_body, _expected), do: {:error, :avatar_size_changed}

  defp response_header(%{headers: headers}, expected_name) when is_list(headers) do
    Enum.find_value(headers, {:error, :missing_part_etag}, fn {name, value} ->
      if String.downcase(name) == expected_name, do: {:ok, value}
    end)
  end

  defp response_header(_response, _expected_name), do: {:error, :missing_part_etag}
end
