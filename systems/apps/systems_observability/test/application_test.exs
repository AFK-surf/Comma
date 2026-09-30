defmodule SystemsObservability.ApplicationTest do
  use ExUnit.Case, async: false

  test "an unavailable metrics port does not prevent the application from starting" do
    previous_port = Application.get_env(:systems_observability, :port, 9568)

    assert :ok = Application.stop(:systems_observability)
    {:ok, listener} = :gen_tcp.listen(0, active: false, reuseaddr: true)
    {:ok, {_address, occupied_port}} = :inet.sockname(listener)
    Application.put_env(:systems_observability, :port, occupied_port)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Application.stop(:systems_observability)
      Application.put_env(:systems_observability, :port, previous_port)
      {:ok, _} = Application.ensure_all_started(:systems_observability)
      await_reporter(20)
    end)

    assert {:ok, _} = Application.ensure_all_started(:systems_observability)
    assert Process.alive?(Process.whereis(SystemsObservability.Runtime))
    refute Process.whereis(SystemsObservability.Prometheus)
    refute Process.whereis(SystemsObservability.Histograms)
  end

  test "release telemetry applications can terminate without terminating the VM" do
    systems_root = Path.expand("../../..", __DIR__)

    script = ~S"""
    release = Mix.Release.from_config!(:comma, Mix.Project.config(), [])

    mode = fn application ->
      release.applications
      |> Map.fetch!(application)
      |> Keyword.fetch!(:mode)
    end

    exporter_mode = mode.(:opentelemetry_exporter)
    observability_mode = mode.(:systems_observability)

    Application.put_env(:comma, :enabled_subsystems, [])
    Application.put_env(:systems_observability, :port, 0)

    {:ok, _} =
      Application.ensure_all_started(:opentelemetry_exporter, type: exporter_mode)

    {:ok, _} =
      Application.ensure_all_started(:systems_observability, type: observability_mode)

    sentinel = spawn(fn -> Process.sleep(:infinity) end)
    Process.exit(Process.whereis(SystemsObservability.Supervisor), :kill)
    Process.sleep(200)

    true = Process.alive?(sentinel)
    false = :systems_observability in Enum.map(Application.started_applications(), &elem(&1, 0))

    :ok = Application.stop(:opentelemetry_exporter)
    Process.sleep(100)
    true = Process.alive?(sentinel)

    :temporary = observability_mode
    :temporary = exporter_mode
    IO.puts("telemetry-apps-isolated")
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        cd: systems_root,
        env: [{"ERL_CRASH_DUMP", "/dev/null"}, {"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "telemetry-apps-isolated"
  end

  defp await_reporter(0), do: flunk("observability reporter did not restart")

  defp await_reporter(attempts) do
    if Process.whereis(SystemsObservability.Prometheus) &&
         Process.whereis(SystemsObservability.Histograms) do
      :ok
    else
      if pid = Process.whereis(SystemsObservability.Runtime), do: send(pid, :retry)
      Process.sleep(25)
      await_reporter(attempts - 1)
    end
  end
end
