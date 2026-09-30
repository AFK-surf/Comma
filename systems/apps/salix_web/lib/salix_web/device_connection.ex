defmodule SalixWeb.DeviceConnection do
  @moduledoc "Public development Connector downloads."
  import Plug.Conn

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
