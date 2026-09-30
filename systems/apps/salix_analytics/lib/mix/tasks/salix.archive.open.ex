defmodule Mix.Tasks.Salix.Archive.Open do
  @shortdoc "Decrypt archived agent events with an age identity (offline only)"

  @moduledoc """
  Open archived agent events.

      mix salix.archive.open --identity key.txt --session ses1_123
      mix salix.archive.open --identity key.txt --input rows.jsonl

  This is the ONLY decryption entry point in the repo, and it ships in no
  release the cluster runs. A production node holds no identity to give it —
  and, under the ClickHouse target, is not expected to hold SELECT on the table
  either.

  Because each row's `e` column is a complete age file, the standard tools work
  just as well and are worth knowing:

      clickhouse-client -q "SELECT e FROM salix_analytics.agent_event_archive \\
        WHERE session_id = 'ses1_123' ORDER BY seq FORMAT TabSeparatedRaw" \\
        | head -1 | base64 -d | age -d -i key.txt

  This task adds what that pipeline cannot do: it verifies the sealed copy of
  each header against the header COLUMNS the row was navigated by. age has no
  AAD, so that comparison — not the decryption itself — is what detects a header
  edited after sealing. That matters more here than it did against object
  storage, because the header columns are independently mutable with an
  `ALTER TABLE … UPDATE` while an object had to be rewritten whole. An item
  whose headers disagree is reported and SKIPPED unless
  `--allow-header-mismatch` is passed.

  ## Options

    * `--identity` / `-i` — path to an age identity file (required unless
      `--headers-only`)
    * `--session` — read this session's rows from ClickHouse
    * `--stream` — read this stream's rows from ClickHouse
    * `--from` / `--to` — inclusive ISO dates bounding a ClickHouse read
    * `--input` — read rows from a local JSONL file, or `-` for stdin
    * `--headers-only` — print plaintext headers, no decryption, no key needed
    * `--allow-header-mismatch` — emit mismatched items instead of skipping
  """

  use Mix.Task

  alias SalixAnalytics.EventArchive.{Item, Sink}
  alias SalixStore.Age

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          identity: :string,
          input: :string,
          session: :string,
          stream: :string,
          from: :string,
          to: :string,
          headers_only: :boolean,
          allow_header_mismatch: :boolean
        ],
        aliases: [i: :identity]
      )

    rows = load_rows(opts)

    if opts[:headers_only] do
      print_headers(rows)
    else
      identity = load_identity(opts[:identity] || Mix.raise("--identity is required"))
      open_all(rows, identity, opts[:allow_header_mismatch] == true)
    end
  end

  defp load_rows(opts) do
    cond do
      opts[:input] -> read_rows(opts[:input])
      opts[:session] -> select(~s|session_id = #{quoted(opts[:session])}|, opts)
      opts[:stream] -> select(~s|stream = #{quoted(opts[:stream])}|, opts)
      true -> Mix.raise("one of --input, --session or --stream is required")
    end
  end

  defp select(predicate, opts) do
    Mix.Task.run("app.start")

    from = opts[:from] || Date.utc_today() |> Date.add(-30) |> Date.to_iso8601()
    to = opts[:to] || Date.utc_today() |> Date.to_iso8601()

    where =
      "event_date BETWEEN #{quoted(from)} AND #{quoted(to)} AND " <> predicate

    case Sink.select(where, order: "stream, writer, seq") do
      {:ok, rows} -> rows
      {:error, reason} -> Mix.raise("could not read the archive: #{inspect(reason)}")
    end
  end

  defp quoted(value) do
    escaped =
      value
      |> to_string()
      |> String.replace(~r/[[:cntrl:]]/, "")
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'" <> escaped <> "'"
  end

  defp read_rows("-"), do: :stdio |> IO.stream(:line) |> Enum.to_list() |> decode()
  defp read_rows(path), do: path |> File.read!() |> String.split("\n", trim: true) |> decode()

  defp decode(lines) do
    Enum.flat_map(lines, fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, row} when is_map(row) -> [row]
        _ -> []
      end
    end)
  end

  defp load_identity(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.find_value(fn line ->
      case Age.parse_identity(line) do
        {:ok, identity} -> identity
        {:error, _} -> nil
      end
    end)
    |> case do
      nil -> Mix.raise("no AGE-SECRET-KEY-1… identity found in #{path}")
      identity -> identity
    end
  end

  defp print_headers(rows) do
    Enum.each(rows, fn row -> IO.puts(Jason.encode!(Item.header_of_row(row))) end)
  end

  defp open_all(rows, identity, allow_mismatch?) do
    {opened, skipped, failed} =
      Enum.reduce(rows, {0, 0, 0}, fn row, {opened, skipped, failed} ->
        case Item.open(row, identity) do
          {:ok, header, payload, :verified} ->
            IO.puts(Jason.encode!(%{"h" => header, "p" => payload}))
            {opened + 1, skipped, failed}

          {:ok, header, payload, {:header_mismatch, sealed}} ->
            warn(
              "header mismatch at seq #{header["seq"]}: the header columns do not " <>
                "match the copy sealed inside the item"
            )

            if allow_mismatch? do
              IO.puts(
                Jason.encode!(%{
                  "h" => header,
                  "sealed_h" => sealed,
                  "p" => payload,
                  "header_mismatch" => true
                })
              )

              {opened + 1, skipped, failed}
            else
              {opened, skipped + 1, failed}
            end

          {:error, reason} ->
            warn("could not open item: #{inspect(reason)}")
            {opened, skipped, failed + 1}
        end
      end)

    warn("opened #{opened}, skipped #{skipped}, failed #{failed}")
    if failed > 0 or skipped > 0, do: exit({:shutdown, 1})
  end

  defp warn(message), do: IO.puts(:stderr, message)
end
