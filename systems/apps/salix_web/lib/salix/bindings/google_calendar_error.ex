defmodule Salix.Bindings.GoogleCalendarError do
  @moduledoc false

  @rate_limit_reasons ~w(rateLimitExceeded userRateLimitExceeded quotaExceeded)
  @rate_limit_statuses [403, 429]

  @spec from_composio_envelope(map()) :: term()
  def from_composio_envelope(envelope) when is_map(envelope) do
    errors = provider_errors(envelope)
    status = provider_status(envelope, errors)

    reasons =
      errors
      |> Enum.flat_map(fn error -> List.wrap(error["errors"]) end)
      |> Enum.filter(&is_map/1)
      |> Enum.map(&trim(&1["reason"]))
      |> Enum.filter(&(&1 in @rate_limit_reasons))
      |> Enum.uniq()

    cond do
      reasons != [] and (is_nil(status) or status in @rate_limit_statuses) ->
        {:google_calendar_rate_limited, status || 403, reasons}

      is_integer(status) ->
        {:google_calendar_http, status}

      true ->
        :google_calendar_provider_error
    end
  end

  @spec from_http_response(integer(), term()) :: term()
  def from_http_response(status, data) when is_integer(status) do
    from_composio_envelope(%{"status" => status, "data" => data})
  end

  defp provider_errors(envelope) do
    [envelope["error"], get_in(envelope, ["data", "error"])]
    |> Enum.filter(&is_map/1)
  end

  defp provider_status(envelope, errors) do
    ([envelope["status"], get_in(envelope, ["data", "status"])] ++
       Enum.flat_map(errors, fn error -> [error["status"], error["code"]] end))
    |> Enum.find_value(&normalize_status/1)
  end

  defp normalize_status(status) when is_integer(status) and status in 100..599, do: status

  defp normalize_status(status) when is_binary(status) do
    case Integer.parse(status) do
      {parsed, ""} when parsed in 100..599 -> parsed
      _ -> symbolic_status(status)
    end
  end

  defp normalize_status(_status), do: nil

  defp symbolic_status("GONE"), do: 410
  defp symbolic_status("NOT_FOUND"), do: 404
  defp symbolic_status(_status), do: nil

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
