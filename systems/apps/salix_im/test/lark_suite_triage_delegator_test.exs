defmodule SalixIM.LarkSuiteTriageDelegatorTest do
  @moduledoc """
  A triage delegation goes through the real `SalixIM.TaskPlacement`: the Task
  runs at the Group's default place, and its first message names the source
  chat and message. The product port (`SalixIM.Ports.TaskCreate`) is a stub
  that records what it was asked to create.
  """

  use SystemsClock.Case, async: false

  alias SalixIM.LarkSuiteTriage.TaskDelegator
  alias SalixStore.{Ids, Keys}

  defmodule Product do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    defp owner, do: SystemsRuntime.fetch_env!(:salix_im, :lark_delegator_test_owner)

    @impl true
    def task_worker(_scope) do
      case SystemsRuntime.get_env(:salix_im, :lark_delegator_test_worker) do
        nil -> {:error, :no_task_agent}
        worker -> {:ok, worker}
      end
    end

    @impl true
    def runs_on(_scope, request), do: {:ok, request}
    @impl true
    def session_model(_scope, choice), do: {:ok, choice}

    @impl true
    def create_task_conversation(group_id, delegator, target, attrs) do
      SystemsRuntime.Proc.send(owner(), {:created, group_id, delegator, target, attrs})
      {:ok, %{"conversation_id" => "cnv1_lark_triage_task"}}
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    keys = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_im, :task_create_mod, Product},
      {:salix_im, :lark_delegator_test_owner, SystemsRuntime.Proc.self()},
      {:salix_im, :lark_delegator_test_worker, nil}
    ]

    previous =
      Enum.map(keys, fn {app, key, _value} -> {app, key, SystemsRuntime.get_env(app, key)} end)

    Enum.each(keys, fn
      {app, key, nil} -> SystemsRuntime.delete_env(app, key)
      {app, key, value} -> SystemsRuntime.put_env(app, key, value)
    end)

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(previous, fn
        {app, key, nil} -> SystemsRuntime.delete_env(app, key)
        {app, key, value} -> SystemsRuntime.put_env(app, key, value)
      end)
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "研发部"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    # The Swarm runs its Tasks on its Cloud VM by default.
    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.merge(group, %{
          "router_agent_id" => router["agent_id"],
          "default_task_place" => %{"kind" => "cloud_vm"}
        })
      end)

    batch = %{
      id: "ltb_delegate",
      tenant_id: tenant_id,
      group_id: group_id,
      provider: "feishu",
      connect_id: "con_feishu_rd",
      router_agent_id: router["agent_id"],
      chat_id: "oc_rd",
      chat_name: "研发群",
      thread_key: "",
      target_message_id: "om_target"
    }

    decision = %{kind: "delegate", task_title: "排查支付回调超时", task_prompt: "查回调超时的原因"}

    {:ok, batch: batch, decision: decision, worker: worker["agent_id"]}
  end

  test "the Task runs at the Swarm's default place and names its source message", ctx do
    SystemsRuntime.put_env(:salix_im, :lark_delegator_test_worker, ctx.worker)

    assert {:ok, "cnv1_lark_triage_task"} = TaskDelegator.delegate(ctx.batch, %{}, ctx.decision)

    assert_received {:created, group_id, delegator, target, attrs}

    assert {group_id, delegator, target} ==
             {ctx.batch.group_id, ctx.batch.router_agent_id, ctx.worker}

    assert attrs["runs_on"] == %{"kind" => "cloud_vm"}
    assert attrs["title"] == "排查支付回调超时"
    assert attrs["client_request_id"] == "lark-triage:ltb_delegate"

    assert attrs["content"] ==
             "查回调超时的原因\n\nSource: Feishu group chat \"研发群\" " <>
               "(chat_id oc_rd, connect_id con_feishu_rd), message om_target."
  end

  test "a Swarm without a Task agent gets no Task", ctx do
    assert {:error, :worker_unavailable} = TaskDelegator.delegate(ctx.batch, %{}, ctx.decision)
    refute_received {:created, _group_id, _delegator, _target, _attrs}
  end

  for provider <- ~w(feishu lark) do
    @provider provider

    test "#{provider}: top-level delegation sends a thread receipt and binds the new thread to the Task",
         ctx do
      SystemsRuntime.put_env(:salix_im, :lark_delegator_test_worker, ctx.worker)
      owner = SystemsRuntime.Proc.self()
      batch = %{ctx.batch | provider: @provider, thread_key: ""}

      connect = %{
        "provider" => @provider,
        "connect_id" => batch.connect_id,
        "group_id" => batch.group_id
      }

      provider_call = fn prov, agent_id, _conn, op, params ->
        SystemsRuntime.Proc.send(owner, {:provider_call, prov, agent_id, op, params})

        {:ok,
         %{
           "chat_id" => batch.chat_id,
           "message" => %{"message_id" => "om_receipt_1", "thread_id" => "omt_opened_1"}
         }}
      end

      thread_binder = fn prov, scope, _conn, params ->
        SystemsRuntime.Proc.send(owner, {:bound, prov, scope, params})
        {:ok, %{"binding_status" => "created"}}
      end

      assert {:ok, "cnv1_lark_triage_task"} =
               TaskDelegator.delegate(batch, connect, ctx.decision,
                 provider_call: provider_call,
                 thread_binder: thread_binder
               )

      assert_received {:created, _group_id, _delegator, _target, _attrs}
      assert_received {:provider_call, @provider, _agent_id, "send_message", send_params}
      assert send_params["chat_id"] == "oc_rd"
      assert send_params["reply_to"] == "om_target"
      assert send_params["reply_in_thread"] == true
      assert is_binary(send_params["text"]) and send_params["text"] != ""

      assert_received {:bound, @provider, scope, bind_params}
      assert scope.agent == %{"role" => "router"}
      assert bind_params["conversation_id"] == "cnv1_lark_triage_task"
      assert bind_params["chat_id"] == "oc_rd"
      assert bind_params["thread_id"] == "omt_opened_1"
      assert bind_params["message_id"] == "om_receipt_1"
    end

    test "#{provider}: in-thread delegation binds existing thread without sending a receipt",
         ctx do
      SystemsRuntime.put_env(:salix_im, :lark_delegator_test_worker, ctx.worker)
      owner = SystemsRuntime.Proc.self()
      batch = %{ctx.batch | provider: @provider, thread_key: "omt_existing"}

      connect = %{
        "provider" => @provider,
        "connect_id" => batch.connect_id,
        "group_id" => batch.group_id
      }

      provider_call = fn prov, agent_id, _conn, op, params ->
        SystemsRuntime.Proc.send(owner, {:provider_call, prov, agent_id, op, params})
        {:ok, %{}}
      end

      thread_binder = fn prov, scope, _conn, params ->
        SystemsRuntime.Proc.send(owner, {:bound, prov, scope, params})
        {:ok, %{"binding_status" => "created"}}
      end

      assert {:ok, "cnv1_lark_triage_task"} =
               TaskDelegator.delegate(batch, connect, ctx.decision,
                 provider_call: provider_call,
                 thread_binder: thread_binder
               )

      refute_received {:provider_call, _prov, _agent, "send_message", _params}
      assert_received {:bound, @provider, scope, bind_params}
      assert scope.agent == %{"role" => "router"}
      assert bind_params["thread_id"] == "omt_existing"
      assert bind_params["message_id"] == "om_target"
    end

    test "#{provider}: worker_unavailable does not send a thread receipt", ctx do
      owner = SystemsRuntime.Proc.self()
      batch = %{ctx.batch | provider: @provider, thread_key: ""}

      connect = %{
        "provider" => @provider,
        "connect_id" => batch.connect_id,
        "group_id" => batch.group_id
      }

      provider_call = fn prov, agent_id, _conn, op, params ->
        SystemsRuntime.Proc.send(owner, {:provider_call, prov, agent_id, op, params})
        {:ok, %{}}
      end

      assert {:error, :worker_unavailable} =
               TaskDelegator.delegate(batch, connect, ctx.decision, provider_call: provider_call)

      refute_received {:created, _group_id, _delegator, _target, _attrs}
      refute_received {:provider_call, _prov, _agent, _op, _params}
    end
  end
end
