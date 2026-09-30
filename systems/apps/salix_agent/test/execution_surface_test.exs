defmodule SalixAgent.ExecutionSurfaceTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{ExecutionSurface, ExecutionTiming}

  test "parallel jobs remain independent and owner death freezes an unknown end" do
    context = %{
      agent_id: "history-test-#{System.unique_integer([:positive])}",
      session_id: "session"
    }

    parent = self()

    jobs =
      for id <- ["a", "b"] do
        spawn(fn ->
          timing = ExecutionTiming.start()

          ExecutionSurface.observe(
            context,
            ExecutionSurface.record(id, "tool", ExecutionTiming.running(timing), %{}, true)
          )

          # Same sender's read is a barrier for its cast before notifying the test.
          ExecutionSurface.get(context.agent_id, context.session_id)
          send(parent, {:started, id})

          receive do
            :finish ->
              ExecutionSurface.observe(
                context,
                ExecutionSurface.record(id, "tool", ExecutionTiming.finish(timing), %{}, false)
              )

              ExecutionSurface.get(context.agent_id, context.session_id)
              send(parent, {:finished, id})
          end
        end)
      end

    assert_receive {:started, "a"}
    assert_receive {:started, "b"}

    assert Enum.all?(
             ExecutionSurface.get(context.agent_id, context.session_id),
             & &1["execution"]["live"]
           )

    [a, b] = jobs
    Process.exit(a, :kill)
    send(b, :finish)
    assert_receive {:finished, "b"}
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
      Process.sleep(5)
      wait_frozen(context, attempts - 1)
    end
  end
end
