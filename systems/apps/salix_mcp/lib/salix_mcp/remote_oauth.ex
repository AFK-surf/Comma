defmodule SalixMCP.RemoteOAuth do
  @moduledoc false

  def challenge_from_http_error({:http_error, status, headers, _body}) do
    challenge = www_authenticate_challenge(headers)

    cond do
      status != 401 ->
        nil

      challenge == %{} ->
        nil

      true ->
        Map.put(challenge, "http_status", status)
    end
  end

  def challenge_from_http_error(_reason), do: nil

  def oauth_challenge?(reason), do: is_map(challenge_from_http_error(reason))

  def reauthorization_challenge?(reason) do
    case challenge_from_http_error(reason) do
      %{"error" => error} ->
        error
        |> to_string()
        |> String.downcase()
        |> then(&(&1 in ["invalid_token", "expired_token"]))

      _ ->
        false
    end
  end

  def protected_resource_metadata_urls(mcp_url) do
    uri = URI.parse(to_string(mcp_url || ""))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      origin = origin(uri)
      path = uri.path || "/"
      normalized_path = if path == "/", do: "", else: path

      [
        origin <> "/.well-known/oauth-protected-resource" <> normalized_path,
        origin <> "/.well-known/oauth-protected-resource"
      ]
      |> Enum.uniq()
    else
      []
    end
  end

  def authorization_server_metadata_urls(issuer) do
    uri = URI.parse(to_string(issuer || ""))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      path = uri.path || ""
      origin = origin(uri)

      [
        origin <> "/.well-known/oauth-authorization-server" <> path,
        URI.to_string(%{
          uri
          | path: join_path(path, ".well-known/oauth-authorization-server"),
            query: nil,
            fragment: nil
        }),
        origin <> "/.well-known/openid-configuration" <> path,
        URI.to_string(%{
          uri
          | path: join_path(path, ".well-known/openid-configuration"),
            query: nil,
            fragment: nil
        })
      ]
      |> Enum.uniq()
    else
      []
    end
  end

  def www_authenticate_challenge(headers) do
    value =
      headers
      |> header_values("www-authenticate")
      |> Enum.join(", ")

    if value == "" or not Regex.match?(~r/\bbearer\b/i, value) do
      %{}
    else
      %{}
      |> maybe_put("resource_metadata_url", bearer_param(value, "resource_metadata"))
      |> maybe_put("resource_metadata_url", bearer_param(value, "resource_metadata_uri"))
      |> maybe_put("scope", bearer_param(value, "scope"))
      |> maybe_put("realm", bearer_param(value, "realm"))
      |> maybe_put("error", bearer_param(value, "error"))
      |> maybe_put("error_description", bearer_param(value, "error_description"))
    end
  end

  def header_values(headers, key) when is_map(headers) do
    wanted = String.downcase(to_string(key))

    headers
    |> Enum.flat_map(fn {header_key, value} ->
      if String.downcase(to_string(header_key)) == wanted do
        List.wrap(value)
      else
        []
      end
    end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def header_values(headers, key) when is_list(headers) do
    wanted = String.downcase(to_string(key))

    headers
    |> Enum.flat_map(fn
      {header_key, value} ->
        if String.downcase(to_string(header_key)) == wanted do
          List.wrap(value)
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def header_values(_headers, _key), do: []

  defp bearer_param(value, name) do
    pattern =
      ~r/(?:^|[\s,])#{Regex.escape(name)}\s*=\s*(?:"([^"]*)"|([^,\s]+))/i

    case Regex.run(pattern, value) do
      [_all, quoted, ""] -> String.trim(quoted)
      [_all, "", bare] -> String.trim(bare)
      [_all, quoted] -> String.trim(quoted)
      _ -> ""
    end
  end

  defp origin(%URI{} = uri) do
    port =
      case {uri.scheme, uri.port} do
        {"http", 80} -> ""
        {"https", 443} -> ""
        {_scheme, nil} -> ""
        {_scheme, port} -> ":#{port}"
      end

    uri.scheme <> "://" <> uri.host <> port
  end

  defp join_path(path, suffix) do
    path =
      case to_string(path || "") do
        "" -> "/"
        value -> value
      end

    path
    |> String.trim_trailing("/")
    |> Kernel.<>("/" <> suffix)
  end

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
