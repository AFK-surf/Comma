defmodule SalixIM.TaskActivityProjectionTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.{ConversationServer, Conversations, TaskActivityProjection}
  alias SalixStore.{Ids, Keys, S3}

  defmodule ProbeS3 do
    @behaviour SalixStore.S3

    def get(key, opts) do
      report({:activity_get, key})
      SalixStore.S3.Fake.get(key, opts)
    end

    def list(prefix, opts) do
      report({:activity_list, prefix, opts})
      SalixStore.S3.Fake.list(prefix, opts)
    end

    def put(key, body, opts) do
      if String.starts_with?(key, "ctl/group_task_activity/") and
           SystemsRuntime.get_env(:salix_im, :fail_activity_index_write, false),
         do: {:error, :index_temporarily_unavailable},
         else: SalixStore.S3.Fake.put(key, body, opts)
    end

    defp report(event) do
      if owner = SystemsRuntime.get_env(:salix_im, :activity_index_probe),
        do: SystemsRuntime.Proc.send(owner, event)
    end

    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake
    defdelegate stream(key, opts), to: SalixStore.S3.Fake
    defdelegate head(key), to: SalixStore.S3.Fake
    defdelegate delete(key, opts), to: SalixStore.S3.Fake
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: SalixStore.S3.Fake
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, ProbeS3)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
      SystemsRuntime.delete_env(:salix_im, :fail_activity_index_write)
      SystemsRuntime.delete_env(:salix_im, :activity_index_probe)
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Task activity"})
    %{group_id: group_id}
  end

  test "the two latest running or attention Tasks include every source and ignore recent finished work",
       %{group_id: group_id} do
    running = old_task(group_id, 1, "in_progress", 10, "wechat")
    review = old_task(group_id, 2, "ready_for_review", 20, "comma")
    escalated = old_task(group_id, 3, "escalated", 20, "slack")

    for conversation <- [running, review, escalated] do
      put_canonical(group_id, conversation)

      assert :ok =
               ConversationServer.repair_task_activity_projection(
                 group_id,
                 conversation["conversation_id"]
               )
    end

    for id <- 4..64 do
      put_canonical(group_id, old_task(group_id, id, "completed", id + 100, "comma"))
    end

    assert {:ok, _} = TaskActivityProjection.advance_rebuild(group_id, nil, true)
    SystemsRuntime.put_env(:salix_im, :activity_index_probe, SystemsRuntime.Proc.self())

    assert {:ok, %{"data" => [first, second]}} = Conversations.list_group_activity_tasks(group_id)
    assert first["conversation_id"] == escalated["conversation_id"]
    assert second["conversation_id"] == review["conversation_id"]
    assert first["metadata"]["origin"]["provider"] == "slack"

    # The probe also sees other processes' lists; only this Group's index counts.
    prefix = Keys.ctl_group_task_activity_prefix(group_id)
    settle_receive({:activity_list, ^prefix, opts})
    assert opts[:max_keys] == 20
    settle_refute_receive({:activity_list, ^prefix, _})
  end

  test "Task transitions refresh activity membership and an index outage preserves the Task mutation",
       %{group_id: group_id} do
    assert {:ok, task} =
             ConversationServer.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "status" => "in_progress",
               "title" => "Running"
             })

    id = task["conversation_id"]
    assert {:ok, _} = TaskActivityProjection.advance_rebuild(group_id, nil, true)
    assert {:ok, %{"data" => [_]}} = Conversations.list_group_activity_tasks(group_id)

    SystemsRuntime.put_env(:salix_im, :fail_activity_index_write, true)

    assert {:ok, %{"status" => "ready_for_review"}} =
             ConversationServer.update_group_conversation(group_id, id, %{
               "status" => "ready_for_review"
             })

    assert {:ok, %{"status" => "ready_for_review"}} =
             Conversations.get_group_conversation(group_id, id)

    SystemsRuntime.put_env(:salix_im, :fail_activity_index_write, false)

    assert_eventually(fn ->
      match?(
        {:ok, %{"data" => [%{"status" => "ready_for_review"}]}},
        Conversations.list_group_activity_tasks(group_id)
      )
    end)

    assert {:ok, _} =
             ConversationServer.update_group_conversation(group_id, id, %{"status" => "completed"})

    assert {:ok, %{"data" => []}} = Conversations.list_group_activity_tasks(group_id)
  end

  defp old_task(group_id, id, status, updated_at, provider) do
    %{
      "agent_group_id" => group_id,
      "conversation_id" => "cnv1_" <> String.pad_leading(Integer.to_string(id), 19, "0"),
      "kind" => "agent_task",
      "status" => status,
      "title" => "Task #{id}",
      "metadata" => %{"origin" => %{"provider" => provider}},
      "created_at" => 1,
      "updated_at" => updated_at,
      "message_count" => 0,
      "message_head_seq" => 0,
      "message_tail_seq" => 0,
      "log_start_seq" => 0,
      "participants" => [],
      "_participant_identity_slots" => %{}
    }
  end

  defp put_canonical(group_id, conversation) do
    assert {:ok, _} =
             S3.put(
               Keys.ctl_group_conversation(group_id, conversation["conversation_id"]),
               Jason.encode!(conversation)
             )
  end

  defp assert_eventually(check, retries \\ 1500)
  defp assert_eventually(_check, 0), do: flunk("Task activity projection did not converge")

  defp assert_eventually(check, retries) do
    if check.(),
      do: :ok,
      else:
        (
          SystemsClock.sleep(20)
          assert_eventually(check, retries - 1)
        )
  end
end
