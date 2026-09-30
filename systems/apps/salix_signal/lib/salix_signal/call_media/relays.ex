defmodule SalixSignal.CallMedia.Relays do
  @moduledoc """
  TURN relay credentials for call media (CRS-13 section 2).

  `GET /v2/calling/relays` on the chat service, with the account's HTTP
  basic authentication, returns `{"relays": [relay]}`. Each relay has a
  `username`, a `password`, a `ttl` in seconds for which it may be reused,
  TURN URIs with host names (`urls`) and the same service with literal IP
  addresses (`urlsWithIps`, TLS server name in `hostname`).

  The service limits this request per account (100 permits, one regained
  every 10 minutes), so the account owner keeps the result until
  `expires_at_ms` and reuses it for every call in that time.

  `ice_servers/1` turns the relays into ICE agent configuration. It puts the
  `urlsWithIps` entries before the `urls` entries, as Signal Desktop does. It
  keeps UDP TURN URIs and TLS TURN URIs with an IPv4 address or a host name.
  `TLSRelay` selects one TLS endpoint and excludes all UDP relay paths.
  The ICE library cannot parse bracketed IPv6.
  """

  @path "/v2/calling/relays"

  @type relay :: %{
          username: String.t(),
          password: String.t(),
          urls: [String.t()],
          urls_with_ips: [String.t()],
          hostname: String.t() | nil
        }

  @doc "Request path of the relay endpoint."
  def path, do: @path

  @doc """
  Fetches relays with `request`, a function that performs an authenticated
  `GET` of the given path on the chat service and returns
  `{:ok, status, body}` or `{:error, reason}`. `now_ms` is wall-clock time.
  """
  @spec fetch((String.t() -> {:ok, integer(), binary()} | {:error, term()}), integer()) ::
          {:ok, %{relays: [relay()], expires_at_ms: integer()}} | {:error, term()}
  def fetch(request, now_ms) when is_function(request, 1) do
    case request.(@path) do
      {:ok, 200, body} -> parse(body, now_ms)
      {:ok, 429, _body} -> {:error, :rate_limited}
      {:ok, 401, _body} -> {:error, :unauthorized}
      {:ok, status, _body} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Parses a 200 response body."
  @spec parse(binary(), integer()) ::
          {:ok, %{relays: [relay()], expires_at_ms: integer()}} | {:error, :invalid_response}
  def parse(body, now_ms) do
    with {:ok, %{"relays" => [_ | _] = relays}} <- Jason.decode(body),
         {:ok, parsed} <- parse_relays(relays) do
      ttl = parsed |> Enum.map(& &1.ttl) |> Enum.min()

      {:ok,
       %{relays: Enum.map(parsed, &Map.delete(&1, :ttl)), expires_at_ms: now_ms + ttl * 1000}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_relays(relays) do
    Enum.reduce_while(relays, {:ok, []}, fn relay, {:ok, acc} ->
      case relay do
        %{"username" => user, "password" => pass, "ttl" => ttl} = relay
        when is_binary(user) and is_binary(pass) and is_integer(ttl) and ttl >= 0 ->
          parsed = %{
            username: user,
            password: pass,
            ttl: ttl,
            urls: strings(relay["urls"]),
            urls_with_ips: strings(relay["urlsWithIps"]),
            hostname: if(is_binary(relay["hostname"]), do: relay["hostname"])
          }

          {:cont, {:ok, acc ++ [parsed]}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_other), do: []

  @doc "ICE agent `ice_servers` for the relays."
  @spec ice_servers([relay()]) :: [map()]
  def ice_servers(relays) do
    relays
    |> Enum.map(fn relay ->
      urls =
        (Enum.reject(relay.urls_with_ips, &String.starts_with?(&1, "turns:")) ++
           relay.urls ++ cloudflare_tls(relay.urls))
        |> Enum.filter(&usable?/1)
        |> Enum.map(&explicit_transport/1)

      %{urls: Enum.uniq(urls), username: relay.username, credential: relay.password}
    end)
    |> Enum.reject(&(&1.urls == []))
  end

  defp usable?("turn:" <> rest) do
    {host_port, transport} =
      case String.split(rest, "?transport=", parts: 2) do
        [host_port, transport] -> {host_port, transport}
        [host_port] -> {host_port, "udp"}
      end

    transport == "udp" and not String.starts_with?(host_port, "[")
  end

  defp usable?("turns:" <> _ = url) do
    case ExSTUN.URI.parse(url) do
      {:ok, %{scheme: :turns, transport: transport}} when transport in [nil, :tcp] -> true
      _ -> false
    end
  end

  defp usable?(_url), do: false

  # Signal can omit the default UDP transport. ExTURN requires it explicitly.
  defp explicit_transport(url) do
    transport = if String.starts_with?(url, "turns:"), do: "tcp", else: "udp"
    if String.contains?(url, "?transport="), do: url, else: url <> "?transport=" <> transport
  end

  # Signal currently advertises Cloudflare's UDP URL only. Cloudflare uses
  # the same TURN credentials on its documented TLS endpoint on port 443:
  # https://developers.cloudflare.com/realtime/turn/#service-address-and-ports
  # Keep the authenticated relay hostname. Never derive a new credential
  # destination from an arbitrary provider URL.
  defp cloudflare_tls(urls) do
    if Enum.any?(urls, fn url ->
         match?({:ok, %{scheme: :turn, host: "turn.cloudflare.com"}}, ExSTUN.URI.parse(url))
       end),
       do: ["turns:turn.cloudflare.com:443?transport=tcp"],
       else: []
  end
end
