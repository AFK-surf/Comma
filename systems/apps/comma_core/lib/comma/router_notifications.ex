defmodule Comma.RouterNotifications.MessagePosition do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "comma_router_notification_messages" do
    field(:workspace_id, :string, primary_key: true)
    field(:seq, :integer, primary_key: true)
    field(:message_id, :string)
    field(:ordinal, :integer)
  end
end

defmodule Comma.RouterNotifications do
  @moduledoc "The Workspace owner's Router read position and bounded unread projection."
  import Ecto.Query
  alias Comma.{Accounts, Conversations, Repo, Workspaces}
  alias Comma.Data.Workspace
  alias Comma.RouterNotifications.MessagePosition
  @page 100

  def snapshot(user, session, group_id) do
    with :ok <- unrestricted(session),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id) do
      reconcile(workspace)
    end
  end

  # Each call reads at most one page of new canonical Messages. A queued
  # continuation owns larger backlogs, independent of phone/target cardinality.
  # The projection worker passes continue?: false and snoozes itself instead,
  # so one backlog page never has a second job racing on commit_page.
  def reconcile(workspace, opts \\ []) do
    started = SystemsClock.monotonic_time()
    result = do_reconcile(workspace, Keyword.get(opts, :continue?, true))

    CommaProduct.Telemetry.emit_operation(
      :router_notification_projection,
      if(match?({:ok, _}, result), do: :ok, else: :error),
      SystemsClock.monotonic_time() - started
    )

    result
  end

  defp do_reconcile(workspace, continue?) do
    with {:ok, workspace} <- current_scope(workspace),
         %Workspace{} = stored <- Repo.get(Workspace, workspace["id"]),
         {:ok, state} <- read_page(workspace, stored.router_notification_state || %{}),
         {:ok, committed} <-
           commit_changes(workspace, stored.router_notification_state || %{}, state) do
      if committed["pending"] do
        if continue?, do: enqueue(workspace["id"])
        {:error, :router_notifications_pending}
      else
        {:ok, public(committed)}
      end
    else
      nil ->
        {:error, :not_found}

      {:error, :projection_changed} ->
        if continue?, do: enqueue(workspace["id"])
        {:error, :router_notifications_pending}

      error ->
        error
    end
  end

  @doc "The last committed public position, without a canonical read or row lock."
  def stored(workspace_id) do
    Repo.one(
      from(w in Workspace, where: w.id == ^workspace_id, select: w.router_notification_state)
    )
    |> Kernel.||(%{})
    |> public()
  end

  def read(user, session, group_id, message_id) when is_binary(message_id) do
    with :ok <- unrestricted(session),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, snapshot} <- reconcile(workspace),
         id when is_binary(id) <- snapshot["conversation_id"],
         {:ok, messages} <- Conversations.message_context(user, session, group_id, id, message_id),
         %{"seq" => seq} when is_integer(seq) and seq > 0 <-
           Enum.find(messages, &(&1["message_id"] == message_id)),
         {:ok, current_user, session} <- Accounts.resolve_session_id(session["id"]),
         true <- current_user["id"] == user["id"],
         :ok <- unrestricted(session),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, result} <- commit_read(workspace, id, seq) do
      Comma.Notifications.enqueue_router(group_id)
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def read(_, _, _, _), do: {:error, {:bad_request, "message_id is required"}}

  def enqueue(workspace_id) do
    Comma.Notifications.insert_wakeup(Comma.Workers.RouterNotificationProjection, %{
      "workspace_id" => workspace_id
    })
  end

  defp current_scope(workspace) do
    with {:ok, current} <-
           Workspaces.authorize_group_owner(
             workspace["id"],
             workspace["default_group_id"],
             workspace["owner_user_id"]
           ),
         {:ok, resolved} <- Comma.Salix.Client.impl().resolve_workspace_scope(current) do
      {:ok, resolved}
    end
  end

  defp read_page(workspace, state) do
    id = workspace["router_conversation_id"]

    cond do
      not is_binary(id) and is_binary(state["conversation_id"]) ->
        {:error, :router_notification_scope_changed}

      not is_binary(id) ->
        {:ok, %{state: initial(nil, 0), messages: []}}

      state["conversation_id"] not in [nil, id] ->
        {:error, :router_notification_scope_changed}

      true ->
        read_router_page(workspace, id, state)
    end
  end

  defp read_router_page(workspace, id, state) do
    client = Comma.Salix.Client.impl()

    with {:ok, tail} <- client.list_group_conversation_message_page(workspace, id, limit: 1) do
      tail_seq = get_in(tail, ["bounds", "tail_seq"]) || 0
      head_seq = get_in(tail, ["bounds", "head_seq"]) || 1

      cond do
        state == %{} ->
          {:ok, %{state: initial(id, tail_seq), messages: []}}

        (state["observed_seq"] || 0) >= tail_seq ->
          {:ok, %{state: Map.put(state, "conversation_id", id), messages: []}}

        (state["observed_seq"] || 0) > 0 and state["observed_seq"] < head_seq - 1 ->
          {:error, :router_notification_history_gap}

        true ->
          position =
            if (state["observed_seq"] || 0) < head_seq,
              do: [around: head_seq],
              else: [after: state["observed_seq"]]

          with {:ok, page} <-
                 client.list_group_conversation_message_page(
                   workspace,
                   id,
                   position ++ [limit: @page]
                 ) do
            messages = page["messages"] || []

            covered =
              get_in(page, ["covered", "last_seq"]) ||
                Enum.reduce(messages, state["observed_seq"] || 0, &max(&1["seq"] || 0, &2))

            current_tail = max(tail_seq, get_in(page, ["bounds", "tail_seq"]) || tail_seq)

            if covered <= (state["observed_seq"] || 0) or covered < head_seq do
              {:error, :router_notification_history_gap}
            else
              next =
                Map.put(state, "conversation_id", id)
                |> Map.put("observed_seq", covered)
                |> Map.put("pending", covered < current_tail)

              {:ok,
               %{state: next, messages: Enum.filter(messages, &router_reply?(&1, workspace))}}
            end
          end
      end
    end
  end

  defp initial(id, seq),
    do: %{
      "conversation_id" => id,
      "observed_seq" => seq,
      "read_seq" => seq,
      "total_count" => 0,
      "read_count" => 0,
      "latest_seq" => 0,
      "latest_message_id" => nil,
      "pending" => false
    }

  # These are committed public Router replies. Tool/draft/hidden input cannot
  # create a notification. The canonical provider.message receipt is also a
  # visible Router reply: its writer permits only the Group Router's sends,
  # and the Conversation owner deduplicates receipt retries before append.
  def router_reply?(message, workspace) do
    is_integer(message["seq"]) and message["seq"] > 0 and is_binary(message["message_id"]) and
      message["visibility"] not in ["hidden", "private"] and
      not is_map(message["agent_input"]) and router_content?(message, workspace)
  end

  defp router_content?(%{"actor_type" => "agent"} = message, workspace),
    do:
      message["agent_id"] == workspace["router_agent_id"] and visible_content?(message["content"])

  defp router_content?(
         %{
           "actor_type" => "system",
           "kind" => "app_event",
           "metadata" => %{"event_type" => "provider.message"},
           "platform_message" => %{"role" => "assistant", "content" => content}
         },
         _workspace
       ),
       do: visible_content?(content)

  defp router_content?(_, _), do: false

  defp visible_content?(text) when is_binary(text), do: String.trim(text) != ""

  defp visible_content?(blocks) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{"type" => "text", "text" => text} when is_binary(text) -> String.trim(text) != ""
      %{"type" => type} when type in ~w(image file audio video dynamic_ui task) -> true
      _ -> false
    end)
  end

  defp visible_content?(_), do: false

  # An unchanged position needs no Workspace row lock: callers include every
  # push, registration and badge read, which would otherwise contend per device.
  defp commit_changes(_workspace, expected, %{state: expected, messages: []}), do: {:ok, expected}
  defp commit_changes(workspace, expected, page), do: commit_page(workspace, expected, page)

  defp commit_page(workspace, expected, %{state: next, messages: messages}) do
    Repo.transaction(fn ->
      row = locked_workspace(workspace)
      if row.router_notification_state != expected, do: Repo.rollback(:projection_changed)

      {next, positions} =
        Enum.reduce(messages, {next, []}, fn message, {state, entries} ->
          ordinal = state["total_count"] + 1

          state =
            state
            |> Map.put("total_count", ordinal)
            |> Map.put("latest_seq", message["seq"])
            |> Map.put("latest_message_id", message["message_id"])

          {state,
           [
             %{
               workspace_id: row.id,
               seq: message["seq"],
               message_id: message["message_id"],
               ordinal: ordinal
             }
             | entries
           ]}
        end)

      if positions != [], do: Repo.insert_all(MessagePosition, positions)

      Repo.update_all(from(w in Workspace, where: w.id == ^row.id),
        set: [router_notification_state: next]
      )

      next
    end)
  end

  defp commit_read(workspace, id, seq) do
    Repo.transaction(fn ->
      row = locked_workspace(workspace)
      state = row.router_notification_state

      cond do
        state["conversation_id"] != id ->
          Repo.rollback(:not_found)

        seq > state["observed_seq"] ->
          Repo.rollback(:router_notifications_pending)

        seq <= state["read_seq"] ->
          public(state)

        true ->
          ordinal =
            Repo.one(
              from(p in MessagePosition,
                where: p.workspace_id == ^row.id and p.seq <= ^seq,
                order_by: [desc: p.seq],
                limit: 1,
                select: p.ordinal
              )
            ) || state["read_count"]

          state = state |> Map.put("read_seq", seq) |> Map.put("read_count", ordinal)

          Repo.update_all(from(w in Workspace, where: w.id == ^row.id),
            set: [router_notification_state: state]
          )

          Repo.delete_all(
            from(p in MessagePosition,
              where: p.workspace_id == ^row.id and p.seq <= ^seq
            )
          )

          public(state)
      end
    end)
  end

  defp locked_workspace(workspace) do
    case Repo.one(
           from(w in Workspace,
             where:
               w.id == ^workspace["id"] and
                 w.owner_user_id == ^workspace["owner_user_id"] and
                 w.salix_group_id == ^workspace["default_group_id"] and w.status == "active",
             lock: "FOR UPDATE"
           )
         ) do
      nil -> Repo.rollback(:not_found)
      row -> row
    end
  end

  defp public(state),
    do: %{
      "conversation_id" => state["conversation_id"],
      "unread_count" => max((state["total_count"] || 0) - (state["read_count"] || 0), 0),
      "latest_message_id" => state["latest_message_id"],
      "latest_seq" => state["latest_seq"] || 0
    }

  defp unrestricted(%{"restricted" => false, "session_source" => "user_login"}), do: :ok
  defp unrestricted(_), do: {:error, :forbidden}
end

defmodule Comma.Workers.RouterNotificationProjection do
  @moduledoc "One canonical Router page per job turn, with no Message content in arguments."
  use Oban.Worker,
    queue: :comma_notifications,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:args],
      states: :incomplete
    ]

  @impl true
  def perform(%Oban.Job{args: %{"workspace_id" => id}}) do
    with {:ok, workspace} <- Comma.Workspaces.get(id),
         {:ok, _} <- Comma.RouterNotifications.reconcile(workspace, continue?: false) do
      Comma.Notifications.enqueue_router(workspace["default_group_id"])
      :ok
    else
      {:error, :router_notifications_pending} -> {:snooze, 1}
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
