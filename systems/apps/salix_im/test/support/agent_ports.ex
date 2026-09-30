defmodule SalixIM.TestSupport.AgentDelivery do
  @moduledoc false

  @behaviour SalixIM.Ports.AgentDelivery

  def deliver(agent_id, payload, opts), do: SalixAgent.deliver(agent_id, payload, opts)

  @impl true
  def prepare_conversation_input(agent_id),
    do: SalixAgent.AgentActor.prepare_conversation_input(agent_id)

  @impl true
  def notify_conversation(agent_id, tail),
    do: SalixAgent.AgentActor.notify_conversation(agent_id, tail)

  @impl true
  def conversation_progress(agent, session, participant) do
    with {:ok, sources, _} <- SalixAgent.ConversationConsumer.progress(agent, session),
         do: {:ok, sources[participant]}
  end

  @impl true
  def get_session(agent_id, session_id, opts),
    do: SalixAgent.Runtime.get_session(agent_id, session_id, opts)

  @impl true
  def get_session_messages(agent_id, session_id),
    do: SalixAgent.Runtime.get_session_messages(agent_id, session_id)
end

defmodule SalixIM.TestSupport.SessionActivity do
  @moduledoc false

  @behaviour SalixIM.Ports.SessionActivity

  @impl true
  def get(agent_id, session_id),
    do: SalixAgent.Runtime.get_session_activity(agent_id, session_id)

  @impl true
  def subscribe(_agent_id, _session_id), do: :ok

  @impl true
  def unsubscribe(_agent_id, _session_id), do: :ok
end

defmodule SalixIM.TestSupport.AgentWorkspace do
  @moduledoc false

  @behaviour SalixIM.Ports.AgentWorkspace

  alias SalixAgent.AgentWorkspace

  @impl true
  def read_upload(agent_id, path, title) do
    path = trim(path)

    cond do
      trim(agent_id) == "" ->
        {:error, "agent VFS is not available"}

      path == "" ->
        {:error, "path is required"}

      true ->
        with {:ok, data} <- AgentWorkspace.read(agent_id, path),
             {:ok, filename} <- upload_filename(path, title) do
          {:ok, %{data: data, filename: filename, path: path}}
        else
          {:error, :not_found} ->
            {:error,
             "file not found in agent VFS: #{path}. Provider file APIs only read agent VFS paths. If the file is on a host or remote environment, copy it into the VFS first and retry with the VFS path."}

          {:error, reason} ->
            {:error, control_error(reason)}
        end
    end
  end

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
        with {:ok, stream, size} <- SalixAgent.Workspace.stream(agent_id, path) do
          {:ok, stream, size, Path.basename(path)}
        else
          {:error, :not_found} -> {:error, "file not found in agent VFS: #{path}"}
          {:error, reason} -> {:error, control_error(reason)}
        end
    end
  end

  @impl true
  def read_ref_stream(agent_id, ref, filename) do
    with {:ok, stream, size} <- SalixStore.Blob.stream(agent_id, ref) do
      {:ok, stream, size, filename}
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

  defp control_error(reason) when is_binary(reason), do: reason
  defp control_error({:bad_request, message}) when is_binary(message), do: message
  defp control_error(reason), do: inspect(reason)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
