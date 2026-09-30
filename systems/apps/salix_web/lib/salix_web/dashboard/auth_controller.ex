defmodule SalixWeb.Dashboard.AuthController do
  @moduledoc """
  Admin-token login for the dashboard. `login/2` renders the token form;
  `create/2` validates the pasted token against `SalixWeb.Auth.admin_token/0`
  (constant-time) and, on success, sets the signed-cookie marker and redirects
  to `/dash`; `logout/2` clears the session.
  """
  use SalixWeb.Dashboard, :controller

  alias SalixWeb.Dashboard.Auth

  # The login page is standalone (root document layout only, no sidebar shell).
  plug(:put_layout, html: false)

  def login(conn, _params) do
    if conn.assigns[:admin?] do
      redirect(conn, to: "/dash")
    else
      render(conn, :login, error: nil, page_title: "Sign in")
    end
  end

  def create(conn, %{"token" => token}) do
    if Auth.verify_token(token) do
      conn
      |> Auth.log_in()
      |> put_flash(:info, "Signed in.")
      |> redirect(to: "/dash")
    else
      conn
      |> put_status(:unauthorized)
      |> render(:login, error: "Invalid admin token.", page_title: "Sign in")
    end
  end

  def create(conn, _params),
    do: render(conn, :login, error: "Token required.", page_title: "Sign in")

  def logout(conn, _params) do
    conn
    |> Auth.log_out()
    |> redirect(to: "/dash/login")
  end
end
