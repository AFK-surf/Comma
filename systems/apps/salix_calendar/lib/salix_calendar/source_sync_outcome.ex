defmodule SalixCalendar.SourceSyncOutcome do
  @moduledoc false

  @simple_reasons ~w(timeout unavailable source_operation_timeout)a
  @google_rate_limit_reasons ~w(rateLimitExceeded userRateLimitExceeded quotaExceeded)
  @reason_classes ~w(
    ambiguous
    calendar_item_identity_conflict
    calendar_retirement_budget_exceeded
    calendar_source_contract_mismatch
    calendar_source_member_budget_exceeded
    calendar_source_previous_failure
    closed
    econnrefused
    external_error
    external_locator_conflict
    failed_connect
    incomparable_source_revision
    invalid_adapter_page
    invalid_scheduling_identity
    invalid_source_object_patch
    nxdomain
    retirement_candidate_advanced
    scheduling_identity_conflict
    source_lease_failed
    source_operation_crashed
    source_refresh_budget_exceeded
    source_revision_conflict
    source_sync_advanced
    timeout
    undated_item
    unsupported_recurrence
  )

  @spec failure(term(), integer()) :: map()
  def failure(reason, attempted_at) when is_integer(attempted_at) do
    %{
      "status" => "error",
      "attempted_at" => attempted_at,
      "reason" => encode_reason(reason)
    }
  end

  @spec last_error(map()) :: {:error, term()} | nil
  def last_error(%{"sync" => %{"last_outcome" => %{"status" => "error"} = outcome}}) do
    {:error, decode_reason(outcome["reason"])}
  end

  def last_error(_source), do: nil

  @spec unsettled?(map()) :: boolean()
  def unsettled?(%{"sync" => %{"settlement_pending" => true}}), do: true
  def unsettled?(_source), do: false

  @spec mark_unsettled(map()) :: map()
  def mark_unsettled(sync) when is_map(sync), do: Map.put(sync, "settlement_pending", true)

  @spec clear_unsettled(map()) :: map()
  def clear_unsettled(sync) when is_map(sync), do: Map.delete(sync, "settlement_pending")

  @spec clear_failure(map()) :: map()
  def clear_failure(sync) when is_map(sync), do: Map.delete(sync, "last_outcome")

  @spec retain_failure(map(), map() | nil) :: map()
  def retain_failure(
        next_sync,
        %{
          "last_outcome" => %{
            "status" => "error",
            "attempted_at" => attempted_at,
            "reason" => reason
          }
        }
      )
      when is_map(next_sync) and is_integer(attempted_at) do
    Map.put(next_sync, "last_outcome", failure(decode_reason(reason), attempted_at))
  end

  def retain_failure(next_sync, _previous_sync) when is_map(next_sync), do: next_sync

  @spec retain_state(map(), map() | nil) :: map()
  def retain_state(next_sync, previous_sync) when is_map(next_sync) do
    next_sync
    |> retain_failure(previous_sync)
    |> retain_unsettled(previous_sync)
  end

  defp retain_unsettled(next_sync, %{"settlement_pending" => true}),
    do: mark_unsettled(next_sync)

  defp retain_unsettled(next_sync, _previous_sync), do: next_sync

  defp encode_reason({:google_calendar_rate_limited, status, reasons})
       when is_integer(status) do
    %{
      "kind" => "google_calendar_rate_limited",
      "status" => status,
      "reasons" =>
        reasons
        |> List.wrap()
        |> Enum.filter(&(&1 in @google_rate_limit_reasons))
        |> Enum.uniq()
    }
  end

  defp encode_reason({:google_calendar_http, status}) when is_integer(status),
    do: %{"kind" => "google_calendar_http", "status" => status}

  defp encode_reason({:transport, reason}),
    do: %{"kind" => "transport", "class" => reason_class(reason)}

  defp encode_reason({:calendar_source_previous_failure, class}),
    do: %{"kind" => "other", "class" => safe_class(class)}

  defp encode_reason(reason) when reason in @simple_reasons,
    do: %{"kind" => Atom.to_string(reason)}

  defp encode_reason(reason), do: %{"kind" => "other", "class" => reason_class(reason)}

  defp decode_reason(%{
         "kind" => "google_calendar_rate_limited",
         "status" => status,
         "reasons" => reasons
       })
       when is_integer(status) and is_list(reasons) do
    {:google_calendar_rate_limited, status,
     reasons |> Enum.filter(&(&1 in @google_rate_limit_reasons)) |> Enum.uniq()}
  end

  defp decode_reason(%{"kind" => "google_calendar_http", "status" => status})
       when is_integer(status),
       do: {:google_calendar_http, status}

  defp decode_reason(%{"kind" => "transport", "class" => class}),
    do: {:transport, safe_class(class)}

  defp decode_reason(%{"kind" => "timeout"}), do: :timeout
  defp decode_reason(%{"kind" => "unavailable"}), do: :unavailable
  defp decode_reason(%{"kind" => "source_operation_timeout"}), do: :source_operation_timeout

  defp decode_reason(%{"kind" => "other", "class" => class}),
    do: {:calendar_source_previous_failure, safe_class(class)}

  defp decode_reason(_reason), do: :calendar_source_previous_failure

  defp reason_class({tag, _rest}) when is_atom(tag), do: tag |> Atom.to_string() |> safe_class()

  defp reason_class({tag, _rest, _more}) when is_atom(tag),
    do: tag |> Atom.to_string() |> safe_class()

  defp reason_class(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> safe_class()

  defp reason_class(_reason), do: "external_error"

  defp safe_class(value) when value in @reason_classes, do: value

  defp safe_class(_value), do: "external_error"
end
