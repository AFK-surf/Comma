defmodule SalixWeb.Dashboard.Auth do
  @moduledoc """
  Admin-token authentication for the Salix dashboard.

  There is a single admin identity: the system-wide admin token
  (`SalixWeb.Auth.admin_token/0`, from `:salix_web, :api_token`, normally
  loaded from config.json).
  The login flow validates a pasted token with a constant-time compare and, on
  success, stores a boolean marker (`"admin_authed"`) in the signed session
  cookie — the raw token is NEVER persisted. All dashboard logic runs in-process
  against Salix public app APIs, so no token is needed after login.

  Provides:
    * `fetch_admin/2` — `:browser` pipeline plug assigning `:admin?`
    * `require_admin/2` — plug redirecting anonymous users to `/dash/login`
    * `on_mount/4` — the `:ensure_admin` `live_session` hook
    * `verify_token/1` — constant-time admin-token check (used by the controller)
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Phoenix.LiveView
  alias Salix.Control.Tenants

  @session_key "admin_authed"
  @tenant_session_key "current_tenant"

  @onboarding_path "/dash/tenants"

  @doc "The session key under which the selected tenant id is stored."
  def tenant_session_key, do: @tenant_session_key

  @doc """
  Resolve the active tenant for an authenticated admin: the explicitly-selected
  tenant from the session, else the first existing tenant, else `nil` when no
  tenant exists yet (fresh install — onboarding required). No tenant is ever
  privileged or synthesized.
  """
  @spec current_tenant(map()) :: String.t() | nil
  def current_tenant(session) when is_map(session) do
    session[@tenant_session_key] || first_tenant_id(Tenants.list())
  end

  defp first_tenant_id([%{"tenant_id" => id} | _]), do: id
  defp first_tenant_id(_), do: nil

  # ---- Plugs (browser pipeline) ----

  @doc "Plug: assign :admin? from the signed session cookie."
  @spec fetch_admin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_admin(conn, _opts) do
    assign(conn, :admin?, get_session(conn, @session_key) == true)
  end

  @doc "Plug: redirect to /dash/login unless authenticated."
  @spec require_admin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_admin(conn, _opts) do
    if conn.assigns[:admin?] do
      conn
    else
      conn
      |> put_flash(:error, "Enter the admin token to continue.")
      |> redirect(to: "/dash/login")
      |> halt()
    end
  end

  @doc "Store the authenticated marker in the signed session (after a valid token)."
  @spec log_in(Plug.Conn.t()) :: Plug.Conn.t()
  def log_in(conn) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, true)
  end

  @doc "Clear the dashboard session."
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn), do: configure_session(conn, drop: true)

  @doc """
  Constant-time check of a presented token against the configured admin token.
  Returns false when no admin token is configured (fail closed).
  """
  @spec verify_token(String.t() | nil) :: boolean()
  def verify_token(presented) when is_binary(presented) and presented != "" do
    case SalixWeb.Auth.admin_token() do
      configured when is_binary(configured) and configured != "" ->
        Plug.Crypto.secure_compare(presented, configured)

      _ ->
        false
    end
  end

  def verify_token(_presented), do: false

  @doc "The session key under which the authenticated marker is stored."
  def session_key, do: @session_key

  # ---- LiveView on_mount hook ----

  @doc """
  on_mount `:ensure_admin` — redirect to /dash/login unless authenticated.
  Also assigns the selected tenant scope (`:current_tenant`) and the tenant list
  (`:tenants`) used by the sidebar switcher.

  When no tenant exists yet (fresh install), `:current_tenant` is `nil` and every
  view except the tenants page redirects to onboarding so an admin creates the
  first tenant before doing anything tenant-scoped.
  """
  def on_mount(:ensure_admin, _params, session, socket) do
    cond do
      session[@session_key] != true ->
        {:halt,
         socket
         |> LiveView.put_flash(:error, "Enter the admin token to continue.")
         |> LiveView.redirect(to: "/dash/login")}

      true ->
        tenants = Tenants.list()
        current_tenant = session[@tenant_session_key] || first_tenant_id(tenants)

        if current_tenant == nil and socket.view != SalixWeb.Dashboard.TenantLive.Index do
          {:halt,
           socket
           |> LiveView.put_flash(:info, "Create a tenant to get started.")
           |> LiveView.redirect(to: @onboarding_path)}
        else
          {:cont,
           socket
           |> Phoenix.Component.assign(:admin?, true)
           |> Phoenix.Component.assign(:current_tenant, current_tenant)
           |> Phoenix.Component.assign(:tenants, tenants)}
        end
    end
  end
end
