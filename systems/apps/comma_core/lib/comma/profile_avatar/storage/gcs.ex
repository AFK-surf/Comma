defmodule Comma.ProfileAvatar.Storage.GCS do
  @moduledoc "Google Cloud Storage adapter using Workload Identity/ADC through Goth."

  @behaviour Comma.ProfileAvatar.Storage

  alias GoogleApi.Storage.V1.Api.Objects
  alias GoogleApi.Storage.V1.Connection
  alias GoogleApi.Storage.V1.Model.Object

  @goth_name Comma.ProfileAvatar.Goth
  @connect_timeout_ms 5_000
  @request_timeout_ms 30_000

  @impl true
  def start_put(key, content_type) do
    metadata = %Object{name: key, contentType: content_type}

    with {:ok, connection} <- connection(),
         {:ok, %Tesla.Env{} = response} <-
           Objects.storage_objects_insert_resumable(
             connection,
             bucket(),
             "resumable",
             body: metadata,
             ifGenerationMatch: "0"
           ),
         session_url when is_binary(session_url) <- Tesla.get_header(response, "location") do
      {:ok, session_url}
    else
      nil -> {:error, :missing_upload_session}
      {:ok, _unexpected_response} -> {:error, :invalid_upload_session_response}
      other -> other
    end
  end

  # google_api_storage exposes resumable-session initiation but not the
  # session completion/cancellation calls. Keep those two protocol requests
  # narrow and isolated here so the caller can durably persist the session URL
  # before any object bytes are sent.
  @impl true
  def finish_put(session_url, path, content_type, byte_size) do
    with {:ok, connection} <- connection(),
         {:ok, body} <- File.read(path),
         {:ok, %{status: status}} when status in [200, 201] <-
           Tesla.put(connection, session_url, body,
             headers: [
               {"content-type", content_type},
               {"content-length", Integer.to_string(byte_size)},
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
    with {:ok, connection} <- connection() do
      case Tesla.delete(connection, session_url) do
        {:ok, %{status: status}} when status in [200, 204, 404, 410, 499] -> :ok
        {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
        other -> other
      end
    end
  end

  @impl true
  def get(key) do
    with {:ok, connection} <- connection() do
      case Objects.storage_objects_get(connection, bucket(), key, alt: "media") do
        {:ok, %{body: body}} when is_binary(body) -> {:ok, body}
        {:error, %{status: 404}} -> {:error, :not_found}
        other -> other
      end
    end
  end

  @impl true
  def delete(key) do
    with {:ok, connection} <- connection() do
      case Objects.storage_objects_delete(connection, bucket(), key) do
        {:ok, _response} -> :ok
        {:error, %{status: 404}} -> :ok
        other -> other
      end
    end
  end

  def child_spec do
    Supervisor.child_spec({Goth, name: @goth_name}, id: @goth_name)
  end

  defp connection do
    case Goth.fetch(@goth_name) do
      {:ok, token} -> {:ok, connection_for_token(token.token)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def connection_for_token(token) when is_binary(token) do
    middleware = token |> Connection.new() |> Tesla.Client.middleware()

    Tesla.client(
      middleware,
      {Tesla.Adapter.Httpc, connect_timeout: @connect_timeout_ms, timeout: @request_timeout_ms}
    )
  end

  defp bucket do
    Comma.ProfileAvatar.Storage.config() |> Keyword.fetch!(:bucket)
  end
end
