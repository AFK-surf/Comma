defmodule SalixCluster.CalendarPlacement do
  @moduledoc "Cluster-aware placement for Calendar owner actors."

  @behaviour SalixCalendar.Placement

  @impl true
  def ensure_started(group_id, calendar_id, opts) do
    owner = SalixCluster.Ring.owner(group_id <> ":calendar:" <> calendar_id)

    if owner == Node.self() do
      SalixCalendar.Fleet.ensure_started(group_id, calendar_id, opts)
    else
      case :erpc.call(
             owner,
             SalixCalendar.Fleet,
             :ensure_started,
             [group_id, calendar_id, opts],
             5_000
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, _} = error -> error
      end
    end
  rescue
    error -> {:error, {:owner_unreachable, error}}
  catch
    :exit, reason -> {:error, {:owner_unreachable, reason}}
  end

  @impl true
  def ensure_source_started(group_id, calendar_id, source_id, opts) do
    owner =
      SalixCluster.Ring.owner(group_id <> ":calendar:" <> calendar_id <> ":source:" <> source_id)

    if owner == Node.self() do
      SalixCalendar.Fleet.ensure_source_started(group_id, calendar_id, source_id, opts)
    else
      case :erpc.call(
             owner,
             SalixCalendar.Fleet,
             :ensure_source_started,
             [group_id, calendar_id, source_id, opts],
             5_000
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, _} = error -> error
      end
    end
  rescue
    error -> {:error, {:owner_unreachable, error}}
  catch
    :exit, reason -> {:error, {:owner_unreachable, reason}}
  end
end
