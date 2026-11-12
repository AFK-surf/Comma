defmodule SalixIM.ConversationGroupActorTest do
  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle

  alias SalixIM.{
    ConversationActor,
    ConversationPGStore,
    ConversationPlacement,
    ConversationServer,
    Conversations
  }

  alias SalixStore.{Ids, Repo}

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()

    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_placement = SystemsRuntime.get_env(:salix_im, :conversation_placement)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    SystemsRuntime.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, previous_backend)
        restore(:salix_im, :conversation_placement, previous_placement)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Pin aggregate"})

    {:ok, %{tenant_id: tenant_id, group_id: group_id}}
  end

  test "task order round-trips per bucket, replaces, clears, and validates", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    ids = for _ <- 1..3, do: Ids.new_conversation_id()
    [first, second, third] = ids

    # Unset order reads as empty, not as an error.
    assert {:ok, %{"orders" => %{}}} = Conversations.get_task_order(group_id, tenant_id)

    assert {:ok, %{"orders" => %{"done" => ^ids}}} =
             ConversationServer.put_task_order(group_id, "done", ids, tenant_id)

    # A drop replaces the bucket wholesale; other buckets are untouched.
    assert {:ok, %{"orders" => orders}} =
             ConversationServer.put_task_order(
               group_id,
               "backlog",
               [third, first],
               tenant_id
             )

    assert orders == %{"done" => ids, "backlog" => [third, first]}
    assert {:ok, %{"orders" => ^orders}} = Conversations.get_task_order(group_id, tenant_id)

    swapped = [second, first, third]

    assert {:ok, %{"orders" => %{"done" => ^swapped}}} =
             ConversationServer.put_task_order(group_id, "done", swapped, tenant_id)

    # An empty list clears the bucket instead of storing a useless entry.
    assert {:ok, %{"orders" => cleared}} =
             ConversationServer.put_task_order(group_id, "backlog", [], tenant_id)

    assert cleared == %{"done" => swapped}

    assert {:error, :invalid_task_order} =
             ConversationServer.put_task_order(group_id, "done", ["nope"], tenant_id)

    assert {:error, :invalid_task_order} =
             ConversationServer.put_task_order(group_id, "done", [first, first], tenant_id)

    assert {:error, :invalid_task_order_bucket} =
             ConversationServer.put_task_order(group_id, "", ids, tenant_id)

    assert {:error, {:task_order_over_limit, 500}} =
             ConversationServer.put_task_order(
               group_id,
               "done",
               for(_ <- 1..501, do: Ids.new_conversation_id()),
               tenant_id
             )

    # Errors never clobbered the stored arrangement.
    assert {:ok, %{"orders" => %{"done" => ^swapped}}} =
             Conversations.get_task_order(group_id, tenant_id)
  end

  test "an overlapping owner reactivates a participant deactivated by its peer", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Participant reactivation"
             })

    attrs = %{"user_id" => "reactivation-user"}

    assert {:ok, %{"participant_id" => participant_id}} =
             ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, registered_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    :ok = DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, registered_owner)

    owner_a =
      start_unnamed_conversation_actor!(
        group_id: group_id,
        conversation_id: conversation_id,
        wake_on_recovery: false
      )

    owner_b =
      start_unnamed_conversation_actor!(
        group_id: group_id,
        conversation_id: conversation_id,
        wake_on_recovery: false
      )

    assert {:ok, %{"participant_count" => 1}} =
             GenServer.call(owner_a, :get_group_conversation)

    assert {:ok, %{"participant_count" => 1}} =
             GenServer.call(owner_b, :get_group_conversation)

    assert {:ok, %{"participant_id" => ^participant_id, "state" => "inactive"}} =
             GenServer.call(
               owner_a,
               {:deactivate_group_conversation_participant, participant_id}
             )

    assert {:ok, %{"participant_id" => ^participant_id}} =
             GenServer.call(
               owner_b,
               {:ensure_group_conversation_user_participant, attrs}
             )

    assert {:ok, [%{"participant_id" => ^participant_id, "state" => "active"}]} =
             SalixIM.ConversationParticipantProjection.list_bounded(
               group_id,
               conversation_id
             )
  end

  test "participant reservation cannot recreate a conversation after delete cleanup", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Delete reservation race"
             })

    assert {:ok, registered_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    :ok = DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, registered_owner)

    stale_owner =
      start_unnamed_conversation_actor!(
        group_id: group_id,
        conversation_id: conversation_id,
        wake_on_recovery: false
      )

    assert {:ok, %{"participant_count" => 0}} =
             GenServer.call(stale_owner, :get_group_conversation)

    store = :sys.get_state(stale_owner).store_pid
    observer = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:salix_store, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == store and metadata.params == [group_id, conversation_id] and
             String.contains?(metadata.query, "FROM salix_conversations") and
             not String.contains?(metadata.query, "FOR UPDATE") and Process.get(handler) != true do
          Process.put(handler, true)
          send(observer, {:participant_source_observed, self()})

          SystemsClock.vreceive do
            :release_participant_source -> :ok
          after
            5_000 -> :ok
          end
        end
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      send(store, :release_participant_source)
    end)

    ensure =
      SystemsRuntime.Task.async(fn ->
        GenServer.call(
          stale_owner,
          {:ensure_group_conversation_user_participant,
           %{
             "user_id" => "delete-race-user"
           }}
        )
      end)

    settle_receive({:participant_source_observed, writer})
    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)
    scope = ConversationPGStore.new(group_id, conversation_id)

    assert :ok =
             eventually(fn ->
               if ConversationPGStore.read(scope) == {:error, :not_found}, do: :ok, else: :retry
             end)

    send(writer, :release_participant_source)
    assert {:error, :not_found} = settled_await(ensure)
    assert {:error, :not_found} = ConversationPGStore.read(scope)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_conversation_participants WHERE group_id=$1 AND conversation_id=$2",
               [group_id, conversation_id]
             )
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp start_unnamed_conversation_actor!(opts) do
    start_supervised!(%{
      id: {ConversationActor, SystemsRuntime.Proc.make_ref()},
      start: {GenServer, :start_link, [ConversationActor, opts]},
      restart: :temporary,
      type: :worker
    })
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
