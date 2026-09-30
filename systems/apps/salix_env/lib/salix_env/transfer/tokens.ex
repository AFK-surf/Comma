defmodule SalixEnv.Transfer.Tokens do
  @moduledoc """
  One-time transfer tokens. Each token authorizes exactly one inbound
  stream and is consumed atomically with `:ets.take/2` (claim-and-delete), so a
  replayed POST gets a 404. A reaper expires unclaimed tokens after a TTL
  (default 3 min), matching the Go transfer server.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 180_000
  @sweep_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Register a one-time token bound to `owner` (default: caller). Returns the token."
  @spec register(keyword()) :: String.t()
  def register(opts \\ []) do
    owner = opts[:owner] || self()
    ttl = opts[:ttl_ms] || @ttl_ms
    token = gen_token()
    expires = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table, {token, owner, expires})
    token
  end

  @doc "Atomically claim a token. Returns `{:ok, owner}` once; `:error` afterward/expired."
  @spec claim(String.t()) :: {:ok, pid()} | :error
  def claim(token) do
    case :ets.take(@table, token) do
      [{^token, owner, expires}] ->
        if System.monotonic_time(:millisecond) <= expires, do: {:ok, owner}, else: :error

      [] ->
        :error
    end
  end

  @doc "Revoke an unclaimed token when its receiver closes before transfer starts."
  @spec revoke(String.t()) :: :ok
  def revoke(token) when is_binary(token) do
    :ets.delete(@table, token)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---- GenServer (owns the table + reaper) ----

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
  defp gen_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end
