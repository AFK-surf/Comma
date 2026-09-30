defmodule SalixWeb.RemoteShell do
  @moduledoc "Public launcher and invitation-authorized registration callback."
  import Plug.Conn

  def launcher(conn) do
    conn
    |> put_resp_content_type("text/x-python")
    |> put_resp_header("cache-control", "no-store")
    |> send_file(200, Application.app_dir(:salix_web, "priv/remote-shell/client.py"))
  end

  def register(conn, group_id, request_id) do
    ticket =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> value] -> value
        _ -> ""
      end

    result =
      with {:ok, handle} <- Salix.Control.DriveBindings.handle(group_id) do
        Salix.RemoteShell.Registration.submit(handle, request_id, ticket, conn.body_params)
      end

    {status, body} =
      case result do
        {:ok, value} ->
          {200, value}

        {:error, :registration_conflict} ->
          {409, %{error: "registration_conflict"}}

        {:error, :registration_cancelled} ->
          {410, %{error: "registration_cancelled"}}

        {:error, :registration_expired} ->
          {410, %{error: "registration_expired"}}

        {:error, :registration_store_unavailable} ->
          {503, %{error: "registration_store_unavailable"}}

        {:error, :invalid_registration} ->
          {400, %{error: "invalid_registration"}}

        _ ->
          {403, %{error: "invalid_registration_ticket"}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
  end
end
