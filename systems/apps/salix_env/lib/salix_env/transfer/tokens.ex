defmodule SalixEnv.Transfer.Tokens do
  @moduledoc """
  One-time transfer tokens. Each token authorizes exactly one inbound
  stream and is consumed atomically with `:ets.take/2` (claim-and-delete), so a
  replayed POST gets a 404. A reaper expires unclaimed tokens after a TTL
  (default 3 min), matching the Go transfer server.
  """
  use SystemsRuntime.Server

  @table __MODULE__
  @ttl_ms 180_000
  @sweep_ms 30_000

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Register a one-time token bound to `owner` (default: caller). Returns the token."
  @spec register(keyword()) :: String.t()
  def register(opts \\ []) do
    owner = opts[:owner] || SystemsRuntime.Proc.self()
    ttl = opts[:ttl_ms] || @ttl_ms
    token = gen_token()
    expires = SystemsClock.monotonic_time(:millisecond) + ttl
    SystemsRuntime.ETS.insert(@table, {token, owner, expires})
    token
  end

  @doc "Atomically claim a token. Returns `{:ok, owner}` once; `:error` afterward/expired."
  @spec claim(String.t()) :: {:ok, pid()} | :error
  def claim(token) do
    case SystemsRuntime.ETS.take(@table, token) do
      [{^token, owner, expires}] ->
        if SystemsClock.monotonic_time(:millisecond) <= expires, do: {:ok, owner}, else: :error

      [] ->
        :error
    end
  end

  @doc "Revoke an unclaimed token when its receiver closes before transfer starts."
  @spec revoke(String.t()) :: :ok
  def revoke(token) when is_binary(token) do
    SystemsRuntime.ETS.delete(@table, token)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---- GenServer (owns the table + reaper) ----

  @impl true
  def init(_opts) do
    SystemsRuntime.ETS.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = SystemsClock.monotonic_time(:millisecond)
    SystemsRuntime.ETS.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :sweep, @sweep_ms)
  defp gen_token, do: SystemsRuntime.Proc.random_bytes(24) |> Base.url_encode64(padding: false)
end
