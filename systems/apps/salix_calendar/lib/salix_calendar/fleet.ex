defmodule SalixCalendar.Fleet do
  @moduledoc "Node-local spawn-on-demand fleet for Calendar owners."
  @behaviour SalixCalendar.Placement

  alias SalixCalendar.{Actor, SourceActor}
  alias SalixStore.Ids

  @start_attempts 5

  @impl true
  def ensure_started(group_id, calendar_id, opts \\ []),
    do:
      ensure(
        Actor,
        Actor.key(group_id, calendar_id),
        opts,
        [group_id: group_id, calendar_id: calendar_id],
        Ids.valid_group_id?(group_id) and Ids.valid_calendar_id?(calendar_id),
        :invalid_calendar_owner_identity
      )

  @impl true
  def ensure_source_started(group_id, calendar_id, source_id, opts \\ []),
    do:
      ensure(
        SourceActor,
        SourceActor.key(group_id, calendar_id, source_id),
        opts,
        [group_id: group_id, calendar_id: calendar_id, source_id: source_id],
        Ids.valid_group_id?(group_id) and Ids.valid_calendar_id?(calendar_id) and
          Ids.valid_calendar_source_id?(source_id),
        :invalid_calendar_source_identity
      )

  defp ensure(module, key, opts, identity, true, _error),
    do: start_or_lookup(key, {module, Keyword.merge(opts, identity)}, @start_attempts)

  defp ensure(_module, _key, _opts, _identity, false, error), do: {:error, error}

  defp start_or_lookup(key, child, attempts) do
    case DynamicSupervisor.start_child(SalixCalendar.FleetSupervisor, child) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, :already_present} when attempts > 0 ->
        case Registry.lookup(SalixCalendar.Registry, key) do
          [{pid, _}] -> {:ok, pid}
          [] -> start_or_lookup(key, child, attempts - 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
