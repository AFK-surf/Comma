defmodule CommaWeb.MemberSourceTriggers do
  @moduledoc """
  Provider triggers that tell the member source item pool to read a source now.

  A trigger event is only a signal. The collector still reads the source through
  its official API under the member's current consent, and the pool stores only
  what that read returns. The event data is neither stored nor shown. The
  15-minute collection chain stays the fallback when events stop.
  """

  require Logger
  alias Comma.MemberSourceItems
  alias CommaWeb.MemberSourceIngest

  # Sources whose new items have a Composio trigger. Other sources are read by
  # the collection chain only.
  @slugs %{"gmail" => "GMAIL_NEW_GMAIL_MESSAGE"}

  # A signal reads its source at most once a minute after the previous read:
  # at most 60 signal reads an hour per source. Events in between join the
  # waiting read.
  @spacing_s 60

  @doc """
  Creates the missing trigger of each collected source that has one. Trigger
  events reach Salix only through the configured Composio webhook; without it
  the pool keeps its schedule. A failed creation is tried again at the next
  collection.
  """
  def ensure(workspace, profile_id) do
    with [_ | _] = states <- MemberSourceItems.untriggered(profile_id, Map.keys(@slugs)),
         {:ok, %{"webhook_configured" => true} = settings} <-
           settings().get(workspace["salix_tenant_id"]) do
      Enum.each(states, fn state ->
        case client().upsert_trigger(
               settings,
               workspace["default_group_id"],
               state.source_id,
               @slugs[state.toolkit],
               %{}
             ) do
          {:ok, %{"trigger_id" => id}} when is_binary(id) and id != "" ->
            MemberSourceItems.put_trigger(state, id)

          other ->
            Logger.warning(
              "member_source_trigger unavailable toolkit=#{state.toolkit} " <>
                "reason=#{inspect(other, limit: 3)}"
            )
        end
      end)
    end

    :ok
  end

  @doc """
  Takes a Composio trigger event from the Salix webhook ingress as a signal.
  Schedules one read of each pooled source that the event names, and returns
  how many reads it scheduled.
  """
  def signal(group_id, trigger_id, account_id) do
    now = DateTime.utc_now()

    trigger_id
    |> MemberSourceItems.triggered(account_id, group_id)
    |> Enum.reduce_while({:ok, 0}, fn target, {:ok, count} ->
      at = Enum.max([now, DateTime.add(target.attempted_at, @spacing_s, :second)], DateTime)

      case MemberSourceIngest.enqueue_source(target.profile_id, target.source_id, at) do
        {:ok, _job} -> {:cont, {:ok, count + 1}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp client, do: Application.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)

  defp settings,
    do: Application.get_env(:salix_web, :composio_settings_mod, Salix.Control.ComposioSettings)
end
