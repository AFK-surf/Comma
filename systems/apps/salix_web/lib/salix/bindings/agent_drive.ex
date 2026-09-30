defmodule Salix.Bindings.AgentDrive do
  @moduledoc """
  `SalixAgent.Drive` over the Synchronicity control-plane file API: a group
  resolves to its Drive binding (`Salix.Control.DriveBindings.handle/1`), and
  every operation is one `Salix.Drive.Files` call with it.

  Product-neutral: the binding is a Salix control record, written by Comma's
  Workspace convergence for a Comma deployment and by an operator in the Salix
  dashboard for a BridgeForTeams one.
  """

  @behaviour SalixAgent.Drive

  alias Salix.Control.DriveBindings
  alias Salix.Drive.Files

  @impl true
  def list(group_id, path) do
    with {:ok, handle} <- DriveBindings.handle(group_id),
         {:ok, entries} <- Files.list(handle, path) do
      {:ok, Enum.map(entries, &entry/1)}
    end
  end

  @impl true
  def stat(group_id, path) do
    with {:ok, handle} <- DriveBindings.handle(group_id),
         {:ok, entries} <- Files.list(handle, parent(path)) do
      case Enum.find(entries, &(&1.path == path or &1.name == Path.basename(path))) do
        nil -> {:error, :not_found}
        %{kind: "tombstone"} -> {:error, :not_found}
        found -> {:ok, entry(found)}
      end
    end
  end

  @impl true
  def read(group_id, path, max_bytes) do
    with {:ok, handle} <- DriveBindings.handle(group_id) do
      Files.read(handle, path, max_bytes)
    end
  end

  @impl true
  def stream(group_id, path) do
    with {:ok, handle} <- DriveBindings.handle(group_id) do
      Files.stream(handle, path)
    end
  end

  @impl true
  def write(group_id, path, body, size) do
    with {:ok, handle} <- DriveBindings.handle(group_id),
         {:ok, result} <- Files.write(handle, path, body, size) do
      {:ok, %{size: result.size, root: result.root}}
    end
  end

  @impl true
  def delete(group_id, path) do
    with {:ok, handle} <- DriveBindings.handle(group_id) do
      Files.delete(handle, path)
    end
  end

  @impl true
  def status(group_id) do
    case DriveBindings.handle(group_id) do
      {:ok, handle} ->
        case Files.status(handle) do
          {:ok, %{browse_enabled: browse, attached: attached, writes: writes}} ->
            available = browse and attached

            {:ok,
             %{
               available: available,
               writable: available and writes,
               detail: status_detail(browse, attached, writes)
             }}

          {:error, reason} ->
            {:ok, %{available: false, writable: false, detail: describe(reason)}}
        end

      {:error, reason} ->
        {:ok, %{available: false, writable: false, detail: describe(reason)}}
    end
  end

  defp status_detail(false, _attached, _writes),
    do: "browsing is turned off for this group's Drive in Synchronicity"

  defp status_detail(true, false, _writes),
    do:
      "no Drive replica is attached yet; if the Drive was never opened on a device, open it there first"

  defp status_detail(true, true, false),
    do: "the Drive can be read; its hosted replica is not taking writes right now"

  defp status_detail(true, true, true),
    do:
      "the Drive can be read and written; a write becomes the hosted copy's version and reaches the user's devices at their next sync"

  defp describe(:not_configured), do: "this group has no Drive binding; an operator can add one"
  defp describe(reason), do: SalixAgent.DriveMount.describe(reason)

  defp entry(%{} = raw) do
    %{
      path: raw.path,
      name: raw.name,
      kind: raw.kind,
      size: raw.size,
      modified_at: modified_at(raw.mtime_ns)
    }
  end

  defp modified_at(mtime_ns) when is_integer(mtime_ns) and mtime_ns > 0,
    do: div(mtime_ns, 1_000_000_000)

  defp modified_at(_mtime_ns), do: nil

  defp parent(path) do
    case Path.dirname(path) do
      "." -> ""
      dir -> dir
    end
  end
end
