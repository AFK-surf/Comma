defmodule SystemsRuntime.DbClock do
  @moduledoc """
  Keeps a test database's time on `SystemsClock`, so SQL that reads `now()`
  agrees with code that reads the clock.

  `install!/1` adds, to a test database only, a `systems_clock` schema whose
  `now()`, `transaction_timestamp()`, `statement_timestamp()` and
  `clock_timestamp()` return, while a manual clock runs, the clock's time at
  its last move (or the last `SystemsClock.timestamp/1` record time before it,
  when that is later: the time never goes back), and the PostgreSQL function
  of the same name otherwise. No real time is added: SQL sees the time the
  code sees, however long the work between two moves takes. It also points column
  defaults that call those functions at the `systems_clock` versions. A
  connection reaches them through `after_connect/1`, which appends the schema and
  then `pg_catalog` to its search path.

  With `config :systems_clock, observers: [SystemsRuntime.DbClock]`, the
  clock calls `clock_moved/1` whenever it stops, moves or is reset, and the
  time is written to every database in
  `config :systems_runtime, db_clock_repos: [...]` that has the schema
  installed. The clock writes and reads through a connection of its own per
  database, started by `install!/1`, never through the repo's pool: a test's
  sandbox connection, and the transaction it holds, are not touched when the
  clock moves in the test's process.
  """

  @schema "systems_clock"
  @functions [
    {"now", "STABLE"},
    {"transaction_timestamp", "STABLE"},
    {"statement_timestamp", "STABLE"},
    {"clock_timestamp", "VOLATILE"}
  ]

  @doc """
  Appends the clock schema and then `pg_catalog` to a new connection's search
  path: new objects still go to the connection's own schemas, and the clock
  functions come before PostgreSQL's.
  """
  @spec after_connect(DBConnection.conn()) :: :ok
  def after_connect(conn) do
    Postgrex.query!(
      conn,
      "SELECT set_config('search_path', current_setting('search_path') || ', #{@schema}, pg_catalog', false)",
      []
    )

    Postgrex.query!(conn, "SELECT set_config('application_name', $1, false)", [node_name()])
    :ok
  end

  # The name this node's connections give the server, which tells them from
  # other nodes' (other test partitions on the same server). Their client
  # ports do not: a server in a container sees the ports of its port
  # forwarding.
  defp node_name, do: "systems-test #{System.pid()}"

  @doc """
  Installs the clock schema in `repo`'s database and moves column defaults
  onto it. For test databases only; run it after the migrations.
  """
  @spec install!(module()) :: :ok
  def install!(repo) do
    conn = connection!(repo)
    install_schema!(conn)
    :persistent_term.put({__MODULE__, repo}, conn)
    :ok
  end

  @doc false
  # The clock schema and the moved column defaults, on connection `conn`'s
  # database.
  def install_schema!(conn) do
    Postgrex.query!(conn, "CREATE SCHEMA IF NOT EXISTS #{@schema}", [])
    Postgrex.query!(conn, "DROP TABLE IF EXISTS #{@schema}.clock CASCADE", [])

    Postgrex.query!(
      conn,
      """
      CREATE TABLE #{@schema}.clock (
        id boolean PRIMARY KEY DEFAULT true CHECK (id),
        at timestamptz NOT NULL
      )
      """,
      []
    )

    for {name, volatility} <- @functions do
      Postgrex.query!(
        conn,
        """
        CREATE OR REPLACE FUNCTION #{@schema}.#{name}() RETURNS timestamptz
        LANGUAGE sql #{volatility} AS
        $$ SELECT COALESCE((SELECT at FROM #{@schema}.clock), pg_catalog.#{name}()) $$
        """,
        []
      )
    end

    move_defaults(conn)
    :ok
  end

  # The clock's own connection to `repo`'s database: registered, so a test's
  # end-of-test stop leaves it, and unlinked from the process that installs it.
  defp connection!(repo) do
    name = Module.concat(__MODULE__, repo)

    case Process.whereis(name) do
      nil ->
        opts =
          repo.config()
          |> Keyword.take([
            :hostname,
            :port,
            :username,
            :password,
            :database,
            :socket_dir,
            :socket,
            :ssl,
            :parameters,
            :types
          ])
          |> Keyword.merge(name: name, pool_size: 1)

        {:ok, conn} = Postgrex.start_link(opts)
        Process.unlink(conn)
        conn

      conn ->
        conn
    end
  end

  defp connections do
    for repo <- Application.get_env(:systems_runtime, :db_clock_repos, []),
        conn = :persistent_term.get({__MODULE__, repo}, nil),
        is_pid(conn) and Process.alive?(conn),
        do: conn
  end

  # A column default binds the function it names when the table is created,
  # whatever the search path is later, so defaults are rewritten in place.
  defp move_defaults(conn) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT n.nspname, c.relname, a.attname, pg_get_expr(d.adbin, d.adrelid)
        FROM pg_attrdef d
        JOIN pg_class c ON c.oid = d.adrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', '#{@schema}')
          AND NOT c.relispartition
          AND pg_get_expr(d.adbin, d.adrelid) ~* '(now|transaction_timestamp|statement_timestamp|clock_timestamp)\\(\\)|current_timestamp'
        """,
        []
      )

    for [schema, table, column, expression] <- rows do
      moved =
        expression
        # With the clock schema on the search path, `pg_get_expr` prints
        # PostgreSQL's own functions qualified (`pg_catalog.now()`).
        |> String.replace(
          ~r/(?<![\w.])(?:pg_catalog\.)?(now|transaction_timestamp|statement_timestamp|clock_timestamp)\(\)/,
          "#{@schema}.\\1()"
        )
        |> String.replace(~r/\bCURRENT_TIMESTAMP\b/i, "#{@schema}.now()")

      Postgrex.query!(
        conn,
        ~s(ALTER TABLE "#{schema}"."#{table}" ALTER COLUMN "#{column}" SET DEFAULT #{moved}),
        []
      )
    end
  end

  @doc """
  A `SystemsClock` check (`config :systems_clock, outside_blocked: [...]`):
  whether every query this node's connections have under way, in any
  database of the server, waits for a lock. A query that waits for a lock an
  idle transaction of the test holds does not go on until the system under
  test moves, so the clock may move. The node's connections are told from
  other nodes' by the application name `after_connect/1` gives them.
  """
  @spec waiting_on_locks?() :: boolean()
  def waiting_on_locks? do
    case connections() do
      [conn | _] ->
        %{rows: [[active, waiting]]} =
          Postgrex.query!(
            conn,
            """
            SELECT count(*) FILTER (WHERE state = 'active'),
                   count(*) FILTER (WHERE state = 'active' AND wait_event_type = 'Lock')
            FROM pg_stat_activity
            WHERE application_name = $1 AND pid <> pg_backend_pid()
            """,
            [node_name()]
          )

        active > 0 and active == waiting

      [] ->
        false
    end
  end

  @doc """
  The node's queries under way, as the database reports them, for a
  `SystemsClock` failure report (`config :systems_clock,
  outside_blocked_report: [...]`): each one's backend, state, wait and the
  start of its text.
  """
  @spec lock_report() :: [list()] | {:error, term()}
  def lock_report do
    case connections() do
      [conn | _] ->
        %{rows: rows} =
          Postgrex.query!(
            conn,
            """
            SELECT pid, client_port, state, wait_event_type, wait_event, left(query, 120)
            FROM pg_stat_activity
            WHERE application_name = $1 AND pid <> pg_backend_pid() AND state <> 'idle'
            """,
            [node_name()]
          )

        rows

      [] ->
        []
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc false
  # SystemsClock observer: `at` is the clock's UTC time in microseconds, or
  # nil when the clock runs on real time again.
  def clock_moved(at) do
    for conn <- connections() do
      case at do
        nil ->
          Postgrex.query!(conn, "DELETE FROM #{@schema}.clock", [])

        at ->
          Postgrex.query!(
            conn,
            """
            INSERT INTO #{@schema}.clock (id, at) VALUES (true, $1)
            ON CONFLICT (id) DO UPDATE SET at = EXCLUDED.at
            """,
            [DateTime.from_unix!(at, :microsecond)]
          )
      end
    end

    :ok
  end
end
