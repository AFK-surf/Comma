defmodule SalixIM.ModelMentionTaskTest do
  use SystemsClock.Case, async: false

  alias SalixIM.ModelMentionTask

  defmodule FakeTaskCreate do
    def task_worker(_scope), do: {:ok, Process.get(:model_mention_task_worker_id)}

    def runs_on(_scope, %{"kind" => "station", "device_id" => "dev_offline"}),
      do: {:error, :device_offline}

    def runs_on(_scope, %{"kind" => "station", "device_id" => "dev_missing"}),
      do: {:error, :device_not_found}

    def runs_on(_scope, request), do: {:ok, request}

    def session_model(_scope, %{"kind" => "runtime", "provider" => "unsupported"}),
      do: {:error, {:not_on_stillfail, %{"claude" => ["claude-opus-5-5"]}}}

    def session_model(_scope, choice), do: {:ok, choice}

    def create_task_conversation(group_id, router_agent_id, worker_agent_id, attrs) do
      if pid = Process.get(:model_mention_task_test_pid) do
        send(pid, {:created_task, group_id, router_agent_id, worker_agent_id, attrs})
      end

      {:ok,
       %{
         "conversation_id" => "cnv_" <> attrs["client_request_id"],
         "group_id" => group_id
       }}
    end
  end

  setup do
    prev_task_create = SystemsRuntime.get_env(:salix_im, :task_create_mod)
    SystemsRuntime.put_env(:salix_im, :task_create_mod, FakeTaskCreate)
    Process.put(:model_mention_task_test_pid, self())

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Window Monoid"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Window Monoid"}, tenant["tenant_id"])

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Router", "role" => "router"},
        tenant["tenant_id"]
      )

    {:ok, _group} =
      SalixStore.CasRecord.update(
        SalixStore.Keys.ctl_group(group["group_id"]),
        &Map.put(&1, "router_agent_id", router["agent_id"])
      )

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    Process.put(:model_mention_task_worker_id, worker["agent_id"])

    on_exit(fn ->
      if prev_task_create,
        do: SystemsRuntime.put_env(:salix_im, :task_create_mod, prev_task_create),
        else: SystemsRuntime.delete_env(:salix_im, :task_create_mod)
    end)

    %{
      group_id: group["group_id"],
      router_id: router["agent_id"],
      worker_id: worker["agent_id"]
    }
  end

  test "start_from_window passes station runs_on with default or runtime model and keeps idempotency",
       ctx do
    runs_on = %{"kind" => "station", "device_id" => "dev_monoid_1"}

    assert {:ok, %{"conversation_id" => "cnv_comma-window-task:usr_1:req_default"}} =
             ModelMentionTask.start_from_window(
               ctx.group_id,
               ctx.router_id,
               "usr_1",
               "req_default",
               %{
                 text: "Deploy staging",
                 runs_on: runs_on
               }
             )

    assert_received {:created_task, group_id, router_id, _worker_id, attrs}
    assert group_id == ctx.group_id
    assert router_id == ctx.router_id
    assert attrs["runs_on"] == runs_on
    refute Map.has_key?(attrs, "session_model")
    assert attrs["owner_user_id"] == "usr_1"
    assert attrs["initial_author"] == "owner"
    assert attrs["client_request_id"] == "comma-window-task:usr_1:req_default"

    runtime_model = %{"kind" => "runtime", "provider" => "claude", "model" => "claude-opus-5-5"}

    assert {:ok, %{"conversation_id" => "cnv_comma-window-task:usr_1:req_runtime"}} =
             ModelMentionTask.start_from_window(
               ctx.group_id,
               ctx.router_id,
               "usr_1",
               "req_runtime",
               %{
                 text: "Fix CI",
                 runs_on: runs_on,
                 runtime_model: runtime_model
               }
             )

    assert_received {:created_task, _group_id, _router_id, _worker_id, attrs2}
    assert attrs2["runs_on"] == runs_on
    assert attrs2["session_model"] == runtime_model
  end

  test "start_from_window refuses unsupported model or offline station with human-readable refusal_message",
       ctx do
    assert {:error, {:runs_on, :device_offline, :requested} = offline_err} =
             ModelMentionTask.start_from_window(
               ctx.group_id,
               ctx.router_id,
               "usr_1",
               "req_off",
               %{
                 text: "hello",
                 runs_on: %{"kind" => "station", "device_id" => "dev_offline"}
               }
             )

    assert {:ok, msg} = ModelMentionTask.refusal_message(offline_err)
    assert msg =~ "Monoid"
    assert msg =~ "offline"

    assert {:error, {:model, {:not_on_stillfail, _}} = model_err} =
             ModelMentionTask.start_from_window(
               ctx.group_id,
               ctx.router_id,
               "usr_1",
               "req_bad",
               %{
                 text: "hello",
                 runs_on: %{"kind" => "station", "device_id" => "dev_monoid_1"},
                 runtime_model: %{"kind" => "runtime", "provider" => "unsupported"}
               }
             )

    assert {:ok, model_msg} = ModelMentionTask.refusal_message(model_err)
    assert model_msg =~ "Monoid"
    assert model_msg =~ "Workspace default"

    assert {:ok, missing_msg} =
             ModelMentionTask.refusal_message({:runs_on, :device_not_found, :requested})

    assert missing_msg =~ "Monoid"
  end
end
