defmodule BridgeForTeams.DbClockTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.Repo

  setup do
    on_exit(&SystemsClock.reset/0)
  end

  test "the test database's now() is the manual clock's time and returns to real time" do
    SystemsClock.manual()
    clock = SystemsClock.utc_now()
    assert db_now() == clock

    SystemsClock.advance(3_600_000)
    assert db_now() == DateTime.add(clock, 3_600, :second)

    SystemsClock.reset()
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM systems_clock.clock")
  end

  test "SQL now() and Ecto timestamps take the time of a moved clock" do
    SystemsClock.manual()
    SystemsClock.advance(86_400_000)
    tomorrow = SystemsClock.utc_now()

    %{rows: [[default_now]]} = Repo.query!("SELECT now()")
    assert default_now == tomorrow
    assert SystemsClock.timestamp(:utc_datetime_usec) == tomorrow
  end

  test "records written at one clock time stay at or before the database's time after a move" do
    SystemsClock.manual()
    now = SystemsClock.utc_now()
    for _ <- 1..3, do: SystemsClock.timestamp(:utc_datetime_usec)

    # Three records took now, +10 µs and +20 µs; a move shorter than that keeps
    # the database at the last of them.
    SystemsClock.advance(0)
    assert db_now() == DateTime.add(now, 20, :microsecond)
  end

  # A process that checked out its own sandbox connection keeps it, and the
  # transaction it holds, when the clock moves in that process.
  test "moving the clock leaves the mover's sandbox connection and transaction alone" do
    SystemsClock.manual()

    task =
      SystemsRuntime.Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
        Repo.query!("CREATE TEMP TABLE db_clock_mover (x integer)")
        Repo.query!("INSERT INTO db_clock_mover VALUES (1)")
        SystemsClock.advance(1_000)
        %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM db_clock_mover")
        count
      end)

    assert SystemsClock.settle(until: fn -> SystemsRuntime.Task.yield(task, 0) end) == {:ok, 1}
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT statement_timestamp()")
    now
  end
end
