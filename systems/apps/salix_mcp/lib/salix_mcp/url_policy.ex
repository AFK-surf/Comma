defmodule SalixMCP.URLPolicy do
  @moduledoc false

  import Bitwise

  @public_dns_nameservers [
    {{1, 1, 1, 1}, 53},
    {{8, 8, 8, 8}, 53}
  ]
  @dns_over_https_url "https://cloudflare-dns.com/dns-query"

  def validate_public_http_url(url) do
    case public_http_target(url) do
      {:ok, _target} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def public_http_target(url) do
    uri = URI.parse(to_string(url || ""))

    with :ok <- validate_http_uri(uri),
         {:ok, address} <- address_for_uri(uri) do
      {:ok,
       %{
         url: pinned_url(uri, address),
         connect_options: [hostname: uri.host],
         host_header: host_header(uri),
         inet6: tuple_size(address) == 8
       }}
    end
  end

  defp validate_http_uri(uri) do
    if allowlisted_private_target?(uri),
      do: validate_basic_http_uri(uri),
      else: validate_public_http_uri(uri)
  end

  defp validate_basic_http_uri(uri) do
    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, {:bad_request, "MCP URL must use http or https"}}

      not is_binary(uri.host) or uri.host == "" ->
        {:error, {:bad_request, "MCP URL must include a host"}}

      is_binary(uri.userinfo) and uri.userinfo != "" ->
        {:error, {:bad_request, "MCP URL must not include userinfo"}}

      true ->
        :ok
    end
  end

  defp address_for_uri(uri) do
    if allowlisted_private_target?(uri), do: any_address(uri.host), else: public_address(uri.host)
  end

  defp allowlisted_private_target?(%URI{scheme: "http", host: host} = uri)
       when host in ["127.0.0.1", "localhost"] do
    url = URI.to_string(uri)

    :salix_mcp
    |> Application.get_env(:private_http_target_allowlist, [])
    |> List.wrap()
    |> Enum.any?(&(&1 == url))
  end

  defp allowlisted_private_target?(_uri), do: false

  defp validate_public_http_uri(uri) do
    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, {:bad_request, "MCP URL must use http or https"}}

      not is_binary(uri.host) or uri.host == "" ->
        {:error, {:bad_request, "MCP URL must include a host"}}

      is_binary(uri.userinfo) and uri.userinfo != "" ->
        {:error, {:bad_request, "MCP URL must not include userinfo"}}

      private_hostname?(uri.host) and not allow_private_http_targets?() ->
        {:error, {:bad_request, "MCP URL host is not allowed from server placement"}}

      true ->
        :ok
    end
  end

  defp private_hostname?(host) do
    host = String.downcase(host)

    host in ["localhost", "localhost.localdomain"] or
      String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".local")
  end

  defp public_address(host) do
    if allow_private_http_targets?() do
      any_address(host)
    else
      public_address_only(host)
    end
  end

  defp public_address_only(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, address} ->
        if private_address?(address) do
          {:error, {:bad_request, "MCP URL host is not allowed from server placement"}}
        else
          {:ok, address}
        end

      _ ->
        resolve_public_address(host)
    end
  end

  defp any_address(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, address} ->
        {:ok, address}

      _ ->
        host = to_charlist(host)

        [:inet, :inet6]
        |> Enum.find_value(fn family ->
          case :inet.getaddrs(host, family) do
            {:ok, [address | _]} -> {:ok, address}
            _ -> nil
          end
        end)
        |> case do
          nil -> {:error, {:bad_request, "MCP URL host could not be resolved"}}
          result -> result
        end
    end
  rescue
    _ -> {:error, {:bad_request, "MCP URL host could not be resolved"}}
  end

  defp resolve_public_address(host) do
    host = to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(host, family) do
          {:ok, addresses} -> addresses
          _ -> []
        end
      end)
      |> Enum.uniq()

    cond do
      addresses == [] ->
        {:error, {:bad_request, "MCP URL host could not be resolved"}}

      Enum.all?(addresses, &fake_ip_address?/1) ->
        resolve_public_address_with_public_dns(host)

      Enum.any?(addresses, &private_address?/1) ->
        {:error, {:bad_request, "MCP URL host is not allowed from server placement"}}

      true ->
        {:ok, prefer_ipv4(addresses)}
    end
  rescue
    _ -> {:error, {:bad_request, "MCP URL host could not be resolved"}}
  end

  defp resolve_public_address_with_public_dns(host) do
    addresses =
      @public_dns_nameservers
      |> Enum.flat_map(fn nameserver ->
        Enum.flat_map([:a, :aaaa], fn type ->
          :inet_res.lookup(host, :in, type, nameservers: [nameserver], timeout: 2_000)
        end)
      end)
      |> Enum.uniq()

    addresses =
      if addresses == [] or Enum.all?(addresses, &fake_ip_address?/1) do
        resolve_public_address_with_dns_over_https(host)
      else
        addresses
      end

    cond do
      addresses == [] ->
        {:error, {:bad_request, "MCP URL host could not be resolved"}}

      Enum.any?(addresses, &private_address?/1) ->
        {:error, {:bad_request, "MCP URL host is not allowed from server placement"}}

      true ->
        {:ok, prefer_ipv4(addresses)}
    end
  rescue
    _ -> {:error, {:bad_request, "MCP URL host could not be resolved"}}
  end

  defp resolve_public_address_with_dns_over_https(host) do
    [1, 28]
    |> Enum.flat_map(&dns_over_https_addresses(host, &1))
    |> Enum.uniq()
  end

  defp dns_over_https_addresses(host, type) do
    case Req.get(@dns_over_https_url,
           params: [name: to_string(host), type: type],
           headers: [{"accept", "application/dns-json"}],
           redirect: false,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        with {:ok, %{"Status" => 0, "Answer" => answers}} <- decode_dns_body(body),
             true <- is_list(answers) do
          answers
          |> Enum.filter(&(&1["type"] == type))
          |> Enum.flat_map(fn answer ->
            case :inet.parse_address(to_charlist(to_string(answer["data"] || ""))) do
              {:ok, address} -> [address]
              _ -> []
            end
          end)
        else
          _ -> []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp decode_dns_body(body) when is_map(body), do: {:ok, body}
  defp decode_dns_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_dns_body(_body), do: :error

  defp prefer_ipv4(addresses) do
    Enum.find(addresses, &(tuple_size(&1) == 4)) || List.first(addresses)
  end

  defp pinned_url(uri, address) do
    host = address |> address_uri_host() |> authority_host()
    port = if uri.port, do: ":" <> Integer.to_string(uri.port), else: ""
    path = uri.path || ""
    query = if uri.query, do: "?" <> uri.query, else: ""

    uri.scheme <> "://" <> host <> port <> path <> query
  end

  defp address_uri_host(address) do
    address
    |> :inet.ntoa()
    |> to_string()
  end

  defp host_header(uri) do
    host = authority_host(uri.host)

    case explicit_port(uri) do
      nil -> host
      port -> host <> ":" <> Integer.to_string(port)
    end
  end

  defp explicit_port(uri) do
    cond do
      not is_integer(uri.port) ->
        nil

      uri.port == URI.default_port(uri.scheme) ->
        nil

      true ->
        uri.port
    end
  end

  defp authority_host(host) when is_binary(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[" <> host <> "]"
    else
      host
    end
  end

  defp private_address?({0, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({127, _, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({172, second, _, _}) when second >= 16 and second <= 31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({100, second, _, _}) when second >= 64 and second <= 127, do: true
  defp private_address?({192, 0, 0, _}), do: true
  defp private_address?({192, 0, 2, _}), do: true
  defp private_address?({192, 88, 99, _}), do: true
  defp private_address?({198, second, _, _}) when second in [18, 19], do: true
  defp private_address?({198, 51, 100, _}), do: true
  defp private_address?({203, 0, 113, _}), do: true
  defp private_address?({first, _, _, _}) when first >= 224, do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, a, b}), do: private_address?(ipv4_mapped(a, b))
  defp private_address?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when (first &&& 0xFF00) == 0xFF00, do: true
  defp private_address?(_address), do: false

  # Some local development networks use 198.18/15 as DNS fake-IP space. These
  # addresses are never accepted directly; they only trigger a public DNS retry.
  defp fake_ip_address?({198, second, _, _}) when second in [18, 19], do: true
  defp fake_ip_address?(_address), do: false

  defp ipv4_mapped(a, b), do: {a >>> 8, a &&& 0xFF, b >>> 8, b &&& 0xFF}

  defp allow_private_http_targets? do
    Application.get_env(:salix_mcp, :allow_private_http_targets, false) == true
  end
end
