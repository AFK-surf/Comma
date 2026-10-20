defmodule SalixAgent.ExecutionSurfaceTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{ExecutionSurface, ExecutionTiming}

  test "parallel jobs remain independent and owner death freezes an unknown end" do
    context = %{
      agent_id: "history-test-#{SystemsRuntime.Proc.unique_integer([:positive])}",
      session_id: "session"
    }

    parent = SystemsRuntime.Proc.self()

    jobs =
      for id <- ["a", "b"] do
        SystemsRuntime.Proc.spawn(fn ->
          timing = ExecutionTiming.start()

          ExecutionSurface.observe(
            context,
            ExecutionSurface.record(id, "tool", ExecutionTiming.running(timing), %{}, true)
          )

          # Same sender's read is a barrier for its cast before notifying the test.
          ExecutionSurface.get(context.agent_id, context.session_id)
          SystemsRuntime.Proc.send(parent, {:started, id})

          SystemsRuntime.Proc.receive do
            :finish ->
              ExecutionSurface.observe(
                context,
                ExecutionSurface.record(id, "tool", ExecutionTiming.finish(timing), %{}, false)
              )

              ExecutionSurface.get(context.agent_id, context.session_id)
              SystemsRuntime.Proc.send(parent, {:finished, id})
          end
        end)
      end

    settle_receive({:started, "a"})
    settle_receive({:started, "b"})

    assert Enum.all?(
             ExecutionSurface.get(context.agent_id, context.session_id),
             & &1["execution"]["live"]
           )

    [a, b] = jobs
    SystemsRuntime.Proc.exit(a, :kill)
    SystemsRuntime.Proc.send(b, :finish)
    settle_receive({:finished, "b"})
    wait_frozen(context, 100)

    records =
      Map.new(
        ExecutionSurface.get(context.agent_id, context.session_id),
        &{&1["execution"]["id"], &1["execution"]}
      )

    assert records["a"]["completed_at_ms"] == nil
    assert records["a"]["live"] == false
    assert is_integer(records["b"]["completed_at_ms"])
    assert records["b"]["live"] == false
    assert ExecutionSurface.get(context.agent_id, "another-session") == []
  end

  defp wait_frozen(_context, 0), do: flunk("owner death was not observed")

  defp wait_frozen(context, attempts) do
    if Enum.any?(
         ExecutionSurface.get(context.agent_id, context.session_id),
         & &1["execution"]["live"]
       ) do
      SystemsClock.sleep(5)
      wait_frozen(context, attempts - 1)
    end
  end
end
