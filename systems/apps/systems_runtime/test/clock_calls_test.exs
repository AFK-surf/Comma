defmodule SystemsRuntime.ClockCallsTest do
  use ExUnit.Case, async: true

  alias SystemsRuntime.ClockCalls

  # A directory of its own: CI runs this file in several `mix test` processes
  # at once, which would share ExUnit's `:tmp_dir`.
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "clock-calls-#{System.unique_integer([:positive])}-#{:os.getpid()}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp_dir: dir}
  end

  test "reports direct clock calls of compiled application modules", %{tmp_dir: dir} do
    compile!(dir, "lib/direct.ex", """
    defmodule ClockCallsSample.Direct do
      def stamp, do: DateTime.utc_now()
      def tick(pid), do: Process.send_after(pid, :tick, 1_000)
      def elapsed(start), do: System.monotonic_time() - start
    end
    """)

    compile!(dir, "lib/captured.ex", """
    defmodule ClockCallsSample.Captured do
      @defaults [stamp: &DateTime.utc_now/0]
      def wait(opts), do: Keyword.get(opts, :sleep, &Process.sleep/1).(1)
      def stamp(opts), do: Keyword.merge(@defaults, opts)[:stamp].()
    end
    """)

    compile!(dir, "lib/clocked.ex", """
    defmodule ClockCallsSample.Clocked do
      def stamp, do: SystemsClock.utc_now()
      def tick(pid), do: SystemsClock.send_after(pid, :tick, 1_000)
    end
    """)

    compile!(dir, "apps/example/test/support/fixture.ex", """
    defmodule ClockCallsSample.Fixture do
      def stamp, do: DateTime.utc_now()
    end
    """)

    assert ClockCalls.scan([dir]) == %{
             "ClockCallsSample.Captured" => ["DateTime.utc_now/0", "Process.sleep/1"],
             "ClockCallsSample.Direct" => [
               ":erlang.monotonic_time/0",
               "DateTime.utc_now/0",
               "Process.send_after/3"
             ]
           }
  end

  test "a baseline admits only the calls it lists" do
    report = %{
      "Old" => ["DateTime.utc_now/0", "Process.sleep/1"],
      "New" => ["DateTime.utc_now/0"]
    }

    baseline = %{"Old" => ["DateTime.utc_now/0"]}

    assert ClockCalls.new_calls(report, baseline) == %{
             "Old" => ["Process.sleep/1"],
             "New" => ["DateTime.utc_now/0"]
           }

    assert ClockCalls.new_calls(baseline, report) == %{}
  end

  test "names the SystemsClock function to call instead" do
    assert ClockCalls.replacement("DateTime.utc_now/0") == "SystemsClock.utc_now/0"
    assert ClockCalls.replacement(":erlang.send_after/3") == "SystemsClock.send_after/4"
  end

  defp compile!(dir, source, code) do
    for {module, binary} <- Code.compile_string(code, source) do
      File.write!(Path.join(dir, "#{module}.beam"), binary)
      :code.purge(module)
      :code.delete(module)
    end
  end
end
