defmodule SalixAgent.TestSupport.Settle do
  @moduledoc """
  Tests that never wait on real time. `use SalixAgent.TestSupport.Settle` holds
  a manual `SystemsClock` for the test module. Instead of waiting, a test settles the
  system (`SystemsClock.settle/1`): every process runs until it is idle, and
  the clock jumps to the next timer while the awaited condition does not hold.
  A backoff or an expiry then completes at once, at exact clock times, and the
  same steps happen on every machine.
  """

  # The code under test: Salix processes and the test's own mocks, and the
  # HTTP and WebSocket servers of this node that serve them. Library processes
  # (connection pools, pollers) keep their own schedules.
  @scope [
    "Elixir.SalixAgent",
    "Elixir.SalixStore",
    "Elixir.SalixIM",
    "Elixir.SalixCluster",
    "Elixir.Salix.",
    "Elixir.ThousandIsland",
    "Elixir.Bandit",
    "Elixir.WebSockex"
  ]

  @doc false
  def scope, do: @scope

  # A script compiles and runs in the runtime's OS process: a call to the
  # loops host, or ScriptRun awaiting the guest, waits on work outside the VM
  # that takes real time, like a database reply. So does a verified-kernel
  # call, which runs native code the process state does not show, an id
  # allocator waiting for the next real millisecond, and a `:global` lock
  # request backing off for a random real time before it retries.
  @doc false
  def io,
    do:
      Keyword.fetch!(SystemsClock.settle_defaults(), :io) ++
        [
          SalixAgent.Loops.Host,
          {SalixAgent.ScriptRun, :await},
          SalixVerifiedKernel,
          {SalixStore.Ids, :wait_next_ms},
          {:global, :random_sleep}
        ]

  # `scope:` adds module prefixes of the module's own code under test, such
  # as `"Elixir.SalixWeb"`.
  defmacro __using__(opts) do
    extra_scope = Keyword.get(opts, :scope, [])

    quote do
      import SalixAgent.TestSupport.Settle

      # One clock for the whole module: work a test leaves behind keeps its
      # timers on the clock, so it runs at the same clock times in every run
      # instead of on the real clock in the middle of a later test.
      setup_all context do
        # Each test's `SystemsSim` world runs its own clock.
        unless context[:sim] do
          SystemsClock.manual(
            drive: true,
            scope: SalixAgent.TestSupport.Settle.scope() ++ unquote(extra_scope),
            io: SalixAgent.TestSupport.Settle.io()
          )

          on_exit(&SystemsClock.reset/0)
        end

        :ok
      end

      setup context do
        unless context[:sim] do
          SystemsClock.take_over()
          on_exit(&SystemsClock.save_report/0)
        end

        :ok
      end
    end
  end

  @doc "Runs the system until it is idle, without moving the clock."
  def settle, do: SystemsClock.settle()

  @doc "Settles until `fun` returns a truthy value, and returns it."
  def settle_until(fun) when is_function(fun, 0), do: SystemsClock.settle(until: fun)

  @doc "Moves the clock `ms` milliseconds and settles."
  def settle_after(ms) do
    SystemsClock.advance(ms)
    SystemsClock.settle()
  end

  @doc "Settles until `task` has replied, and returns its result."
  def settled_await(%Task{} = task) do
    case SystemsClock.settle(until: fn -> SystemsRuntime.Task.yield(task, 0) end) do
      {:ok, value} -> value
      {:exit, reason} -> exit(reason)
    end
  end

  @doc "As `SystemsClock.Assertions.settle_receive/1`."
  defmacro settle_receive(pattern) do
    quote do
      require SystemsClock.Assertions
      SystemsClock.Assertions.settle_receive(unquote(pattern))
    end
  end

  @doc "As `SystemsClock.Assertions.settle_refute_receive/2`."
  defmacro settle_refute_receive(pattern, ms \\ 100) do
    quote do
      require SystemsClock.Assertions
      SystemsClock.Assertions.settle_refute_receive(unquote(pattern), unquote(ms))
    end
  end
end
