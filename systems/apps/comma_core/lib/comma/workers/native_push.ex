defmodule Comma.Workers.NativePush do
  @moduledoc "One exact APNs target per job; credentials/content stay outside job arguments."
  use Oban.Worker, queue: :comma_notifications, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"target_id" => id, "conversation_id" => task}}) do
    case Comma.Notifications.deliver(id, task) do
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

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Comma.Workers.NativePushFanout do
  @moduledoc "Indexed notification-address fanout in pages of 100, never a Task scan."
  use Oban.Worker, queue: :comma_notifications, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"group_id" => group, "conversation_id" => task, "cursor" => cursor}
      }) do
    page = Comma.Notifications.targets_for_task(group, task, cursor)

    Enum.reduce_while(page, :ok, fn target, :ok ->
      case Comma.Notifications.enqueue(target.id, task) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok when length(page) == 100 ->
        case Comma.Notifications.enqueue_task(group, task, List.last(page).id) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      other ->
        other
    end
  end
end
