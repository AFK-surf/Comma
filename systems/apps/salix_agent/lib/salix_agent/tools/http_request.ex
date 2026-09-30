defmodule SalixAgent.Tools.HttpRequest do
  @moduledoc """
  `web.http_request`: one HTTP request to a JSON API, with the method, headers
  and body chosen by the caller.

  One canonical tool serves every runtime. A model round calls it through the
  `call` envelope; a `script.run` / `script.run_file` program calls
  `sf_host_call("salix.call", {"tool": "web.http_request", ...})` through
  `SalixAgent.ScriptRun`; a
  background Loop calls `sf_host_call("web.http_request", ...)`, the tool
  being on the Loop allowlist (`SalixAgent.Loops.Capabilities`). All three
  reach this module through
  `SalixAgent.SessionToolDispatch`, so authorization, information flow
  (`web.*` is public egress in `SalixAgent.IFC.Destination`) and archival
  belong to the dispatcher, not to this module.

  ## Request

    * `url` — absolute `http` or `https` URL without userinfo.
    * `method` — `GET` (default), `POST`, `PUT`, `PATCH`, `DELETE` or `HEAD`.
    * `query` — object appended to the URL's query string.
    * `headers` — object of header name to string value. Framing and
      hop-by-hop headers (`host`, `content-length`, `transfer-encoding`,
      `connection`, ...) are refused. `accept` defaults to
      `application/json`, `user-agent` to a fixed platform value.
    * `body` — an object, array, number or boolean is JSON-encoded and sent
      with `content-type: application/json` (unless the caller set one). A
      string is sent verbatim, with `text/plain; charset=utf-8` unless the
      caller set a content type. `null` or absent sends no body.
    * `credential_env` — the same references `env.exec` takes
      (`SalixAgent.OAuthCredentials`). Header and query values may contain
      `${NAME}` placeholders that resolve to the credential bound to
      `env_var` NAME, so a token never passes through the model or the
      archived arguments. A placeholder without an entry is an error.
    * `timeout_ms` — 1 000 to 60 000, default 20 000. The dispatcher deadline
      is derived from it (`SalixAgent.Tools.tool_timeout_ms/2`).

  ## Response

  A JSON object: `status`, `ok` (2xx), `headers` (lower-cased names, one
  string per name; a header the client reports more than once is joined
  with `, `), `body` when the response parsed as JSON,
  otherwise `body_text` (neither for an empty body), `truncated` when the
  body was cut at the read cap, and `duration_ms`. A non-2xx status is a
  result, not a tool error, so a script or Loop can branch on it. Redirects
  are not followed: a 3xx comes back with its `location` header. Refused
  arguments, blocked destinations, transport failures and timeouts raise.
  Never retried: a POST is not known to be idempotent.

  ## Destination policy

  The request leaves from the platform's own network position, so the
  destination is checked before connecting: the host must resolve only to
  global unicast addresses. Loopback, private (RFC 1918), link-local,
  carrier-grade NAT, multicast, documentation, unspecified and reserved
  ranges are refused for IPv4, IPv6, IPv4-mapped, NAT64 and 6to4 addresses,
  as are `localhost`, `*.localhost`, `*.local`, `*.internal`, `*.svc` and
  `*.cluster.local` names.

  The name is resolved once, here, and the connection is made to one of the
  addresses that passed the check: Mint is given the IP as the address and
  the URL host as `:hostname`, so the `Host` header, TLS SNI and certificate
  verification still use the name while no second DNS lookup happens between
  the check and the connect. A DNS answer that changes after the check (DNS
  rebinding) therefore cannot move the connection. `:salix_agent,
  :http_request_allow_private_hosts` (tests) lifts the address check; the
  connection is still pinned to the resolved address.
  """

  alias SalixAgent.Egress.Destination
  alias SalixAgent.OAuthCredentials

  @tool "web.http_request"
  @methods ~w(GET POST PUT PATCH DELETE HEAD)
  @default_timeout_ms 20_000
  @min_timeout_ms 1_000
  @max_timeout_ms 60_000
  @connect_timeout_ms 10_000
  # Grace the dispatcher adds on top of the request timeout before it kills
  # the tool: the request must time out first and return a real error.
  @dispatch_grace_ms 5_000
  @max_response_bytes 256 * 1024
  @max_body_bytes 1024 * 1024
  @max_headers 32
  @max_header_bytes 8 * 1024
  @max_query_entries 64
  @user_agent "Salix-Agent/1.0 (web.http_request)"

  # Set by the transport, or a hop-by-hop header a caller has no business
  # choosing. `proxy-*` is refused as a family.
  @blocked_headers ~w(host content-length transfer-encoding connection keep-alive upgrade expect te trailer)
  @header_name ~r/^[a-z0-9!#$%&'*+.^_`|~-]+$/
  @placeholder ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/

  @doc "The dispatcher deadline for one call: the request timeout plus grace. Never raises."
  @spec dispatch_timeout_ms(term()) :: pos_integer()
  def dispatch_timeout_ms(args) when is_map(args) do
    case parse_timeout(raw(args, "timeout_ms")) do
      {:ok, ms} -> ms + @dispatch_grace_ms
      {:error, _} -> @default_timeout_ms + @dispatch_grace_ms
    end
  end

  def dispatch_timeout_ms(_args), do: @default_timeout_ms + @dispatch_grace_ms

  @doc "Read cap on the response body, in bytes."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc false
  @spec request(map(), map()) :: String.t()
  def request(args, ctx) when is_map(args) do
    method = method!(args)
    uri = url!(args)
    timeout_ms = timeout!(args)
    secrets = credentials!(args, ctx)
    uri = put_query(uri, query!(args, secrets))
    headers = headers!(args, secrets)
    {headers, body} = body!(args, headers)
    addresses = resolve_destination!(uri.host)

    started = System.monotonic_time(:millisecond)
    result = perform(uri, addresses, method, headers, body, timeout_ms)
    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, response} ->
        emit(outcome(response.status), elapsed)
        format(response, elapsed)

      {:error, %Mint.TransportError{reason: :timeout}} ->
        emit("timeout", elapsed)
        raise "#{@tool}: no response within #{timeout_ms} ms"

      {:error, %Mint.TransportError{reason: reason}} ->
        emit("error", elapsed)
        raise "#{@tool}: transport error #{format_transport_reason(reason)}"

      {:error, exception} when is_exception(exception) ->
        emit("error", elapsed)
        raise "#{@tool}: transport error #{Exception.message(exception)}"

      {:error, reason} ->
        emit("error", elapsed)
        raise "#{@tool}: transport error #{inspect(reason) |> String.slice(0, 256)}"
    end
  end

  # ---- transport -------------------------------------------------------------

  # One HTTP/1.1 exchange on a fresh connection to an address the policy
  # checked. The IP tuple is the address Mint connects to; the URL host is
  # only the `:hostname` (Host header, SNI, certificate check), so nothing
  # resolves the name a second time.
  defp perform(uri, addresses, method, headers, body, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    scheme = if uri.scheme == "https", do: :https, else: :http
    body = if is_nil(body) and method not in ["GET", "HEAD"], do: "", else: body

    case connect(scheme, addresses, uri.host, uri.port, timeout_ms) do
      {:ok, conn} ->
        exchange =
          with {:ok, conn, ref} <-
                 Mint.HTTP.request(conn, method, request_target(uri), headers, body),
               {:ok, conn, response} <- receive_response(conn, ref, deadline, new_response()) do
            {:ok, conn, response}
          end

        case exchange do
          {:ok, conn, response} ->
            _ = Mint.HTTP.close(conn)
            {:ok, response}

          {:error, conn, reason} ->
            _ = Mint.HTTP.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Addresses come IPv4 first from `resolve_destination!/1`; the first one
  # that accepts the connection is used, the last failure is reported.
  defp connect(scheme, addresses, host, port, timeout_ms) do
    connect_timeout = min(timeout_ms, @connect_timeout_ms)

    Enum.reduce_while(addresses, {:error, %Mint.TransportError{reason: :nxdomain}}, fn address,
                                                                                       _last ->
      case Mint.HTTP.connect(scheme, address, port,
             hostname: host,
             mode: :passive,
             protocols: [:http1],
             transport_opts: [timeout: connect_timeout]
           ) do
        {:ok, conn} -> {:halt, {:ok, conn}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp request_target(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if uri.query in [nil, ""], do: path, else: path <> "?" <> uri.query
  end

  defp new_response, do: %{status: nil, headers: [], body: "", truncated: false}

  # Passive mode: read until `:done`, the deadline, or the body cap. A body
  # over the cap is cut there and the connection is closed unread.
  defp receive_response(conn, ref, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, conn, %Mint.TransportError{reason: :timeout}}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          case fold_responses(responses, ref, acc) do
            {:cont, acc} -> receive_response(conn, ref, deadline, acc)
            {:halt, acc} -> {:ok, conn, acc}
            {:error, reason} -> {:error, conn, reason}
          end

        {:error, conn, reason, responses} ->
          case fold_responses(responses, ref, acc) do
            {:halt, acc} -> {:ok, conn, acc}
            {:error, inner} -> {:error, conn, inner}
            {:cont, _acc} -> {:error, conn, reason}
          end
      end
    end
  end

  defp fold_responses(responses, ref, acc) do
    Enum.reduce_while(responses, {:cont, acc}, fn
      {:status, ^ref, status}, {:cont, acc} ->
        {:cont, {:cont, %{acc | status: status}}}

      {:headers, ^ref, headers}, {:cont, acc} ->
        {:cont, {:cont, %{acc | headers: acc.headers ++ headers}}}

      {:data, ^ref, data}, {:cont, acc} ->
        body = acc.body <> data

        if byte_size(body) > @max_response_bytes do
          cut = %{acc | body: binary_part(body, 0, @max_response_bytes), truncated: true}
          {:halt, {:halt, cut}}
        else
          {:cont, {:cont, %{acc | body: body}}}
        end

      {:done, ^ref}, {:cont, acc} ->
        {:halt, {:halt, acc}}

      {:error, ^ref, reason}, _state ->
        {:halt, {:error, reason}}

      _other, state ->
        {:cont, state}
    end)
  end

  # ---- argument parsing ------------------------------------------------------

  defp method!(args) do
    case raw(args, "method") do
      nil ->
        "GET"

      value ->
        method = value |> to_string() |> String.trim() |> String.upcase()

        if method in @methods,
          do: method,
          else: raise("#{@tool}: method must be one of #{Enum.join(@methods, ", ")}")
    end
  end

  defp url!(args) do
    url = args |> raw("url") |> to_string() |> String.trim()
    if url == "", do: raise("'url' is required")

    uri =
      case URI.new(url) do
        {:ok, uri} -> uri
        {:error, part} -> raise "#{@tool}: invalid url near #{inspect(part)}"
      end

    cond do
      uri.scheme not in ["http", "https"] ->
        raise "#{@tool}: url must be an absolute http or https URL"

      uri.host in [nil, ""] ->
        raise "#{@tool}: url has no host"

      uri.userinfo != nil ->
        raise "#{@tool}: url must not carry credentials; use headers with credential_env"

      uri.fragment != nil ->
        %{uri | fragment: nil}

      true ->
        uri
    end
  end

  defp timeout!(args) do
    case parse_timeout(raw(args, "timeout_ms")) do
      {:ok, ms} -> ms
      {:error, message} -> raise "#{@tool}: #{message}"
    end
  end

  defp parse_timeout(nil), do: {:ok, @default_timeout_ms}
  defp parse_timeout(""), do: {:ok, @default_timeout_ms}

  defp parse_timeout(value) when is_integer(value) do
    if value >= @min_timeout_ms and value <= @max_timeout_ms,
      do: {:ok, value},
      else: {:error, "timeout_ms must be between #{@min_timeout_ms} and #{@max_timeout_ms}"}
  end

  defp parse_timeout(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> parse_timeout(int)
      _ -> {:error, "timeout_ms must be an integer"}
    end
  end

  defp parse_timeout(_value), do: {:error, "timeout_ms must be an integer"}

  # `credential_env` follows `env.exec`: absent or `[]` resolves to nothing;
  # anything else goes through the OAuth resolver under the calling Agent.
  defp credentials!(args, ctx) do
    case raw(args, "credential_env") do
      nil ->
        %{}

      [] ->
        %{}

      entries ->
        agent_id = Map.get(ctx, :agent_id) || Map.get(ctx, "agent_id")

        if agent_id in [nil, ""],
          do: raise("#{@tool}: credential_env needs an agent context")

        case OAuthCredentials.resolve(agent_id, entries) do
          {:ok, resolved} -> resolved
          {:error, message} -> raise "#{@tool}: #{message}"
        end
    end
  end

  defp query!(args, secrets) do
    case raw(args, "query") do
      nil ->
        []

      query when is_map(query) ->
        if map_size(query) > @max_query_entries,
          do: raise("#{@tool}: query may carry at most #{@max_query_entries} entries")

        Enum.map(query, fn {key, value} ->
          key = to_string(key)
          if key == "", do: raise("#{@tool}: query keys must be non-empty")
          {key, substitute!(scalar!(value, "query value for #{key}"), secrets, "query #{key}")}
        end)

      _ ->
        raise "#{@tool}: query must be an object of name to scalar value"
    end
  end

  defp put_query(uri, []), do: uri

  defp put_query(uri, pairs) do
    encoded = URI.encode_query(pairs)

    case uri.query do
      nil -> %{uri | query: encoded}
      "" -> %{uri | query: encoded}
      existing -> %{uri | query: existing <> "&" <> encoded}
    end
  end

  defp headers!(args, secrets) do
    given =
      case raw(args, "headers") do
        nil -> %{}
        headers when is_map(headers) -> headers
        _ -> raise "#{@tool}: headers must be an object of name to string value"
      end

    if map_size(given) > @max_headers,
      do: raise("#{@tool}: at most #{@max_headers} headers")

    headers =
      Enum.reduce(given, [], fn {name, value}, acc ->
        name = name |> to_string() |> String.trim() |> String.downcase()
        value = header_value!(name, value, secrets)

        cond do
          not Regex.match?(@header_name, name) ->
            raise "#{@tool}: invalid header name #{inspect(name)}"

          name in @blocked_headers or String.starts_with?(name, "proxy-") ->
            raise "#{@tool}: header #{name} is set by the transport and cannot be overridden"

          List.keymember?(acc, name, 0) ->
            raise "#{@tool}: duplicate header #{name}"

          true ->
            [{name, value} | acc]
        end
      end)
      |> Enum.reverse()

    total = Enum.reduce(headers, 0, fn {n, v}, sum -> sum + byte_size(n) + byte_size(v) end)

    if total > @max_header_bytes,
      do: raise("#{@tool}: headers exceed #{@max_header_bytes} bytes")

    headers
    |> put_new_header("accept", "application/json")
    |> put_new_header("user-agent", @user_agent)
  end

  defp header_value!(name, value, secrets) do
    text = scalar!(value, "header #{name}")

    if String.contains?(text, ["\r", "\n"]),
      do: raise("#{@tool}: header #{name} must not contain line breaks")

    substitute!(text, secrets, "header #{name}")
  end

  defp scalar!(value, _what) when is_binary(value), do: value
  defp scalar!(value, _what) when is_number(value) or is_boolean(value), do: to_string(value)
  defp scalar!(_value, what), do: raise("#{@tool}: #{what} must be a string")

  # `${NAME}` resolves to the credential bound to env_var NAME. The error
  # names the placeholder, never a value.
  defp substitute!(text, secrets, where) do
    Regex.replace(@placeholder, text, fn _match, name ->
      case Map.fetch(secrets, name) do
        {:ok, value} ->
          value

        :error ->
          raise "#{@tool}: #{where} references ${#{name}} but credential_env has no entry with env_var #{name}"
      end
    end)
  end

  defp body!(args, headers) do
    content_type = List.keyfind(headers, "content-type", 0)

    {headers, body} =
      case Map.fetch(args, "body") do
        :error ->
          case Map.fetch(args, :body) do
            :error -> {headers, nil}
            {:ok, body} -> encode_body(body, headers, content_type)
          end

        {:ok, body} ->
          encode_body(body, headers, content_type)
      end

    if is_binary(body) and byte_size(body) > @max_body_bytes,
      do: raise("#{@tool}: body exceeds #{@max_body_bytes} bytes")

    {headers, body}
  end

  defp encode_body(nil, headers, _content_type), do: {headers, nil}

  defp encode_body(body, headers, content_type) when is_binary(body) do
    headers =
      if content_type,
        do: headers,
        else: headers ++ [{"content-type", "text/plain; charset=utf-8"}]

    {headers, body}
  end

  defp encode_body(body, headers, content_type) do
    headers =
      if content_type, do: headers, else: headers ++ [{"content-type", "application/json"}]

    {headers, Jason.encode!(body)}
  end

  defp put_new_header(headers, name, value) do
    if List.keymember?(headers, name, 0), do: headers, else: headers ++ [{name, value}]
  end

  # ---- destination policy ----------------------------------------------------

  @doc """
  Resolve `host` once and return the addresses the connection may use, IPv4
  first. Raises when the name is not a public destination or any resolved
  address lies outside global unicast space (`SalixAgent.Egress.Destination`).
  `:http_request_allow_private_hosts` lifts the check but not the resolution:
  the connection is always pinned to what was resolved here.
  """
  @spec resolve_destination!(String.t()) :: [:inet.ip_address()]
  def resolve_destination!(host) when is_binary(host) do
    allow_private =
      Application.get_env(:salix_agent, :http_request_allow_private_hosts, false) == true

    case Destination.resolve(host, allow_private: allow_private) do
      {:ok, addresses} ->
        addresses

      {:error, {:blocked_name, _}} ->
        raise "#{@tool}: #{host} is not a public destination"

      {:error, {:blocked_address, _, address}} ->
        raise "#{@tool}: #{host} resolves to #{:inet.ntoa(address)}, which is not a public address"

      {:error, {:unresolved, _}} ->
        raise "#{@tool}: could not resolve host #{host}"
    end
  end

  @doc "Whether an `:inet` address tuple lies outside global unicast space."
  @spec blocked_address?(:inet.ip_address()) :: boolean()
  defdelegate blocked_address?(address), to: Destination

  # ---- response --------------------------------------------------------------

  defp format(%{status: status, truncated: truncated} = response, elapsed) do
    headers = flatten_headers(response.headers)

    %{
      "status" => status,
      "ok" => status in 200..299,
      "headers" => headers,
      "truncated" => truncated,
      "duration_ms" => elapsed
    }
    |> put_body(response.body, truncated, Map.get(headers, "content-type", ""))
    |> Jason.encode!()
  end

  # Mint reports headers as a list; a header sent more than once is joined.
  defp flatten_headers(headers) when is_list(headers) do
    headers
    |> Enum.group_by(fn {name, _} -> String.downcase(to_string(name)) end, fn {_, v} -> v end)
    |> Map.new(fn {name, values} -> {name, Enum.join(values, ", ")} end)
  end

  defp put_body(result, "", _truncated, _content_type), do: result

  defp put_body(result, body, truncated, content_type) do
    with false <- truncated,
         true <- json_like?(body, content_type),
         {:ok, decoded} <- Jason.decode(body) do
      Map.put(result, "body", decoded)
    else
      _ -> Map.put(result, "body_text", SalixAgent.Utf8.scrub(body))
    end
  end

  defp json_like?(body, content_type) do
    String.contains?(String.downcase(content_type), "json") or
      String.starts_with?(String.trim_leading(body), ["{", "["])
  end

  # Salix.Telemetry outcome vocabulary: a remote refusal is `rejected`, a
  # remote failure `failed`; `error` is kept for the transport.
  defp outcome(status) when status in 200..299, do: "ok"
  defp outcome(status) when status in 400..499, do: "rejected"
  defp outcome(status) when status in 500..599, do: "failed"
  defp outcome(_status), do: "other"

  defp format_transport_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_transport_reason(reason), do: inspect(reason) |> String.slice(0, 256)

  defp emit(outcome, elapsed_ms) do
    Salix.Telemetry.emit_operation(
      "salix_agent",
      "web_http_request",
      "salix",
      outcome,
      System.convert_time_unit(elapsed_ms, :millisecond, :native)
    )
  end

  defp raw(args, key), do: Map.get(args, key, Map.get(args, String.to_atom(key)))
end
