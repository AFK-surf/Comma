defmodule SalixAgent.DriveMount do
  @moduledoc """
  The `/drive/...` mount of `SalixAgent.FileBackend`: the user's Comma Drive,
  through `SalixAgent.Drive`.

  Unlike the workspace and skill mounts, a write here is an effect on a
  store outside Salix, performed when the tool runs and not deferred to the
  round's commit: there is no content-addressed staging area on the far side
  whose orphans would be harmless, and a deferred publish could neither be
  retried idempotently nor read back within the same round. So the
  `prepare_*` functions return no journal event (`{:ok, nil}`) once the
  Drive has acknowledged the change, the way `calendar.create_event` leaves
  no VFS event either.

  Paths are validated here and handed to the port relative to the Drive
  root; the control plane validates them again.
  """

  alias SalixAgent.{Drive, StorageAuthorization}
  alias SalixStore.Blob

  @prefix "/drive"
  # Entries a recursive listing stops at, directories included: a Drive can
  # be far larger than an agent workspace, `fs.list_files` returns one flat
  # list, and every directory met is one more control-plane call. Depth
  # bounds nothing on its own (a wide tree is flat), so the entry budget is
  # charged for directories as they are queued, and the request budget caps
  # the calls a single listing may make whatever the tree's shape.
  @max_listed_entries 2_000
  @max_list_requests 256
  @max_list_depth 32
  # Bytes a streamed write may spool before it is refused: the control
  # plane's own per-write cap.
  @max_stream_write_bytes 1024 * 1024 * 1024
  @spool_chunk_bytes 256 * 1024

  @doc "The mount prefix."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "True when a path is in the Drive mount."
  @spec matches?(term()) :: boolean()
  def matches?(path) when is_binary(path) do
    path = clean(path)
    path == @prefix or String.starts_with?(path, @prefix <> "/")
  end

  def matches?(_path), do: false

  @doc "True when the mount has a product behind it."
  @spec available?() :: boolean()
  def available?, do: Drive.configured?()

  @spec read(map(), String.t()) :: {:ok, binary(), boolean()} | {:error, term()}
  def read(ctx, path) do
    with {:ok, rel} <- file_path(path) do
      case Drive.read(ctx, rel, Blob.max_bytes()) do
        {:ok, body, truncated} -> {:ok, body, truncated}
        {:error, _} = error -> refusal(error)
      end
    end
  end

  @spec stream(map(), String.t()) ::
          {:ok, Enumerable.t(), non_neg_integer()} | {:error, term()}
  def stream(ctx, path) do
    with {:ok, rel} <- file_path(path) do
      case Drive.stream(ctx, rel) do
        {:ok, stream, size} when is_integer(size) -> {:ok, stream, size}
        {:ok, stream, nil} -> {:ok, stream, 0}
        {:error, _} = error -> refusal(error)
      end
    end
  end

  @doc """
  Every file path under `prefix`, walking directories breadth-first up to a
  bound (`#{@max_listed_entries}` entries, files and directories alike, and
  `#{@max_list_requests}` directory listings). Answers `[]` unless the prefix
  is inside the mount: `fs.glob` and `fs.grep` over the whole tree do not
  sweep the Drive, which can be far larger than the workspace; list
  `/drive/...` explicitly.
  """
  @spec file_paths(map(), String.t()) :: [String.t()]
  def file_paths(ctx, prefix) do
    if is_binary(prefix) and matches?(prefix) and available?() do
      start = relative(prefix)

      case walk(ctx, [{start, 0}], [], %{entries: 0, requests: 0}) do
        [] when start != "" ->
          # The prefix may itself name one file.
          case Drive.stat(ctx, start) do
            {:ok, %{kind: "file"}} -> [absolute(start)]
            _ -> []
          end

        paths ->
          paths
      end
    else
      []
    end
  rescue
    _ -> []
  end

  @spec stat(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def stat(ctx, path) do
    rel = relative(path)

    cond do
      rel == "" ->
        {:ok, %{kind: "dir", size: 0, path: @prefix}}

      true ->
        with {:ok, rel} <- file_path(path) do
          case Drive.stat(ctx, rel) do
            {:ok, entry} ->
              {:ok,
               %{
                 kind: entry.kind,
                 size: entry.size,
                 modified_at: entry[:modified_at],
                 path: absolute(rel)
               }}

            {:error, _} = error ->
              refusal(error)
          end
        end
    end
  end

  @doc "Publishes `content` at `path`; no journal event comes back."
  @spec prepare_write(map(), String.t(), binary()) :: {:ok, nil} | {:error, term()}
  def prepare_write(ctx, path, content) when is_binary(content) do
    with {:ok, rel} <- file_path(path),
         :ok <- authorize(ctx, path, "drive_write"),
         {:ok, _result} <- refusal(Drive.write(ctx, rel, content, byte_size(content))) do
      {:ok, nil}
    end
  end

  @doc """
  Publishes a stream at `path`. The Drive needs the size before the first
  byte, so the stream is spooled to a bounded temporary file first.
  """
  @spec prepare_write_stream(map(), String.t(), Enumerable.t()) ::
          {:ok, nil} | {:error, term()}
  def prepare_write_stream(ctx, path, stream) do
    with {:ok, rel} <- file_path(path),
         :ok <- authorize(ctx, path, "drive_write") do
      spool(stream, fn spooled, size ->
        with {:ok, _result} <- refusal(Drive.write(ctx, rel, spooled, size)), do: {:ok, nil}
      end)
    end
  end

  @doc "Withdraws the Drive's version of `path`; no journal event comes back."
  @spec prepare_delete(map(), String.t()) :: {:ok, nil} | {:error, term()}
  def prepare_delete(ctx, path) do
    with {:ok, rel} <- file_path(path),
         :ok <- authorize(ctx, path, "drive_delete"),
         {:ok, _result} <- refusal(Drive.delete(ctx, rel)) do
      {:ok, nil}
    end
  end

  # ---- paths ----

  @doc "The Drive-relative form of a mount path (`\"\"` for the root)."
  @spec relative(String.t()) :: String.t()
  def relative(path) do
    case clean(path) do
      @prefix -> ""
      @prefix <> "/" <> rest -> rest
      _other -> ""
    end
  end

  defp absolute(""), do: @prefix
  defp absolute(rel), do: @prefix <> "/" <> rel

  # A file path: inside the mount, not the root, no empty or dot components.
  defp file_path(path) do
    rel = relative(path)

    cond do
      not matches?(path) ->
        {:error, :not_found}

      rel == "" ->
        {:error, "#{@prefix} is a directory"}

      String.contains?(rel, "\0") ->
        {:error, "invalid drive path"}

      Enum.any?(String.split(rel, "/"), &(&1 in ["", ".", ".."])) ->
        {:error, "invalid drive path"}

      true ->
        {:ok, rel}
    end
  end

  defp clean(path), do: Path.expand(to_string(path || ""), "/")

  # ---- listing ----

  # Breadth-first over a queue of directories. Every entry met, file or
  # directory, spends one unit of the entry budget, and every listing spends
  # one of the request budget; a directory met after the entry budget is
  # exhausted is not queued, so a wide flat tree costs one listing, not one
  # per child.
  defp walk(_ctx, [], acc, _budget), do: Enum.reverse(acc)

  defp walk(ctx, [{dir, depth} | rest], acc, budget) do
    cond do
      budget.entries >= @max_listed_entries or budget.requests >= @max_list_requests ->
        Enum.reverse(acc)

      depth > @max_list_depth ->
        walk(ctx, rest, acc, budget)

      true ->
        budget = %{budget | requests: budget.requests + 1}

        case Drive.list(ctx, dir) do
          {:ok, entries} ->
            room = max(@max_listed_entries - budget.entries, 0)
            admitted = entries |> Enum.sort_by(& &1.path) |> Enum.take(room)

            {files, dirs} =
              Enum.reduce(admitted, {[], []}, fn entry, {files, dirs} ->
                case entry.kind do
                  "file" -> {[absolute(entry.path) | files], dirs}
                  "dir" -> {files, [{entry.path, depth + 1} | dirs]}
                  _ -> {files, dirs}
                end
              end)

            walk(
              ctx,
              rest ++ Enum.reverse(dirs),
              Enum.reverse(Enum.sort(files)) ++ acc,
              %{budget | entries: budget.entries + length(admitted)}
            )

          {:error, _reason} ->
            walk(ctx, rest, acc, budget)
        end
    end
  end

  # ---- writes ----

  defp authorize(ctx, path, event_type) do
    StorageAuthorization.authorize_write(%{
      agent_id: Map.get(ctx, :agent_id) || Map.get(ctx, "agent_id"),
      events: [%{"type" => event_type, "path" => path}],
      billing_context: Map.get(ctx, :billing_context) || Map.get(ctx, "billing_context") || %{},
      entrypoint: "storage_write",
      actor_type: "tool"
    })
  end

  defp spool(stream, fun) do
    dir = Path.join(System.tmp_dir!(), "salix-drive-spool")
    File.mkdir_p!(dir)
    spooled = Path.join(dir, "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}")

    try do
      size =
        File.open!(spooled, [:write, :binary], fn io ->
          Enum.reduce(stream, 0, fn chunk, size ->
            chunk = IO.iodata_to_binary(chunk)
            size = size + byte_size(chunk)
            if size > @max_stream_write_bytes, do: throw(:too_large)
            IO.binwrite(io, chunk)
            size
          end)
        end)

      fun.(File.stream!(spooled, @spool_chunk_bytes), size)
    catch
      :too_large -> {:error, :too_large}
    after
      File.rm(spooled)
    end
  end

  # Port refusals as the file tools report them: `:not_found` stays an atom
  # for the tools' own "no such file"; everything else becomes a sentence.
  defp refusal({:ok, _} = ok), do: ok
  defp refusal({:ok, _, _} = ok), do: ok
  defp refusal({:error, :not_found}), do: {:error, :not_found}
  defp refusal({:error, :too_large}), do: {:error, :too_large}
  defp refusal({:error, reason}), do: {:error, describe(reason)}

  @doc false
  def describe(:drive_not_configured), do: "the Comma Drive is not available on this deployment"

  def describe(:not_configured),
    do: "this agent's group has no Drive binding; an operator can add one"

  def describe(:unavailable), do: "the Drive binding store is temporarily unavailable; try again"
  def describe(:workspace_not_found), do: "this agent's Workspace has no Comma Drive"
  def describe(:missing_group_id), do: "this agent's Workspace has no Comma Drive"

  def describe(:not_provisioned),
    do: "the Comma Drive is still being set up for this Workspace; try again later"

  def describe(:agent_key_missing),
    do: "the Comma Drive is still being set up for this Workspace; try again later"

  def describe(:auth),
    do: "the Comma Drive refused this agent's credential; ask the Workspace owner"

  def describe(:browse_disabled),
    do: "browsing is turned off for this Workspace's Drive in Synchronicity"

  def describe(:hosting_disabled),
    do:
      "cloud hosting is turned off for this Workspace's Drive, so it cannot be written from here"

  def describe(:no_device_attached),
    do:
      "no Drive replica is attached right now (the space may not exist yet: open Comma Drive on a device first)"

  def describe(:no_cloud_attached),
    do: "the Drive's hosted replica is not attached right now; try again in a minute"

  def describe(:precondition), do: "the Drive file changed since it was read"
  def describe(:over_budget), do: "the Workspace's Drive storage budget is exhausted"

  def describe({:retryable, _reason}),
    do: "the Comma Drive is temporarily unavailable; try again in a minute"

  def describe({:invalid, {:bad_request, code}}) when is_binary(code),
    do: "the Comma Drive refused the request: #{code}"

  def describe(reason), do: "Comma Drive error: #{inspect(reason)}"
end
