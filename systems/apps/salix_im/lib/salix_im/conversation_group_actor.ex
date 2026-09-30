defmodule SalixIM.ConversationGroupActor do
  @moduledoc """
  Owner for bounded conversation state shared by one agent group.

  Conversation-local facts stay in `ConversationActor`. This owner serializes
  group-level commands, while the canonical CAS aggregate also preserves its
  constraints across owner overlap or retry.

  The best-effort mutation wakeup and reconnect resynchronization boundary is
  modeled in `tla/salix/ConversationMutationSubscription.tla`; changes to that
  contract must move the spec and its executable scenarios together.
  """

  use GenServer

  require Logger

  alias SalixIM.{Conversations, GroupDirectory}
  alias SalixStore.{CasRecord, Ids, Keys}

  @pin_limit 200
  @task_order_bucket_limit 16
  @task_order_bucket_name_limit 64
  @task_order_id_limit 500
  @call_timeout :infinity

  defstruct group_id: nil,
            list_generation: nil,
            router_read_hint: nil,
            list_revisions: %{"agent_task" => 0, "user_chat" => 0},
            mutation_revision: 0,
            list_subscribers: %{},
            mutation_subscribers: %{}

  def child_spec(opts) do
    group_id = Keyword.fetch!(opts, :group_id)

    %{
      id: key(group_id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    group_id = Keyword.fetch!(opts, :group_id)

    case Keyword.get(opts, :name, via(group_id)) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def key(group_id), do: {:conversation_group, group_id}

  defp via(group_id),
    do: {:via, Registry, {SalixIM.ConversationRegistry, key(group_id)}}

  # A read-ahead address only. Callers must resolve current Group authority.
  def router_read_hint(group_id) do
    case Registry.lookup(SalixIM.ConversationRegistry, key(group_id)) do
      [{pid, _}] -> GenServer.call(pid, :router_read_hint, 100)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  def remove_deleted_pin(pid, conversation_id),
    do: call(pid, {:remove_deleted_pin, conversation_id})

  def subscribe_conversation_list(pid, kind, subscriber)
      when kind in ["agent_task", "user_chat"] and is_pid(subscriber),
      do: call(pid, {:subscribe_conversation_list, kind, subscriber})

  def subscribe_conversation_mutations(pid, subscriber) when is_pid(subscriber),
    do: call(pid, {:subscribe_conversation_mutations, subscriber})

  def notify_conversation_mutation_if_running(group_id, mutation) when is_map(mutation) do
    if valid_mutation?(mutation) do
      case Registry.lookup(SalixIM.ConversationRegistry, key(group_id)) do
        [{pid, _value}] ->
          GenServer.cast(pid, {:conversation_mutated, mutation})

        [] ->
          :ok
      end
    else
      # A mutation without a canonical event and Conversation kind cannot be
      # attributed to a list, so no subscriber is ever woken for it. That is a
      # defect in the caller, not a runtime condition: name it here instead of
      # letting the wakeup disappear.
      Logger.warning(
        "dropped unattributable group conversation mutation",
        group_id: group_id,
        mutation: inspect(mutation)
      )
    end

    :ok
  end

  def notify_conversation_mutation_if_running(_group_id, _mutation), do: :ok

  defp call(pid, command), do: GenServer.call(pid, command, @call_timeout)

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       group_id: Keyword.fetch!(opts, :group_id),
       list_generation: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
     }}
  end

  @impl true
  def handle_call(:router_read_hint, _from, state),
    do: {:reply, state.router_read_hint, state}

  def handle_call({:router_read_hint, agent_id}, _from, state),
    do: {:reply, :ok, %{state | router_read_hint: agent_id}}

  def handle_call({:pin, conversation_id, tenant_id}, _from, state) do
    reply =
      with {:ok, _group} <- GroupDirectory.get_group(state.group_id, tenant_id),
           {:ok, _conversation} <-
             Conversations.get_group_conversation(state.group_id, conversation_id) do
        put_pin(state.group_id, conversation_id, System.system_time(:millisecond))
      end

    {:reply, reply, state}
  end

  def handle_call({:unpin, conversation_id, tenant_id}, _from, state) do
    reply =
      with {:ok, _group} <- GroupDirectory.get_group(state.group_id, tenant_id),
           {:ok, _aggregate} <- delete_pin(state.group_id, conversation_id) do
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:put_task_order, bucket, conversation_ids, tenant_id}, _from, state) do
    reply =
      with {:ok, _group} <- GroupDirectory.get_group(state.group_id, tenant_id),
           :ok <- validate_task_order_input(bucket, conversation_ids) do
        put_task_order(state.group_id, bucket, conversation_ids)
      end

    {:reply, reply, state}
  end

  def handle_call({:remove_deleted_pin, conversation_id}, _from, state) do
    reply =
      case delete_pin(state.group_id, conversation_id) do
        {:ok, _aggregate} -> :ok
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:import_pin, pin}, _from, state) do
    {:reply, import_pin_record(state.group_id, pin), state}
  end

  def handle_call({:subscribe_conversation_list, kind, subscriber}, _from, state)
      when kind in ["agent_task", "user_chat"] and is_pid(subscriber) do
    state = put_list_subscriber(state, kind, subscriber)

    {:reply,
     {:ok,
      %{
        "owner_pid" => self(),
        "resync_required" => true,
        "version" => list_version(state, kind)
      }}, state}
  end

  def handle_call({:subscribe_conversation_mutations, subscriber}, _from, state)
      when is_pid(subscriber) do
    case GroupDirectory.get_group(state.group_id) do
      {:ok, _group} ->
        state = put_mutation_subscriber(state, subscriber)

        {:reply,
         {:ok,
          %{
            "owner_pid" => self(),
            "version" => mutation_version(state)
          }}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:conversation_mutated, mutation}, state) when is_map(mutation) do
    state = %{state | mutation_revision: state.mutation_revision + 1}
    state = invalidate_conversation_lists(state, mutation)
    version = mutation_version(state)

    Enum.each(Map.keys(state.mutation_subscribers), fn subscriber ->
      send(subscriber, {:group_conversation_mutated, state.group_id, mutation, version})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, subscriber, _reason}, state) do
    state = drop_list_subscriber(state, subscriber, ref)
    {:noreply, drop_mutation_subscriber(state, subscriber, ref)}
  end

  defp put_task_order(group_id, bucket, conversation_ids) do
    now = System.system_time(:millisecond)

    with {:ok, aggregate} <-
           update_task_order_aggregate(group_id, fn aggregate ->
             orders =
               if conversation_ids == [],
                 do: Map.delete(aggregate["orders"], bucket),
                 else: Map.put(aggregate["orders"], bucket, conversation_ids)

             cond do
               orders == aggregate["orders"] ->
                 {:unchanged, aggregate}

               map_size(orders) > @task_order_bucket_limit ->
                 {:error, {:task_order_bucket_limit, @task_order_bucket_limit}}

               true ->
                 aggregate
                 |> Map.put("orders", orders)
                 |> Map.put("updated_at", now)
             end
           end) do
      {:ok, %{"orders" => aggregate["orders"]}}
    end
  end

  defp update_task_order_aggregate(group_id, updater) do
    CasRecord.update(
      Keys.ctl_task_order_aggregate(group_id),
      fn
        nil -> updater.(empty_task_order_aggregate(group_id))
        aggregate -> updater.(aggregate)
      end,
      invalid: :invalid_task_order_aggregate,
      validate: &validate_task_order_aggregate(&1, group_id)
    )
  end

  defp empty_task_order_aggregate(group_id),
    do: %{"agent_group_id" => group_id, "orders" => %{}}

  defp validate_task_order_input(bucket, conversation_ids) do
    cond do
      not (is_binary(bucket) and bucket != "" and
               byte_size(bucket) <= @task_order_bucket_name_limit) ->
        {:error, :invalid_task_order_bucket}

      not is_list(conversation_ids) ->
        {:error, :invalid_task_order}

      length(conversation_ids) > @task_order_id_limit ->
        {:error, {:task_order_over_limit, @task_order_id_limit}}

      not Enum.all?(conversation_ids, &Ids.valid_conversation_id?/1) ->
        {:error, :invalid_task_order}

      length(Enum.uniq(conversation_ids)) != length(conversation_ids) ->
        {:error, :invalid_task_order}

      true ->
        :ok
    end
  end

  def validate_task_order_aggregate(
        %{"agent_group_id" => group_id, "orders" => orders},
        expected_group_id
      )
      when group_id == expected_group_id and is_map(orders) and
             map_size(orders) <= @task_order_bucket_limit do
    if Enum.all?(orders, fn {bucket, ids} ->
         validate_task_order_input(bucket, ids) == :ok and ids != []
       end),
       do: :ok,
       else: {:error, :invalid_task_order_aggregate}
  end

  def validate_task_order_aggregate(_aggregate, _group_id),
    do: {:error, :invalid_task_order_aggregate}

  def task_order_limits,
    do: %{
      buckets: @task_order_bucket_limit,
      bucket_name_bytes: @task_order_bucket_name_limit,
      ids: @task_order_id_limit
    }

  defp put_pin(group_id, conversation_id, now) do
    with {:ok, aggregate} <-
           update_aggregate(group_id, fn aggregate ->
             pins = aggregate["pins"]

             case Enum.find(pins, &(&1["conversation_id"] == conversation_id)) do
               nil when length(pins) >= @pin_limit ->
                 {:error, {:pin_collection_over_limit, @pin_limit}}

               nil ->
                 pin = pin_record(group_id, conversation_id, now)
                 put_pins(aggregate, [pin | pins], now)

               current ->
                 pin =
                   current
                   |> Map.put("pinned_at", now)
                   |> Map.put("updated_at", now)

                 put_pins(aggregate, [pin | reject_pin(pins, conversation_id)], now)
             end
           end) do
      {:ok,
       aggregate["pins"]
       |> Enum.find(&(&1["conversation_id"] == conversation_id))
       |> pin_json()}
    end
  end

  defp delete_pin(group_id, conversation_id) do
    update_aggregate(group_id, fn aggregate ->
      pins = reject_pin(aggregate["pins"], conversation_id)

      if length(pins) == length(aggregate["pins"]),
        do: {:unchanged, aggregate},
        else: put_pins(aggregate, pins, System.system_time(:millisecond))
    end)
  end

  defp import_pin_record(group_id, pin) do
    canonical_pin = pin_json(pin)

    with :ok <- validate_import_pin(canonical_pin, group_id),
         {:ok, _aggregate} <-
           update_aggregate(group_id, fn aggregate ->
             conversation_id = canonical_pin["conversation_id"]
             pins = aggregate["pins"]

             case Enum.find(pins, &(&1["conversation_id"] == conversation_id)) do
               nil when length(pins) >= @pin_limit ->
                 {:error, {:pin_collection_over_limit, @pin_limit}}

               nil ->
                 put_pins(
                   aggregate,
                   [canonical_pin | pins],
                   canonical_pin["updated_at"]
                 )

               ^canonical_pin ->
                 {:unchanged, aggregate}

               _different ->
                 {:error, :pin_import_conflict}
             end
           end) do
      :ok
    end
  end

  defp update_aggregate(group_id, updater) do
    CasRecord.update(
      Keys.ctl_conversation_pins_aggregate(group_id),
      fn
        nil -> updater.(empty_aggregate(group_id))
        aggregate -> updater.(aggregate)
      end,
      invalid: :invalid_pin_aggregate,
      validate: &validate_aggregate(&1, group_id)
    )
  end

  defp empty_aggregate(group_id), do: %{"agent_group_id" => group_id, "pins" => []}

  defp put_pins(aggregate, pins, updated_at) do
    aggregate
    |> Map.put("pins", Enum.sort_by(pins, & &1["conversation_id"]))
    |> Map.put("updated_at", updated_at)
  end

  defp validate_aggregate(
         %{"agent_group_id" => group_id, "pins" => pins},
         expected_group_id
       )
       when group_id == expected_group_id and is_list(pins) and length(pins) <= @pin_limit do
    ids = Enum.map(pins, & &1["conversation_id"])

    if Enum.all?(pins, &(validate_import_pin(&1, group_id) == :ok)) and
         length(ids) == MapSet.size(MapSet.new(ids)),
       do: :ok,
       else: {:error, :invalid_pin_aggregate}
  end

  defp validate_aggregate(_aggregate, _group_id), do: {:error, :invalid_pin_aggregate}

  defp validate_import_pin(pin, group_id) do
    if is_map(pin) and pin["agent_group_id"] == group_id and
         Ids.valid_conversation_id?(pin["conversation_id"]) and is_integer(pin["pinned_at"]) and
         is_integer(pin["created_at"]) and is_integer(pin["updated_at"]),
       do: :ok,
       else: {:error, :invalid_pin}
  end

  defp pin_record(group_id, conversation_id, now) do
    %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "pinned_at" => now,
      "created_at" => now,
      "updated_at" => now
    }
  end

  defp reject_pin(pins, conversation_id),
    do: Enum.reject(pins, &(&1["conversation_id"] == conversation_id))

  defp put_list_subscriber(state, kind, subscriber) do
    case state.list_subscribers[subscriber] do
      %{kinds: kinds} = current ->
        put_in(state.list_subscribers[subscriber], %{current | kinds: MapSet.put(kinds, kind)})

      nil ->
        subscriber_state = %{kinds: MapSet.new([kind]), ref: Process.monitor(subscriber)}
        put_in(state.list_subscribers[subscriber], subscriber_state)
    end
  end

  defp put_mutation_subscriber(state, subscriber) do
    if Map.has_key?(state.mutation_subscribers, subscriber) do
      state
    else
      put_in(state.mutation_subscribers[subscriber], Process.monitor(subscriber))
    end
  end

  defp drop_list_subscriber(state, subscriber, ref) do
    case state.list_subscribers[subscriber] do
      %{ref: ^ref} ->
        %{state | list_subscribers: Map.delete(state.list_subscribers, subscriber)}

      _other ->
        state
    end
  end

  defp drop_mutation_subscriber(state, subscriber, ref) do
    case state.mutation_subscribers[subscriber] do
      ^ref ->
        %{state | mutation_subscribers: Map.delete(state.mutation_subscribers, subscriber)}

      _other ->
        state
    end
  end

  defp invalidate_conversation_lists(state, mutation) do
    mutation
    |> mutation_kinds()
    |> Enum.reduce(state, fn kind, state ->
      state = update_in(state.list_revisions[kind], &(&1 + 1))
      version = list_version(state, kind)

      Enum.each(state.list_subscribers, fn
        {subscriber, %{kinds: kinds}} ->
          if MapSet.member?(kinds, kind) do
            send(
              subscriber,
              {:group_conversation_list_invalidated, state.group_id, kind,
               mutation.conversation_id, version}
            )
          end
      end)

      state
    end)
  end

  defp mutation_kinds(mutation) do
    [mutation.kind, mutation[:previous_kind]]
    |> Enum.filter(&(&1 in ["agent_task", "user_chat"]))
    |> Enum.uniq()
  end

  defp valid_mutation?(%{
         event: event,
         conversation_id: conversation_id,
         kind: kind
       })
       when event in [:conversation_upsert, :conversation_delete, :message_created] and
              kind in ["agent_task", "user_chat"] do
    Ids.valid_conversation_id?(conversation_id)
  end

  defp valid_mutation?(_mutation), do: false

  defp list_version(state, kind),
    do: state.list_generation <> "." <> Integer.to_string(state.list_revisions[kind])

  defp mutation_version(state),
    do: state.list_generation <> "." <> Integer.to_string(state.mutation_revision)

  defp pin_json(pin),
    do: Map.take(pin, ~w(agent_group_id conversation_id pinned_at created_at updated_at))
end
