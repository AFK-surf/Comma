defmodule Salix.Bindings.MeetingPersonalPublication do
  @moduledoc "One bounded personal-notice batch through the Conversation log."

  alias Salix.Bindings.MeetingPublicationReceiver
  alias SalixMeet.{MeetingPlan, PersonalPreparation}
  alias SalixMeet.Ports.PersonalPreparation, as: Provider

  @retry_delay_ms 30_000

  def receive(payload, opts) do
    group_id = payload["group_id"]
    plan_id = payload["meeting_plan_id"]
    opts = Keyword.put(opts, :kind, "personal")

    with {:ok, _due} <- MeetingPlan.card_action(group_id, plan_id, opts),
         {:ok, plan} <- MeetingPlan.get(group_id, plan_id),
         :ok <- MeetingPlan.validate_report(plan),
         discovery = PersonalPreparation.prepare_reminders(plan),
         {:ok, pending} <- PersonalPreparation.pending(plan, opts),
         {:ok, recipients} <- current_recipients(plan, pending, opts),
         :ok <- publish_batch(plan, pending, recipients, opts),
         {:ok, more_attendees} <- discovery,
         {:ok, remains} <- PersonalPreparation.has_pending?(plan) do
      if remains or more_attendees do
        {:ok, :continue}
      else
        with :ok <- MeetingPlan.checkpoint_card_sent(group_id, plan_id, kind: "personal"),
             do: {:ok, :fired}
      end
    else
      {:settle, _} ->
        expire(group_id, plan_id)

      {:error, reason}
      when reason in [
             :stale_dispatch_revision,
             :meeting_plan_inactive,
             :calendar_event_cancelled,
             :calendar_event_changed,
             :calendar_event_not_found
           ] ->
        case MeetingPlan.settle_card(group_id, plan_id, reason, opts) do
          {:settle, _} -> expire(group_id, plan_id)
          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp expire(group_id, plan_id) do
    with {:ok, plan} <- MeetingPlan.get(group_id, plan_id),
         :ok <- PersonalPreparation.expire(plan),
         do: {:ok, :fired}
  end

  defp current_recipients(_plan, [], _opts), do: {:ok, []}

  defp current_recipients(plan, pending, opts) do
    case Provider.current_recipients(plan, pending) do
      {:error, reason} = error ->
        # Delay this page, so the next invocation can serve later recipients.
        Enum.reduce_while(pending, error, fn recipient, original ->
          case defer(plan, recipient, reason, opts) do
            :ok -> {:cont, original}
            {:error, _} = failed -> {:halt, failed}
          end
        end)

      result ->
        result
    end
  end

  defp defer(plan, recipient, reason, opts) do
    retry_at = Keyword.get(opts, :now, System.system_time(:millisecond)) + @retry_delay_ms
    PersonalPreparation.defer(plan, recipient["user_id"], retry_at, reason)
  end

  defp publish_batch(plan, pending, recipients, opts) do
    Enum.reduce(pending, :ok, fn recipient, result ->
      outcome =
        if Enum.any?(
             recipients,
             &(Map.take(&1, ~w(user_id email)) == Map.take(recipient, ~w(user_id email)))
           ) do
          publish_one(plan, recipient, opts)
        else
          PersonalPreparation.settle(plan, recipient["user_id"], "skipped")
        end

      outcome =
        case outcome do
          {:error, reason} = error ->
            case defer(plan, recipient, reason, opts) do
              :ok -> error
              failed -> failed
            end

          :ok ->
            :ok
        end

      case {result, outcome} do
        {:ok, :ok} -> :ok
        {{:error, _}, _} -> result
        {_, {:error, _} = error} -> error
      end
    end)
  end

  defp publish_one(plan, recipient, opts) do
    group_id = plan["group_id"]
    plan_id = plan["meeting_plan_id"]
    connect_id = get_in(plan, ["publication_target", "params", "connect_id"])
    user_id = recipient["user_id"]

    with {:ok, true} <- PersonalPreparation.enabled?(group_id, connect_id, user_id),
         advice = authorized_advice(plan, recipient),
         {:ok, channel} <- Provider.open_dm(plan, recipient),
         :ok <- MeetingPlan.validate_report(plan),
         {:ok, action} <- MeetingPlan.card_action(group_id, plan_id, opts),
         {:ok, :queued} <-
           MeetingPublicationReceiver.queue_notice(group_id, plan_id, %{
             "provider" => "slack",
             "params" => %{"connect_id" => connect_id, "channel" => channel},
             "text" => action["text"] <> advice,
             "not_after_ms" => action["not_after_ms"],
             "idempotency_key" => "calendar-personal:" <> plan_id <> ":" <> user_id
           }) do
      PersonalPreparation.settle(plan, user_id, "queued")
    else
      {:ok, false} ->
        PersonalPreparation.settle(plan, user_id, "skipped")

      {:settle, _} ->
        PersonalPreparation.settle(plan, user_id, "skipped")

      {:error, _} = error ->
        error
    end
  end

  defp authorized_advice(plan, %{"report" => %{"text" => text} = report} = recipient)
       when is_binary(text) and text != "" do
    with :ok <- Provider.authorize_report(plan, recipient, report["sources_label"]),
         :ok <-
           SalixMeet.PreparationSources.authorize_files(plan, Map.get(report, "source_files", [])) do
      "\n\n" <> text
    else
      # Withhold advice whose sources cannot be verified. The meeting's own
      # title, time and entry links remain available to a current attendee.
      {:error, _} -> ""
    end
  end

  defp authorized_advice(_plan, _recipient), do: ""
end
