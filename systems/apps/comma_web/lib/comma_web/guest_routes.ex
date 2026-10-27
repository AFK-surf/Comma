defmodule CommaWeb.GuestRoutes do
  @moduledoc """
  Fail-closed route allowlist for guest sessions.

  A guest may read its session and profile, bootstrap its Workspace, and use
  its Router chat. Every other product route returns `guest_signup_required`,
  including routes added later.

  A guest may also run a Mini App shared by link (design §7.5): the link
  reads, and the app runtime routes only with `x-comma-app-via: link/<token>`.
  A guest cannot list, create, install or remix apps.
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
    {"POST", ~r{#{@conversation}/(messages|cancel)$}},
    {"GET", ~r{^/v1/comma/apps/links/#{@segment}(/bundle)?$}}
  ]

  @app "^/v1/comma/apps/#{@segment}"

  # Runtime routes of an app, allowed only through a link.
  @link_app_routes [
    {"POST", ~r{#{@app}/open$}},
    {"POST", ~r{#{@app}/backend(/.*)?$}},
    {"GET", ~r{#{@app}/storage/#{@segment}(/.+)?$}},
    {"PUT", ~r{#{@app}/storage/#{@segment}/.+$}},
    {"DELETE", ~r{#{@app}/storage/#{@segment}/.+$}},
    {"POST", ~r{#{@app}/ai/chat$}},
    {"POST", ~r{#{@app}/ai/decide$}},
    {"POST", ~r{#{@app}/web/search$}},
    {"GET", ~r{#{@app}/icon$}},
    # The app answers `unsupported`: a guest has no Drive.
    {"GET", ~r{#{@app}/drive(/file)?$}},
    {"PUT", ~r{#{@app}/drive/file$}},
    {"DELETE", ~r{#{@app}/drive/file$}}
  ]

  @doc "Whether a guest may make this runtime call: an app route reached through a link."
  @spec link_app_call?(String.t(), String.t(), String.t() | nil) :: boolean()
  def link_app_call?(method, path, via) when is_binary(via) do
    String.starts_with?(via, "link/") and
      Enum.any?(@link_app_routes, fn {allowed_method, pattern} ->
        method == allowed_method and Regex.match?(pattern, path)
      end)
  end

  def link_app_call?(_method, _path, _via), do: false

  @spec allowed?(String.t(), String.t()) :: boolean()
  def allowed?(method, path) when is_binary(method) and is_binary(path) do
    Enum.any?(@allowed, fn {allowed_method, pattern} ->
      method == allowed_method and Regex.match?(pattern, path)
    end)
  end

  @doc "Halts a guest request outside the allowlist."
  @spec enforce(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def enforce(conn, %{"kind" => "guest"}) do
    via = conn |> Plug.Conn.get_req_header("x-comma-app-via") |> List.first()

    if allowed?(conn.method, conn.request_path) or
         link_app_call?(conn.method, conn.request_path, via) do
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
