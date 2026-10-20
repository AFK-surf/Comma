defmodule CommaWeb.StationOrigin do
  @moduledoc """
  The public origin stations reach the control plane at: `COMMA_STATION_ORIGIN`
  when set, else the origin of the request itself. Stations sign against the
  origin they were enrolled with (the install command's URL), and that is the
  host and scheme their requests arrive with, so the request's own origin
  matches without configuration. Behind a TLS-terminating proxy the scheme
  comes from `x-forwarded-proto`.
  """

  import Plug.Conn

  @spec of(Plug.Conn.t()) :: String.t() | nil
  def of(conn), do: Comma.Stations.Config.origin(request_origin(conn))

  @doc false
  def request_origin(%Plug.Conn{host: host} = conn) when is_binary(host) and host != "" do
    scheme =
      case get_req_header(conn, "x-forwarded-proto") do
        [proto | _] when proto in ["http", "https"] -> proto
        _ -> to_string(conn.scheme)
      end

    if Regex.match?(~r/\A[A-Za-z0-9.-]+\z/, host),
      do: scheme <> "://" <> host <> port_suffix(conn, scheme),
      else: nil
  end

  def request_origin(_conn), do: nil

  # A proxy that sets the scheme also owns the public port; only a direct
  # request on a non-default port keeps it.
  defp port_suffix(conn, scheme) do
    forwarded? = get_req_header(conn, "x-forwarded-proto") != []

    cond do
      forwarded? -> ""
      scheme == "http" and conn.port == 80 -> ""
      scheme == "https" and conn.port == 443 -> ""
      true -> ":#{conn.port}"
    end
  end
end
