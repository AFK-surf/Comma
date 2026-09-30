defmodule CommaSSH.Chat do
  @moduledoc "One authorized, bounded Router Conversation subscription per terminal."
  use GenServer
  alias Comma.{Accounts, AssistantChats, Conversations, Workspaces}

  def start_link(context), do: GenServer.start_link(__MODULE__, context)

  def init(state) do
    Process.flag(:sensitive, true)

    with {:ok, user, session} <- Accounts.resolve_session(state.token),
         {:ok, workspace} <- Workspaces.authorize(user, session, state.workspace["id"]),
         {:ok, conversation} <-
           AssistantChats.ensure_chat(user, session, workspace["default_group_id"]),
         {:ok, snapshot, _, context} <-
           Conversations.events(user, session, workspace["default_group_id"], conversation["id"]) do
      for key <- [:owner_pid, :participant_owner_pid],
          is_pid(context[key]),
          do: Process.monitor(context[key])

      state =
        Map.merge(state, %{
          workspace: workspace,
          conversation: conversation["id"],
          context: context,
          snapshot: snapshot,
          refresh: nil,
          task_owner: nil,
          task_count: nil,
          tasks_dirty: false
        })
        |> subscribe_tasks(user, session)
        |> refresh_tasks(user, session)

      publish(state)
      {:ok, state}
    else
      _ -> {:stop, :chat_unavailable}
    end
  end

  def format_status(status),
    do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted)

  def handle_call({:command, text}, _from, state) do
    result =
      with {:ok, user, session} <- authorized(state) do
        if text == "/stop" do
          Conversations.cancel(user, session, group(state), state.conversation)
        else
          Conversations.send_message(user, session, group(state), state.conversation, %{
            "content" => text,
            "client_request_id" => Ecto.UUID.generate()
          })
        end
      end

    case result do
      {:ok, _} ->
        {:reply, :ok, refresh(state)}

      _ ->
        emit(
          state,
          {:notice,
           "Request failed or acknowledgment was lost. Check history before sending again."}
        )

        {:reply, :error, state}
    end
  end

  def handle_info(:refresh, state) do
    if elem(Process.info(self(), :message_queue_len), 1) > 256 do
      send(state.ui, {:chat_close, self()})
      {:stop, :normal, state}
    else
      {:noreply, refresh(%{state | refresh: nil})}
    end
  end

  def handle_info({:DOWN, _, :process, owner, _}, %{task_owner: owner} = state) do
    state = %{state | task_owner: nil, task_count: nil, tasks_dirty: false}
    emit(state, {:task_count, nil})
    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, _, _}, state) do
    emit(state, {:screen, :workspace, ["Chat owner changed. Enter /workspace to reconnect."]})

    {:stop, :normal, state}
  end

  def handle_info({:conversation_message_created, _, _, _, _}, state),
    do: {:noreply, schedule(state)}

  def handle_info({:conversation_participant_status_changed, _, _, _}, state),
    do: {:noreply, schedule(state)}

  def handle_info({:group_conversation_list_invalidated, group_id, "agent_task", _, _}, state) do
    if group_id == group(state) and is_pid(state.task_owner),
      do: {:noreply, schedule(%{state | tasks_dirty: true})},
      else: {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule(%{refresh: nil} = state),
    do: %{state | refresh: Process.send_after(self(), :refresh, 250)}

  defp schedule(state), do: state

  defp refresh(state) do
    with {:ok, user, session} <- authorized(state),
         {:ok, snapshot} <- Conversations.get(user, session, group(state), state.conversation) do
      state = refresh_tasks(%{state | snapshot: snapshot}, user, session)
      publish(state)
      state
    else
      _ ->
        send(state.ui, {:chat_close, self()})
        state
    end
  end

  defp authorized(state) do
    with {:ok, user, session} <- Accounts.resolve_session(state.token),
         {:ok, _} <- Workspaces.authorize(user, session, state.workspace["id"]) do
      {:ok, user, session}
    end
  end

  defp emit(state, event), do: send(state.ui, {:chat_ui, self(), event})
  defp group(state), do: state.workspace["default_group_id"]

  defp publish(state) do
    lines = transcript(state.snapshot["messages"] || []) ++ participant_lines(state)
    emit(state, {:chat, state.workspace["name"] || "Workspace", lines})
    emit(state, {:task_count, state.task_count})
  end

  defp subscribe_tasks(state, user, session) do
    case Conversations.list_events(user, session, group(state)) do
      {:ok, %{owner_pid: owner}} when is_pid(owner) ->
        Process.monitor(owner)
        %{state | task_owner: owner, tasks_dirty: true}

      _ ->
        state
    end
  end

  defp refresh_tasks(%{tasks_dirty: false} = state, _, _), do: state
  defp refresh_tasks(%{refresh: timer} = state, _, _) when is_reference(timer), do: state

  defp refresh_tasks(state, user, session) do
    # One indexed page per coalesced list invalidation, at most four reads/second per connection.
    count =
      case Conversations.list_page(user, session, group(state), limit: 50) do
        {:ok, page} -> task_count(page)
        _ -> nil
      end

    %{state | task_count: count, tasks_dirty: false}
  end

  def task_count(%{"data" => tasks, "has_more" => more}) do
    %{
      running:
        Enum.count(
          tasks,
          &(&1["kind"] == "agent_task" and
              &1["status"] in ["active", "in_progress", "running", "working"])
        ),
      partial: more
    }
  end

  def transcript(messages) do
    messages
    |> Enum.take(-100)
    |> Enum.reject(&SalixIM.ConversationMessage.internal_delivery?/1)
    |> Enum.flat_map(fn message ->
      label =
        case message["actor_type"] do
          "user" -> {:styled, :cyan, "You"}
          "agent" -> {:styled, :green, "Comma"}
          _ -> "System"
        end

      [label, message_text(message), ""]
    end)
  end

  defp message_text(%{"content" => text}) when is_binary(text), do: bounded(text)

  defp message_text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.take(32)
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> bounded(text)
      _ -> "[Attachment: open in Comma]"
    end)
    |> Enum.join("\n")
    |> bounded()
  end

  defp message_text(%{"text" => text}) when is_binary(text), do: bounded(text)
  defp message_text(_), do: "[Open in Comma]"
  defp bounded(text), do: text |> String.slice(0, 8_000) |> CommaTUI.Text.safe()

  defp participant_lines(state) do
    case Conversations.participant_status(state.context) do
      {:ok, status} ->
        activity = Conversations.public_participant_status(status["activity"], state.context)
        display = if activity, do: [activity["status"]], else: []
        display ++ draft_lines(status["draft"], state.context)

      _ ->
        []
    end
  end

  defp draft_lines(
         %{
           "text" => text,
           "response_key" => response,
           "source_message_ids" => ids,
           "revision" => revision
         },
         context
       )
       when is_binary(text) and is_list(ids) and ids != [] and is_integer(revision) and
              revision > 0 do
    if is_binary(Conversations.visible_reply_response_identity(response)) and
         length(Conversations.canonical_source_message_ids(ids, context)) == length(ids),
       do: [{:styled, :green, "Comma (draft)"}, bounded(text)],
       else: []
  end

  defp draft_lines(_, _), do: []
end
