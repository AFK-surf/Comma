defmodule SalixWeb.CORS do
  @moduledoc false
  import Plug.Conn

  @allowed_headers "authorization,content-type"
  @allowed_methods "GET,POST,PATCH,PUT,DELETE,OPTIONS"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = put_cors_headers(conn)

    if conn.method == "OPTIONS" and String.starts_with?(conn.request_path, "/v1/") do
      conn
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end

  defp put_cors_headers(conn) do
    origin =
      conn
      |> get_req_header("origin")
      |> List.first()

    conn
    |> maybe_put_origin(origin)
    |> put_resp_header("access-control-allow-methods", @allowed_methods)
    |> put_resp_header("access-control-allow-headers", @allowed_headers)
    |> put_resp_header("access-control-max-age", "600")
  end

  defp maybe_put_origin(conn, nil), do: conn

  defp maybe_put_origin(conn, origin),
    do: put_resp_header(conn, "access-control-allow-origin", origin)
end
