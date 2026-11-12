defmodule SalixMeet.Ports.Events do
  @moduledoc """
  Product events a meeting publishes to the product's subscribers (Background
  Loops subscribed with `loop.subscribe`).

  `meeting_completed/1` publishes `meeting.completed` once a meeting is done
  and its notes are complete. The event carries only product-generated facts:
  ids, the provider, times and counts. It never carries a title, summary,
  transcript or name: a subscriber reads those with `meeting.get`. `:ok` means
  every subscriber has the event; `{:error, _}` asks the caller to retry, and
  the fixed event_id makes a retry a duplicate.
  """

  require Logger

  @callback publish(group_id :: String.t(), topic :: String.t(), event :: map()) ::
              :ok | {:error, term()}

  @spec meeting_completed(map()) :: :ok | {:error, term()}
  def meeting_completed(state) when is_map(state) do
    with "done" <- text(state["status"]),
         group_id when group_id != "" <- text(state["group_id"]),
         meeting_id when meeting_id != "" <- text(state["meeting_id"]) do
      case impl().publish(group_id, "meeting.completed", completed_event(meeting_id, state)) do
        :ok -> :ok
        {:error, _reason} = error -> error
        other -> {:error, {:unexpected_event_result, other}}
      end
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("meeting.completed publish crashed: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason ->
      Logger.warning("meeting.completed publish exited: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  @doc false
  def completed_event(meeting_id, state) do
    joined_at = state["joined_at"]
    left_at = state["left_at"]

    duration =
      if is_integer(joined_at) and is_integer(left_at) and left_at >= joined_at,
        do: left_at - joined_at

    payload =
      %{
        "meeting_id" => meeting_id,
        "provider" => text(state["provider"]),
        "started_at" => if(is_integer(joined_at), do: joined_at),
        "ended_at" => if(is_integer(left_at), do: left_at),
        "duration_seconds" => duration,
        "participant_count" => participant_count(state),
        "scheduled_start_at" => scheduled(state, "start_at"),
        "scheduled_end_at" => scheduled(state, "end_at")
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    %{"event_id" => "meeting.completed:" <> meeting_id, "payload" => payload}
  end

  # The people the meeting attests, without Salix's own meeting bot. Unknown
  # when the runtime reported none.
  defp participant_count(state) do
    bot = state["bot_name"] |> text() |> String.downcase()

    case state["participants"] do
      names when is_list(names) and names != [] ->
        names
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
        |> Enum.reject(&(&1 == "" or &1 == bot))
        |> Enum.uniq()
        |> length()

      _ ->
        nil
    end
  end

  # Calendar meetings carry the event's scheduled times (unix seconds).
  defp scheduled(%{"source" => %{"kind" => "calendar"}} = state, key) do
    if is_integer(state[key]), do: state[key]
  end

  defp scheduled(_state, _key), do: nil

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""

  defp impl, do: SystemsRuntime.get_env(:salix_meet, :events_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.Events

    @impl true
    def publish(_group_id, _topic, _event), do: :ok
  end
end
