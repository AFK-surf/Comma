defmodule SalixAgent.AgentReplyTask do
  require SystemsRuntime.Proc

  require SystemsClock

  @moduledoc false

  @default_timeout_ms 120_000

  @spec start(GenServer.from(), (-> term())) :: {:ok, pid()} | {:error, term()}
  def start({caller, _tag} = from, fun)
      when SystemsRuntime.Proc.is_process(caller) and is_function(fun, 0) do
    start_on(SalixAgent.AgentReplyTaskSup, from, caller, fun)
  end

  @spec start_stage(GenServer.from(), (-> term())) :: {:ok, pid()} | {:error, term()}
  def start_stage({caller, _tag} = from, fun)
      when SystemsRuntime.Proc.is_process(caller) and is_function(fun, 0) do
    start_on(SalixAgent.AgentStageTaskSup, from, caller, fun)
  end

  @doc """
  Run `fun` in a supervised reply task and wait for its result.

  The task keeps the bounds of `start/2`: it is cancelled when the caller
  exits and it answers `{:error, {:agent_actor_reply_timeout, ms}}` when the
  configured reply timeout elapses. `timeout` is the caller's own wait, with
  `GenServer.call/3` semantics: the caller exits when it elapses.
  """
  @spec call((-> term()), timeout()) :: term()
  def call(fun, timeout \\ :infinity) when is_function(fun, 0) do
    caller = SystemsRuntime.Proc.self()
    tag = SystemsRuntime.Proc.make_ref()
    reply = fn result -> SystemsRuntime.Proc.send(caller, {tag, result}) end

    case SystemsRuntime.TaskSupervisor.start_child(SalixAgent.AgentReplyTaskSup, fn ->
           run(reply, caller, fun, timeout_ms())
         end) do
      {:ok, pid} -> await_call(pid, tag, timeout)
      {:error, reason} -> {:error, {:agent_actor_reply_task_failed, reason}}
    end
  end

  defp await_call(pid, tag, timeout) do
    monitor = SystemsRuntime.Proc.monitor(pid)

    SystemsClock.vreceive do
      {^tag, result} ->
        SystemsRuntime.Proc.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:agent_actor_reply_task_failed, reason}}
    after
      timeout ->
        SystemsRuntime.Proc.demonitor(monitor, [:flush])
        SystemsRuntime.Proc.exit(pid, :kill)
        exit({:timeout, {__MODULE__, :call, [timeout]}})
    end
  end

  defp start_on(supervisor, from, caller, fun) do
    SystemsRuntime.TaskSupervisor.start_child(supervisor, fn ->
      run(&SystemsRuntime.Server.reply(from, &1), caller, fun, timeout_ms())
    end)
  end

  defp run(reply, caller, fun, timeout_ms) do
    caller_monitor = SystemsRuntime.Proc.monitor(caller)
    owner = SystemsRuntime.Proc.self()
    token = SystemsRuntime.Proc.make_ref()

    worker =
      SystemsRuntime.Proc.spawn_link(fn ->
        SystemsRuntime.Proc.send(owner, {:agent_reply_task_result, token, safe_call(fun)})
      end)

    timer =
      SystemsClock.send_after(
        SystemsRuntime.Proc.self(),
        {:agent_reply_task_timeout, token},
        timeout_ms
      )

    SystemsRuntime.Proc.receive do
      {:agent_reply_task_result, ^token, result} ->
        cancel_timer(timer)
        SystemsRuntime.Proc.demonitor(caller_monitor, [:flush])
        reply.(result)

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        cancel_timer(timer)
        terminate(worker)

      {:agent_reply_task_timeout, ^token} ->
        SystemsRuntime.Proc.demonitor(caller_monitor, [:flush])
        terminate(worker)
        # The caller may be on another BEAM node, while `SystemsRuntime.Proc.alive?/1` is
        # only a reliable local-process predicate. Reply unconditionally; a
        # dead caller simply drops it.
        reply.({:error, {:agent_actor_reply_timeout, timeout_ms}})
    end
  end

  # One staging chain reads the agent's control record at several seams;
  # the read scope serves the repeats from the first read.
  defp safe_call(fun) do
    SalixStore.ReadScope.run(fun)
  catch
    kind, reason -> {:error, {:agent_actor_call_failed, kind, reason}}
  end

  @doc "How long a reply task may run before it is killed."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    case SystemsRuntime.get_env(:salix_agent, :agent_reply_task_timeout_ms, @default_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_timeout_ms
    end
  end

  defp cancel_timer(timer) do
    SystemsClock.cancel_timer(timer)
    :ok
  end

  defp terminate(pid) when SystemsRuntime.Proc.is_process(pid) do
    if SystemsRuntime.Proc.alive?(pid) do
      SystemsRuntime.Proc.unlink(pid)
      SystemsRuntime.Proc.exit(pid, :kill)
    end

    :ok
  end
end
