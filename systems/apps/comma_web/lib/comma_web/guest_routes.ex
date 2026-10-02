defmodule CommaWeb.GuestRoutes do
  @moduledoc """
  Fail-closed route allowlist for guest sessions.

  A guest may read its session and profile, bootstrap its Workspace, and use
  its Router chat. Every other product route returns `guest_signup_required`,
  including routes added later.
  """

  @segment "[^/]+"
  @group "^/v1/comma/groups/#{@segment}"
  @conversation "#{@group}/conversations/#{@segment}"

  @allowed [
    {"GET", ~r{^/v1/comma/auth/session$}},
    {"POST", ~r{^/v1/comma/auth/logout$}},
    {"POST", ~r{^/v1/comma/auth/guest/handoff$}},
    {"GET", ~r{^/v1/comma/me/profile$}},
    {"GET", ~r{^/v1/comma/me/avatar/#{@segment}$}},
    {"POST", ~r{^/v1/comma/me/bootstrap$}},
    {"GET", ~r{^/v1/comma/workspaces$}},
    {"GET", ~r{^/v1/comma/workspaces/#{@segment}$}},
    {"POST", ~r{#{@group}/assistant-chat$}},
    {"GET", ~r{#{@group}/files$}},
    {"POST", ~r{#{@group}/files$}},
    {"GET", ~r{#{@group}/conversations$}},
    {"GET", ~r{#{@group}/conversations/(events|search)$}},
    {"GET", ~r{#{@group}/(conversation-pins|task-summaries|task-order|task-labels|proactive)$}},
    {"GET", ~r{#{@conversation}(/(messages|events|preview))?$}},
    {"GET", ~r{#{@conversation}/messages/#{@segment}/(context|attachments/#{@segment})$}},
    {"GET", ~r{#{@conversation}/participants/#{@segment}/history(/events)?$}},
    {"POST", ~r{#{@conversation}/(messages|cancel)$}}
  ]

  @spec allowed?(String.t(), String.t()) :: boolean()
  def allowed?(method, path) when is_binary(method) and is_binary(path) do
    Enum.any?(@allowed, fn {allowed_method, pattern} ->
      method == allowed_method and Regex.match?(pattern, path)
    end)
  end

  @doc "Halts a guest request outside the allowlist."
  @spec enforce(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def enforce(conn, %{"kind" => "guest"}) do
    if allowed?(conn.method, conn.request_path) do
      conn
    else
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(403, Jason.encode!(%{error: "guest_signup_required"}))
      |> Plug.Conn.halt()
    end
  end

  def enforce(conn, _user), do: conn
end
