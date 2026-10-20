defmodule SystemsClock.Formatter do
  @moduledoc """
  ExUnit formatter that prints `SystemsClock.report/0` for each failed test
  that ran on a manual clock: the clock's moves and where each process in
  scope waited. It also prints each finished test file's duration, the sum of
  its tests' times, as `beam-test-file apps/APP/test/FILE SECONDS`, which
  `scripts/ci/beam_test_shard.exs --timings` reads. Run it beside the CLI
  formatter:

      mix test --formatter ExUnit.CLIFormatter --formatter SystemsClock.Formatter
  """
  use GenServer

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :public, :set])
    {:ok, nil}
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, _}} = test}, state) do
    case SystemsClock.report() do
      nil -> :ok
      report -> IO.puts("\n#{inspect(test.module)} #{test.name}\n#{report}\n")
    end

    :ets.delete(__MODULE__, :report)
    {:noreply, state}
  end

  def handle_cast({:test_finished, _test}, state) do
    :ets.delete(__MODULE__, :report)
    {:noreply, state}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{file: file, tests: tests}}, state) do
    case Regex.run(~r{(apps/[^/]+/test/.+_test\.exs)$}, file || "") do
      [_, path] ->
        micros = tests |> Enum.map(&(&1.time || 0)) |> Enum.sum()
        IO.puts("beam-test-file #{path} #{Float.round(micros / 1_000_000, 1)}")

      nil ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
