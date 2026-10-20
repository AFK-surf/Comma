defmodule CommaWeb.NativeNotificationStateEndpoints do
  @moduledoc false
  import Plug.Conn

  def activity(conn, group_id) do
    authorized(conn, &Comma.Conversations.activity_tasks(&1, &2, group_id))
  end

  def router(conn, group_id) do
    authorized(conn, &Comma.RouterNotifications.snapshot(&1, &2, group_id))
  end

  def read(conn, group_id) do
    authorized(
      conn,
      &Comma.RouterNotifications.read(&1, &2, group_id, conn.body_params["message_id"])
    )
  end

  defp authorized(conn, action) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} -> respond(conn, action.(user, session))
      _ -> json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp respond(conn, {:ok, body}), do: json(conn, 200, body)
  defp respond(conn, {:error, :forbidden}), do: json(conn, 403, %{error: "forbidden"})
  defp respond(conn, {:error, reason}) when reason in [:revoked, :expired, :invalid_token, :disabled],
    do: json(conn, 401, %{error: "unauthorized"})
  defp respond(conn, {:error, :not_found}), do: json(conn, 404, %{error: "not_found"})

  defp respond(conn, {:error, {:bad_request, message}}),
    do: json(conn, 400, %{error: "bad_request", message: message})

  defp respond(conn, {:error, reason})
       when reason in [:activity_projection_pending, :router_notifications_pending] do
    conn |> put_resp_header("retry-after", "1") |> json(503, %{error: Atom.to_string(reason)})
  end

  defp respond(conn, {:error, reason})
       when reason in [:router_notification_scope_changed, :router_notification_history_gap],
       do: json(conn, 409, %{error: Atom.to_string(reason)})

  defp respond(conn, {:error, _}), do: json(conn, 503, %{error: "notification_state_unavailable"})

  defp json(conn, status, body),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
end
