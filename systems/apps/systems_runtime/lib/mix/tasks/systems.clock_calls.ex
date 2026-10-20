defmodule Mix.Tasks.Systems.ClockCalls do
  @shortdoc "Fails on new direct clock calls in umbrella application code"
  @moduledoc """
  Checks the compiled umbrella applications for calls that read time or arm
  timers without `SystemsClock` (see `SystemsRuntime.ClockCalls`). Calls
  listed in the baseline are allowed; any other call fails the task.

      mix systems.clock_calls
      mix systems.clock_calls --update-baseline

  `--update-baseline` rewrites the baseline to the current calls. Use it after
  removing calls, so they cannot come back. Do not use it to admit a new call.
  """
  use Mix.Task

  alias SystemsRuntime.ClockCalls

  @baseline "apps/systems_runtime/priv/clock_calls_baseline.exs"

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    report =
      Mix.Project.apps_paths()
      |> Map.keys()
      |> Enum.map(&Path.join(Mix.Project.build_path(), "lib/#{&1}/ebin"))
      |> ClockCalls.scan()

    if "--update-baseline" in args do
      File.write!(@baseline, baseline_source(report))
      Mix.shell().info("Wrote #{map_size(report)} modules to #{@baseline}")
    else
      {baseline, _} = Code.eval_file(@baseline)
      check(ClockCalls.new_calls(report, baseline))
    end
  end

  defp check(new) when map_size(new) == 0, do: :ok

  defp check(new) do
    lines =
      for {module, calls} <- Enum.sort(new),
          call <- calls,
          do: "  #{module}: #{call}, use #{ClockCalls.replacement(call)}"

    Mix.raise("""
    Direct clock calls that a test cannot control:

    #{Enum.join(lines, "\n")}

    Read time and arm timers through SystemsClock.
    """)
  end

  defp baseline_source(report) do
    entries =
      Enum.map_join(Enum.sort(report), ",\n", fn {module, calls} ->
        "#{inspect(module)} => #{inspect(calls)}"
      end)

    formatted = IO.iodata_to_binary(Code.format_string!("%{\n#{entries}\n}"))

    """
    # Direct clock calls that existed before `mix systems.clock_calls`. Remove
    # entries as code moves to SystemsClock; never add one by hand.
    #{formatted}
    """
  end
end
