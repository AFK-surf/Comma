defmodule SalixWeb.Dashboard.TenantController do
  @moduledoc """
  Sets the active tenant scope in the signed session, then redirects back.

  LiveView can't write the session cookie, so the sidebar switcher links here
  (`/dash/tenant/select?tenant_id=...`). On return, every authenticated LiveView's
  `on_mount` reads `current_tenant` and scopes control-plane calls to it.
  """
  use SalixWeb.Dashboard, :controller

  alias SalixWeb.Dashboard.Auth

  def select(conn, %{"tenant_id" => tenant_id}) when is_binary(tenant_id) and tenant_id != "" do
    conn
    |> put_session(Auth.tenant_session_key(), tenant_id)
    |> redirect(to: command_scope_return(return_to(conn)))
  end

  def select(conn, _params), do: redirect(conn, to: "/dash/agents")

  defp command_scope_return(path) do
    if String.starts_with?(path, "/dash/slack-") or
         Regex.match?(~r{^/dash/groups/[^/]+/slack/[^/]+/commands}, path),
       do: "/dash/slack-commands",
       else: path
  end

  # Prefer the page the switch was triggered from (same-host referer); fall back
  # to the agents list. Detail pages for a tenant that no longer owns a resource
  # gracefully redirect to their list on mount.
  defp return_to(conn) do
    case get_req_header(conn, "referer") do
      [ref | _] when is_binary(ref) -> safe_path(ref)
      _ -> "/dash/agents"
    end
  end

  defp safe_path(ref) do
    case URI.parse(ref) do
      %URI{path: "/dash" <> _ = path} = uri ->
        if uri.query, do: path <> "?" <> uri.query, else: path

      _ ->
        "/dash/agents"
    end
  end
end
