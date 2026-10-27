defmodule Comma.MiniApps.Drive do
  @moduledoc """
  The `drive.app_folder` capability: an app reaches only `Apps/<app name>/`
  of the viewer Workspace's Comma Drive, through the `SalixAgent.Drive` port
  with that Workspace's Group (as `CommaWeb.DriveBrowse` does).

  Only a viewer who reaches the app through a Workspace (its owner Workspace
  or an Install) has a Drive: a link viewer or a guest gets `unsupported`.
  The capability must be in the Version's manifest and granted on the
  Workspace's grants (the app's, or its Install's). Paths are relative to
  the app folder; `..`, absolute paths, backslashes and control characters
  are refused. Files are at most 20 MiB.
  """

  alias SalixAgent.Drive

  @max_bytes 20 * 1024 * 1024
  @max_path_bytes 1_024

  def max_bytes, do: @max_bytes

  @doc "`:ok` when this runtime call may use the app folder."
  def access(%{kind: kind, guest: guest}) when kind == :link or guest == true,
    do: {:error, :unsupported}

  def access(rt) do
    granted =
      case rt do
        %{kind: :owner, app: app} -> app.grants
        %{kind: :install, install: %{grants: grants}} -> grants
        _ -> []
      end

    if "drive.app_folder" in (rt.version.manifest["capabilities"] || []) and
         "drive.app_folder" in granted,
       do: :ok,
       else: {:error, :not_granted}
  end

  @doc "The app folder of an app name: `Apps/<name>` with unsafe characters replaced."
  def folder(name) do
    safe =
      name
      |> to_string()
      |> String.replace(~r/[^\p{L}\p{N} ._-]/u, "-")
      |> String.trim()
      |> String.trim_leading(".")
      |> String.slice(0, 60)

    "Apps/" <> if(safe == "", do: "App", else: safe)
  end

  @doc "The Drive path of `path` inside the app folder (`\"\"` is the folder)."
  def path(app, path) when is_binary(path) do
    cond do
      path == "" -> {:ok, folder(app.name)}
      byte_size(path) > @max_path_bytes -> {:error, :invalid}
      not String.valid?(path) -> {:error, :invalid}
      String.starts_with?(path, "/") -> {:error, :invalid}
      String.contains?(path, "\\") -> {:error, :invalid}
      Regex.match?(~r/[\x00-\x1f\x7f]/, path) -> {:error, :invalid}
      Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])) -> {:error, :invalid}
      true -> {:ok, folder(app.name) <> "/" <> path}
    end
  end

  def path(_app, _path), do: {:error, :invalid}

  @doc "The entries of a directory in the app folder; a folder not made yet is empty."
  def list(group_id, full_path) do
    case Drive.impl().list(group_id, full_path) do
      {:ok, entries} ->
        {:ok,
         for %{kind: kind} = entry <- entries, kind in ["file", "dir"] do
           %{
             "name" => entry.name,
             "kind" => kind,
             "size" => entry.size,
             "updated_at" => iso(entry[:modified_at])
           }
         end}

      {:error, :not_found} ->
        {:ok, []}

      error ->
        mapped(error)
    end
  end

  @doc "One file's bytes (at most 20 MiB)."
  def read(group_id, full_path) do
    case Drive.impl().read(group_id, full_path, @max_bytes) do
      {:ok, _body, true} -> {:error, :too_large}
      {:ok, body, false} -> {:ok, body}
      error -> mapped(error)
    end
  end

  def write(group_id, full_path, body) when byte_size(body) <= @max_bytes do
    case Drive.impl().write(group_id, full_path, body, byte_size(body)) do
      {:ok, _result} -> :ok
      error -> mapped(error)
    end
  end

  def write(_group_id, _full_path, _body), do: {:error, :too_large}

  def delete(group_id, full_path) do
    case Drive.impl().delete(group_id, full_path) do
      {:ok, _result} -> :ok
      {:error, :not_found} -> :ok
      error -> mapped(error)
    end
  end

  defp mapped({:error, :not_found}), do: {:error, :not_found}
  defp mapped({:error, :drive_not_configured}), do: {:error, :unavailable}
  defp mapped({:error, _reason}), do: {:error, :unavailable}

  defp iso(seconds) when is_integer(seconds),
    do: seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp iso(_seconds), do: nil
end
