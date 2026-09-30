defmodule CommaWeb.ClientSurface do
  @moduledoc """
  Derives trusted Comma client surfaces from server-owned routing and Origin
  configuration. Caller-provided transport headers never establish trust.
  """

  import Plug.Conn

  @non_cookie_paths [
    "/v1/comma/billing/stripe/webhook",
    "/v1/comma/billing/stripe/checkout/return",
    "/v1/comma/billing/stripe/checkout/cancel",
    "/v1/comma/integrations/telegram/connect/callback",
    "/v1/comma/integrations/telegram/webhook"
  ]
  @public_auth_paths [
    "/v1/comma/auth/email/login",
    "/v1/comma/auth/email/verify",
    "/v1/comma/auth/google/attempt",
    "/v1/comma/auth/google",
    "/v1/comma/auth/google/link/verify",
    "/v1/comma/auth/telegram-miniapp"
  ]
  @session_lifecycle_paths [
    "/v1/comma/auth/session",
    "/v1/comma/auth/logout"
  ]

  @spec public_auth_path?(String.t()) :: boolean()
  def public_auth_path?(path), do: path in @public_auth_paths

  @spec assign_trusted_surface(Plug.Conn.t(), String.t() | nil) :: Plug.Conn.t()
  def assign_trusted_surface(conn, origin) do
    cond do
      web_cookie_origin?(origin) and web_cookie_path?(conn.request_path) ->
        assign(conn, :comma_client_surface, :web_cookie)

      admin_cookie_origin?(origin) and admin_cookie_path?(conn.request_path) ->
        assign(conn, :comma_client_surface, :admin_cookie)

      true ->
        conn
    end
  end

  @doc """
  Validates the two explicit, path-scoped browser Cookie surfaces before
  CommaWeb starts.
  """
  @spec validate_configuration!() :: :ok
  def validate_configuration! do
    allowed_origins = Application.fetch_env!(:comma_web, :allowed_origins)
    web_cookie_origin = Application.get_env(:comma_web, :web_cookie_origin)
    admin_cookie_origin = Application.get_env(:comma_web, :admin_cookie_origin)

    unless is_list(allowed_origins) and
             Enum.all?(allowed_origins, &valid_origin?/1) do
      raise ArgumentError,
            ":comma_web, :allowed_origins must be a list of absolute HTTP(S) origins"
    end

    unless valid_origin?(web_cookie_origin) do
      raise ArgumentError,
            ":comma_web, :web_cookie_origin must be exactly one absolute HTTP(S) origin"
    end

    unless Enum.count(allowed_origins, &(&1 == web_cookie_origin)) == 1 do
      raise ArgumentError,
            ":comma_web, :web_cookie_origin must appear exactly once in :allowed_origins"
    end

    unless valid_origin?(admin_cookie_origin) do
      raise ArgumentError,
            ":comma_web, :admin_cookie_origin must be exactly one absolute HTTP(S) origin"
    end

    unless Enum.count(allowed_origins, &(&1 == admin_cookie_origin)) == 1 do
      raise ArgumentError,
            ":comma_web, :admin_cookie_origin must appear exactly once in :allowed_origins"
    end

    if admin_cookie_origin == web_cookie_origin do
      raise ArgumentError,
            ":comma_web, :admin_cookie_origin must differ from :web_cookie_origin"
    end

    :ok
  end

  @spec allowed_web_origin?(String.t() | nil) :: boolean()
  def allowed_web_origin?(origin) when is_binary(origin) do
    origin in Application.get_env(:comma_web, :allowed_origins, [])
  end

  def allowed_web_origin?(_origin), do: false

  @spec web_cookie_origin?(String.t() | nil) :: boolean()
  def web_cookie_origin?(origin) when is_binary(origin) do
    origin == Application.get_env(:comma_web, :web_cookie_origin)
  end

  def web_cookie_origin?(_origin), do: false

  @spec admin_cookie_origin?(String.t() | nil) :: boolean()
  def admin_cookie_origin?(origin) when is_binary(origin) do
    origin == Application.get_env(:comma_web, :admin_cookie_origin)
  end

  def admin_cookie_origin?(_origin), do: false

  @spec origin_scope_violation?(String.t() | nil, String.t()) :: boolean()
  def origin_scope_violation?(origin, path) when is_binary(path) do
    String.starts_with?(path, "/v1/") and
      cond do
        web_cookie_origin?(origin) -> not web_cookie_path?(path)
        admin_cookie_origin?(origin) -> not admin_cookie_path?(path)
        true -> false
      end
  end

  @spec web_cookie?(Plug.Conn.t()) :: boolean()
  def web_cookie?(conn), do: conn.assigns[:comma_client_surface] == :web_cookie

  @spec admin_cookie?(Plug.Conn.t()) :: boolean()
  def admin_cookie?(conn), do: conn.assigns[:comma_client_surface] == :admin_cookie

  @spec cookie?(Plug.Conn.t()) :: boolean()
  def cookie?(conn), do: web_cookie?(conn) or admin_cookie?(conn)

  @spec web_cookie_path?(String.t()) :: boolean()
  def web_cookie_path?(path) when is_binary(path) do
    String.starts_with?(path, "/v1/") and
      not String.starts_with?(path, "/v1/comma/admin/") and
      not CommaWeb.TaskShareEndpoints.public_path?(path) and
      path not in @non_cookie_paths
  end

  @spec admin_cookie_path?(String.t()) :: boolean()
  def admin_cookie_path?(path) when is_binary(path) do
    admin_product_path?(path) or public_auth_path?(path) or
      path in @session_lifecycle_paths
  end

  @spec admin_product_path?(String.t()) :: boolean()
  def admin_product_path?(path) when is_binary(path) do
    path == "/v1/comma/admin/audit-events" or
      Enum.any?(
        [
          "/v1/comma/admin/users",
          "/v1/comma/admin/billing",
          "/v1/comma/admin/model-selection-policy",
          "/v1/comma/admin/oauth-clients",
          "/v1/comma/admin/compute/agent-vmm"
        ],
        &path_prefix?(path, &1)
      )
  end

  defp path_prefix?(path, prefix),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp valid_origin?(origin) when is_binary(origin) do
    uri = URI.parse(origin)

    origin == String.trim(origin) and uri.scheme in ["http", "https"] and
      is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
      uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp valid_origin?(_origin), do: false
end
