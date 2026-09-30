defmodule BridgeForTeamsWeb.HealthControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  @endpoint BridgeForTeamsWeb.DashboardEndpoint
  @opts @endpoint.init([])

  test "standalone health endpoints fail closed when the launcher lifecycle is absent" do
    previous = Application.get_env(:bridge_for_teams_web, :lifecycle_module)
    missing_lifecycle = Module.concat([__MODULE__, MissingLifecycle])
    Application.put_env(:bridge_for_teams_web, :lifecycle_module, missing_lifecycle)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:bridge_for_teams_web, :lifecycle_module)
      else
        Application.put_env(:bridge_for_teams_web, :lifecycle_module, previous)
      end
    end)

    assert call("/live").status == 200
    assert call("/ready").status == 503
    assert call("/health").status == 503
    assert call("/login").status == 200
  end

  defp call(path) do
    :get
    |> conn(path)
    |> @endpoint.call(@opts)
  end
end
