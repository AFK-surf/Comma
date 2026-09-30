defmodule CommaWeb.LegacyPaths do
  @moduledoc """
  Serves the pre-namespace paths of the non-admin Comma API.

  Every Comma endpoint lives under `/v1/comma/...`. Installed clients and
  registered callbacks (Telegram webhook, Stripe Checkout return URLs, sent
  links) still use the old paths, so this plug maps them onto the canonical
  path before routing: `/v1/auth`, `/v1/me`, `/v1/workspaces`, `/v1/groups`,
  `/v1/billing`, `/v1/public/shares` and `/v1/integrations/telegram`.
  Everything after this plug (CORS, session, origin scope, routing) sees only
  the canonical path, so no check is written twice.

  The old admin paths (`/v1/admin/...`) are not mapped: `/v1/admin` belongs to
  Salix, and the Comma admin API is `/v1/comma/admin/...` only.
  """

  @behaviour Plug

  @legacy_roots ~w(auth me workspaces groups billing)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["v1" | rest]} = conn, _opts) do
    if legacy?(rest), do: to_canonical(conn, rest), else: conn
  end

  def call(conn, _opts), do: conn

  defp legacy?([root | _]) when root in @legacy_roots, do: true
  defp legacy?(["public", "shares" | _]), do: true
  defp legacy?(["integrations", "telegram" | _]), do: true
  defp legacy?(_rest), do: false

  defp to_canonical(conn, rest) do
    %{
      conn
      | path_info: ["v1", "comma" | rest],
        request_path: "/v1/comma" <> String.replace_prefix(conn.request_path, "/v1", "")
    }
  end
end
