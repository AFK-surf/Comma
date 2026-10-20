defmodule SalixStore.StationReadiness do
  @moduledoc """
  Whether a device can take Salix Tasks, read from the `tasks` capability its
  Connector run reports, and how its user upgrades it when it cannot.

  - `tasks` 2: a Comma station that speaks the current Tasks protocol
    (task.invite/put/post/hello): ready.
  - no `tasks`: the device runs the old Go connector (`salix-connect`), which
    runs no Task: `device_needs_station`. Its user installs the Comma desktop
    app (it includes the station) or the standalone station.
  - another `tasks` (1: task.changed/read/post): a station too old for the
    current protocol: `station_outdated`. Its user updates the desktop app, or
    a standalone station with `stillfail update` or its Updates page.

  The reason is structured (`refusal/1`) so pages can say it in their own
  language; `instructions/1` is the English text for agents and APIs.
  """

  @tasks 2

  @type refusal :: %{required(String.t()) => String.t() | integer() | nil}

  @doc "The Tasks protocol version a station must report to take Tasks."
  @spec tasks_version() :: pos_integer()
  def tasks_version, do: @tasks

  @doc """
  `:ready`, or `{:device_needs_station, info}` / `{:station_outdated, info}`
  for a device's capabilities map (the device's `meta.capabilities`, or a
  projected environment's `capabilities`).
  """
  @spec check(map() | nil) ::
          :ready | {:device_needs_station, refusal()} | {:station_outdated, refusal()}
  def check(capabilities) do
    case tasks(capabilities) do
      @tasks -> :ready
      nil -> {:device_needs_station, info("device_needs_station", nil)}
      older -> {:station_outdated, info("station_outdated", older)}
    end
  end

  @doc "The structured reason a device cannot take Tasks, or nil when it can."
  @spec refusal(map() | nil) :: refusal() | nil
  def refusal(capabilities) do
    case check(capabilities) do
      :ready -> nil
      {_reason, info} -> info
    end
  end

  @doc "What the user does, in English, for a reason from `check/1`."
  @spec instructions(:device_needs_station | :station_outdated | String.t()) :: String.t()
  def instructions(reason) when reason in [:device_needs_station, "device_needs_station"],
    do:
      "This device runs the old connector, which cannot take Tasks. " <>
        "Install the Comma desktop app on it (it includes the station), " <>
        "or install the station with the command from Add station in Comma."

  def instructions(reason) when reason in [:station_outdated, "station_outdated"],
    do:
      "This device's station is too old to take Tasks. " <>
        "Update the Comma desktop app, or on a standalone station " <>
        "run `stillfail update` or use its Updates page."

  defp info(reason, tasks),
    do: %{"reason" => reason, "tasks" => tasks, "required_tasks" => @tasks}

  defp tasks(%{"tasks" => tasks}), do: tasks
  defp tasks(%{tasks: tasks}), do: tasks
  defp tasks(_capabilities), do: nil
end
