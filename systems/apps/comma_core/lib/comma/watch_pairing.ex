defmodule Comma.WatchPairing do
  @moduledoc """
  The phone's full Auth Session delegates one short-lived grant to a paired
  Watch (`Comma.SessionPairing`).

  WatchConnectivity carries only the two-minute grant; phone bearer authority
  never crosses this channel.
  """
  alias Comma.SessionPairing

  @purpose "watch_pairing"

  def create(user, session), do: SessionPairing.create(@purpose, user, session)

  def exchange(attrs) when is_map(attrs) do
    case SessionPairing.exchange(@purpose, attrs, fn _grant ->
           {:ok,
            [
              auth_method: "watch_pairing",
              client_kind: "watch",
              client_platform: "watchos",
              device_label: "Comma on Apple Watch"
            ]}
         end) do
      {:error, :invalid_pairing} -> {:error, :invalid_watch_pairing}
      result -> result
    end
  end

  def exchange(_), do: {:error, :invalid_watch_pairing}
end
