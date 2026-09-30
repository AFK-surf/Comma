defmodule BridgeForTeamsWeb.HealthController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  def live(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def ready(conn, _params) do
    lifecycle =
      Application.get_env(
        :bridge_for_teams_web,
        :lifecycle_module,
        Module.concat([Comma, PodLifecycle])
      )

    result =
      if Code.ensure_loaded?(lifecycle) and function_exported?(lifecycle, :ready, 1) do
        apply(lifecycle, :ready, [:bridge_for_teams])
      else
        {:error, :lifecycle_unavailable}
      end

    case result do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "not_ready", reason: reason})
    end
  end
end
