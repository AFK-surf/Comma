defmodule Mix.Tasks.Salix.Archive.Verify do
  @shortdoc "Check the archive for sequence gaps (no key required)"

  @moduledoc """
  Report gaps in the archive's per-stream sequence runs.

      mix salix.archive.verify --from 2026-08-01 --to 2026-08-25
      mix salix.archive.verify --tenant tnt_1
      mix salix.archive.verify --input rows.jsonl

  Needs NO decryption key: the header columns are plaintext precisely so
  completeness can be audited by someone who cannot read the contents. Run it on
  a schedule — a best-effort archive is only defensible if somebody is actually
  looking at whether it dropped anything.

  Against ClickHouse the aggregation runs server-side, so this verifies the
  whole window rather than only the segments a reader managed to download. The
  cost is that it needs SELECT on the archive table, which the runtime
  deliberately does not have — run it as an auditor, not as the app.

  Exits non-zero when any gap is found, so it can gate CI or alerting.
  A RESET is reported but does not fail the run: per-node counters restart when
  a node restarts, which is expected and is not loss.

  ## Options

    * `--from` / `--to` — inclusive ISO dates (default: the last 7 days)
    * `--tenant` — restrict to one tenant
    * `--stream` — restrict to one stream
    * `--input` — analyze a local JSONL file of rows instead of querying
    * `--json` — emit the report as JSON
  """

  use Mix.Task

  alias SalixAnalytics.EventArchive.Completeness

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          from: :string,
          to: :string,
          tenant: :string,
          stream: :string,
          input: :string,
          json: :boolean
        ]
      )

    report =
      if opts[:input] do
        opts[:input] |> read_rows() |> Completeness.analyze()
      else
        Mix.Task.run("app.start")

        query_opts =
          [from: opts[:from], to: opts[:to], tenant_id: opts[:tenant], stream: opts[:stream]]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        case Completeness.report(query_opts) do
          {:ok, report} -> report
          {:error, reason} -> Mix.raise("could not query the archive: #{inspect(reason)}")
        end
      end

    if opts[:json] do
      IO.puts(Jason.encode!(report))
    else
      report |> Completeness.format() |> Enum.each(&IO.puts/1)
    end

    if Enum.any?(report.findings, &(&1.kind == :gap)) do
      exit({:shutdown, 1})
    end
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
end
