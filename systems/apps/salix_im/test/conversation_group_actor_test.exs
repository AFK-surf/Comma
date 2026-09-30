defmodule SalixIM.ConversationGroupActorTest do
  use ExUnit.Case, async: false

  alias SalixIM.{
    ConversationActor,
    ConversationGroupActor,
    ConversationPlacement,
    ConversationServer,
    Conversations
  }

  alias SalixStore.{Ids, Keys}

  @participant_identity_slots_field "_participant_identity_slots"

  defmodule SplitBrainPlacement do
    @moduledoc false
    use Agent

    @behaviour SalixIM.ConversationPlacement

    def start_link(_opts),
      do: Agent.start_link(fn -> %{owners: [], next: 0} end, name: __MODULE__)

    def configure(owners),
      do: Agent.update(__MODULE__, fn _ -> %{owners: owners, next: 0} end)

    @impl true
    def ensure_started(group_id, conversation_id, opts),
      do: SalixIM.ConversationFleet.ensure_started(group_id, conversation_id, opts)

    @impl true
    def ensure_group_started(_group_id, _opts) do
      Agent.get_and_update(__MODULE__, fn %{owners: owners, next: next} = state ->
        owner = Enum.at(owners, rem(next, length(owners)))
        {{:ok, owner}, %{state | next: next + 1}}
      end)
    end

    @impl true
    def notify_group_conversation_mutation_if_running(group_id, mutation),
      do:
        SalixIM.ConversationGroupActor.notify_conversation_mutation_if_running(
          group_id,
          mutation
        )
  end

  defmodule AggregateReadBarrier do
    @moduledoc false
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{key: nil, test: nil, blocked: 0} end, name: __MODULE__)

    def configure(key, test),
      do: Agent.update(__MODULE__, fn _ -> %{key: key, test: test, blocked: 0} end)

    def block?(key) do
      Agent.get_and_update(__MODULE__, fn state ->
        block? = key == state.key and state.blocked < 2
        test = state.test
        next = if block?, do: %{state | blocked: state.blocked + 1}, else: state
        {{block?, test}, next}
      end)
    end
  end

  defmodule ParticipantSlotWriteBarrier do
    @moduledoc false
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{targets: [], test: nil, blocked?: false} end, name: __MODULE__)

    def configure(targets, test),
      do:
        Agent.update(__MODULE__, fn _ ->
          %{targets: List.wrap(targets), test: test, blocked?: false}
        end)

    def block?(key, body) do
      Agent.get_and_update(__MODULE__, fn state ->
        block? =
          not state.blocked? and
            Enum.any?(state.targets, &target_matches?(&1, key, body))

        next = if block?, do: %{state | blocked?: true}, else: state
        {{block?, state.test}, next}
      end)
    end

    defp target_matches?(expected_key, key, _body) when is_binary(expected_key),
      do: key == expected_key

    defp target_matches?({expected_key, field}, key, body) do
      key == expected_key and
        match?(
          {:ok, %{^field => slots}} when is_map(slots),
          Jason.decode(IO.iodata_to_binary(body))
        )
    end
  end

  defmodule BarrierS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def get(key, opts) do
      case AggregateReadBarrier.block?(key) do
        {true, test} ->
          send(test, {:aggregate_read_blocked, self()})

          receive do
            :release_aggregate_read -> SalixStore.S3.Fake.get(key, opts)
          after
            5_000 -> {:error, :aggregate_read_barrier_timeout}
          end

        {false, _test} ->
          SalixStore.S3.Fake.get(key, opts)
      end
    end

    @impl true
    def put(key, body, opts) do
      case ParticipantSlotWriteBarrier.block?(key, body) do
        {true, test} ->
          send(test, {:participant_slot_write_blocked, self()})

          receive do
            :release_participant_slot_write -> SalixStore.S3.Fake.put(key, body, opts)
          after
            5_000 -> {:error, :participant_slot_write_barrier_timeout}
          end

        {false, _test} ->
          SalixStore.S3.Fake.put(key, body, opts)
      end
    end

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_placement = Application.get_env(:salix_im, :conversation_placement)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SplitBrainPlacement)
    start_supervised!(AggregateReadBarrier)
    start_supervised!(ParticipantSlotWriteBarrier)

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

  test "the 200-pin limit survives overlapping group owners", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    {:ok, registered_owner} = ConversationPlacement.ensure_group_started(group_id)
    now = System.system_time(:millisecond)

    for index <- 1..199 do
      pin = %{
        "agent_group_id" => group_id,
        "conversation_id" => Ids.new_conversation_id(),
        "pinned_at" => now + index,
        "created_at" => now + index,
        "updated_at" => now + index
      }

      assert :ok = ConversationServer.import_conversation_pin(group_id, pin)
    end

    conversation_ids =
      for title <- ["Boundary A", "Boundary B"] do
        assert {:ok, %{"conversation_id" => conversation_id}} =
                 SalixIM.ConversationInput.create_group_conversation(group_id, %{
                   "kind" => "agent_task",
                   "title" => title
                 })

        conversation_id
      end

    :ok = DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, registered_owner)
    {:ok, owner_a} = ConversationGroupActor.start_link(group_id: group_id, name: nil)
    {:ok, owner_b} = ConversationGroupActor.start_link(group_id: group_id, name: nil)

    SplitBrainPlacement.configure([owner_a, owner_b])
    AggregateReadBarrier.configure(Keys.ctl_conversation_pins_aggregate(group_id), self())
    Application.put_env(:salix_store, :s3_backend, BarrierS3)
    Application.put_env(:salix_im, :conversation_placement, SplitBrainPlacement)

    tasks =
      Enum.map(conversation_ids, fn conversation_id ->
        Task.async(fn ->
          ConversationServer.pin_conversation(group_id, conversation_id, tenant_id)
        end)
      end)

    assert_receive {:aggregate_read_blocked, reader_a}, 2_000
    assert_receive {:aggregate_read_blocked, reader_b}, 2_000
    send(reader_a, :release_aggregate_read)
    send(reader_b, :release_aggregate_read)

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert 1 == Enum.count(results, &match?({:ok, %{}}, &1))

    assert 1 ==
             Enum.count(
               results,
               &match?({:error, {:pin_collection_over_limit, 200}}, &1)
             )

    assert {:ok, %{body: aggregate_body}} =
             SalixStore.S3.get(Keys.ctl_conversation_pins_aggregate(group_id))

    assert %{"pins" => pins} = Jason.decode!(aggregate_body)
    assert length(pins) == 200

    assert {:ok, %{"data" => listed, "has_more" => false}} =
             Conversations.list_conversation_pins(group_id, tenant_id, limit: 200)

    assert length(listed) == 1
    assert List.first(listed)["conversation_id"] in conversation_ids
  end

  test "the 200-participant limit survives overlapping conversation owners", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Participant boundary"
             })

    for index <- 1..199 do
      user_id = "boundary-user-#{index}"

      assert {:ok, %{"user_id" => ^user_id}} =
               ConversationServer.ensure_group_conversation_user_participant(
                 group_id,
                 conversation_id,
                 %{"user_id" => user_id}
               )
    end

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

    assert {:ok, %{"participant_count" => 199}} =
             GenServer.call(owner_a, :get_group_conversation)

    assert {:ok, %{"participant_count" => 199}} =
             GenServer.call(owner_b, :get_group_conversation)

    assert {:ok, projection} = Conversations.get_group_conversation(group_id, conversation_id)
    refute Map.has_key?(projection, @participant_identity_slots_field)

    assert {:ok, %{"data" => listed}} =
             Conversations.list_group_conversations(group_id, limit: 10)

    refute Enum.any?(listed, &Map.has_key?(&1, @participant_identity_slots_field))

    assert {:ok, searched} =
             Conversations.search_group_conversations(group_id, "Participant boundary")

    refute Enum.any?(searched, &Map.has_key?(&1, @participant_identity_slots_field))

    results =
      [
        {owner_a, "boundary-user-a"},
        {owner_b, "boundary-user-b"}
      ]
      |> Task.async_stream(
        fn {owner, user_id} ->
          GenServer.call(
            owner,
            {:ensure_group_conversation_user_participant, %{"user_id" => user_id}}
          )
        end,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    participant_prefix =
      Keys.ctl_group_conversation_participant_states_prefix(group_id, conversation_id)

    assert {:ok, durable_participants} = SalixStore.S3.list_all(participant_prefix)
    assert length(durable_participants) == 200
    assert Enum.count(results, &match?({:ok, %{}}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, {:participant_collection_over_limit, 200}}, &1)
           ) == 1

    assert {:ok, participants} =
             SalixIM.ConversationParticipantProjection.list_bounded(group_id, conversation_id)

    assert length(participants) == 200
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

    legacy_slots_key =
      Keys.ctl_group_conversation_dir(group_id, conversation_id) <> "participant_slots.json"

    ParticipantSlotWriteBarrier.configure(
      [
        legacy_slots_key,
        {Keys.ctl_group_conversation(group_id, conversation_id),
         @participant_identity_slots_field}
      ],
      self()
    )

    Application.put_env(:salix_store, :s3_backend, BarrierS3)

    ensure =
      Task.async(fn ->
        GenServer.call(
          stale_owner,
          {:ensure_group_conversation_user_participant,
           %{
             "user_id" => "delete-race-user"
           }}
        )
      end)

    assert_receive {:participant_slot_write_blocked, writer}, 2_000
    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)

    conversation_prefix = Keys.ctl_group_conversation_dir(group_id, conversation_id)

    assert :ok =
             eventually(fn ->
               case SalixStore.S3.list(conversation_prefix, max_keys: 1) do
                 {:ok, %{objects: []}} -> :ok
                 _other -> :retry
               end
             end)

    send(writer, :release_participant_slot_write)
    result = Task.await(ensure, 5_000)

    assert {:ok, %{objects: []}} = SalixStore.S3.list(conversation_prefix, max_keys: 10)
    assert {:error, :not_found} = result
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp start_unnamed_conversation_actor!(opts) do
    start_supervised!(%{
      id: {ConversationActor, make_ref()},
      start: {GenServer, :start_link, [ConversationActor, opts]},
      restart: :temporary,
      type: :worker
    })
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: {:error, :timeout}

  defp eventually(fun, attempts) do
    case fun.() do
      :ok ->
        :ok

      :retry ->
        receive do
        after
          10 -> eventually(fun, attempts - 1)
        end
    end
  end
end
