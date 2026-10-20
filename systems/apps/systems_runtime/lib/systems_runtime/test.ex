defmodule SystemsRuntime.Test do
  @moduledoc """
  Binds application configuration for one test, as read through
  `SystemsRuntime.get_env/3` and `SystemsRuntime.fetch_env/2`. A binding is
  seen by the test process and the processes that act for it (see
  `SystemsRuntime`), and ends when the test process exits: no `on_exit`
  restores the previous value.

  It needs `config :systems_runtime, scoped_env: true`, which the test
  configuration sets.
  """

  alias SystemsRuntime.Bindings

  @doc "Captures log text during `fun`, as `ExUnit.CaptureLog.capture_log/1`."
  def capture_log(fun) when is_function(fun, 0), do: ExUnit.CaptureLog.capture_log(fun)

  @doc "Binds `key` of `app` to `value` for the calling process."
  @spec put_env(atom(), atom(), term()) :: :ok
  def put_env(app, key, value), do: call!({:bind, self(), app, key, {:value, value}})

  @doc "Binds `key` of `app` as not configured for the calling process."
  @spec delete_env(atom(), atom()) :: :ok
  def delete_env(app, key), do: call!({:bind, self(), app, key, :unset})

  @doc """
  Lets `pid`, a process that does not act for the caller (one started with the
  application, for example), read the caller's bindings until either exits.
  """
  @spec allow(pid()) :: :ok
  def allow(pid) when is_pid(pid), do: call!({:allow, self(), pid})

  @doc """
  Makes every process in the VM read the caller's bindings until the caller
  exits. Only for `async: false` tests, which run while no other test does;
  it fails if another test holds shared mode.
  """
  @spec shared() :: :ok
  def shared, do: call!({:share, self()})

  defp call!(request) do
    unless SystemsRuntime.table(),
      do:
        raise(
          ArgumentError,
          "scoped bindings are off; set `config :systems_runtime, scoped_env: true`"
        )

    case GenServer.call(Bindings, request) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "cannot bind: #{inspect(reason)}"
    end
  end
end
