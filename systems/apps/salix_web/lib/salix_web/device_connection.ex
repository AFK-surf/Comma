defmodule SalixWeb.DeviceConnection do
  @moduledoc """
  Public Connector installation: the installer script for a Connector token
  and development Connector downloads.
  """
  import Plug.Conn

  def serve(conn, ["install.sh"]) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    {status, script} =
      case SalixEnv.DeviceInstall.install_script(token) do
        {:ok, script} -> {200, script}
        {:error, :unauthorized, script} -> {401, script}
        {:error, :unavailable, script} -> {503, script}
      end

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, script)
  end

  def serve(conn, [platform, "salix-connect"]) do
    case SalixEnv.DeviceInstall.local_artifact_path(platform) do
      {:ok, path} ->
        conn |> put_resp_content_type("application/octet-stream") |> send_file(200, path)

      {:error, _} ->
        send_resp(conn, 404, "Not found")
    end
  end

  def serve(conn, _path), do: send_resp(conn, 404, "Not found")
end
