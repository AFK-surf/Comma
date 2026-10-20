defmodule SalixAgent.Tools.LoopsTest do
  @moduledoc """
  The `loop.*` tool surface: registration, schemas, the read/write
  classification, and the error paths a model sees without a spinfoam child.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.Tools
  alias SalixAgent.Tools.Loops, as: LoopTools
  alias SalixStore.S3.Fake

  defmodule TaskOwnerStub do
    @behaviour SalixAgent.Loops.TaskOwner
    @impl true
    def loop_ended(_, _), do: :ok
    @impl true
    def loop_wake(_, _, _), do: {:ok, :created}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_owner = SystemsRuntime.get_env(:salix_agent, :loop_task_owner_mod)
    SystemsRuntime.put_env(:salix_agent, :loop_task_owner_mod, TaskOwnerStub)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if previous_owner,
        do: SystemsRuntime.put_env(:salix_agent, :loop_task_owner_mod, previous_owner),
        else: SystemsRuntime.delete_env(:salix_agent, :loop_task_owner_mod)
    end)

    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    if SystemsRuntime.Proc.whereis(Fake), do: Fake.reset(), else: start_supervised!(Fake)
    SalixStore.Repo.query!("TRUNCATE agent_loops, agent_loop_acks")

    on_exit(fn ->
      if prev_store,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, prev_store),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "worker"})
    {:ok, ctx: %{agent_id: agent_id, session_id: SalixStore.Ids.new_session_id(), role: "worker"}}
  end

  @tag :spinfoam
  @tag skip:
         if(File.exists?(SalixAgent.SpinfoamFixture.binary()),
           do: false,
           else: "spinfoam binary unavailable"
         )
  @tag :spinfoam
  @tag skip:
         if(SalixAgent.SpinfoamFixture.available?(),
           do: false,
           else: "spinfoam binary unavailable"
         )

  defp put_file!(agent_id, path, content) do
    {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent_id, path, content)

    {:ok, _} =
      SalixAgent.AgentWorkspace.seed_operation(
        agent_id,
        "tools-loops-test:#{SystemsRuntime.Proc.unique_integer([:positive])}",
        %{},
        [event]
      )

    :ok
  end

  test "loop.create explains a missing file and manages an owned loop", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/no file at \/loops\/missing.elf/, fn ->
      LoopTools.create(%{"path" => "/loops/missing.elf"}, ctx)
    end

    :ok = put_file!(ctx.agent_id, "/loops/main.elf", <<0x7F, ?E, ?L, ?F>>)

    created =
      Jason.decode!(
        LoopTools.create(
          %{"path" => "/loops/main.elf", "name" => "n"},
          ctx
        )
      )

    assert created["status"] == "active"

    listed = Jason.decode!(LoopTools.list(%{}, ctx))
    assert [%{"loop_id" => loop_id}] = listed

    shown = Jason.decode!(LoopTools.get(%{"loop_id" => loop_id}, ctx))
    assert shown["name"] == "n"

    assert_raise RuntimeError, ~r/loop not found/, fn ->
      LoopTools.get(%{"loop_id" => "lop1_0"}, ctx)
    end

    assert_raise RuntimeError, ~r/'loop_id' is required/, fn -> LoopTools.pause(%{}, ctx) end

    paused = Jason.decode!(LoopTools.pause(%{"loop_id" => loop_id}, ctx))
    assert paused["paused_by"] == "user"

    assert_raise RuntimeError, ~r/loop is paused/, fn ->
      LoopTools.send_event(%{"loop_id" => loop_id, "topic" => "t"}, ctx)
    end

    deleted = Jason.decode!(LoopTools.delete(%{"loop_id" => loop_id}, ctx))
    assert deleted["status"] == "deleted"
    assert Jason.decode!(LoopTools.list(%{}, ctx)) == []
  end

  test "a Task round manages only its Task's loop; other rounds only the agent's unbound loops",
       %{ctx: ctx} do
    :ok = put_file!(ctx.agent_id, "/loops/main.elf", <<0x7F, ?E, ?L, ?F>>)
    task_a = in_task(ctx, "cnv_a")
    task_b = in_task(ctx, "cnv_b")
    create = &Jason.decode!(LoopTools.create(%{"path" => "/loops/main.elf"}, &1))
    # A loop Task A's Session made before loops recorded their Task.
    %{"loop_id" => legacy} = create.(Map.delete(task_a, :trusted_origin))
    %{"loop_id" => a} = create.(task_a)
    %{"loop_id" => b} = create.(task_b)
    %{"loop_id" => free} = create.(ctx)

    assert [%{"loop_id" => ^b, "task_conversation_id" => "cnv_b"}] =
             Jason.decode!(LoopTools.list(%{}, task_b))

    assert [%{"loop_id" => ^legacy}, %{"loop_id" => ^a, "task_conversation_id" => "cnv_a"}] =
             Jason.decode!(LoopTools.list(%{}, task_a))

    assert [%{"loop_id" => ^legacy}, %{"loop_id" => ^free} = listed] =
             Jason.decode!(LoopTools.list(%{}, ctx))

    refute Map.has_key?(listed, "task_conversation_id")

    # Task B's round, and a round outside any Task, cannot reach Task A's loop.
    for caller <- [task_b, ctx],
        call <- [
          &LoopTools.get/2,
          &LoopTools.pause/2,
          &LoopTools.resume/2,
          &LoopTools.delete/2,
          &LoopTools.webhook(Map.put(&1, "action", "revoke"), &2),
          &LoopTools.send_event(Map.put(&1, "topic", "t"), &2)
        ] do
      assert_raise RuntimeError, ~r/loop not found/, fn -> call.(%{"loop_id" => a}, caller) end
    end

    for loop_id <- [free, legacy] do
      assert_raise RuntimeError, ~r/loop not found/, fn ->
        LoopTools.get(%{"loop_id" => loop_id}, task_b)
      end
    end

    # Task A's rounds reach it, also one its loop woke without a Task Message.
    woken = Map.delete(task_a, :trusted_origin)
    assert %{"paused_by" => "user"} = Jason.decode!(LoopTools.pause(%{"loop_id" => a}, woken))
    assert %{"status" => "active"} = Jason.decode!(LoopTools.resume(%{"loop_id" => a}, task_a))

    assert_raise RuntimeError, ~r/this Task already has background loop #{a}/, fn ->
      LoopTools.create(%{"path" => "/loops/main.elf"}, task_a)
    end

    assert %{"status" => "deleted"} = Jason.decode!(LoopTools.delete(%{"loop_id" => a}, task_a))
    assert [%{"loop_id" => ^legacy}] = Jason.decode!(LoopTools.list(%{}, task_a))
    assert [%{"loop_id" => ^b}] = Jason.decode!(LoopTools.list(%{}, task_b))
  end

  defp in_task(ctx, task_id) do
    Map.merge(ctx, %{
      session_id: SalixStore.Ids.new_session_id(),
      trusted_origin: %{
        "provider" => "internal",
        "conversation_kind" => "agent_task",
        "conversation_id" => task_id,
        "agent_group_id" => group_id(ctx)
      }
    })
  end

  defp group_id(ctx) do
    {:ok, agent} = SalixAgent.Control.get(ctx.agent_id)
    agent["group_id"]
  end

  test "another agent's loop is indistinguishable from a missing one", %{ctx: ctx} do
    :ok = put_file!(ctx.agent_id, "/loops/main.elf", <<0x7F, ?E, ?L, ?F>>)
    %{"loop_id" => loop_id} = Jason.decode!(LoopTools.create(%{"path" => "/loops/main.elf"}, ctx))

    other = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(other, %{"role" => "worker"})
    other_ctx = %{agent_id: other, session_id: SalixStore.Ids.new_session_id(), role: "worker"}

    assert_raise RuntimeError, ~r/loop not found/, fn ->
      LoopTools.get(%{"loop_id" => loop_id}, other_ctx)
    end

    assert_raise RuntimeError, ~r/loop not found/, fn ->
      LoopTools.delete(%{"loop_id" => loop_id}, other_ctx)
    end

    assert [_] = Jason.decode!(LoopTools.list(%{}, ctx))
  end
end
