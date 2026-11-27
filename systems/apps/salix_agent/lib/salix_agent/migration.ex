defmodule SalixAgent.Migration do
  @moduledoc """
  Reads an export of another agent platform (a zip or tar.gz of its home or
  workspace folder) and sorts every file into one kind. Pure: no workspace
  access.

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

  @max_archive_bytes 50_000_000
  @max_entries 2_000
  @max_total_bytes 100_000_000
  @max_file_bytes 10_000_000
  # The largest tar the file limits allow: its files, plus headers and padding.
  @max_tar_bytes @max_total_bytes + @max_entries * 2_048
  @max_tar_meta_bytes 65_536
  @tar_block 512
  @tar_zero_block :binary.copy(<<0>>, @tar_block)
  @not_tar "the file is not a readable tar archive"

  @type file :: %{
          required(String.t()) => term()
        }

  @doc "Bounds checked before and while an archive is expanded."
  def limits,
    do: %{
      archive_bytes: @max_archive_bytes,
      zip_bytes: @max_archive_bytes,
      entries: @max_entries,
      total_bytes: @max_total_bytes,
      file_bytes: @max_file_bytes
    }

  @doc """
  Expands a `.zip`, `.tar.gz` or `.tar` archive in memory. The format comes
  from the content, not the file name. Limits apply while expanding, as in
  `unzip/1`. Tar links and special files are skipped and never followed.
  """
  @spec extract(binary()) ::
          {:ok, [{String.t(), binary()}], [String.t()]} | {:error, String.t()}
  def extract(archive) when is_binary(archive) do
    with :ok <- check_archive_size(archive),
         {:ok, files} <- extract_files(archive) do
      finalize_files(files)
    end
  end

  @doc """
  Expands `zip` in memory. Sizes are enforced while inflating, not taken
  from the archive's headers, which its author controls. Returns regular
  files as `{relative_path, body}`, with operating system noise
  (`__MACOSX/`, `.DS_Store`, `._*`) removed and the folder the user zipped
  stripped, plus the names of entries refused for an unsafe path.
  """
  @spec unzip(binary()) ::
          {:ok, [{String.t(), binary()}], [String.t()]} | {:error, String.t()}
  def unzip(zip) when is_binary(zip) do
    with :ok <- check_archive_size(zip),
         {:ok, files} <- zip_files(zip) do
      finalize_files(files)
    end
  end

  defp check_archive_size(archive) when byte_size(archive) > @max_archive_bytes,
    do: {:error, "the archive is larger than #{div(@max_archive_bytes, 1_000_000)} MB"}

  defp check_archive_size(_archive), do: :ok

  defp extract_files(<<0x1F, 0x8B, _::binary>> = archive) do
    with {:ok, tar} <- gunzip(archive), do: parse_tar(tar)
  end

  defp extract_files(<<0x50, 0x4B, 0x03, 0x04, _::binary>> = archive), do: zip_files(archive)
  defp extract_files(<<0x50, 0x4B, 0x05, 0x06, _::binary>> = archive), do: zip_files(archive)

  defp extract_files(archive) do
    if tar?(archive) do
      parse_tar(archive)
    else
      # A self-extracting zip has a prefix before its first entry.
      case zip_files(archive) do
        {:error, "the file is not a readable zip archive"} ->
          {:error, "the file is not a readable zip or tar.gz archive"}

        result ->
          result
      end
    end
  end

  defp zip_files(zip) do
    with {:ok, entries} <- central_directory(zip), do: expand(zip, entries)
  end

  # A later entry of the same path replaces an earlier one, as when a tar
  # is unpacked. `./a` and `a` are one path after cleaning.
  defp finalize_files(files) do
    {kept, refused} =
      Enum.reduce(files, {[], []}, fn {name, body}, {kept, refused} ->
        case clean_path(name) do
          {:ok, path} ->
            if noise?(path), do: {kept, refused}, else: {[{path, body} | kept], refused}

          :error ->
            {kept, [String.replace_invalid(name) | refused]}
        end
      end)

    kept = kept |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse()
    {:ok, strip_common_folder(kept), Enum.reverse(refused)}
  end

  # Output stops at the limit, so a small gzip cannot expand without bound.
  defp gunzip(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31, :reset)
      gunzip_loop(z, :zlib.safeInflate(z, data), [], 0)
    rescue
      ErlangError -> {:error, "the archive is corrupt"}
    after
      :zlib.close(z)
    end
  end

  defp gunzip_loop(z, {state, out}, acc, size) do
    size = size + IO.iodata_length(out)

    cond do
      size > @max_tar_bytes ->
        {:error, expands_error()}

      state == :finished ->
        # Raises on a truncated stream.
        :ok = :zlib.inflateEnd(z)
        {:ok, IO.iodata_to_binary(Enum.reverse([out | acc]))}

      true ->
        gunzip_loop(z, :zlib.safeInflate(z, []), [out | acc], size)
    end
  end

  defp tar?(<<header::binary-size(@tar_block), _::binary>>),
    do: header != @tar_zero_block and tar_checksum?(header)

  defp tar?(_archive), do: false

  defp parse_tar(tar), do: tar_entries(tar, %{}, [], 0, 0)

  defp tar_entries(<<>>, _pending, files, _count, _total), do: {:ok, Enum.reverse(files)}

  defp tar_entries(<<@tar_zero_block, _::binary>>, _pending, files, _count, _total),
    do: {:ok, Enum.reverse(files)}

  defp tar_entries(
         <<header::binary-size(@tar_block), rest::binary>>,
         pending,
         files,
         count,
         total
       ) do
    with true <- tar_checksum?(header) or {:error, @not_tar},
         {:ok, fields} <- tar_fields(header) do
      tar_entry(fields, rest, pending, files, count, total)
    end
  end

  defp tar_entries(_short, _pending, _files, _count, _total), do: {:error, @not_tar}

  # One entry's PAX header: its records apply to the next entry only.
  defp tar_entry(%{type: ?x, size: size}, _rest, _pending, _files, _count, _total)
       when size > @max_tar_meta_bytes,
       do: {:error, @not_tar}

  defp tar_entry(%{type: ?x, size: size}, rest, pending, files, count, total) do
    with {:ok, data, rest} <- tar_take(rest, size),
         {:ok, records} <- pax_records(data, %{}),
         {:ok, pending} <- pax_pending(records, pending) do
      tar_entries(rest, pending, files, count, total)
    end
  end

  defp tar_entry(%{type: ?L, size: size}, _rest, _pending, _files, _count, _total)
       when size > @max_tar_meta_bytes,
       do: {:error, @not_tar}

  defp tar_entry(%{type: ?L, size: size}, rest, pending, files, count, total) do
    with {:ok, data, rest} <- tar_take(rest, size) do
      name = String.replace(data, ~r/\0+\z/, "")
      tar_entries(rest, Map.put(pending, :long_name, name), files, count, total)
    end
  end

  # PAX global headers and GNU long link names change no file we keep.
  defp tar_entry(%{type: type, size: size}, rest, pending, files, count, total)
       when type in [?g, ?K] do
    with {:ok, _data, rest} <- tar_take(rest, size) do
      tar_entries(rest, pending, files, count, total)
    end
  end

  defp tar_entry(fields, rest, pending, files, count, total) do
    name = pending[:pax_path] || pending[:long_name] || fields.name
    size = Map.get(pending, :pax_size, fields.size)

    if tar_regular?(fields.type, name) do
      with :ok <- tar_limits(name, size, count, total),
           {:ok, body, rest} <- tar_take(rest, size) do
        tar_entries(rest, %{}, [{name, body} | files], count + 1, total + size)
      end
    else
      with {:ok, _data, rest} <- tar_take(rest, size) do
        tar_entries(rest, %{}, files, count, total)
      end
    end
  end

  defp tar_regular?(type, name),
    do: type in [?0, 0] and not String.ends_with?(name, "/") and name not in [".", "./"]

  defp tar_limits(name, size, count, total) do
    cond do
      count + 1 > @max_entries -> {:error, "the archive has more than #{@max_entries} files"}
      size > @max_file_bytes -> {:error, file_too_large(name)}
      total + size > @max_total_bytes -> {:error, expands_error()}
      true -> :ok
    end
  end

  defp tar_take(rest, size) do
    padded = div(size + @tar_block - 1, @tar_block) * @tar_block

    if byte_size(rest) < padded do
      {:error, "the archive is corrupt"}
    else
      {:ok, binary_part(rest, 0, size), binary_part(rest, padded, byte_size(rest) - padded)}
    end
  end

  defp tar_fields(
         <<name::binary-size(100), _mode_ids::binary-size(24), size::binary-size(12),
           _mtime::binary-size(12), _checksum::binary-size(8), type, _link::binary-size(100),
           magic::binary-size(6), _version::binary-size(2), _owner::binary-size(80),
           prefix::binary-size(155), _pad::binary-size(12)>>
       ) do
    with {:ok, size} <- tar_size(size) do
      {:ok, %{name: tar_name(name, prefix, magic), size: size, type: type}}
    end
  end

  # Only POSIX ustar has a prefix field. GNU tar stores other data there.
  defp tar_name(name, prefix, "ustar\0") do
    case {tar_string(prefix), tar_string(name)} do
      {"", name} -> name
      {prefix, name} -> prefix <> "/" <> name
    end
  end

  defp tar_name(name, _prefix, _magic), do: tar_string(name)

  defp tar_string(field), do: field |> :binary.split(<<0>>) |> hd()

  # GNU base-256: the top bit is set, the next is the sign.
  defp tar_size(<<1::1, 0::1, size::94>>), do: {:ok, size}
  defp tar_size(<<1::1, _::bits>>), do: {:error, @not_tar}

  defp tar_size(field) do
    case tar_octal(field) do
      {:ok, size} -> {:ok, size}
      :error -> {:error, @not_tar}
    end
  end

  defp tar_octal(field) do
    case Regex.run(~r/\A *([0-7]*)[ \0]*\z/, field, capture: :all_but_first) do
      [""] -> {:ok, 0}
      [digits] -> {:ok, String.to_integer(digits, 8)}
      nil -> :error
    end
  end

  # The checksum field counts as spaces. Old tools summed signed bytes.
  defp tar_checksum?(<<before::binary-size(148), stored::binary-size(8), rest::binary-size(356)>>) do
    blanks = 8 * ?\s

    {unsigned, signed} =
      for <<byte <- before <> rest>>, reduce: {blanks, blanks} do
        {unsigned, signed} ->
          {unsigned + byte, signed + if(byte > 127, do: byte - 256, else: byte)}
      end

    case tar_octal(stored) do
      {:ok, sum} -> sum == unsigned or sum == signed
      :error -> false
    end
  end

  # Records are "<length> <key>=<value>\n". The length counts bytes of the
  # whole record, so UTF-8 paths are cut by byte.
  defp pax_records(<<>>, acc), do: {:ok, acc}
  defp pax_records(<<0, _::binary>>, acc), do: {:ok, acc}

  defp pax_records(data, acc) do
    with {at, 1} <- :binary.match(data, " "),
         digits = binary_part(data, 0, at),
         true <- Regex.match?(~r/\A[0-9]{1,6}\z/, digits),
         length = String.to_integer(digits),
         true <- length > at + 1 and length <= byte_size(data),
         true <- :binary.at(data, length - 1) == ?\n,
         record = binary_part(data, at + 1, length - at - 2),
         [key, value] <- :binary.split(record, "=") do
      data
      |> binary_part(length, byte_size(data) - length)
      |> pax_records(Map.put(acc, key, value))
    else
      _ -> {:error, @not_tar}
    end
  end

  defp pax_pending(records, pending) do
    pending =
      case records do
        %{"path" => path} when path != "" -> Map.put(pending, :pax_path, path)
        _ -> pending
      end

    case records do
      %{"size" => size} ->
        if Regex.match?(~r/\A[0-9]{1,20}\z/, size),
          do: {:ok, Map.put(pending, :pax_size, String.to_integer(size))},
          else: {:error, @not_tar}

      _ ->
        {:ok, pending}
    end
  end

  defp expands_error,
    do: "the archive expands to more than #{div(@max_total_bytes, 1_000_000)} MB"

  defp file_too_large(name) do
    "the archive has a file larger than #{div(@max_file_bytes, 1_000_000)} MB " <>
      "(#{safe_label(name)})"
  end

  # An archive's author controls the name, and it goes into a tool result.
  defp safe_label(name) do
    name
    |> binary_part(0, min(byte_size(name), 400))
    |> String.replace_invalid()
    |> String.replace(~r/[[:cntrl:]]/u, "?")
    |> String.slice(0, 100)
  end

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
      :too_many -> {:error, "the archive has more than #{@max_entries} files"}
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
         {:ok, body} <- inflate(entry, data, min(@max_file_bytes, left), left),
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

  defp inflate(%{method: 0, name: name}, data, cap, left),
    do: within(byte_size(data), cap, left, data, name)

  defp inflate(%{method: 8, name: name}, data, cap, left) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_loop(z, :zlib.safeInflate(z, data), [], 0, cap, left, name)
    rescue
      ErlangError -> {:error, "the zip is corrupt"}
    after
      :zlib.close(z)
    end
  end

  defp inflate(_entry, _data, _cap, _left),
    do: {:error, "the zip uses an unsupported compression"}

  defp inflate_loop(z, {state, out}, acc, size, cap, left, name) do
    size = size + IO.iodata_length(out)

    cond do
      size > cap -> within(size, cap, left, nil, name)
      state == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([out | acc]))}
      true -> inflate_loop(z, :zlib.safeInflate(z, []), [out | acc], size, cap, left, name)
    end
  end

  defp within(size, cap, left, body, name) do
    cond do
      size > left -> {:error, expands_error()}
      size > cap -> {:error, file_too_large(name)}
      true -> {:ok, body}
    end
  end

  # Relative, slash-separated, no empty, "." or ".." segments; directories
  # (trailing slash) are dropped. A leading "./" is harmless: `tar -czf x .`
  # writes one on every path.
  defp clean_path(name) do
    name = if String.valid?(name), do: String.replace(name, "\\", "/"), else: name
    name = strip_dot_prefix(name)
    segments = String.split(name, "/")

    cond do
      not String.valid?(name) -> :error
      String.starts_with?(name, "/") or String.ends_with?(name, "/") -> :error
      String.contains?(name, <<0>>) -> :error
      Enum.any?(segments, &(&1 in ["", ".", ".."])) -> :error
      true -> {:ok, name}
    end
  end

  defp strip_dot_prefix("./" <> rest), do: strip_dot_prefix(rest)
  defp strip_dot_prefix(name), do: name

  # `._*` files are the AppleDouble metadata that macOS tar adds.
  defp noise?(path) do
    base = Path.basename(path)

    String.starts_with?(path, "__MACOSX/") or base in [".DS_Store", "Thumbs.db"] or
      String.starts_with?(base, "._")
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
