defmodule SystemsClock.Test do
  @moduledoc """
  `use SystemsClock.Test, scope: [...]` in an `async: false` ExUnit module
  holds one driven manual clock for the module and hands it to each test, so
  the tests wait for events by settling instead of waiting real time. Work a
  test leaves behind keeps its timers on the same clock and runs at the same
  clock times in every run. Other options are those of `SystemsClock.settle/1`.

  It imports `SystemsClock.Assertions`, `settle_until/1` and `settled_await/1`.
  """

  defmacro __using__(opts) do
    quote do
      import SystemsClock.Assertions
      import SystemsClock.Test, only: [settle_until: 1, settled_await: 1]

      setup_all do
        SystemsClock.manual(Keyword.put(unquote(opts), :drive, true))
        on_exit(&SystemsClock.reset/0)
        :ok
      end

      setup do
        SystemsClock.take_over()
        on_exit(&SystemsClock.save_report/0)
        :ok
      end
    end
  end

  @doc "Settles until `fun` returns a truthy value, and returns it."
  def settle_until(fun) when is_function(fun, 0), do: SystemsClock.settle(until: fun)

  @doc "Settles until `task` has replied, and returns its result, as `Task.await/2` does."
  def settled_await(%Task{} = task) do
    case SystemsClock.settle(until: fn -> Task.yield(task, 0) end) do
      {:ok, value} -> value
      {:exit, reason} -> exit(reason)
    end
  end
end
