defmodule CommaWeb.DriveBrowse do
  @moduledoc """
  Read-only browser access to a Workspace's Comma Drive, for clients that run
  no Synchronicity node of their own (the web client).

  Reads go through the `SalixAgent.Drive` port with the Workspace group's
  Drive binding, the same way the Router's `/drive` mount reads. They serve
  the hosted replica's selected version of each path: a file a device saved
  moments ago may not be there yet, and nothing here writes.

  The caller authorizes the group first (the router requires the owner's full
  Workspace session). Paths are Drive-relative, without a leading slash.

  A tree is one walk of `browse/ls`, which lists one directory per call. The
  walk stops at 2,000 entries, 64 listings or 32 levels, whichever comes
  first, and says so with `truncated: true`; a subdirectory whose listing
  fails is left out the same way. The web client reads a tree when Drive
  opens and when its window regains focus, never on a timer.
  """

  alias SalixAgent.Drive

  @max_entries 2_000
  @max_requests 64
  @max_depth 32
  @max_path_bytes 4_096

  @type entry :: %{
          required(String.t()) => String.t() | non_neg_integer() | nil
        }

  @doc "Every file and directory of the group's Drive, up to the walk's bounds."
  @spec tree(String.t()) ::
          {:ok, %{String.t() => [entry()] | boolean()}} | {:error, term()}
  def tree(group_id) when is_binary(group_id) do
    impl = Drive.impl()

    case impl.list(group_id, "") do
      {:ok, entries} ->
        {acc, budget} =
          walk(impl, group_id, entries, 0, [], %{entries: 0, requests: 1, truncated: false})

        {:ok, %{"entries" => Enum.reverse(acc), "truncated" => budget.truncated}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Opens one file for streaming: `{:ok, stream, size}`, where the stream must
  be consumed by the calling process.
  """
  @spec open_file(String.t(), term()) ::
          {:ok, Enumerable.t(), non_neg_integer() | nil} | {:error, term()}
  def open_file(group_id, path) when is_binary(group_id) do
    with {:ok, path} <- file_path(path) do
      Drive.impl().stream(group_id, path)
    end
  end

  @doc "A file path the walk could have returned, or `{:error, :invalid_path}`."
  @spec file_path(term()) :: {:ok, String.t()} | {:error, :invalid_path}
  def file_path(path)
      when is_binary(path) and path != "" and byte_size(path) <= @max_path_bytes do
    if String.valid?(path) and not String.contains?(path, "\0") and
         Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])) do
      {:ok, path}
    else
      {:error, :invalid_path}
    end
  end

  def file_path(_path), do: {:error, :invalid_path}

  # One directory's entries are admitted, then its subdirectories are listed
  # in turn. Every entry spends one unit of the entry budget and every listing
  # one of the request budget; a tombstone is a deletion, not an entry.
  defp walk(impl, group_id, entries, depth, acc, budget) do
    room = max(@max_entries - budget.entries, 0)

    {admitted, rest} =
      entries
      |> Enum.filter(&(&1.kind in ["file", "dir"]))
      |> Enum.sort_by(& &1.path)
      |> Enum.split(room)

    budget = %{
      budget
      | entries: budget.entries + length(admitted),
        truncated: budget.truncated or rest != []
    }

    acc = Enum.reduce(admitted, acc, &[view(&1) | &2])

    admitted
    |> Enum.filter(&(&1.kind == "dir"))
    |> Enum.reduce({acc, budget}, fn dir, {acc, budget} ->
      cond do
        budget.entries >= @max_entries or budget.requests >= @max_requests or
            depth + 1 > @max_depth ->
          {acc, %{budget | truncated: true}}

        true ->
          budget = %{budget | requests: budget.requests + 1}

          case impl.list(group_id, dir.path) do
            {:ok, children} -> walk(impl, group_id, children, depth + 1, acc, budget)
            {:error, _reason} -> {acc, %{budget | truncated: true}}
          end
      end
    end)
  end

  defp view(entry) do
    %{
      "path" => entry.path,
      "name" => entry.name,
      "kind" => entry.kind,
      "size" => entry.size,
      "modified_at" => entry[:modified_at]
    }
  end
end
