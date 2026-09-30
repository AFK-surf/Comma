defmodule SalixIM.Migrations.ConversationDeliveryParticipantFields do
  @moduledoc """
  Normalize legacy delivery fields through the exact participant owner.

  The migration owns only legacy-record discovery and field normalization.
  Delivery CAS, indexes, attempts, and participant events remain the single
  implementation in `ConversationParticipantActor`.
  """

  alias SalixIM.{ConversationFleet, ConversationServer}
  alias SalixStore.{Ids, Keys, S3}

  @delivery_state_re ~r|/participants/[^/]+/deliveries/[^/]+/state\.json$|
  @scan_page_size 200

  @type stats :: %{
          migrated: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @spec run() ::
          {:ok, stats()}
          | {:error, {:conversation_delivery_participant_fields_failed, stats()}}
          | {:error, term()}
  def run do
    with {:ok, stats} <- migrate_pages(nil, zero_stats()) do
      CommaLog.log("migrate_conversation_delivery_participant_fields", stats)

      if stats.failed == 0,
        do: {:ok, stats},
        else: {:error, {:conversation_delivery_participant_fields_failed, stats}}
    end
  end

  defp migrate_pages(token, stats) do
    opts =
      if is_binary(token),
        do: [max_keys: @scan_page_size, continuation_token: token],
        else: [max_keys: @scan_page_size]

    case S3.list(Keys.ctl_group_conversations_prefix(), opts) do
      {:ok, %{objects: objects, next: next}} ->
        stats =
          objects
          |> Enum.map(& &1.key)
          |> Enum.filter(&Regex.match?(@delivery_state_re, &1))
          |> Enum.reduce(stats, &migrate_key/2)

        if is_binary(next) and next != "",
          do: migrate_pages(next, stats),
          else: {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp migrate_key(key, stats) do
    case migrate_delivery(key) do
      :migrated -> Map.update!(stats, :migrated, &(&1 + 1))
      :skipped -> Map.update!(stats, :skipped, &(&1 + 1))
      {:error, _reason} -> Map.update!(stats, :failed, &(&1 + 1))
    end
  end

  defp migrate_delivery(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, rec} when is_map(rec) <- Jason.decode(body),
         {:ok, fields} <- delivery_fields(rec),
         ^key <-
           Keys.ctl_group_conversation_participant_delivery_state(
             fields.group_id,
             fields.conversation_id,
             fields.participant_id,
             fields.delivery_id
           ),
         {:ok, _pid} <-
           ConversationFleet.ensure_started(
             fields.group_id,
             fields.conversation_id,
             wake_on_recovery: false
           ) do
      if old_target_record?(rec) do
        ConversationServer.migrate_legacy_group_conversation_delivery_participant_fields(
          fields.group_id,
          fields.conversation_id,
          fields.participant_id,
          fields.delivery_id
        )
      else
        :skipped
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_delivery_identity}
    end
  end

  defp delivery_fields(rec) do
    fields = %{
      group_id: rec["agent_group_id"],
      conversation_id: rec["conversation_id"],
      participant_id: rec["participant_id"] || rec["target_participant_id"],
      delivery_id: rec["delivery_id"]
    }

    if Ids.valid_group_id?(fields.group_id) and
         Ids.valid_conversation_id?(fields.conversation_id) and
         Ids.valid_participant_id?(fields.participant_id) and
         is_binary(fields.delivery_id) and fields.delivery_id != "",
       do: {:ok, fields},
       else: {:error, :invalid_delivery_identity}
  end

  defp old_target_record?(rec) do
    Enum.any?(
      ~w(target_participant_id target_agent_id target_role_label target_session_id target_provider target_connect_id target_channel_id target_thread_ts target_session_name target_billing_context),
      &Map.has_key?(rec, &1)
    )
  end

  defp zero_stats, do: %{migrated: 0, skipped: 0, failed: 0}
end
