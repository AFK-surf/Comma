defmodule BridgeForTeams.TestConversationStore do
  @moduledoc false

  defmacro __using__(opts) do
    store =
      case opts do
        :group_router -> quote(do: __MODULE__.Store)
        opts when is_list(opts) -> Keyword.fetch!(opts, :store)
      end

    quote do
      def get_group(group_id),
        do: BridgeForTeams.TestConversationStore.get_group_with_router(group_id)

      def ensure_group_conversation_provider_participant(group_id, conversation_id, attrs),
        do:
          BridgeForTeams.TestConversationStore.ensure_group_conversation_provider_participant(
            unquote(store),
            group_id,
            conversation_id,
            attrs
          )

      def get_group_conversation(group_id, conversation_id),
        do:
          BridgeForTeams.TestConversationStore.get_group_conversation(
            unquote(store),
            group_id,
            conversation_id
          )

      def list_group_conversation_participants(group_id, conversation_id, opts),
        do:
          BridgeForTeams.TestConversationStore.list_group_conversation_participants(
            unquote(store),
            group_id,
            conversation_id,
            opts
          )

      def get_group_conversation_with_messages(group_id, conversation_id, opts) do
        with {:ok, conversation} <- get_group_conversation(group_id, conversation_id),
             {:ok, messages} <-
               apply(__MODULE__, :list_group_conversation_messages, [
                 group_id,
                 conversation_id,
                 opts
               ]) do
          {:ok, %{"conversation" => conversation, "messages" => messages}}
        end
      end

      defoverridable ensure_group_conversation_provider_participant: 3,
                     get_group_conversation: 2,
                     list_group_conversation_participants: 3,
                     get_group_conversation_with_messages: 3
    end
  end

  def reset(store), do: Agent.update(ensure_store(store), fn _ -> %{} end)

  def get_group_with_router(group_id) when is_binary(group_id) and group_id != "" do
    with {:ok, project} <- BridgeForTeams.Projects.get_project_by_salix_group(group_id),
         %BridgeForTeams.Schema.Agent{} = router <-
           BridgeForTeams.Repo.get_by(BridgeForTeams.Schema.Agent,
             project_id: project.id,
             role: "router"
           ) do
      {:ok, %{"group_id" => group_id, "router_agent_id" => router.salix_agent_id}}
    else
      _missing -> {:error, :not_found}
    end
  end

  def get_group_with_router(_group_id), do: {:error, :not_found}

  def create_group_conversation(store, group_id, attrs) do
    now = DateTime.utc_now()
    id = attrs["conversation_id"] || SalixStore.Ids.new_conversation_id()

    conversation =
      attrs
      |> Map.put("conversation_id", id)
      |> Map.put_new("agent_group_id", group_id)
      |> Map.put_new("kind", "user_chat")
      |> Map.put_new("status", "active")
      |> Map.put_new("activity_status", "idle")
      |> Map.put_new("participants", [])
      |> Map.put_new("metadata", %{})
      |> Map.put_new("source_refs", %{})
      |> Map.put_new("created_at", now)
      |> Map.put("updated_at", now)

    Agent.update(ensure_store(store), &Map.put(&1, {group_id, id}, conversation))
    {:ok, conversation}
  end

  def list_group_conversations(store, group_id, opts) do
    limit = Keyword.get(opts, :limit, 200)

    conversations =
      store
      |> ensure_store()
      |> Agent.get(fn state ->
        state
        |> Enum.flat_map(fn
          {{^group_id, _id}, conversation} -> [conversation]
          _other -> []
        end)
      end)
      |> Enum.sort_by(&timestamp_sort_key(&1["created_at"]), :desc)
      |> Enum.take(limit)

    {:ok, conversations}
  end

  def get_group_conversation(store, group_id, conversation_id) do
    case Agent.get(ensure_store(store), &Map.get(&1, {group_id, conversation_id})) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  def get_group_conversation_or(store, group_id, conversation_id, fallback)
      when is_function(fallback, 0) do
    case get_group_conversation(store, group_id, conversation_id) do
      {:error, :not_found} -> fallback.()
      result -> result
    end
  end

  def list_group_conversation_participants(store, group_id, conversation_id, _opts) do
    case get_group_conversation(store, group_id, conversation_id) do
      {:ok, conversation} ->
        {:ok,
         %{
           "conversation_id" => conversation_id,
           "participants" => List.wrap(conversation["participants"])
         }}

      {:error, _reason} = error ->
        error
    end
  end

  def ensure_group_conversation_provider_participant(store, group_id, conversation_id, attrs) do
    Agent.get_and_update(ensure_store(store), fn state ->
      key = {group_id, conversation_id}

      case Map.fetch(state, key) do
        {:ok, conversation} ->
          participants = List.wrap(conversation["participants"])

          case Enum.find(participants, fn participant ->
                 participant["actor_type"] == "provider" and
                   participant["provider"] == attrs["provider"] and
                   participant["target_key"] == attrs["target_key"]
               end) do
            nil ->
              participant =
                attrs
                |> Map.put("participant_id", SalixStore.Ids.new_participant_id())
                |> Map.put("conversation_id", conversation_id)

              updated = Map.put(conversation, "participants", participants ++ [participant])
              {{:ok, participant}, Map.put(state, key, updated)}

            participant ->
              {{:ok, participant}, state}
          end

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  def update_group_conversation(store, group_id, conversation_id, attrs) do
    Agent.get_and_update(ensure_store(store), fn state ->
      key = {group_id, conversation_id}

      case Map.fetch(state, key) do
        {:ok, conversation} ->
          updated =
            conversation
            |> deep_merge(stringify(attrs))
            |> Map.put("updated_at", DateTime.utc_now())

          {{:ok, updated}, Map.put(state, key, updated)}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  # Mirrors real Salix: appending to a conversation that was never created
  # is :not_found, not a silent create. (This exact phantom-append behavior
  # once hid a real bug — first-time task delegation sent prompts into
  # conversations that only existed as locally minted ids.)
  def append_group_conversation_message(store, group_id, conversation_id, attrs) do
    key = {group_id, conversation_id, :messages}

    Agent.get_and_update(ensure_store(store), fn state ->
      if Map.has_key?(state, {group_id, conversation_id}) do
        messages = Map.get(state, key, [])

        case find_message_by_request_identity(messages, attrs) do
          nil ->
            message =
              attrs
              |> Map.put("message_id", SalixStore.Ids.new_message_id())
              |> Map.put_new("created_at", DateTime.utc_now())

            result = append_message_result(conversation_id, message["message_id"], true)
            {{:ok, result}, Map.put(state, key, [message | messages])}

          message ->
            result = append_message_result(conversation_id, message["message_id"], false)
            {{:ok, result}, state}
        end
      else
        {{:error, :not_found}, state}
      end
    end)
  end

  # Mirrors the delivery-free seam of
  # `SalixIM.ConversationServer.seed_group_conversation_transcript/3`: appends
  # `attrs["messages"]` without any delivery side effects and without touching
  # the conversation record. Returns the real seed summary shape.
  def seed_group_conversation_transcript(store, group_id, conversation_id, attrs) do
    messages = List.wrap(attrs["messages"])
    key = {group_id, conversation_id, :messages}

    # Real seeding CREATES the conversation when it doesn't exist yet (kind
    # user_chat, from the payload's "conversation" attrs) — mirror that so
    # later appends to a seeded conversation succeed like they do in Salix.
    conversation_attrs =
      attrs
      |> Map.get("conversation", %{})
      |> Map.put("conversation_id", conversation_id)

    Agent.update(ensure_store(store), fn state ->
      Map.put_new_lazy(state, {group_id, conversation_id}, fn ->
        now = DateTime.utc_now()

        conversation_attrs
        |> Map.put_new("agent_group_id", group_id)
        |> Map.put_new("kind", "user_chat")
        |> Map.put_new("status", "active")
        |> Map.put_new("activity_status", "idle")
        |> Map.put_new("participants", [])
        |> Map.put_new("metadata", %{})
        |> Map.put_new("source_refs", %{})
        |> Map.put_new("created_at", now)
        |> Map.put("updated_at", now)
      end)
    end)

    seeded =
      Enum.map(messages, fn message ->
        message
        |> Map.put("message_id", SalixStore.Ids.new_message_id())
        |> Map.put_new("created_at", DateTime.utc_now())
      end)

    Agent.update(
      ensure_store(store),
      &Map.update(&1, key, Enum.reverse(seeded), fn existing ->
        Enum.reverse(seeded) ++ existing
      end)
    )

    total =
      store
      |> ensure_store()
      |> Agent.get(&length(Map.get(&1, key, [])))

    count = length(seeded)

    {:ok,
     %{
       "conversation_id" => conversation_id,
       "requested_count" => count,
       "appended_count" => count,
       "skipped_count" => 0,
       "message_count" => total
     }}
  end

  def list_group_conversation_messages(store, group_id, conversation_id, opts) do
    limit = Keyword.get(opts, :limit, 100)

    messages =
      store
      |> ensure_store()
      |> Agent.get(&Map.get(&1, {group_id, conversation_id, :messages}, []))
      |> Enum.reverse()
      |> Enum.take(limit)

    {:ok, messages}
  end

  defp ensure_store(store) do
    case Process.whereis(store) do
      nil ->
        case Agent.start_link(fn -> %{} end, name: store) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  defp timestamp_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp timestamp_sort_key(_value), do: 0

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp append_message_result(conversation_id, message_id, inserted) do
    %{
      "conversation_id" => conversation_id,
      "message_id" => message_id,
      "delivery_status" => "queued",
      "inserted" => inserted
    }
  end

  defp find_message_by_request_identity(messages, attrs) do
    request_identity =
      Enum.find_value(~w(client_request_id source_message_id idempotency_key), fn key ->
        case attrs[key] do
          value when is_binary(value) and value != "" -> {key, value}
          _other -> nil
        end
      end)

    case request_identity do
      nil -> nil
      {key, value} -> Enum.find(messages, &(&1[key] == value))
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = left_map, %{} = right_map -> deep_merge(left_map, right_map)
      _key, _left_value, right_value -> right_value
    end)
  end
end
