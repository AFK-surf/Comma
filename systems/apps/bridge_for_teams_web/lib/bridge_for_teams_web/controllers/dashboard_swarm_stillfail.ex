defmodule BridgeForTeamsWeb.DashboardSwarmStillfail do
  @moduledoc """
  The Agent Swarm still.fail page for `DashboardAPIController`: the swarm's
  still.fail stations (`SalixEnv.StillfailDevices`), what still.fail's agents
  spent by person in the last 30 days, a new station's line to connect with,
  and removing them.

  The page reads Salix through the client (`stillfail_stations/1`,
  `station_usage/5`), two bounded queries of the swarm's Group. Every swarm
  member reads it; making a line and removing the stations are for swarm
  admins. A line is shown once, at the answer that made it.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.Salix.Client

  @source "stillfail"
  @days 30

  @doc "The page."
  def page(_org, _user, project, role) do
    today = SystemsClock.utc_now() |> DateTime.to_date()
    from = today |> Date.add(-(@days - 1)) |> Date.to_iso8601()

    with {:ok, stations} <- call(:stillfail_stations, [project.salix_group_id]),
         {:ok, usage} <-
           call(:station_usage, [
             project.salix_group_id,
             from,
             Date.to_iso8601(today),
             :person,
             @source
           ]) do
      {:ok,
       %{
         "project" => %{"id" => project.id, "name" => project.name, "role" => role},
         "days" => @days,
         "stations" => stations,
         "usage" => usage
       }}
    end
  end

  @doc "A new still.fail station's line, `comma <server> <token>` (swarm admins only)."
  def connect(org, _user, project, role, _params) do
    with :ok <- admin(role),
         {:ok, line} <-
           call(:stillfail_connect_line, [org.salix_tenant_id, project.salix_group_id]) do
      {:ok, %{"line" => line}}
    end
  end

  @doc "Removes the swarm's still.fail stations and what they sent (swarm admins only)."
  def disconnect(_org, _user, project, role) do
    with :ok <- admin(role),
         {:ok, _removed} <- call(:remove_stillfail_stations, [project.salix_group_id]) do
      {:ok, %{"notice" => gettext("This Agent Swarm no longer has still.fail stations.")}}
    end
  end

  defp call(fun, args) do
    case Client.call_optional(fun, args) do
      {:ok, value} ->
        {:ok, value}

      {:error, :unsupported} ->
        {:error, 503, "unavailable", gettext("Salix cannot answer this yet."), %{}}

      {:error, reason} ->
        {:error, 503, "unavailable",
         gettext("Salix did not answer: %{reason}", reason: inspect(reason)), %{}}
    end
  end

  defp admin("admin"), do: :ok

  defp admin(_role),
    do: {:error, 403, "forbidden", gettext("Only Agent Swarm admins can change this."), %{}}
end
