defmodule SalixAgent.Migration do
  @moduledoc """
  Reads an export of another agent platform (a zip of its home or workspace
  folder) and sorts every file into one kind. Pure: no workspace access.

  The kinds say where a file goes in Comma:

    * `instructions` — persona and identity, appended to the Router's
      instructions by the `agent-migration` skill.
    * `preferences` — general agent rules that mostly concern the old
      platform; the skill copies only the user's own preferences into memory.
    * `memory` — long-term memory, split by the skill into `/memory/semantic/*`.
    * `episode` — a dated log, copied to `/memory/episodes/<date>.md` by code.
    * `skill` — a file of a skill folder, imported into the skill catalog by code.
    * `archive` — kept only in the import archive, with a reason.
    * `skip` — credentials, session transcripts and runtime state: not stored.
    * `other` — not recognised; the skill decides.

  Platform layouts are in `SalixAgent.Migration.Platforms`.
  """

  alias SalixAgent.Migration.Platforms

  @max_zip_bytes 25_000_000
  @max_entries 2_000
  @max_total_bytes 100_000_000
  @max_file_bytes 10_000_000

  @type file :: %{
          required(String.t()) => term()
        }

  @doc "Bounds checked before a zip is expanded."
  def limits,
    do: %{
      zip_bytes: @max_zip_bytes,
      entries: @max_entries,
      total_bytes: @max_total_bytes,
      file_bytes: @max_file_bytes
    }

  @doc """
  Expands `zip` in memory. Sizes are enforced while inflating, not taken
  from the archive's headers, which its author controls. Returns regular
  files as `{relative_path, body}`, with operating system noise
  (`__MACOSX/`, `.DS_Store`) removed and the folder the user zipped
  stripped, plus the names of entries refused for an unsafe path.
  """
  @spec unzip(binary()) ::
          {:ok, [{String.t(), binary()}], [String.t()]} | {:error, String.t()}
  def unzip(zip) when is_binary(zip) do
    with :ok <- check_zip_size(zip),
         {:ok, entries} <- central_directory(zip),
         {:ok, files} <- expand(zip, entries) do
      {kept, refused} =
        Enum.reduce(files, {[], []}, fn {name, body}, {kept, refused} ->
          case clean_path(name) do
            {:ok, path} ->
              if noise?(path), do: {kept, refused}, else: {[{path, body} | kept], refused}

            :error ->
              {kept, [String.replace_invalid(name) | refused]}
          end
        end)

      {:ok, kept |> Enum.reverse() |> strip_common_folder(), Enum.reverse(refused)}
    end
  end

  defp check_zip_size(zip) when byte_size(zip) > @max_zip_bytes,
    do: {:error, "the zip is larger than #{div(@max_zip_bytes, 1_000_000)} MB"}

  defp check_zip_size(_zip), do: :ok

  @eocd <<0x50, 0x4B, 0x05, 0x06>>
  @central <<0x50, 0x4B, 0x01, 0x02>>
  @local <<0x50, 0x4B, 0x03, 0x04>>
  @zip64 0xFFFFFFFF

  # The end-of-central-directory record is in the last 22 + 65535 bytes.
  defp central_directory(zip) do
    tail_at = max(byte_size(zip) - 65_557, 0)
    tail = binary_part(zip, tail_at, byte_size(zip) - tail_at)

    with [_ | _] = found <- :binary.matches(tail, @eocd),
         {at, _} = List.last(found),
         <<_::binary-size(^at), @eocd, _disk::little-16, _cd_disk::little-16, _here::little-16,
           count::little-16, size::little-32, offset::little-32, _rest::binary>> <- tail,
         true <- (count != 0xFFFF and offset != @zip64) or :zip64,
         true <- count <= @max_entries or :too_many,
         true <- offset + size <= byte_size(zip) or :bad do
      zip |> binary_part(offset, size) |> central_entries(count, [])
    else
      :zip64 -> {:error, "ZIP64 archives are not supported"}
      :too_many -> {:error, "the zip has more than #{@max_entries} files"}
      _ -> {:error, "the file is not a readable zip archive"}
    end
  end

  defp central_entries(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp central_entries(
         <<@central, _made::little-16, _needed::little-16, flags::little-16, method::little-16,
           _time::little-16, _date::little-16, crc::little-32, compressed::little-32,
           _size::little-32, name_len::little-16, extra_len::little-16, comment_len::little-16,
           _disk::little-16, _internal::little-16, _external::little-32, offset::little-32,
           name::binary-size(name_len), _extra::binary-size(extra_len),
           _comment::binary-size(comment_len), rest::binary>>,
         count,
         acc
       ) do
    entry = %{
      name: name,
      flags: flags,
      method: method,
      crc: crc,
      compressed: compressed,
      offset: offset
    }

    central_entries(rest, count - 1, [entry | acc])
  end

  defp central_entries(_rest, _count, _acc),
    do: {:error, "the file is not a readable zip archive"}

  defp expand(zip, entries) do
    entries
    |> Enum.reject(&String.ends_with?(&1.name, "/"))
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, files, total} ->
      case entry_body(zip, entry, @max_total_bytes - total) do
        {:ok, body} -> {:cont, {:ok, [{entry.name, body} | files], total + byte_size(body)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _total} -> {:ok, Enum.reverse(files)}
      {:error, _} = error -> error
    end
  end

  defp entry_body(_zip, %{flags: flags}, _left) when Bitwise.band(flags, 1) == 1,
    do: {:error, "the zip is encrypted"}

  defp entry_body(_zip, %{compressed: @zip64}, _left),
    do: {:error, "ZIP64 archives are not supported"}

  defp entry_body(zip, entry, left) do
    with {:ok, data} <- entry_data(zip, entry),
         {:ok, body} <- inflate(entry.method, data, min(@max_file_bytes, left), left),
         true <- :erlang.crc32(body) == entry.crc or :crc do
      {:ok, body}
    else
      :crc -> {:error, "the zip is corrupt (#{String.replace_invalid(entry.name)})"}
      {:error, _} = error -> error
    end
  end

  defp entry_data(zip, %{offset: offset, compressed: compressed}) do
    with true <- offset + 30 <= byte_size(zip),
         <<@local, _::binary-size(22), name_len::little-16, extra_len::little-16>> <-
           binary_part(zip, offset, 30),
         start = offset + 30 + name_len + extra_len,
         true <- start + compressed <= byte_size(zip) do
      {:ok, binary_part(zip, start, compressed)}
    else
      _ -> {:error, "the file is not a readable zip archive"}
    end
  end

  defp inflate(0, data, cap, left), do: within(byte_size(data), cap, left, data)

  defp inflate(8, data, cap, left) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_loop(z, :zlib.safeInflate(z, data), [], 0, cap, left)
    rescue
      ErlangError -> {:error, "the zip is corrupt"}
    after
      :zlib.close(z)
    end
  end

  defp inflate(_method, _data, _cap, _left),
    do: {:error, "the zip uses an unsupported compression"}

  defp inflate_loop(z, {state, out}, acc, size, cap, left) do
    size = size + IO.iodata_length(out)

    cond do
      size > cap -> within(size, cap, left, nil)
      state == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([out | acc]))}
      true -> inflate_loop(z, :zlib.safeInflate(z, []), [out | acc], size, cap, left)
    end
  end

  defp within(size, cap, left, body) do
    cond do
      size > left ->
        {:error, "the zip expands to more than #{div(@max_total_bytes, 1_000_000)} MB"}

      size > cap ->
        {:error, "the zip has a file larger than #{div(@max_file_bytes, 1_000_000)} MB"}

      true ->
        {:ok, body}
    end
  end

  # Relative, slash-separated, no empty, "." or ".." segments; directories
  # (trailing slash) are dropped.
  defp clean_path(name) do
    name = if String.valid?(name), do: String.replace(name, "\\", "/"), else: name
    segments = String.split(name, "/")

    cond do
      not String.valid?(name) -> :error
      String.starts_with?(name, "/") or String.ends_with?(name, "/") -> :error
      String.contains?(name, <<0>>) -> :error
      Enum.any?(segments, &(&1 in ["", ".", ".."])) -> :error
      true -> {:ok, name}
    end
  end

  defp noise?(path) do
    String.starts_with?(path, "__MACOSX/") or Path.basename(path) in [".DS_Store", "Thumbs.db"]
  end

  # First-level folders the platform layouts name; a zip of only one of
  # them keeps it.
  @layout_folders ~w(workspace agent agents memories memory projects skills sessions prompts commands rules profiles extensions)

  defp strip_common_folder([]), do: []

  defp strip_common_folder(files) do
    tops = Enum.map(files, fn {path, _} -> String.split(path, "/", parts: 2) end)

    case Enum.uniq_by(tops, &hd/1) do
      [[top, _rest]] ->
        if top not in @layout_folders and Enum.all?(tops, &match?([_, _], &1)) do
          files
          |> Enum.map(fn {path, body} -> {String.replace_prefix(path, top <> "/", ""), body} end)
          |> strip_common_folder()
        else
          files
        end

      _ ->
        files
    end
  end

  @doc """
  The platform whose layout matches the most files, or an error when none
  or several match equally.
  """
  @spec detect([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def detect(paths) do
    scores =
      Platforms.ids()
      |> Enum.map(fn id -> {id, Enum.count(paths, &Platforms.marker?(id, &1))} end)
      |> Enum.filter(fn {_id, score} -> score > 0 end)
      |> Enum.sort_by(fn {_id, score} -> -score end)

    case scores do
      [] ->
        {:error,
         "could not tell which platform this export is from; pass platform as one of " <>
           Enum.join(Platforms.ids(), ", ")}

      [{id, score}, {_other, score} | _] ->
        {:error,
         "the export matches more than one platform (#{id} among them); pass platform explicitly"}

      [{id, _score} | _] ->
        {:ok, id}
    end
  end

  @doc """
  One manifest entry per file. Entries that code places itself (`episode`,
  `skill`) are returned pending; the caller marks them once written.
  `archive` and `skip` entries are final here.
  """
  @spec classify(String.t(), [{String.t(), binary()}]) :: [file()]
  def classify(platform, files) do
    paths = MapSet.new(files, &elem(&1, 0))
    builtin = Platforms.builtin_skills(platform, files)

    Enum.map(files, fn {path, body} ->
      base = %{
        "path" => path,
        "size" => byte_size(body),
        "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
        "status" => nil
      }

      kind =
        if private_key?(body),
          do: {:skip, "credentials or keys are never imported"},
          else: Platforms.classify(platform, path, paths)

      case kind do
        {:skip, reason} ->
          base
          |> Map.merge(%{"kind" => "skip", "status" => "skipped", "reason" => reason})
          |> Map.delete("sha256")

        {:archive, reason} ->
          Map.merge(base, %{"kind" => "archive", "status" => "archived", "reason" => reason})

        {:episode, date} ->
          Map.merge(base, %{"kind" => "episode", "date" => date})

        {:skill, skill_dir, rel} ->
          if Path.basename(skill_dir) in builtin do
            Map.merge(base, %{
              "kind" => "archive",
              "status" => "archived",
              "reason" => "built-in skill of #{Platforms.name(platform)}"
            })
          else
            Map.merge(base, %{"kind" => "skill", "skill_dir" => skill_dir, "skill_path" => rel})
          end

        kind when kind in [:instructions, :preferences, :memory, :other] ->
          Map.put(base, "kind", Atom.to_string(kind))
      end
    end)
  end

  # A key pasted into a file with an ordinary name.
  defp private_key?(body) do
    head = binary_part(body, 0, min(byte_size(body), 65_536))
    String.contains?(head, "PRIVATE KEY-----")
  end
end
