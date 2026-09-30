defmodule Salix.Bindings.IMAgentWorkspace do
  @moduledoc false

  @behaviour SalixIM.Ports.AgentWorkspace

  alias SalixAgent.{AgentWorkspace, FileBackend}
  alias SalixStore.Blob

  @impl true
  def read_upload(agent_id, path, title) do
    path = trim(path)

    cond do
      trim(agent_id) == "" ->
        {:error, "agent VFS is not available"}

      path == "" ->
        {:error, "path is required"}

      true ->
        with {:ok, data} <- read_visible_file(agent_id, path),
             {:ok, filename} <- upload_filename(path, title) do
          {:ok, %{data: data, filename: filename, path: path}}
        else
          {:error, :not_found} ->
            {:error,
             "file not found in agent-visible files: #{path}. Provider file APIs read visible file paths. If the file is on a host or remote environment, copy it into the agent-visible file system first and retry with that path."}

          {:error, reason} ->
            {:error, control_error(reason)}
        end
    end
  end

  # `SalixAgent.Workspace.list/2` already answers the three-way shape the port
  # documents (`{:ok, entries}` / `{:file, entry}` / `{:error, :not_found}`), so
  # nothing is flattened here: a caller that cannot tell "no such path" from "the
  # workspace could not be read" has no way to answer the person who asked.
  @impl true
  def list(agent_id, path) do
    if trim(agent_id) == "" do
      {:error, "agent VFS is not available"}
    else
      SalixAgent.Workspace.list(agent_id, path)
    end
  end

  @impl true
  def write(agent_id, path, body) do
    cond do
      trim(agent_id) == "" ->
        {:error, "agent VFS is not available"}

      trim(path) == "" ->
        {:error, "path is required"}

      true ->
        case SalixAgent.Workspace.write(agent_id, path, body, create: true) do
          {:ok, file} -> {:ok, %{path: file["path"] || path, size: file["size"]}}
          {:error, reason} -> {:error, control_error(reason)}
        end
    end
  end

  @impl true
  def put_ref(agent_id, path, ref) do
    cond do
      trim(agent_id) == "" ->
        {:error, "agent VFS is not available"}

      trim(path) == "" ->
        {:error, "path is required"}

      true ->
        case SalixAgent.Workspace.put_ref(agent_id, path, ref, create: true) do
          {:ok, file} -> {:ok, %{path: file["path"] || path, size: file["size"]}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def file_ref(agent_id, path) do
    cond do
      trim(agent_id) == "" ->
        {:error, "agent VFS is not available"}

      trim(path) == "" ->
        {:error, "path is required"}

      true ->
        case AgentWorkspace.entry(agent_id, path) do
          {:ok, %{"ref" => ref}} -> {:ok, ref}
          {:error, :not_found} -> {:error, "file not found in agent VFS: #{path}"}
          {:error, reason} -> {:error, control_error(reason)}
        end
    end
  end

  @impl true
  def read_stream(agent_id, path) do
    cond do
      trim(agent_id) == "" ->
        {:error, "agent VFS is not available"}

      trim(path) == "" ->
        {:error, "path is required"}

      true ->
        with {:ok, stream, size} <- stream_visible_file(agent_id, path) do
          {:ok, stream, size, Path.basename(path)}
        else
          {:error, :not_found} -> {:error, "file not found in agent-visible files: #{path}"}
          {:error, reason} -> {:error, control_error(reason)}
        end
    end
  end

  @impl true
  def read_ref_stream(agent_id, ref, filename) do
    filename = trim(filename)

    cond do
      trim(agent_id) == "" ->
        {:error, "agent VFS is not available"}

      filename in ["", ".", "..", "/"] ->
        {:error, "filename is required"}

      not valid_blob_ref?(ref) ->
        {:error, "invalid immutable blob ref"}

      true ->
        with {:ok, stream, size} <- Blob.stream(agent_id, ref) do
          {:ok, stream, size, filename}
        end
    end
  end

  defp upload_filename(path, title) do
    filename =
      case trim(title) do
        "" -> Path.basename(path)
        override -> override
      end

    if filename in ["", ".", "/"],
      do: {:error, "path must point to a file"},
      else: {:ok, filename}
  end

  defp read_visible_file(agent_id, path) do
    case provider_tool_context(agent_id) do
      %{} = ctx when map_size(ctx) > 0 ->
        case FileBackend.read(ctx, path) do
          {:ok, body, false} -> {:ok, body}
          {:ok, _body, true} -> {:error, :too_large}
          {:error, _} = err -> err
        end

      _ ->
        # Non-session system deliveries and inbound file staging use this port
        # without an agent runtime tool context. Those paths can only address
        # ordinary agent workspace files; session runtime mounts require the
        # FileBackend branch above with a session_id.
        AgentWorkspace.read(agent_id, path)
    end
  end

  defp stream_visible_file(agent_id, path) do
    case provider_tool_context(agent_id) do
      %{} = ctx when map_size(ctx) > 0 -> FileBackend.stream(ctx, path)
      _ -> SalixAgent.Workspace.stream(agent_id, path)
    end
  end

  defp valid_blob_ref?(ref) do
    kind = ref[:kind] || ref["kind"]
    uuid = trim(ref[:uuid] || ref["uuid"])
    hash = trim(ref[:hash] || ref["hash"])
    size = ref[:size] || ref["size"]

    kind == "blob" and uuid != "" and hash != "" and is_integer(size) and size >= 0
  end

  defp provider_tool_context(agent_id) do
    ctx = SalixIM.Provider.current_tool_context()

    case ctx["session_id"] || ctx[:session_id] do
      value when is_binary(value) and value != "" ->
        ctx
        |> Map.put_new(:agent_id, ctx["agent_id"] || agent_id)
        |> Map.put_new(:session_id, value)

      _ ->
        %{}
    end
  end

  defp control_error(reason) when is_binary(reason), do: reason
  defp control_error({:bad_request, message}) when is_binary(message), do: message
  defp control_error(reason), do: inspect(reason)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
