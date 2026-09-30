defmodule SalixIM.SlackSemanticFiles do
  @moduledoc """
  Background-only Slack attachment access. The exact configured active connect
  owns the credential; neither source URLs nor Slack credentials reach the GPU.
  No message, mirror or ordinary tool invokes this module.
  """
  alias SalixIM.Provider.Slack.API
  alias SalixIM.{ProviderConnects, SlackFiles}
  @max_bytes 512 * 1024 * 1024
  @allow_loopback Mix.env() == :test

  def extract(scope, file_id, consumer, opts \\ []) do
    cancelled = Keyword.get(opts, :cancelled, fn -> false end)

    result =
      with false <- cancelled.(),
           {:ok, connect} <- resolve_connect(scope),
           installation = API.installation(connect),
           %{"ok" => true, "channel" => %{"is_member" => true}} <-
             API.request_form(
               installation,
               "conversations.info",
               %{"channel" => scope["channel_id"]},
               timeout_ms: 1500
             ),
           %{"ok" => true, "file" => %{"id" => ^file_id} = file} <-
             API.request_form(installation, "files.info", %{"file" => file_id}, timeout_ms: 1500),
           :ok <- supported_file(file),
           url = SlackFiles.download_url(file),
           true <- download_origin?(URI.parse(url)),
           mime = SlackFiles.mime(file) do
        download(installation, url, mime, consumer, cancelled)
      else
        {:error, :unsupported_attachment} = error ->
          error

        {:error, :attachment_inaccessible} = error ->
          error

        %{"ok" => true, "channel" => %{"is_member" => false}} ->
          {:error, :attachment_inaccessible}

        _ ->
          {:error, :semantic_attachment_unavailable}
      end

    if cancelled.(), do: {:error, :preempted}, else: result
  rescue
    error in API.Error ->
      # The existing Slack adapter raises API-level failures. They do not
      # reach the `with` response-pattern branches above. Definite revoked
      # access/deletion is terminal for this observation; a later canonical
      # sweep may rediscover it after access is restored. Transport/rate-limit
      # failures remain retryable and never authorize content access.
      if error.message in ~w(file_not_found channel_not_found not_in_channel invalid_auth token_revoked account_inactive),
        do: {:error, :attachment_inaccessible},
        else: {:error, :semantic_attachment_unavailable}

    _ ->
      {:error, :semantic_attachment_unavailable}
  catch
    _, _ -> {:error, :semantic_attachment_unavailable}
  end

  defp resolve_connect(scope) do
    case ProviderConnects.get_active_connect_by_id(
           scope["group_id"],
           scope["connect_id"],
           "slack"
         ) do
      {:ok, connect} ->
        if connect["tenant_id"] == scope["tenant_id"] and
             connect["workspace_id"] == scope["workspace_id"],
           do: {:ok, connect},
           else: {:error, :attachment_inaccessible}

      {:error, :not_found} ->
        {:error, :attachment_inaccessible}

      other ->
        other
    end
  end

  defp download_origin?(%URI{scheme: "https", host: host, port: 443, userinfo: nil}),
    do: host in ["files.slack.com", "files-pri.slack.com"]

  defp download_origin?(%URI{scheme: "http", host: "127.0.0.1", userinfo: nil}),
    do: @allow_loopback

  defp download_origin?(_), do: false

  defp download(installation, url, mime, consumer, cancelled) do
    path = Path.join(System.tmp_dir!(), "comma-semantic-#{SalixStore.ULID.generate()}")
    {:ok, output} = File.open(path, [:write, :binary, :exclusive])
    File.chmod!(path, 0o600)
    deadline = System.monotonic_time(:millisecond) + 300_000

    try do
      result =
        API.stream_file(
          installation,
          url,
          fn {:data, chunk}, {req, resp} ->
            size = (resp.private[:semantic_bytes] || 0) + byte_size(chunk)

            if not cancelled.() and resp.status == 200 and size <= @max_bytes and
                 System.monotonic_time(:millisecond) < deadline do
              :ok = IO.binwrite(output, chunk)
              {:cont, {req, Req.Response.put_private(resp, :semantic_bytes, size)}}
            else
              {:halt, {req, Req.Response.put_private(resp, :semantic_failed, true)}}
            end
          end,
          redirect: false,
          receive_timeout: 5000,
          pool_timeout: 50,
          finch: SalixAnalytics.SlackSemanticIndex.HTTP
        )

      File.close(output)

      case result do
        {:ok, %{status: 200, private: private}}
        when not is_map_key(private, :semantic_failed) ->
          if cancelled.(), do: {:error, :preempted}, else: consumer.(path, mime)

        _ ->
          {:error, :semantic_attachment_unavailable}
      end
    after
      File.close(output)
      File.rm(path)
    end
  end

  defp supported_file(file) do
    size = file["size"]

    if (is_nil(size) or (is_integer(size) and size in 0..@max_bytes)) and
         supported?(SlackFiles.mime(file)), do: :ok, else: {:error, :unsupported_attachment}
  end

  defp supported?(mime),
    do:
      String.starts_with?(mime, ["image/", "audio/", "video/", "text/"]) or
        mime in ["application/pdf", "application/vnd.slack-docs"]
end
