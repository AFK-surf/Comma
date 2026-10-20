defmodule Comma.Workers.NativePush do
  @moduledoc "One exact APNs target per job; credentials/content stay outside job arguments."
  use Oban.Worker,
    queue: :comma_notifications,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:args],
      keys: [:target_id, :mode, :conversation_id, :successor],
      states: :incomplete
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"target_id" => id} = args}) do
    result =
      if args["mode"] == "router",
        do: Comma.Notifications.deliver_router(id),
        else: Comma.Notifications.deliver(id, args["conversation_id"])

    case result do
      result when result in [:delivered, :current, :obsolete] ->
        :ok

      {:error, reason}
      when reason in [
             :push_unavailable,
             :apns_rejected,
             :apns_configuration_error,
             :apns_token_environment_mismatch
           ] ->
        {:cancel, reason}

      # Another delivery, or a crashed one until its lease lapses, owns the
      # address. Waiting must not spend the bounded failure attempts.
      {:error, :delivery_busy} ->
        {:snooze, 30}

      # ActivityKit orders payloads by seconds. The successor rereads canonical
      # content instead of sending a second, ambiguously ordered state.
      {:error, :activity_update_busy} ->
        {:snooze, 1}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Comma.Workers.NativePushFanout do
  @moduledoc "Indexed notification-address fanout in pages of 100, never a Task scan."
  use Oban.Worker,
    queue: :comma_notifications,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:args],
      keys: [:group_id, :mode, :conversation_id, :cursor, :successor],
      states: :incomplete
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"group_id" => group, "conversation_id" => task, "cursor" => cursor} = args
      }) do
    mode = args["mode"] || "task"

    page =
      case mode do
        "activity" -> Comma.Notifications.targets_for_activity(group, cursor)
        "router" -> Comma.Notifications.targets_for_router(group, cursor)
        "task" -> Comma.Notifications.targets_for_task(group, task, cursor)
      end

    Enum.reduce_while(page, :ok, fn target, :ok ->
      case Comma.Notifications.insert_wakeup(Comma.Workers.NativePush, %{
             "target_id" => target.id,
             "mode" => mode,
             "conversation_id" => task
           }) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok when length(page) == 100 ->
        continuation =
          case mode do
            "activity" -> Comma.Notifications.enqueue_activity(group, List.last(page).id)
            "router" -> Comma.Notifications.enqueue_router(group, List.last(page).id)
            "task" -> Comma.Notifications.enqueue_task(group, task, List.last(page).id)
          end

        case continuation do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      other ->
        other
    end
  end
end
