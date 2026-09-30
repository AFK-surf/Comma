defmodule SalixCalendar.MeetingDiagnosticContract do
  @moduledoc """
  Shared bounded vocabulary for Calendar meeting diagnostics.

  Salix normalizes durable meeting state into this vocabulary before publishing
  it, and BFT validates the same vocabulary before deriving public health. This
  keeps rolling producer/consumer versions from maintaining divergent autojoin
  status enums while still failing unknown internal state closed.
  """

  @autojoin_statuses ~w(
    not_started pending scheduled provisioning joining joined running active processing
    done failed abandoned cancelled unavailable
  )
  @autojoin_error_statuses ~w(failed abandoned unavailable)

  @spec autojoin_status(term()) :: String.t()
  def autojoin_status(status) when status in @autojoin_statuses, do: status
  def autojoin_status(_status), do: "unavailable"

  @spec autojoin_status?(term()) :: boolean()
  def autojoin_status?(status), do: status in @autojoin_statuses

  @spec autojoin_error_status?(term()) :: boolean()
  def autojoin_error_status?(status), do: status in @autojoin_error_statuses
end
