defmodule SystemsRuntime.StateMachine do
  @moduledoc "`:gen_statem`: each function is the `:gen_statem` function of the same name."

  def start_link(module, args, opts), do: :gen_statem.start_link(module, args, opts)

  def start_link(name, module, args, opts), do: :gen_statem.start_link(name, module, args, opts)

  # ast-grep-ignore: ex-lib-wait -- the caller chooses the timeout
  def call(server, request, timeout \\ 5000), do: :gen_statem.call(server, request, timeout)

  def cast(server, request), do: :gen_statem.cast(server, request)

  def stop(server, reason \\ :normal, timeout \\ :infinity),
    do: :gen_statem.stop(server, reason, timeout)

  @doc "The machine's `{state, data}`, as `:sys.get_state/2`."
  def get_state(server, timeout \\ 5000), do: :sys.get_state(server, timeout)
end
