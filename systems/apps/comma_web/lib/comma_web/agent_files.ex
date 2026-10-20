defmodule CommaWeb.AgentFiles do
  @moduledoc """
  The Router VFS files a Comma user sees in Drive (`Comma.SystemFiles`):
  one page of a listing, a read, a replacement and a delete.

  `/memory/scoped/<name>.md` holds notes taken from DMs and private channels
  (`docs/verification.md` §8). While the Group's information-flow check is on
  (`SalixAgent.IFC.mode_for/2` is not `:off`), a scoped file is listed, read,
  replaced or deleted only when `SalixIFC.reader?/3` answers exactly `true`
  for the user and the file's label. A file without a label reads as
  agent-private. Every other answer hides the file: it is absent from the
  listing and `:not_found` everywhere else. A replacement keeps the label the
  file had, so an edit never widens who may read it.
  """

  alias SalixAgent.{AgentWorkspace, IFC}
  alias SalixAgent.Tools.Memory
  alias SalixIFC.{Codec, Label}

  @default_limit 500

  @doc "One page of the files under `dir`, in path order, without the ones `reader` may not read."
  def list(scope, dir, opts) do
    agent_id = scope["router_agent_id"]
    limit = Keyword.get(opts, :limit) || @default_limit
    cursor = Keyword.get(opts, :cursor)

    with {:ok, vfs} <- AgentWorkspace.manifest(agent_id) do
      entries =
        vfs
        |> Enum.filter(fn {path, _meta} ->
          String.starts_with?(path, dir) and (cursor == nil or path > cursor)
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.take(limit + 1)

      {page, rest} = Enum.split(entries, limit)
      readable = readable(scope, Keyword.fetch!(opts, :reader), page)

      {:ok,
       %{
         "files" => for({path, meta} <- page, readable.(path), do: entry_json(path, meta)),
         "next_cursor" => if(rest == [], do: nil, else: page |> List.last() |> elem(0))
       }}
    end
  end

  @doc """
  One file `reader` may read, at most `max_bytes` of it, with the content
  hash a later write or delete names as its precondition.
  """
  def read(scope, path, max_bytes, reader) do
    agent_id = scope["router_agent_id"]

    with {:ok, entry} <- AgentWorkspace.entry(agent_id, path),
         true <- readable(scope, reader, [{path, entry}]).(path) || {:error, :not_found},
         true <- (entry["size"] || 0) <= max_bytes || {:error, :too_large},
         {:ok, body} <- SalixStore.Blob.get(agent_id, entry["ref"]),
         true <- byte_size(body) <= max_bytes || {:error, :too_large} do
      {:ok, %{"content" => body, "hash" => entry["hash"]}}
    end
  end

  @doc """
  Creates or replaces one file for `opts[:reader]`, keeping its label. With
  `opts[:expected_hash]`, the file must still have that content (an absent
  file never does): otherwise `{:conflict, _}`. The check is not atomic with
  the commit: a write that lands between them can still be overwritten. Under the check, a scoped note must already
  exist: a new one would have no label, so it would read as agent-private and
  vanish from its own author. Refusing it says no more than a hidden note
  does: both are `:not_found`.
  """
  def write(scope, path, body, opts) do
    agent_id = scope["router_agent_id"]

    with {:ok, entry} <- current(agent_id, path),
         :ok <- may_change(scope, Keyword.fetch!(opts, :reader), path, entry),
         :ok <- unchanged(entry, Keyword.get(opts, :expected_hash)),
         {:ok, result} <-
           SalixAgent.Workspace.write(agent_id, path, body,
             ifc_label: label(entry),
             idempotency_key: request_key(),
             entrypoint: "drive_system_files",
             actor_type: "user"
           ) do
      # The manifest names a blob by the SHA-256 of its bytes
      # (`SalixStore.Blob`), so this is the hash of exactly what was written.
      {:ok, Map.put(result, "hash", SalixStore.Crypto.hex(body))}
    end
  end

  @doc "Deletes one file `opts[:reader]` may read, with the same `expected_hash` precondition."
  def delete(scope, path, opts) do
    agent_id = scope["router_agent_id"]

    with {:ok, entry} <- current(agent_id, path),
         :ok <- may_change(scope, Keyword.fetch!(opts, :reader), path, entry),
         true <- entry != nil || {:error, :not_found},
         :ok <- unchanged(entry, Keyword.get(opts, :expected_hash)) do
      SalixAgent.Workspace.delete(agent_id, path,
        idempotency_key: request_key(),
        entrypoint: "drive_system_files",
        actor_type: "user"
      )
    end
  end

  # The manifest entry at `path`, or nil when there is none.
  defp current(agent_id, path) do
    case AgentWorkspace.entry(agent_id, path) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp may_change(scope, reader, path, entry) do
    cond do
      not checked?(scope, path) -> :ok
      entry != nil and readable(scope, reader, [{path, entry}]).(path) -> :ok
      true -> {:error, :not_found}
    end
  end

  defp unchanged(_entry, nil), do: :ok
  defp unchanged(%{"hash" => hash}, hash) when is_binary(hash), do: :ok
  defp unchanged(_entry, _expected), do: {:error, {:conflict, "the file changed"}}

  # Each Drive request is its own write: two saves of the same text, or a
  # delete after the file came back, are separate operations, not replays.
  defp request_key, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(16), padding: false)

  defp label(%{"ifc_label" => label}) when is_list(label), do: label
  defp label(_unlabelled_or_absent), do: nil

  defp checked?(scope, path) do
    Memory.scoped_path?(path) and
      IFC.mode_for(scope["salix_tenant_id"], scope["default_group_id"]) != :off
  end

  # A predicate over the paths of `entries`: true unless the path is a scoped
  # note under the check that `reader` may not read. One facts request covers
  # the whole page.
  defp readable(scope, reader, entries) do
    checked =
      for {path, meta} <- entries, checked?(scope, path), into: %{} do
        {path, Codec.decode_label(meta["ifc_label"], Label.new([:agent_private]))}
      end

    if checked == %{} do
      fn _path -> true end
    else
      readers = readers(scope, reader, checked)
      fn path -> not Map.has_key?(checked, path) or MapSet.member?(readers, path) end
    end
  end

  defp readers(scope, reader, labels) do
    principal = {:comma_user, reader}

    request = %{
      "tenant_id" => scope["salix_tenant_id"],
      "group_id" => scope["default_group_id"],
      "agent_id" => scope["router_agent_id"],
      "requester" => Codec.encode_principal!(principal),
      "destination" => %{"kind" => "agent_private"},
      "atoms" => labels |> Map.values() |> Enum.flat_map(&Codec.encode_label/1) |> Enum.uniq(),
      "now" => SystemsClock.system_time(:millisecond)
    }

    case IFC.resolve(request) do
      {:ok, reply} ->
        facts = Codec.decode_facts(reply)

        for {path, label} <- labels,
            reader?(principal, label, facts),
            into: MapSet.new(),
            do: path

      {:error, _reason} ->
        MapSet.new()
    end
  rescue
    _error -> MapSet.new()
  end

  defp reader?(principal, label, facts) do
    SalixIFC.reader?(principal, label, facts) == true
  rescue
    _error -> false
  end

  defp entry_json(path, meta) do
    %{
      "path" => path,
      "size" => meta["size"] || 0,
      "hash" => meta["hash"],
      "modified_at" => meta["modified_at"]
    }
  end
end
