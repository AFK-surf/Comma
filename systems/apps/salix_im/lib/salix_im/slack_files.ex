defmodule SalixIM.SlackFiles do
  @moduledoc """
  Shared helpers for streaming Slack file attachments into the agent VFS.

  Used both by inbound event handling (`SalixIM.ProviderHTTP`) and by the Slack
  read APIs that return historic messages (`SalixIM.Provider.Slack`), so a file
  is staged the same way no matter how the agent encountered it. Downloads are
  streamed straight into S3 multipart upload with end-to-end backpressure — a
  file is never buffered whole in memory — and the bytes are committed to the
  agent VFS by reference (no bytes pass through the agent).
  """

  alias SalixStore.Blob
  alias SalixIM.Ports.AgentWorkspace
  alias SalixIM.Provider.Slack.API, as: SlackAPI

  # Default ceiling for files we stage into the agent VFS. Streaming staging
  # uploads in chunks (never buffering the whole file), so this can be large;
  # override via :salix_im, :slack_file_max_bytes.
  @default_max_bytes 1024 * 1024 * 1024

  @doc "Configured max file size to stage."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: Application.get_env(:salix_im, :slack_file_max_bytes, @default_max_bytes)

  @doc "True when a Slack file's declared size exceeds the staging ceiling."
  @spec oversized?(map()) :: boolean()
  def oversized?(file), do: is_integer(file["size"]) and file["size"] > max_bytes()

  @doc "Best-effort mime for a Slack file, defaulting to octet-stream."
  @spec mime(map()) :: String.t()
  def mime(file) do
    case trim(file["mimetype"]) do
      "" -> "application/octet-stream"
      mime -> mime
    end
  end

  @doc "Best-effort display name for a Slack file."
  @spec name(map()) :: String.t()
  def name(file) do
    first_nonblank([file["name"], file["title"], file["id"], "attachment"])
  end

  @doc "The downloadable URL for a Slack file, or `\"\"` when absent."
  @spec download_url(map()) :: String.t()
  def download_url(file), do: first_nonblank([file["url_private_download"], file["url_private"]])

  @doc """
  Deterministic, VFS-safe path for a Slack file, scoped by opaque source
  identity and preserving the original extension so `read_file` can tell what
  kind of file it is. The returned path intentionally does not expose Slack
  channel, thread, or file ids; agents only need a readable workspace path.
  Stable across re-fetches of the same message, so re-staging is an idempotent
  overwrite.
  """
  @spec vfs_path(String.t(), String.t(), map()) :: String.t()
  def vfs_path(channel_id, ts, file) do
    file_id = path_segment(file["id"], "file")
    source = opaque_id([channel_id, ts, file_id])

    "/slack/attachments/#{source}-#{basename(file, file_id)}"
  end

  @doc """
  Deterministic opaque VFS path for a file fetched by id (no channel/ts
  context), e.g. via `slack.fetch_file`. Keyed by file id so re-fetching
  overwrites in place, without leaking the provider file id in the path.
  """
  @spec file_vfs_path(map()) :: String.t()
  def file_vfs_path(file) do
    file_id = path_segment(file["id"], "file")
    "/slack/files/#{opaque_id([file_id])}-#{basename(file, file_id)}"
  end

  @doc """
  Stream a Slack file at `url` into the agent VFS at `path` and commit it by
  reference. Returns `{:ok, path}`.
  """
  @spec stage(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def stage(agent_id, token, path, url) do
    with {:ok, ref} <- stream_to_blob(agent_id, token, url),
         {:ok, _} <- AgentWorkspace.put_ref(agent_id, path, ref) do
      {:ok, path}
    end
  end

  @doc """
  Stream a Slack file straight into S3 multipart upload with end-to-end
  backpressure: `into: fun` uses `Finch.stream_while` (passive `recv`), so the
  next network read only happens after the current chunk's part upload returns.
  Nothing is buffered beyond one in-flight multipart part. Returns the blob ref.
  """
  @spec stream_to_blob(String.t(), String.t(), String.t()) :: {:ok, Blob.ref()} | {:error, term()}
  def stream_to_blob(agent_id, token, url) do
    init = Blob.put_stream_init(agent_id)

    result =
      SlackAPI.stream_file(
        token,
        url,
        fn {:data, chunk}, {req, resp} ->
          cond do
            resp.status not in 200..299 ->
              {:halt, {req, resp}}

            resp.private[:blob_error] != nil ->
              {:halt, {req, resp}}

            true ->
              state = resp.private[:blob_state] || init

              case Blob.put_stream_step(state, chunk) do
                {:ok, state} ->
                  {:cont, {req, Req.Response.put_private(resp, :blob_state, state)}}

                {:error, reason, state} ->
                  resp =
                    resp
                    |> Req.Response.put_private(:blob_state, state)
                    |> Req.Response.put_private(:blob_error, reason)

                  {:halt, {req, resp}}
              end
          end
        end
      )

    case result do
      {:ok, resp} ->
        state = resp.private[:blob_state] || init

        cond do
          resp.status not in 200..299 ->
            Blob.put_stream_abort(state)
            {:error, "slack download HTTP #{resp.status}"}

          resp.private[:blob_error] != nil ->
            Blob.put_stream_abort(state)
            {:error, resp.private[:blob_error]}

          true ->
            Blob.put_stream_finish(state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Sanitized "<name>.<ext>" preserving the original extension, falling back to
  # the declared mimetype for the extension when the name has none.
  defp basename(file, fallback) do
    raw = trim(file["name"])
    base = raw |> Path.rootname() |> path_segment(fallback)

    ext =
      case raw |> Path.extname() |> String.trim_leading(".") |> String.downcase() do
        "" -> mime_ext(file["mimetype"])
        e -> e
      end

    case ext do
      nil -> base
      "" -> base
      e -> base <> "." <> path_segment(e, "bin")
    end
  end

  defp path_segment(value, fallback) do
    cleaned =
      value
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.trim("_")

    if cleaned == "", do: fallback, else: cleaned
  end

  defp opaque_id(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  # Used only as an extension fallback for files whose name lacks one; keeps
  # image extensions accurate so read_file still recognizes inline images.
  defp mime_ext(mime) do
    case mime |> to_string() |> String.downcase() do
      "image/png" -> "png"
      "image/gif" -> "gif"
      "image/webp" -> "webp"
      "image/jpeg" -> "jpg"
      "image/jpg" -> "jpg"
      _ -> nil
    end
  end

  defp first_nonblank(values) do
    Enum.find_value(values, "", fn v ->
      s = trim(v)
      if s != "", do: s, else: nil
    end)
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
