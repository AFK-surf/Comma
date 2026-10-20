defmodule CommaWeb.Stations.Directory do
  @moduledoc """
  Read port for the stations of a Salix Group (the Group is the workspace).

  The station control plane owns station enrollment and removal
  (`SalixStore.Stations`). Station tools read it only through this port, so
  they never write station state.

  `list_group_stations/2` returns the Group's non-removed stations as
  string-keyed maps with at least `"id"` (lower-case hex station id) and
  `"name"`; `"online"`, `"version"` and `"enrolled_by"` (the enrolling user id) are optional.

  Configure with `config :comma_web, :station_directory, Module`. The
  application installs `CommaWeb.Stations.GroupDirectory` (the control
  plane's rows) unless one is configured; the fallback
  `CommaWeb.Stations.Directory.Unavailable` reports
  `:station_directory_unavailable`, so station tools fail closed.
  """

  @callback list_group_stations(tenant_id :: String.t(), group_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @spec list_group_stations(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_group_stations(tenant_id, group_id),
    do: impl().list_group_stations(tenant_id, group_id)

  defp impl, do: SystemsRuntime.get_env(:comma_web, :station_directory, __MODULE__.Unavailable)

  defmodule Unavailable do
    @moduledoc "Default until the station control plane is installed."
    @behaviour CommaWeb.Stations.Directory

    @impl true
    def list_group_stations(_tenant_id, _group_id), do: {:error, :station_directory_unavailable}
  end
end
