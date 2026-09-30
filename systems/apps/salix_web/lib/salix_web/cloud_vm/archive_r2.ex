defmodule SalixWeb.CloudVM.ArchiveR2 do
  @moduledoc "Signs exact Connector archive parts for direct R2 transfer."

  @expires_in 120

  def transfer_urls(key, expires_in \\ @expires_in) when is_binary(key) do
    with {:ok, put} <-
           signed_url(:put, key, headers: [{"if-none-match", "*"}], expires_in: expires_in),
         {:ok, get} <- signed_url(:get, key, expires_in: expires_in) do
      {:ok, %{"put_url" => put, "get_url" => get}}
    end
  end

  def read_url(key, expires_in \\ @expires_in), do: signed_url(:get, key, expires_in: expires_in)

  def head(key) do
    with {:ok, url} <- signed_url(:head, key),
         {:ok, %Req.Response{status: status} = response} <-
           Req.request(method: :head, url: url, retry: false, receive_timeout: 20_000) do
      case status do
        200 ->
          case Req.Response.get_header(response, "content-length") do
            [value] ->
              case Integer.parse(value) do
                {size, ""} -> {:ok, size}
                _ -> {:error, :invalid_r2_archive_size}
              end

            _ ->
              {:error, :invalid_r2_archive_size}
          end

        404 ->
          {:error, :not_found}

        _ ->
          {:error, :r2_archive_unavailable}
      end
    else
      {:error, _} -> {:error, :r2_archive_unavailable}
    end
  end

  def list(prefix, max_keys) when is_binary(prefix) and max_keys in 1..100 do
    with {:ok, bucket, config} <- request_config(),
         {:ok, %{body: %{contents: contents, is_truncated: truncated}}} <-
           ExAws.request(
             ExAws.S3.list_objects_v2(bucket, prefix: prefix, max_keys: max_keys),
             config
           ) do
      {:ok, %{keys: Enum.map(contents, & &1.key), complete: truncated != "true"}}
    else
      {:error, _} -> {:error, :r2_archive_unavailable}
      _ -> {:error, :r2_archive_unavailable}
    end
  end

  def delete(key) when is_binary(key) do
    with {:ok, bucket, config} <- request_config(),
         {:ok, _} <- ExAws.request(ExAws.S3.delete_object(bucket, key), config) do
      :ok
    else
      {:error, _} -> {:error, :r2_archive_unavailable}
      _ -> {:error, :r2_archive_unavailable}
    end
  end

  defp request_config do
    case Application.get_env(:salix_web, :cloud_vm_archive_r2) do
      %{"bucket" => bucket} when is_binary(bucket) and bucket != "" ->
        with {:ok, config} <- signing_config() do
          {:ok, bucket, Map.to_list(Map.put(config, :http_client, ExAws.Request.Req))}
        end

      _ ->
        {:error, :r2_archive_not_configured}
    end
  end

  defp signed_url(method, key, opts \\ []) do
    case Application.get_env(:salix_web, :cloud_vm_archive_r2) do
      %{"bucket" => bucket} when is_binary(bucket) and bucket != "" ->
        with {:ok, config} <- signing_config() do
          ExAws.S3.presigned_url(
            config,
            method,
            bucket,
            key,
            Keyword.merge([expires_in: @expires_in, virtual_host: false], opts)
          )
        end

      _ ->
        {:error, :r2_archive_not_configured}
    end
  end

  defp signing_config do
    case Application.get_env(:salix_web, :cloud_vm_archive_r2) do
      %{"endpoint" => endpoint, "access_key_id" => access, "secret_access_key" => secret}
      when is_binary(endpoint) and is_binary(access) and is_binary(secret) ->
        uri = URI.parse(endpoint)

        if uri.scheme == "https" and is_binary(uri.host) and
             String.ends_with?(uri.host, ".r2.cloudflarestorage.com") do
          {:ok,
           ExAws.Config.new(:s3,
             scheme: "https://",
             host: uri.host,
             port: 443,
             region: "auto",
             access_key_id: access,
             secret_access_key: secret
           )}
        else
          {:error, :invalid_r2_archive_endpoint}
        end

      _ ->
        {:error, :r2_archive_not_configured}
    end
  end
end
