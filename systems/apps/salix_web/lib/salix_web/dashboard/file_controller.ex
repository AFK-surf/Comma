defmodule SalixWeb.Dashboard.FileController do
  @moduledoc """
  Binary download of an agent VFS file. LiveView can't stream a binary response,
  so the file browser links here and streams through the agent workspace API.
  """
  use SalixWeb.Dashboard, :controller

  alias SalixWeb.Dashboard.Auth
  alias SalixAgent.{Control, Workspace}

  def download(conn, %{"id" => agent_id} = params) do
    path = params["path"] || "/"
    tenant = Auth.current_tenant(get_session(conn))

    # Includes archived agents: downloads are read-only history access.
    with {:ok, _agent} <- Control.get_including_archived(agent_id, tenant),
         {:file, %{"path" => file_path}, stream, _size} <- Workspace.open(agent_id, path) do
      filename = file_path |> String.trim_trailing("/") |> String.split("/") |> List.last()

      conn =
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_chunked(200)

      Enum.reduce_while(stream, conn, fn chunk, conn ->
        case chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    else
      _ -> conn |> put_status(404) |> text("file not found")
    end
  end
end
