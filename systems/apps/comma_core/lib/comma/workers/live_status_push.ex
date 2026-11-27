defmodule Comma.Workers.LiveStatusPush do
  @moduledoc "One exact `live_status_v1` APNs target per job; credentials and content stay outside job args."
  use Oban.Worker,
    queue: :comma_notifications,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:args],
      keys: [:target_id, :live_key, :successor],
      states: :incomplete
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"target_id" => id} = args}) do
    case Comma.LiveStatuses.deliver(id, args["live_key"]) do
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

      {:error, :activity_update_busy} ->
        {:snooze, 1}

      {:error, :delivery_busy} ->
        {:snooze, 2}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Comma.Workers.LiveStatusPushFanout do
  @moduledoc "Indexed `live_status_v1` target fanout in pages of 100."
  use Oban.Worker,
    queue: :comma_notifications,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:args],
      keys: [:group_id, :live_key, :cursor, :expires_at_unix, :successor],
      states: :incomplete
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"group_id" => group_id, "live_key" => live_key, "cursor" => cursor} = args
      }) do
    if Map.has_key?(args, "expires_at_unix") and is_nil(cursor) do
      Comma.LiveStatuses.prune_old_statuses(group_id)
    end

    page = Comma.LiveStatuses.targets_for_key(group_id, live_key, cursor)

    Enum.reduce_while(page, :ok, fn target, :ok ->
      job_live_key = if target.kind == "push_to_start", do: nil, else: live_key

      case Comma.Notifications.insert_wakeup(Comma.Workers.LiveStatusPush, %{
             "target_id" => target.id,
             "live_key" => job_live_key
           }) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok when length(page) == 100 ->
        case Comma.LiveStatuses.enqueue_group(group_id, live_key, List.last(page).id) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      other ->
        other
    end
  end
end
