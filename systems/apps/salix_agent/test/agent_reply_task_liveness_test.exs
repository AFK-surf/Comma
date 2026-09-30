defmodule SalixAgent.AgentReplyTaskLivenessTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:salix_agent, :agent_reply_task_timeout_ms)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_agent, :agent_reply_task_timeout_ms),
        else: Application.put_env(:salix_agent, :agent_reply_task_timeout_ms, previous)
    end)

    :ok
  end

  test "caller death retires the exact command reply worker" do
    test_pid = self()

    caller =
      spawn(fn ->
        SalixAgent.AgentReplyTask.call(fn ->
          send(test_pid, {:command_reply_worker_started, self()})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:command_reply_worker_started, worker}, 500
    monitor = Process.monitor(worker)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 500
  end

  test "command reply deadline returns a typed error and retires its worker" do
    Application.put_env(:salix_agent, :agent_reply_task_timeout_ms, 25)
    test_pid = self()

    assert {:error, {:agent_actor_reply_timeout, 25}} =
             SalixAgent.AgentReplyTask.call(fn ->
               send(test_pid, {:timed_command_reply_worker_started, self()})
               Process.sleep(:infinity)
             end)

    assert_receive {:timed_command_reply_worker_started, worker}, 500
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 500
  end

  test "core staging replies use admission isolated from user-command replies" do
    caller = self()
    reply_tag = make_ref()
    stage_tag = make_ref()

    assert {:ok, reply_owner} =
             SalixAgent.AgentReplyTask.start({caller, reply_tag}, fn ->
               send(caller, {:isolated_reply_worker, self()})

               receive do
                 :release -> :reply_done
               end
             end)

    assert {:ok, stage_owner} =
             SalixAgent.AgentReplyTask.start_stage({caller, stage_tag}, fn ->
               send(caller, {:isolated_stage_worker, self()})

               receive do
                 :release -> :stage_done
               end
             end)

    assert_receive {:isolated_reply_worker, reply_worker}, 500
    assert_receive {:isolated_stage_worker, stage_worker}, 500

    on_exit(fn ->
      Enum.each([reply_owner, stage_owner, reply_worker, stage_worker], fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)
    end)

    assert reply_owner in Task.Supervisor.children(SalixAgent.AgentReplyTaskSup)
    refute reply_owner in Task.Supervisor.children(SalixAgent.AgentStageTaskSup)
    assert stage_owner in Task.Supervisor.children(SalixAgent.AgentStageTaskSup)
    refute stage_owner in Task.Supervisor.children(SalixAgent.AgentReplyTaskSup)

    send(reply_worker, :release)
    send(stage_worker, :release)

    assert_receive {^reply_tag, :reply_done}, 500
    assert_receive {^stage_tag, :stage_done}, 500
  end
end
