defmodule SalixAgent.Egress.Destination do
  @moduledoc """
  Public-destination policy for tools that open connections from the
  platform's own network position (`web.http_request`, `ssh.*`).

  A host must resolve only to global unicast addresses. Loopback, private
  (RFC 1918), link-local, carrier-grade NAT, multicast, documentation,
  unspecified and reserved ranges are refused for IPv4, IPv6, IPv4-mapped,
  NAT64 and 6to4 addresses, as are `localhost`, `*.localhost`, `*.local`,
  `*.internal`, `*.svc` and `*.cluster.local` names.

  The name is resolved once, here. Callers connect to one of the returned
  addresses, so a DNS answer that changes after the check (DNS rebinding)
  cannot move the connection. `allow_private: true` (tests) lifts the checks
  but not the resolution.
  """

  import Bitwise

  @blocked_host_names ~w(localhost)
  @blocked_host_suffixes ~w(.localhost .local .internal .svc .cluster.local)

  @type error ::
          {:blocked_name, String.t()}
          | {:blocked_address, String.t(), :inet.ip_address()}
          | {:unresolved, String.t()}

  @doc "Resolve `host` to the addresses a connection may use, IPv4 first."
  @spec resolve(String.t(), keyword()) :: {:ok, [:inet.ip_address()]} | {:error, error()}
  def resolve(host, opts \\ []) when is_binary(host) do
    if Keyword.get(opts, :allow_private, false) == true do
      lookup_all(host)
    else
      if blocked_name?(host) do
        {:error, {:blocked_name, host}}
      else
        with {:ok, addresses} <- lookup_all(host) do
          case Enum.find(addresses, &blocked_address?/1) do
            nil -> {:ok, addresses}
            address -> {:error, {:blocked_address, host, address}}
          end
        end
      end
    end
  end

  @doc "Whether a name is an internal name (`localhost`, `*.internal`, ...)."
  @spec blocked_name?(String.t()) :: boolean()
  def blocked_name?(host) when is_binary(host) do
    name = host |> String.downcase() |> String.trim_trailing(".")

    name in @blocked_host_names or
      Enum.any?(@blocked_host_suffixes, &String.ends_with?(name, &1))
  end

  defp lookup_all(host) do
    chars = String.to_charlist(host)

    case :inet.parse_address(chars) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _} ->
        case lookup(chars, :inet) ++ lookup(chars, :inet6) do
          [] -> {:error, {:unresolved, host}}
          addresses -> {:ok, addresses}
        end
    end
  end

  defp lookup(host, family) do
    case :inet.getaddrs(host, family) do
      {:ok, addresses} -> addresses
      {:error, _} -> []
    end
  end

  @doc "Whether an `:inet` address tuple lies outside global unicast space."
  @spec blocked_address?(:inet.ip_address()) :: boolean()
  def blocked_address?({a, b, c, _d}) do
    cond do
      a == 0 -> true
      a == 10 -> true
      a == 100 and b in 64..127 -> true
      a == 127 -> true
      a == 169 and b == 254 -> true
      a == 172 and b in 16..31 -> true
      a == 192 and b == 0 and c in [0, 2] -> true
      a == 192 and b == 168 -> true
      a == 198 and b in 18..19 -> true
      a == 198 and b == 51 and c == 100 -> true
      a == 203 and b == 0 and c == 113 -> true
      a >= 224 -> true
      true -> false
    end
  end

  def blocked_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  def blocked_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d) addresses
  # are judged by the embedded IPv4 address.
  def blocked_address?({0, 0, 0, 0, 0, f, g, h}) when f in [0, 0xFFFF],
    do: blocked_address?(embedded_v4(g, h))

  # NAT64 well-known prefix 64:ff9b::/96 embeds the IPv4 target too.
  def blocked_address?({0x64, 0xFF9B, 0, 0, 0, 0, g, h}), do: blocked_address?(embedded_v4(g, h))

  # 6to4 (2002::/16) embeds the IPv4 relay in the next 32 bits.
  def blocked_address?({0x2002, b, c, _, _, _, _, _}), do: blocked_address?(embedded_v4(b, c))

  def blocked_address?({a, b, _, _, _, _, _, _}) do
    cond do
      band(a, 0xFE00) == 0xFC00 -> true
      band(a, 0xFFC0) == 0xFE80 -> true
      band(a, 0xFF00) == 0xFF00 -> true
      a == 0x2001 and b == 0x0DB8 -> true
      true -> false
    end
  end

  defp embedded_v4(g, h), do: {bsr(g, 8), band(g, 0xFF), bsr(h, 8), band(h, 0xFF)}
end
