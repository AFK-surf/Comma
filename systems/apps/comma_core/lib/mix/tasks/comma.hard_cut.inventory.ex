defmodule Mix.Tasks.Comma.HardCut.Inventory do
  use Mix.Task

  @shortdoc "Generate the read-only Comma Chat hard-cut inventory"

  @switches [output: :string, require_machine_ready: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix comma.hard_cut.inventory [--output PATH] [--require-machine-ready]")
    end

    {:ok, _} = Application.ensure_all_started(:salix_store)

    report =
      case Comma.HardCutInventory.generate() do
        {:ok, report} -> report
        {:error, reason} -> Mix.raise("hard-cut inventory failed: #{inspect(reason)}")
      end

    encoded = Jason.encode_to_iodata!(report, pretty: true) |> IO.iodata_to_binary()

    case opts[:output] do
      nil -> Mix.shell().info(encoded)
      path -> File.write!(path, encoded <> "\n")
    end

    if opts[:require_machine_ready] and not report["machine_ready"] do
      Mix.raise("hard-cut inventory is not machine-ready")
    end
  end
end
