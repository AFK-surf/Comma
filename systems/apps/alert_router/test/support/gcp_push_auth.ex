defmodule AlertRouter.TestGCPPushAuth do
  @moduledoc false

  @behaviour AlertRouter.Web.GCPPushAuth

  @impl true
  def authorize(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer test-google-signed-jwt"] -> :ok
      _ -> {:error, :unauthorized}
    end
  end
end
