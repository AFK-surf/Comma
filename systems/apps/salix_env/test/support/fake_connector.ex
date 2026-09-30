defmodule SalixEnv.Connector.Fake do
  @moduledoc """
  In-memory `SalixEnv.Connector` for tests. A `GenServer` holds a per-env handler
  table; `dispatch/2` looks up the handler for `env_id` and round-trips the
  request through it. With no registered handler an env is treated as
  unreachable (`{:error, :disconnected}`), matching the registry's record status.

  Register behavior with `handle/2`:

    * a 1-arity function `fn request -> {:ok, resp} | {:error, term} end`
    * a fixed `{:ok, resp}` / `{:error, reason}` tuple returned for every call
  """
  use GenServer
  @behaviour SalixEnv.Connector

  # ---- lifecycle ----

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Register a handler (fun or fixed reply) for `env_id`."
  def handle(env_id, handler), do: GenServer.call(__MODULE__, {:handle, env_id, handler})

  @doc "Wipe all handlers (test setup)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ---- behaviour ----

  @impl SalixEnv.Connector
  def dispatch(env_id, request), do: GenServer.call(__MODULE__, {:dispatch, env_id, request})

  # ---- server ----

  @impl GenServer
  def init(_), do: {:ok, %{handlers: %{}}}

  @impl GenServer
  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{handlers: %{}}}

  def handle_call({:handle, env_id, handler}, _from, state),
    do: {:reply, :ok, put_in(state.handlers[env_id], handler)}

  def handle_call({:dispatch, env_id, request}, _from, state) do
    reply =
      case state.handlers[env_id] do
        nil -> {:error, :disconnected}
        fun when is_function(fun, 1) -> fun.(request)
        fixed -> fixed
      end

    {:reply, reply, state}
  end
end
