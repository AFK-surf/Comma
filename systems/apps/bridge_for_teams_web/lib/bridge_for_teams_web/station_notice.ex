defmodule BridgeForTeamsWeb.StationNotice do
  @moduledoc """
  What the dashboard says about a device that cannot take tasks, and how its
  user upgrades it (`SalixStore.StationReadiness`), in the reader's language.
  The Devices page, the agent station picker and refused agent writes share
  these words.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  @doc """
  The notice for a device's capabilities: nil when it takes tasks, else its
  `reason` (`device_needs_station` or `station_outdated`), the `tasks`
  version it reports, the `required_tasks` version and the localized
  `message`.
  """
  @spec for_capabilities(map() | nil) :: map() | nil
  def for_capabilities(capabilities) do
    case SalixStore.StationReadiness.refusal(capabilities) do
      nil -> nil
      refusal -> Map.put(refusal, "message", message(refusal["reason"]))
    end
  end

  @doc "The localized instructions for a reason."
  @spec message(String.t() | atom()) :: String.t()
  def message(reason) when reason in ["device_needs_station", :device_needs_station],
    do:
      gettext(
        "This device runs the old connector, which cannot take tasks. Install the Comma desktop app on it (it includes the station), or install the station with the command from Add station in Comma."
      )

  def message(reason) when reason in ["station_outdated", :station_outdated],
    do:
      gettext(
        "This device's station is too old to take tasks. Update the Comma desktop app, or on a standalone station run `stillfail update` or use its Updates page."
      )
end
