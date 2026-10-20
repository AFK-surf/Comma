defmodule Comma.SystemFiles do
  @moduledoc """
  Drive's System Files space: the Group Router's memory and import archive in
  its Agent VFS (`docs/product-features.md`, Files and navigation).

  Only the Workspace owner reaches it, as for the Condensed Workspace. Only
  `/memory/**`, `/imports/**` and `/Comma/**` are visible. The owner may
  create, replace or delete a memory file that `memory.write` could write
  (`SalixAgent.Tools.Memory.allowed_write_path?/1`), an episode of any date
  included. `/imports/**` is the raw archive of a migration and stays
  read-only. `/Comma/**` holds what Comma renders for the owner, such as the
  proactive notebook (`CommaWeb.ProactiveNotebook`), and stays read-only. Salix hides a scoped memory note from a user who may not read it.

  A read answers the file's content `hash`. A write or delete that names it as
  `expected_hash` fails with a conflict when the file changed since. The check
  is not atomic with the commit, so a Router write that lands between them can
  still be overwritten.
  """

  alias Comma.Workspaces
  alias SalixAgent.Tools.Memory

  @roots ["/memory/", "/imports/", "/Comma/"]
  @max_read_bytes 1_000_000
  @max_write_bytes 1_000_000
  @max_path_bytes 1_024
  @max_page 500

  def max_write_bytes, do: @max_write_bytes

  @doc "One page of the files under a directory, in path order."
  @spec list(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def list(user, session, group_id, params) do
    with {:ok, dir} <- directory(params["path"]),
         {:ok, cursor} <- cursor(params["cursor"], dir),
         {:ok, limit} <- limit(params["limit"]),
         {:ok, workspace} <- authorize(user, session, group_id) do
      workspace
      |> Comma.Salix.Client.list_agent_files(dir,
        reader: user["id"],
        cursor: cursor,
        limit: limit
      )
      |> salix_result()
    end
  end

  @doc "One text file, at most #{@max_read_bytes} bytes."
  @spec read(map(), map(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def read(user, session, group_id, path) do
    with {:ok, path} <- file_path(path),
         {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, %{"content" => body, "hash" => hash}} <-
           workspace
           |> Comma.Salix.Client.read_agent_file_as(path, @max_read_bytes, user["id"])
           |> salix_result(),
         true <- String.valid?(body) || {:error, :unsupported_file_type} do
      {:ok, %{"path" => path, "content" => body, "size" => byte_size(body), "hash" => hash}}
    end
  end

  @doc """
  Creates or replaces one memory file with `attrs["content"]`, if it still has
  the optional `attrs["expected_hash"]`.
  """
  @spec write(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def write(user, session, group_id, attrs) do
    with {:ok, path} <- writable_path(attrs["path"]),
         {:ok, content} <- content(attrs["content"]),
         {:ok, expected} <- expected_hash(attrs["expected_hash"]),
         {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, result} <-
           workspace
           |> Comma.Salix.Client.write_agent_file_as(path, content,
             reader: user["id"],
             expected_hash: expected
           )
           |> salix_result() do
      {:ok, %{"path" => path, "size" => byte_size(content), "hash" => result["hash"]}}
    end
  end

  @doc "Deletes one memory file, if it still has the optional `params[\"expected_hash\"]`."
  @spec delete(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def delete(user, session, group_id, params) do
    with {:ok, path} <- writable_path(params["path"]),
         {:ok, expected} <- expected_hash(params["expected_hash"]),
         {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, _result} <-
           workspace
           |> Comma.Salix.Client.delete_agent_file(path,
             reader: user["id"],
             expected_hash: expected
           )
           |> salix_result() do
      {:ok, %{"path" => path, "deleted" => true}}
    end
  end

  @doc "The Router's effective instructions, read-only."
  @spec instructions(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def instructions(user, session, group_id) do
    with {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, content} <-
           workspace |> Comma.Salix.Client.get_router_instructions() |> salix_result() do
      {:ok, %{"content" => content}}
    end
  end

  defp authorize(user, session, group_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, nil) do
      {:ok, workspace}
    end
  end

  # A directory is a visible root or a clean path under one; the listing is
  # of everything under it.
  defp directory(path) do
    with {:ok, path} <- clean(path) do
      dir = if String.ends_with?(path, "/"), do: path, else: path <> "/"

      if Enum.any?(@roots, &String.starts_with?(dir, &1)),
        do: {:ok, dir},
        else: {:error, :not_found}
    end
  end

  defp file_path(path) do
    with {:ok, path} <- clean(path) do
      if not String.ends_with?(path, "/") and Enum.any?(@roots, &String.starts_with?(path, &1)),
        do: {:ok, path},
        else: {:error, :not_found}
    end
  end

  defp writable_path(path) do
    with {:ok, path} <- file_path(path) do
      if Memory.allowed_write_path?(path),
        do: {:ok, path},
        else: {:error, {:forbidden, "this file is read-only"}}
    end
  end

  # Absolute and already clean: no `.`/`..` segments, no doubled or NUL bytes.
  defp clean(path)
       when is_binary(path) and byte_size(path) > 1 and byte_size(path) <= @max_path_bytes do
    trimmed = String.trim_trailing(path, "/")

    if String.valid?(path) and String.starts_with?(path, "/") and
         not String.contains?(path, ["\0", "//"]) and Path.expand(trimmed) == trimmed,
       do: {:ok, path},
       else: {:error, {:bad_request, "path must be a clean absolute path"}}
  end

  defp clean(_path), do: {:error, {:bad_request, "path is required"}}

  defp cursor(nil, _dir), do: {:ok, nil}
  defp cursor("", _dir), do: {:ok, nil}

  defp cursor(cursor, dir) when is_binary(cursor) and byte_size(cursor) <= @max_path_bytes do
    if String.starts_with?(cursor, dir),
      do: {:ok, cursor},
      else: {:error, {:bad_request, "cursor is not in this directory"}}
  end

  defp cursor(_cursor, _dir), do: {:error, {:bad_request, "cursor is invalid"}}

  defp limit(nil), do: {:ok, @max_page}

  defp limit(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n in 1..@max_page -> {:ok, n}
      _ -> {:error, {:bad_request, "limit must be 1 to #{@max_page}"}}
    end
  end

  defp content(content) when is_binary(content) and byte_size(content) > @max_write_bytes,
    do: {:error, :file_too_large}

  defp content(content) when is_binary(content) do
    if String.valid?(content),
      do: {:ok, content},
      else: {:error, {:bad_request, "content must be UTF-8 text"}}
  end

  defp content(_content), do: {:error, {:bad_request, "content is required"}}

  defp expected_hash(nil), do: {:ok, nil}
  defp expected_hash(""), do: {:ok, nil}

  defp expected_hash(hash) when is_binary(hash) and byte_size(hash) <= 256, do: {:ok, hash}
  defp expected_hash(_hash), do: {:error, {:bad_request, "expected_hash is invalid"}}

  defp salix_result({:ok, _value} = ok), do: ok
  defp salix_result({:error, {:conflict, _message}} = error), do: error
  defp salix_result({:error, :not_found}), do: {:error, :not_found}
  defp salix_result({:error, :too_large}), do: {:error, :file_too_large}
  defp salix_result({:error, {:forbidden, _message}} = error), do: error
  defp salix_result({:error, :bad_path}), do: {:error, {:bad_request, "path is invalid"}}
  defp salix_result({:error, :runtime_path}), do: {:error, {:bad_request, "path is invalid"}}
  defp salix_result({:error, reason}), do: {:error, {:unavailable, reason}}
end
