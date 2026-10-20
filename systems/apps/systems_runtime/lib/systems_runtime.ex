defmodule SystemsRuntime do
  @moduledoc """
  The runtime context that code reads its outside dependencies from, so a test
  can change what one test's processes see without changing what every other
  process in the VM sees.

  `get_env/3` and `fetch_env/2` read application configuration as
  `Application.get_env/3` and `Application.fetch_env/2` do. Outside a test VM
  they are those functions, after one `:persistent_term` read. In a test VM
  (`config :systems_runtime, scoped_env: true`), a value that a test bound with
  `SystemsRuntime.Test.put_env/3` comes first, for the test process and the
  processes that act for it:

    * processes that name it in `$callers` (`Task`, `Task.Supervisor`), or in
      `$ancestors` (processes the test starts, such as with `start_supervised/1`);
    * processes it allowed with `SystemsRuntime.Test.allow/1`;
    * every process, while it holds the bindings in shared mode
      (`SystemsRuntime.Test.shared/0`).

  Other processes read the application environment. A binding ends when the
  test process exits, so a failed test cannot leave a module swapped for the
  next one, and tests that bind different values can run with `async: true`.

  A read is a few ETS lookups in the calling process, one per process it acts
  for; only binding goes through a server. Read a dependency through this
  module at the point where the code chooses it, such as a port's `impl/0`,
  rather than caching it in a process started with the application: such a
  process does not act for any test.
  """

  @table_key {__MODULE__, :table}

  @doc "As `Application.ensure_all_started/2`."
  def ensure_all_started(app, opts \\ []), do: Application.ensure_all_started(app, opts)

  @doc "Sets `key` of `app`, as `Application.put_env/4`."
  def put_env(app, key, value, opts \\ []), do: Application.put_env(app, key, value, opts)

  @doc "Deletes `key` of `app`, as `Application.delete_env/3`."
  def delete_env(app, key, opts \\ []), do: Application.delete_env(app, key, opts)

  @doc "The configured value of `key` for `app`, as `Application.get_env/3`."
  @spec get_env(atom(), atom(), term()) :: term()
  def get_env(app, key, default \\ nil) do
    case fetch_env(app, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "The configured value of `key` for `app`, as `Application.fetch_env!/2`."
  def fetch_env!(app, key) do
    case fetch_env(app, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "could not fetch application environment #{inspect(key)} for application #{inspect(app)}"
    end
  end

  @doc "The configured value of `key` for `app`, as `Application.fetch_env/2`."
  @spec fetch_env(atom(), atom()) :: {:ok, term()} | :error
  def fetch_env(app, key) do
    case bound(app, key) do
      {:ok, {:value, value}} -> {:ok, value}
      {:ok, :unset} -> :error
      :error -> Application.fetch_env(app, key)
    end
  end

  defp bound(app, key) do
    case :persistent_term.get(@table_key, nil) do
      nil -> :error
      table -> table |> owners() |> Enum.find_value(:error, &lookup(table, {:bind, &1, app, key}))
    end
  end

  defp lookup(table, row) do
    case :ets.lookup(table, row) do
      [{_, binding}] -> {:ok, binding}
      [] -> nil
    end
  end

  # The live processes whose bindings the caller reads: the shared owner, or
  # the caller and those it acts for (`$callers` first, as a task's caller is
  # the closer owner, then `$ancestors` that are pids), each followed by the
  # owner that allowed it. A binding ends when its owner exits, before the
  # server deletes its rows.
  defp owners(table) do
    case :ets.lookup(table, :shared) do
      [{:shared, owner}] ->
        alive([owner])

      [] ->
        ancestors = Enum.filter(Process.get(:"$ancestors", []), &is_pid/1)

        [self() | Process.get(:"$callers", [])]
        |> Kernel.++(ancestors)
        |> Enum.flat_map(fn pid ->
          case :ets.lookup(table, {:allow, pid}) do
            [{_, owner}] -> [pid, owner]
            [] -> [pid]
          end
        end)
        |> alive()
    end
  end

  defp alive(pids), do: Enum.filter(pids, &(&1 == self() or Process.alive?(&1)))

  @doc false
  def table, do: :persistent_term.get(@table_key, nil)

  @doc false
  def put_table(table), do: :persistent_term.put(@table_key, table)
end
