defmodule SalixWeb.L4ESRecent do
  @moduledoc """
  What this node recently made true in an L4ES workspace (`SalixWeb.L4ES`):
  that it has the release's sandbox image, and that its members are a given
  set. Each sandbox create asks for both; while an entry is fresh (10
  minutes), the calls that would find it so are skipped. A changed member
  set or another image is another entry, so it is synced at once.

  L4ES stays the source of truth: a change made in L4ES itself is found at
  the latest when the entry expires, and a create L4ES refuses forgets the
  workspace's entries (`forget/1`), so the next one asks again. The table is
  node-local: another node syncs once for itself. Without the table (it is
  not running), nothing is remembered.
  """

  use SystemsRuntime.Server

  @table __MODULE__
  @ttl_ms 600_000

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  What was remembered of `key` (`{kind, workspace_id, what}`) within the
  last 10 minutes: `{:ok, value}`, else `:error`.
  """
  def recall(key) do
    case SystemsRuntime.ETS.lookup(@table, key) do
      [{^key, value, expires_at}] -> if expires_at > now(), do: {:ok, value}, else: :error
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "`key` is `value` now."
  def remember(key, value) do
    SystemsRuntime.ETS.insert(@table, {key, value, now() + @ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Nothing is remembered of workspace `workspace_id` any more."
  def forget(workspace_id) do
    SystemsRuntime.ETS.match_delete(@table, {{:_, workspace_id, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    SystemsRuntime.ETS.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  # Entries expire where they lie; the sweep drops them so memory follows
  # the workspaces that made sandboxes recently.
  @impl true
  def handle_info(:sweep, state) do
    SystemsRuntime.ETS.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:"=<", :"$1", now()}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :sweep, @ttl_ms)

  defp now, do: SystemsClock.monotonic_time(:millisecond)
end
