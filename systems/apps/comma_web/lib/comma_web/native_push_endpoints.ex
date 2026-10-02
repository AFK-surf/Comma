defmodule CommaWeb.NativePushEndpoints do
  @moduledoc false
  import Plug.Conn

  def register(conn, kind) do
    with %{comma_user: user, comma_session: session} <- conn.assigns,
         {:ok, result} <- Comma.Notifications.register(user, session, kind, conn.body_params) do
      json(conn, 200, result)
    else
      {:error, :push_unavailable} -> json(conn, 503, %{error: "push_unavailable"})
      {:error, :forbidden} -> json(conn, 403, %{error: "forbidden"})
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, _} -> json(conn, 422, %{error: "invalid_push_registration"})
      _ -> json(conn, 401, %{error: "unauthorized"})
    end
  end

  def unregister_device(conn) do
    with %{comma_session: session} <- conn.assigns,
         :ok <- Comma.Notifications.unregister_device(session) do
      send_resp(conn, 204, "")
    else
      {:error, :forbidden} -> json(conn, 403, %{error: "forbidden"})
      _ -> json(conn, 401, %{error: "unauthorized"})
    end
  end

  def unregister(conn, id) do
    with %{comma_session: session} <- conn.assigns,
         :ok <- Comma.Notifications.unregister(session, id) do
      send_resp(conn, 204, "")
    else
      _ -> json(conn, 404, %{error: "not_found"})
    end
  end

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
