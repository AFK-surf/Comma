defmodule SalixEnv.ExecActivity do
  @moduledoc """
  In-memory record of the most recent `env.exec` per connector run — the short
  human-facing `description` label and when it was dispatched.

  Deliberately not part of the durable registry record: this is ephemeral
  activity state, lost on node restart, never written to S3. Writes fan out
  best-effort to connected peers (`:erpc.cast`) so any node serving a device
  listing merges the label from its local table — no cross-node read on the
  listing path, and a node that joined after the exec simply has no entry.

  Entries are never pruned; the table is bounded by distinct connector runs
  seen since boot.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Record the latest exec description for a connector run (all nodes, best
  effort). Returns the stored entry, or nil when the input isn't recordable.
  """
  @spec record(String.t(), String.t()) :: map() | nil
  def record(connector_run_id, description)
      when is_binary(connector_run_id) and connector_run_id != "" and
             is_binary(description) and description != "" do
    entry = %{"description" => description, "at" => System.system_time(:millisecond)}
    put(connector_run_id, entry)
    Enum.each(Node.list(), &:erpc.cast(&1, __MODULE__, :put, [connector_run_id, entry]))
    entry
  end

  def record(_connector_run_id, _description), do: nil

  @doc false
  def put(connector_run_id, %{"at" => at} = entry) do
    # Casts can arrive out of order; never let an older entry win.
    case :ets.lookup(@table, connector_run_id) do
      [{_id, %{"at" => existing}}] when existing > at -> :ok
      _ -> :ets.insert(@table, {connector_run_id, entry}) && :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "The latest exec entry for a connector run, or nil."
  @spec get(String.t()) :: map() | nil
  def get(connector_run_id) do
    case :ets.lookup(@table, connector_run_id) do
      [{_id, entry}] -> entry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
