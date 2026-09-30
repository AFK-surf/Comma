defmodule BridgeForTeamsWeb.MacMiniInstallController do
  @moduledoc """
  Public runner onboarding wrapper endpoint.

  The endpoint validates a short-lived install code and returns shell in both
  success and failure cases. It deliberately does not use the browser session or
  CSRF pipeline so customer admins can run the dashboard-generated command from
  a target machine terminal.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  require Logger

  alias BridgeForTeams.MacMiniOnboarding
  alias BridgeForTeamsWeb.MacMiniRelease

  @doc "GET /v1/orgs/:org_id/runners/install.sh?code=..."
  def show(conn, %{"org_id" => org_id} = params) do
    script =
      with :ok <- ensure_https(conn),
           :ok <- reject_runner_install_action(params["action"]),
           {:ok, code} <- fetch_code(params),
           {:ok, release} <- MacMiniRelease.install_release(conn),
           {:ok, consumed} <-
             MacMiniOnboarding.consume_install_code(org_id, code, request_id: request_id(conn)) do
        consumed
        |> Map.put(:release, release)
        |> MacMiniOnboarding.wrapper_script()
      else
        {:error, reason} -> MacMiniOnboarding.error_script(reason)
      end

    conn
    |> put_resp_content_type("text/x-shellscript", "utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, script)
  end

  defp fetch_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp fetch_code(_params), do: {:error, :missing_code}

  defp reject_runner_install_action(nil), do: :ok
  defp reject_runner_install_action(""), do: :ok
  defp reject_runner_install_action(_action), do: {:error, :runner_install_action_removed}

  defp request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [request_id | _] when is_binary(request_id) and request_id != "" ->
        request_id

      _ ->
        case Logger.metadata()[:request_id] do
          value when is_binary(value) and value != "" -> value
          _ -> Ecto.UUID.generate()
        end
    end
  end

  defp ensure_https(conn) do
    cond do
      conn.scheme == :https ->
        :ok

      forwarded_proto(conn) == "https" ->
        :ok

      local_host?(conn.host) ->
        :ok

      true ->
        {:error, :https_required}
    end
  end

  defp forwarded_proto(conn) do
    conn
    |> get_req_header("x-forwarded-proto")
    |> List.first()
    |> to_string()
    |> String.downcase()
  end

  defp local_host?(host), do: host in ["localhost", "127.0.0.1", "::1"]
end
