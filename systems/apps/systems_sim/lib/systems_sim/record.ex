defmodule SystemsSim.Record do
  @moduledoc """
  The execution record of each test, for the determinism proof
  (`scripts/determinism`). With `DETERMINISM_RECORD` set to a path, run the
  tests with this formatter beside the CLI formatter:

      mix test --formatter ExUnit.CLIFormatter --formatter SystemsSim.Record

  Each finished test appends one JSON line to the path:

      {"file": "systems/apps/APP/test/FILE", "test": "...", "status": "passed",
       "events": 3, "digest": "<sha256 hex>"}

  The events are the test's `SystemsSim.run/2` runs, in order: each run's
  seed, step count, record (every step's messages with their content) and
  result, with pids, references, ports and functions in the result replaced
  by their order of appearance. The
  digest is the SHA-256 of the events; a test that ran no simulation has no
  events, and cannot prove its file deterministic. With
  `DETERMINISM_RECORD_DUMP` set to a directory, each test's events are also
  written there (`:erlang.term_to_binary/1`, a file per test) to find where
  two runs part.
  """
  use SystemsRuntime.Server

  @doc false
  # Adds a run of the calling test's simulation to its record.
  @spec add(SystemsSim.Run.t()) :: :ok
  def add(%SystemsSim.Run{} = run) do
    with true <- SystemsRuntime.ETS.whereis(__MODULE__) != :undefined,
         %ExUnit.Test{module: module, name: name} <- current_test() do
      event = {run.seed, run.steps, run.record, stable(run.result)}

      SystemsRuntime.ETS.insert(
        __MODULE__,
        {{module, name, System.unique_integer([:monotonic])}, event}
      )
    end

    :ok
  end

  # The test the caller, or a process that started it, runs: ExUnit keeps
  # it in the dictionary of the process that starts each test's process.
  defp current_test do
    starters = [self() | Process.get(:"$callers", [])]
    Enum.find_value(starters, &test_above(&1, 6))
  end

  defp test_above(_pid, 0), do: nil

  defp test_above(pid, depth) do
    case Process.info(pid, [:dictionary, :parent]) do
      [dictionary: dictionary, parent: parent] ->
        case List.keyfind(dictionary, ExUnit.Runner, 0) do
          {_, %ExUnit.Test{} = test} -> test
          _ when is_pid(parent) -> test_above(parent, depth - 1)
          _ -> nil
        end

      nil ->
        nil
    end
  end

  # A term's text with each pid, reference, port and function named by its
  # order of appearance, so equal runs print the same.
  defp stable(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)

    {text, _seen} =
      Regex.split(~r/#(PID|Reference|Port|Function)<[^>]*>/, text, include_captures: true)
      |> Enum.map_reduce(%{}, fn part, seen ->
        case Regex.run(~r/^#(PID|Reference|Port|Function)</, part) do
          [_, kind] ->
            seen = Map.put_new(seen, part, map_size(seen))
            {"##{kind}<#{seen[part]}>", seen}

          nil ->
            {part, seen}
        end
      end)

    Enum.join(text)
  end

  @impl true
  def init(_opts) do
    SystemsRuntime.ETS.new(__MODULE__, [:named_table, :public, :ordered_set])
    {:ok, System.get_env("DETERMINISM_RECORD")}
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, path) when is_binary(path) do
    events =
      __MODULE__
      |> SystemsRuntime.ETS.match({{test.module, test.name, :_}, :"$1"})
      |> List.flatten()

    SystemsRuntime.ETS.match_delete(__MODULE__, {{test.module, test.name, :_}, :_})

    line = %{
      file: repo_path(test.tags[:file]),
      test: "#{inspect(test.module)} #{test.name}",
      status: status(test.state),
      events: length(events),
      digest:
        :crypto.hash(:sha256, :erlang.term_to_binary(events, [:deterministic]))
        |> Base.encode16(case: :lower)
    }

    File.write!(path, [JSON.encode!(line), "\n"], [:append])

    if dir = System.get_env("DETERMINISM_RECORD_DUMP") do
      File.mkdir_p!(dir)
      name = :crypto.hash(:sha256, line.test) |> Base.encode16(case: :lower) |> binary_part(0, 16)
      File.write!(Path.join(dir, name <> ".bin"), :erlang.term_to_binary({line.test, events}))
    end

    {:noreply, path}
  end

  def handle_cast(_event, path), do: {:noreply, path}

  defp status(nil), do: "passed"
  defp status({:failed, _}), do: "failed"
  defp status({:excluded, _}), do: "excluded"
  defp status({:skipped, _}), do: "skipped"
  defp status({:invalid, _}), do: "invalid"

  # The path from the repository's root.
  defp repo_path(file) when is_binary(file) do
    case Regex.run(~r{(systems/apps/.+)$}, file) do
      [_, path] -> path
      nil -> file
    end
  end

  defp repo_path(_file), do: nil
end
