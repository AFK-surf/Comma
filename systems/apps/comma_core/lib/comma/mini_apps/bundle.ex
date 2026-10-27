defmodule Comma.MiniApps.Bundle do
  @moduledoc """
  Checks the files of one deploy (design §5.4 step 4): the frontend bundle is
  an uncompressed ustar archive of regular files with `index.html` (at most
  8 MiB), at most 25 MiB and 2,000 files in all; the backend module is at most
  3 MiB gzip-compressed; the source archive is at most 50 MiB.

  The digest is the SHA-256 of the bundle archive. It is a cache key and
  provenance, not a security check (design §8).
  """

  @mib 1024 * 1024
  @index_max 8 * @mib
  @total_max 25 * @mib
  @files_max 2_000
  @backend_max 3 * @mib
  @source_max 50 * @mib
  # Tar framing (512-byte headers and padding) on top of the content limit.
  @archive_max @total_max + (@files_max + 2) * 1024
  @icon_max 256 * 1024

  def limits,
    do: %{
      index_bytes: @index_max,
      bundle_bytes: @total_max,
      bundle_files: @files_max,
      backend_gzip_bytes: @backend_max,
      source_bytes: @source_max
    }

  @doc """
  Checks the bundle archive at `path`: `{:ok, %{files, size, digest}}` or
  `{:error, [message]}`.
  """
  def inspect_bundle(path) when is_binary(path) do
    with {:ok, %{size: archive_size}} <- stat(path, "bundle.tar"),
         :ok <- max_size(archive_size, @archive_max, "bundle.tar is larger than 25 MiB"),
         {:ok, entries} <- table(path) do
      errors = entry_errors(entries)
      files = for {name, :regular, size} <- entries, do: {name, size}
      total = files |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      errors =
        errors ++
          Enum.reject(
            [
              if(length(files) > @files_max, do: "the bundle has more than 2,000 files"),
              if(total > @total_max, do: "the bundle is larger than 25 MiB"),
              index_error(files)
            ],
            &is_nil/1
          )

      if errors == [] do
        {:ok, %{files: Map.new(files), size: total, digest: digest(path)}}
      else
        {:error, errors}
      end
    end
  end

  @doc "Reads one bundle file (the icon or the cover) into memory, at most `max` bytes (256 KiB)."
  def read_file(path, name, max \\ @icon_max) do
    case :erl_tar.extract(String.to_charlist(path), [
           :memory,
           {:files, [String.to_charlist(name)]}
         ]) do
      {:ok, [{_name, data}]} when byte_size(data) <= max -> {:ok, data}
      {:ok, [{_name, _data}]} -> {:error, :too_large}
      _ -> {:error, :not_found}
    end
  end

  @doc "Checks the backend module: at most 3 MiB once gzip-compressed."
  def inspect_backend(path) do
    with {:ok, %{size: size}} <- stat(path, "worker.js"),
         :ok <- max_size(size, 10 * @mib, "worker.js is larger than 10 MiB"),
         {:ok, source} <- File.read(path) do
      if byte_size(:zlib.gzip(source)) <= @backend_max,
        do: {:ok, source},
        else: {:error, ["the backend is larger than 3 MiB compressed"]}
    else
      {:error, [_ | _]} = error -> error
      {:error, _reason} -> {:error, ["worker.js could not be read"]}
    end
  end

  @doc "Checks the source archive size."
  def inspect_source(path) do
    with {:ok, %{size: size}} <- stat(path, "source.tar.gz"),
         :ok <- max_size(size, @source_max, "source.tar.gz is larger than 50 MiB") do
      :ok
    end
  end

  @doc "The SHA-256 (lower hex) of a file, read in parts."
  def digest(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp stat(path, label) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, %{size: size}}
      _ -> {:error, ["#{label} is missing"]}
    end
  end

  defp max_size(size, max, _message) when size <= max, do: :ok
  defp max_size(_size, _max, message), do: {:error, [message]}

  defp table(path) do
    case :erl_tar.table(String.to_charlist(path), [:verbose]) do
      {:ok, entries} ->
        {:ok,
         Enum.map(entries, fn {name, type, size, _mtime, _mode, _uid, _gid} ->
           {to_string(name), type, size}
         end)}

      {:error, _reason} ->
        {:error, ["bundle.tar is not a valid tar archive"]}
    end
  end

  defp entry_errors(entries) do
    entries
    |> Enum.flat_map(fn
      {_name, :directory, _size} ->
        []

      {name, :regular, _size} ->
        cond do
          String.starts_with?(name, "./") ->
            ["bundle path #{inspect(name)} starts with ./"]

          not Comma.MiniApps.Manifest.safe_path?(name) ->
            ["bundle path #{inspect(name)} is unsafe"]

          true ->
            []
        end

      {name, _type, _size} ->
        ["bundle entry #{inspect(name)} is not a regular file"]
    end)
    |> Enum.take(20)
  end

  defp index_error(files) do
    case List.keyfind(files, "index.html", 0) do
      nil -> "the bundle has no index.html"
      {_name, size} when size > @index_max -> "index.html is larger than 8 MiB"
      _ -> nil
    end
  end
end
