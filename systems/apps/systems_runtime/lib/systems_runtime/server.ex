defmodule SystemsRuntime.Server do
  @moduledoc """
  `GenServer`: `use SystemsRuntime.Server` is `use GenServer`, and each
  function here is the `GenServer` or `:sys` function it names.
  """

  defmacro __using__(opts) do
    quote do
      use GenServer, unquote(opts)
    end
  end

  @type server :: GenServer.server()

  @doc "Starts a server linked to the caller, as `GenServer.start_link/3`."
  def start_link(module, arg, opts \\ []), do: GenServer.start_link(module, arg, opts)

  @doc "Starts a server, as `GenServer.start/3`."
  def start(module, arg, opts \\ []), do: GenServer.start(module, arg, opts)

  @doc "Calls a server, as `GenServer.call/3`."
  # ast-grep-ignore: ex-lib-wait -- the caller chooses the timeout
  def call(server, request, timeout \\ 5000), do: GenServer.call(server, request, timeout)

  @doc "Casts to a server, as `GenServer.cast/2`."
  def cast(server, request), do: GenServer.cast(server, request)

  @doc "Replies to a call, as `GenServer.reply/2`."
  def reply(from, reply), do: GenServer.reply(from, reply)

  @doc "Stops a server, as `GenServer.stop/3`."
  def stop(server, reason \\ :normal, timeout \\ :infinity),
    do: GenServer.stop(server, reason, timeout)

  @doc "Reads the server state between callbacks, as `:sys.get_state/2`."
  def get_state(server, timeout \\ 5000), do: :sys.get_state(server, timeout)

  @doc "Suspends application callbacks while still accepting system requests, as `:sys.suspend/2`."
  def suspend(server, timeout \\ 5000), do: :sys.suspend(server, timeout)

  @doc "Resumes a suspended server, as `:sys.resume/2`."
  def resume(server, timeout \\ 5000), do: :sys.resume(server, timeout)

  @doc "Replaces a server's state between callbacks, as `:sys.replace_state/3`."
  def replace_state(server, fun, timeout \\ 5000), do: :sys.replace_state(server, fun, timeout)

  @doc "The process of `server`, or nil, as `GenServer.whereis/1`."
  def whereis(server), do: GenServer.whereis(server)
end
