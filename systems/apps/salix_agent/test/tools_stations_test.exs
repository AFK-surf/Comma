defmodule SalixAgent.ToolsStationsTest do
  @moduledoc """
  Station targets and station tools against a fake `SalixAgent.Stations` port:
  environment tools with a `station:<id>` device id become `comma/tools/1` ops
  with the full tool ctx, chunked file movement keeps the per-call limit, and
  station results and failures reach the model in the documented shape.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.Stations.Env
  alias SalixAgent.ToolDisclosure
  alias SalixAgent.Tools.{Peers, Stations}

  @station String.duplicate("ab", 32)
  @ctx %{agent_id: "agt_station_test", session_id: "ses_1", tool_call_id: "call_1"}

  defmodule FakePort do
    @behaviour SalixAgent.Stations

    @impl true
    def configured?, do: SystemsRuntime.get_env(:salix_agent, :fake_station_configured, true)

    @impl true
    def list(ctx) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:station_list, ctx})
      {:ok, [%{"id" => String.duplicate("ab", 32), "name" => "Studio Mac", "online" => true}]}
    end

    @impl true
    def call(ctx, station_id, op, args) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:station_call, ctx, station_id, op, args}
      )

      SystemsRuntime.fetch_env!(:salix_agent, :fake_station_reply).(op, args)
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :stations)
    SystemsRuntime.put_env(:salix_agent, :stations, FakePort)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :stations, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :stations)

      SystemsRuntime.delete_env(:salix_agent, :fake_station_reply)
      SystemsRuntime.delete_env(:salix_agent, :fake_station_configured)
    end)

    :ok
  end

  defp reply(fun), do: SystemsRuntime.put_env(:salix_agent, :fake_station_reply, fun)

  test "env.exec on a station target runs exec through the port with the tool ctx" do
    reply(fn "exec", _args ->
      {:ok, %{"exit_code" => 0, "stdout" => "Darwin\n", "stderr" => "", "truncated" => false}}
    end)

    output =
      Peers.exec(
        %{
          "device_id" => "station:" <> @station,
          "environment" => "station",
          "command" => "uname",
          "description" => "Check OS",
          "working_dir" => "/tmp",
          "timeout" => 30
        },
        @ctx
      )

    assert %{"exit_code" => 0, "stdout" => "Darwin\n"} = Jason.decode!(output)
    assert_received {:station_call, ctx, @station, "exec", args}
    assert ctx.agent_id == @ctx.agent_id and ctx.tool_call_id == "call_1"
    assert args == %{"command" => "uname", "cwd" => "/tmp", "timeout_ms" => 30_000}
  end

  test "station.session forwards the task and reports unknown outcomes on timeout" do
    reply(fn "session.start", _args -> {:ok, %{"session" => "s1", "thread" => "t1"}} end)

    output =
      Stations.session(
        %{
          "station_id" => "station:" <> @station,
          "action" => "start",
          "prompt" => "Fix the build",
          "runtime" => "codex"
        },
        @ctx
      )

    assert Jason.decode!(output) == %{"session" => "s1", "thread" => "t1"}
    assert_received {:station_call, _, @station, "session.start", args}
    assert args == %{"prompt" => "Fix the build", "runtime" => "codex"}

    reply(fn "session.say", _args -> {:error, {:gateway, "timeout", "no answer"}} end)

    error =
      assert_raise RuntimeError, fn ->
        Stations.session(
          %{
            "station_id" => @station,
            "action" => "say",
            "thread" => "t1",
            "text" => "and test it"
          },
          @ctx
        )
      end

    assert error.message =~ "may have run"

    reply(fn "session.say", _args -> {:error, {:gateway, "station_unreachable", "offline"}} end)

    error =
      assert_raise RuntimeError, fn ->
        Stations.session(
          %{"station_id" => @station, "action" => "say", "thread" => "t1", "text" => "again"},
          @ctx
        )
      end

    assert error.message =~ "was not sent"
  end
end
