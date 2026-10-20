defmodule SalixAgent.AgentReplyTaskLivenessTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :agent_reply_task_timeout_ms)

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_agent, :agent_reply_task_timeout_ms),
        else: SystemsRuntime.put_env(:salix_agent, :agent_reply_task_timeout_ms, previous)
    end)

    :ok
  end

  test "caller death retires the exact command reply worker" do
    test_pid = SystemsRuntime.Proc.self()

    caller =
      SystemsRuntime.Proc.spawn(fn ->
        SalixAgent.AgentReplyTask.call(fn ->
          SystemsRuntime.Proc.send(
            test_pid,
            {:command_reply_worker_started, SystemsRuntime.Proc.self()}
          )

          SystemsClock.sleep(:infinity)
        end)
      end)

    settle_receive({:command_reply_worker_started, worker})
    monitor = SystemsRuntime.Proc.monitor(worker)

    SystemsRuntime.Proc.exit(caller, :kill)

    settle_receive({:DOWN, ^monitor, :process, ^worker, _reason})
  end
end
