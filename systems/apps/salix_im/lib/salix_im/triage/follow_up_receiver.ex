defmodule SalixIM.Triage.FollowUpReceiver do
  @moduledoc """
  Shared-Schedule receiver for durable Triage follow-ups.

  `triage_context_entries` remains the product authority. A Schedule carries
  only the entry id and its Slack authority generation. At the due occurrence
  this receiver re-reads that exact thread. Activity is not completion: the
  original Slack message is recorded as a
  typed `scheduled_recheck` receipt and admitted to the existing Runtime. The
  context settlement atomically creates the next one-shot Schedule. An
  evidence-backed evaluator resolution may close the entry through the existing
  product-effect settlement, making that next wakeup inert.

  Receiver ACK and retry are owned by `SalixCluster.Schedules`; this module does
  not own a ticker, queue or retry store.

  Protocol anchor: `tla/salix/TriageFollowUpSchedule.tla` models the exact
  occurrence, fresh decision, idempotent admission, atomic rearm and shared
  receiver ACK boundary.
  """

  alias SalixIM.Ports.TriageFollowUpThreadReader
  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.{ProviderConnects, ProviderReceipts}
  alias SalixStore.{Ids, TriageProductRuntime}

  @slack_ts ~r/\A[0-9]+\.[0-9]{1,6}\z/

  @doc false
  def receive(payload, status, opts) when status in [:claimed, :exists] and is_list(opts) do
    result =
      with {:ok, invocation} <- invocation(payload, opts),
           {:ok, due} <-
             TriageProductRuntime.get_due_follow_up(
               invocation.entry_id,
               invocation.authority_generation,
               invocation.schedule_id,
               invocation.scheduled_for_ms
             ) do
        handle_due(due, invocation)
      else
        {:error, _reason} = error -> error
      end

    normalize_receiver_result(result)
  end

  def receive(_payload, {:error, reason}, _opts), do: {:error, reason}
  def receive(_payload, _status, _opts), do: {:error, :invalid_triage_follow_up_invocation}

  defp handle_due(:stale, _invocation), do: {:ok, :stale}

  defp handle_due(%{payload: payload}, invocation) do
    with {:ok, source} <- source(payload, invocation),
         {:ok, authority} <- current_authority(source),
         {:ok, connect} <- current_connect(source),
         {:ok, page} <- TriageFollowUpThreadReader.read(authority, connect, source.target),
         {:ok, messages} <- messages(page),
         :ok <- verify_authority(authority),
         {:ok, trigger} <- source_trigger(messages, source) do
      admit_recheck(authority, trigger, invocation)
    else
      {:stale, _reason} -> settle(invocation, :stale_authority)
      {:error, _reason} = error -> error
    end
  end

  defp invocation(
         %{
           "entry_id" => entry_id,
           "authority_generation" => authority_generation
         } = payload,
         opts
       ) do
    schedule_id = opts[:schedule_id]
    scheduled_for_ms = opts[:scheduled_for]

    valid? =
      Map.keys(payload) |> Enum.sort() == ~w(authority_generation entry_id) and
        nonblank?(entry_id) and nonblank?(authority_generation) and nonblank?(schedule_id) and
        is_integer(scheduled_for_ms) and scheduled_for_ms >= 0

    if valid? do
      {:ok,
       %{
         entry_id: entry_id,
         authority_generation: authority_generation,
         schedule_id: schedule_id,
         scheduled_for_ms: scheduled_for_ms
       }}
    else
      {:error, :invalid_triage_follow_up_invocation}
    end
  end

  defp invocation(_payload, _opts), do: {:error, :invalid_triage_follow_up_invocation}

  defp source(payload, invocation) do
    target = payload["target"]
    product_identity = payload["product_identity"]
    trigger_message_ts = payload["trigger_message_ts"]

    valid? =
      is_map(target) and is_map(product_identity) and
        target["connect_generation"] == invocation.authority_generation and
        nonblank?(target["connect_id"]) and nonblank?(target["workspace_id"]) and
        nonblank?(target["channel_id"]) and valid_slack_ts?(target["thread_ts"]) and
        valid_slack_ts?(trigger_message_ts) and
        nonblank?(product_identity["project_salix_group_id"])

    if valid? do
      group_id = product_identity["project_salix_group_id"]

      try do
        {:ok,
         %{
           tenant_id: Ids.tenant_id_from_group!(group_id),
           group_id: group_id,
           target: target,
           trigger_message_ts: trigger_message_ts
         }}
      rescue
        _invalid -> {:stale, :invalid_product_identity}
      end
    else
      {:stale, :invalid_follow_up_source}
    end
  end

  defp current_authority(source) do
    case ProviderConnects.get_slack_triage_authority(
           source.tenant_id,
           source.group_id,
           source.target["connect_id"],
           source.target["channel_id"]
         ) do
      {:ok, authority} ->
        if exact_authority?(authority, source),
          do: {:ok, authority},
          else: {:stale, :source_authority_changed}

      {:error, :slack_triage_authority_unavailable} ->
        {:error, :slack_triage_authority_unavailable}

      {:error, _ineligible} ->
        {:stale, :source_authority_changed}
    end
  end

  defp current_connect(source) do
    case ProviderConnects.get_active_connect_by_id(
           source.group_id,
           source.target["connect_id"],
           "slack"
         ) do
      {:ok, connect} -> {:ok, connect}
      {:error, :not_found} -> {:stale, :source_connect_inactive}
      {:error, _reason} -> {:error, :source_connect_unavailable}
    end
  end

  defp exact_authority?(authority, source) do
    authority["connect_id"] == source.target["connect_id"] and
      authority["connect_generation"] == source.target["connect_generation"] and
      authority["workspace_id"] == source.target["workspace_id"] and
      authority["approved_channel_id"] == source.target["channel_id"]
  end

  defp verify_authority(authority) do
    case ProviderConnects.verify_slack_triage_authority(authority) do
      :ok ->
        :ok

      {:error, :slack_triage_authority_unavailable} ->
        {:error, :slack_triage_authority_unavailable}

      {:error, _stale} ->
        {:stale, :source_authority_changed}
    end
  end

  defp messages(%{"messages" => messages}) when is_list(messages), do: {:ok, messages}
  defp messages(_page), do: {:error, :invalid_triage_follow_up_thread}

  defp source_trigger(messages, source) do
    with %{} = trigger <- Enum.find(messages, &(message_ts(&1) == source.trigger_message_ts)),
         {:ok, trigger} <- verified_trigger(trigger, source) do
      {:ok, trigger}
    else
      nil -> {:stale, :source_message_missing}
      {:error, _reason} -> {:error, :invalid_triage_follow_up_thread}
    end
  end

  defp verified_trigger(message, source) do
    verified = %{
      "workspace_id" => source.target["workspace_id"],
      "channel_id" => source.target["channel_id"],
      "root_thread_ts" => source.target["thread_ts"],
      "message_ts" => source.trigger_message_ts,
      "actor_id" => message["actor_id"] || message["user"],
      "actor_kind" => message["actor_kind"],
      "text" => message["text"]
    }

    if Enum.all?(Map.values(verified), &nonblank?/1),
      do: {:ok, verified},
      else: {:error, :invalid_triage_follow_up_source}
  end

  defp admit_recheck(authority, trigger, invocation) do
    occurrence = %{
      "entry_id" => invocation.entry_id,
      "schedule_id" => invocation.schedule_id,
      "scheduled_for_ms" => invocation.scheduled_for_ms
    }

    case TriageProductRuntime.admit_follow_up_wakeup(
           invocation.entry_id,
           invocation.authority_generation,
           invocation.schedule_id,
           invocation.scheduled_for_ms,
           fn -> admit_current_recheck(authority, trigger, occurrence) end
         ) do
      {:ok, :rescheduled} -> {:ok, :admitted}
      {:ok, :stale} -> {:ok, :stale}
      {:stale, _reason} -> settle(invocation, :stale_authority)
      {:error, _reason} = error -> error
    end
  end

  defp admit_current_recheck(authority, trigger, occurrence) do
    scope = route_scope(authority, trigger)

    with {:ok, :triage, claim_identity} <- ThreadRouteOwner.lookup_claim(scope),
         :ok <- verify_authority(authority),
         {:ok, _receipt_status, receipt} <-
           ProviderReceipts.record_slack_triage_recheck(authority, trigger, occurrence),
         {:ok, status} when status in [:accepted, :duplicate] <-
           SalixIM.Triage.accept_current(authority, receipt),
         {:ok, :triage} <- ThreadRouteOwner.verify_claim(scope, :triage, claim_identity) do
      {:ok, receipt["event_id"]}
    else
      {:ok, _owner, _claim_identity} -> {:stale, :source_route_changed}
      {:conflict, _owner} -> {:stale, :source_route_changed}
      :unavailable -> {:error, :slack_route_unavailable}
      {:stale, _reason} = stale -> stale
      :off -> {:error, :triage_runtime_off}
      {:error, _reason} = error -> error
      _invalid -> {:error, :triage_follow_up_admission_failed}
    end
  end

  defp route_scope(authority, trigger) do
    %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "connect_generation" => authority["connect_generation"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => trigger["root_thread_ts"]
    }
  end

  defp settle(invocation, outcome) do
    case TriageProductRuntime.settle_follow_up_wakeup(
           invocation.entry_id,
           invocation.authority_generation,
           invocation.schedule_id,
           invocation.scheduled_for_ms,
           outcome
         ) do
      {:ok, :resolved} -> {:ok, :resolved}
      {:ok, :stopped} -> {:ok, :stopped}
      {:ok, :rescheduled} -> {:ok, :rescheduled}
      {:ok, :stale} -> {:ok, :stale}
      {:error, _reason} = error -> error
    end
  end

  defp message_ts(message), do: message["message_ts"] || message["ts"] || ""

  # Schedule owns execution disposition; context/receipt storage owns the
  # product outcome. Keep the shared receiver vocabulary finite so run_once/1
  # reports every acknowledged follow-up occurrence as an actual firing.
  defp normalize_receiver_result({:ok, _product_outcome}), do: {:ok, :fired}
  defp normalize_receiver_result({:error, _reason} = error), do: error

  defp slack_ts_key(value) when is_binary(value) do
    if Regex.match?(@slack_ts, value) do
      [seconds, fraction] = String.split(value, ".", parts: 2)

      {:ok,
       {String.to_integer(seconds),
        fraction |> String.pad_trailing(6, "0") |> String.to_integer()}}
    else
      {:error, :invalid_slack_timestamp}
    end
  end

  defp slack_ts_key(_value), do: {:error, :invalid_slack_timestamp}
  defp valid_slack_ts?(value), do: match?({:ok, _}, slack_ts_key(value))

  defp nonblank?(value),
    do: is_binary(value) and value != "" and value == String.trim(value)
end
