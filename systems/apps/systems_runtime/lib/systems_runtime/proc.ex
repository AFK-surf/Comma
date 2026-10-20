defmodule SystemsRuntime.Proc do
  @moduledoc """
  Processes, messages, links, monitors, timers and random numbers: each
  function is the BEAM primitive it names.

  The machine's clock, random values and unique integers come from a
  simulated world instead while one runs (`SystemsSim`), for the processes of
  that world: from its seed and its clock, so that a run repeats.
  """

  import Kernel,
    except: [
      self: 0,
      node: 0,
      node: 1,
      spawn: 1,
      spawn_link: 1,
      spawn_monitor: 1,
      send: 2,
      make_ref: 0
    ]

  @type dest :: pid() | reference() | atom()

  @doc "Whether `module` is loaded, as `Code.ensure_loaded?/1`."
  def ensure_loaded?(module) when is_atom(module), do: Code.ensure_loaded?(module)

  @doc "Whether `term` is a process."
  defguard is_process(term) when is_pid(term)

  @doc "Whether `term` is a reference."
  defguard is_ref(term) when is_reference(term)

  @doc "The calling process."
  def self, do: Kernel.self()

  @doc "The current node."
  def node, do: Kernel.node()

  @doc "The node owning a process."
  def node(pid), do: Kernel.node(pid)

  @doc "Starts `fun` in a new process."
  def spawn(fun) when is_function(fun, 0), do: Kernel.spawn(fun)

  @doc "Starts `fun` in a new process linked to the caller."
  def spawn_link(fun) when is_function(fun, 0), do: Kernel.spawn_link(fun)

  @doc "Starts `fun` in a new process monitored by the caller; returns `{pid, ref}`."
  def spawn_monitor(fun) when is_function(fun, 0), do: Kernel.spawn_monitor(fun)

  @doc "Sends `msg` to `dest`; returns `msg`."
  def send(dest, msg), do: Kernel.send(dest, msg)

  @doc "The process's queued messages or their count, as `Process.info/2`."
  def info(pid, item) when item in [:messages, :message_queue_len], do: Process.info(pid, item)

  @doc "Receives a message: the BEAM's own `receive/1`, inline in the caller's function."
  defmacro receive(clauses), do: SystemsRuntime.Proc.Native.receive_ast(clauses)

  @doc "Yields the scheduler."
  def quiesce do
    :erlang.yield()
    :ok
  end

  @doc "A new reference."
  def make_ref, do: Kernel.make_ref()

  @doc "A process alias that receives messages until its creator revokes it or exits."
  def alias, do: :erlang.alias()

  @doc "Revokes the caller's active alias; returns false otherwise. Queued messages stay queued."
  def unalias(ref), do: :erlang.unalias(ref)

  @doc "Monitors `dest`; returns the monitor's reference."
  def monitor(dest), do: Process.monitor(dest)

  @doc "Removes a monitor, as `Process.demonitor/2`."
  def demonitor(ref, opts \\ []), do: Process.demonitor(ref, opts)

  @doc "Links the caller to `dest`."
  def link(dest), do: Process.link(dest)

  @doc "Removes a link to `dest`."
  def unlink(dest), do: Process.unlink(dest)

  @doc "Sends an exit signal to `dest`, as `Process.exit/2`."
  def exit(dest, reason), do: Process.exit(dest, reason)

  @doc "Sets whether the caller traps exits; returns the old value."
  def trap_exit(trap) when is_boolean(trap), do: Process.flag(:trap_exit, trap)

  @doc "Registers `dest` under `name`."
  def register(dest, name) when is_atom(name), do: Process.register(dest, name)

  @doc "Removes the registration of `name`."
  def unregister(name) when is_atom(name), do: Process.unregister(name)

  @doc "The process registered as `name`, or nil."
  def whereis(name) when is_atom(name), do: Process.whereis(name)

  @doc "As `:net_kernel.monitor_nodes/2`."
  def monitor_nodes(flag, opts \\ []), do: :net_kernel.monitor_nodes(flag, opts)

  @doc "As `:global.trans/2`: runs `fun` while holding the lock `{resource, requester}`."
  def global_trans({_resource, _requester} = id, fun), do: :global.trans(id, fun)

  @doc "Whether `pid` is alive."
  def alive?(pid), do: Process.alive?(pid)

  @doc "Sends `msg` to `dest` after `ms` milliseconds; returns the timer's reference."
  # ast-grep-ignore: ex-harness-real-clock -- the runtime API names the BEAM primitive
  def send_after(dest, msg, ms), do: Process.send_after(dest, msg, ms)

  @doc "Cancels a timer; returns the milliseconds it had left, or false."
  def cancel_timer(ref), do: Process.cancel_timer(ref)

  @doc "Waits `ms` milliseconds."
  # ast-grep-ignore: ex-harness-real-clock -- the runtime API names the BEAM primitive
  def sleep(ms), do: Process.sleep(ms)

  @doc "Monotonic time in `unit`."
  def monotonic_time(unit \\ :native),
    # ast-grep-ignore: ex-harness-real-clock -- the runtime API names the BEAM primitive
    do: world({:monotonic_time, unit}, fn -> System.monotonic_time(unit) end)

  @doc "Wall-clock time in `unit`."
  def system_time(unit \\ :native),
    # ast-grep-ignore: ex-harness-real-clock -- the runtime API names the BEAM primitive
    do: world({:system_time, unit}, fn -> System.system_time(unit) end)

  @doc "Sends `{:timeout, ref, msg}` to `dest` after `ms` milliseconds; returns `ref`, as `:erlang.start_timer/3`."
  # ast-grep-ignore: ex-harness-real-clock -- the runtime API names the BEAM primitive
  def start_timer(ms, dest, msg), do: :erlang.start_timer(ms, dest, msg)

  @doc "Milliseconds left on a timer, or false, as `Process.read_timer/1`."
  def read_timer(ref), do: Process.read_timer(ref)

  @doc "A random integer in `1..n`."
  def uniform(n), do: world({:uniform, n}, fn -> :rand.uniform(n) end)

  @doc "As `:rand.uniform/0`."
  def uniform, do: world(:uniform, &:rand.uniform/0)

  @doc "As `:crypto.generate_key/2`."
  def generate_key(type, params), do: :crypto.generate_key(type, params)

  @doc "As `:crypto.generate_key/3`: the private key is given."
  def generate_key(type, params, private), do: :crypto.generate_key(type, params, private)

  @doc "As `:crypto.sign/4`."
  def sign(type, digest, message, key), do: :crypto.sign(type, digest, message, key)

  @doc "As `Ecto.UUID.generate/0`."
  def uuid, do: world(:uuid, &Ecto.UUID.generate/0)

  @doc "`n` random bytes."
  def random_bytes(n), do: world({:bytes, n}, fn -> :crypto.strong_rand_bytes(n) end)

  @doc "An integer unique in this runtime instance, as `System.unique_integer/1`."
  def unique_integer(modifiers \\ []),
    do: world({:unique_integer, modifiers}, fn -> System.unique_integer(modifiers) end)

  # The module of the simulated world that runs, if one does: it answers
  # `request` for a process of its own, and calls `machine` for any other.
  defp world(request, machine) do
    case :persistent_term.get({__MODULE__, :world}, nil) do
      nil -> machine.()
      world -> world.draw(request, machine)
    end
  end
end

defmodule SystemsRuntime.Proc.Native do
  @moduledoc false
  # Builds the BEAM `receive` for `SystemsRuntime.Proc.receive/1`. It lives
  # here because inside `SystemsRuntime.Proc` a quoted `receive` would call
  # that macro again.

  def receive_ast(clauses), do: quote(do: receive(unquote(clauses)))
end
