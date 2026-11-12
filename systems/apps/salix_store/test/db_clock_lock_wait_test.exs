defmodule SalixStore.DbClockLockWaitTest do
  @moduledoc """
  When the clock may move past a query that waits for a lock
  (`SystemsRuntime.DbClock.waiting_on_locks?/0`).
  """
  use SystemsClock.Case, async: false

  alias SalixStore.Repo
  alias SystemsRuntime.DbClock

  @table "salix_session_sources"

  setup do
    {:ok, holder} =
      Postgrex.start_link(
        Repo.config()
        |> Keyword.take([:hostname, :port, :username, :password, :database])
      )

    on_exit(fn -> if Process.alive?(holder), do: GenServer.stop(holder) end)
    Postgrex.query!(holder, "BEGIN", [])
    Postgrex.query!(holder, "LOCK TABLE #{@table} IN ACCESS EXCLUSIVE MODE", [])
    %{rows: [[holder_pid]]} = Postgrex.query!(holder, "SELECT pg_backend_pid()", [])

    reader =
      Task.async(fn -> Repo.query!("SELECT count(*) FROM #{@table}", [], timeout: :infinity) end)

    await(
      holder_pid,
      "EXISTS (SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)))"
    )

    %{holder: holder, holder_pid: holder_pid, reader: reader}
  end

  test "a lock an idle transaction holds lets the clock move", context do
    assert DbClock.waiting_on_locks?()

    Postgrex.query!(context.holder, "COMMIT", [])
    assert %{rows: [[_count]]} = Task.await(context.reader, :infinity)
  end

  test "a lock a working backend holds does not", context do
    working =
      Task.async(fn ->
        Postgrex.query(context.holder, "SELECT pg_sleep(3600)", [], timeout: :infinity)
      end)

    await(
      context.holder_pid,
      "EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = $1 AND state = 'active')"
    )

    refute DbClock.waiting_on_locks?()

    Repo.query!("SELECT pg_cancel_backend($1)", [context.holder_pid])

    assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
             Task.await(working, :infinity)

    Postgrex.query!(context.holder, "ROLLBACK", [])
    assert %{rows: [[_count]]} = Task.await(context.reader, :infinity)
  end

  defp await(holder_pid, condition) do
    case Repo.query!("SELECT #{condition}", [holder_pid]).rows do
      [[true]] -> :ok
      [[false]] -> await(holder_pid, condition)
    end
  end
end
