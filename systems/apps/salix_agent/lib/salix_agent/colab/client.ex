defmodule SalixAgent.Colab.Client do
  @moduledoc """
  Pure Elixir HTTP client for Google Colab's `/tun/m/*` control-plane API,
  matching the `google-colab-cli` 0.8.0 wire protocol.

  Also provides `validate_proxy_url/2` for SSRF-safe proxy URL validation
  (shared with WebSocket-SSH tunnels).
  """

  alias SalixAgent.Egress.Destination

  @default_base_url "https://colab.research.google.com"
  @xssi_prefix ")]}'\n"
  @client_agent "colab-cli"

  @gpu_accelerators ~w(G4 L4 T4 A100 H100)
  @high_mem_only_accelerators ~w(L4)

  @allowed_proxy_exact "colab.research.google.com"
  @allowed_proxy_suffixes [
    ".colab.research.google.com",
    ".prod.colab.googleusercontent.com",
    ".prod.colab.dev",
    ".prod.r.colab.dev"
  ]

  @doc """
  Convert a UUID string into Google Colab's 44-character `nbh` (notebook hash):
  replace `-` with `_` and right-pad with `.` to 44 characters.
  """
  @spec notebook_hash(String.t()) :: String.t()
  def notebook_hash(uuid_str) when is_binary(uuid_str) do
    transformed = String.replace(uuid_str, "-", "_")
    pad = max(44 - byte_size(transformed), 0)
    transformed <> String.duplicate(".", pad)
  end

  @doc """
  Map a requested GPU/CPU spec to Colab's `{variant, accelerator, shape}` wire parameters.
  - `"CPU"` -> `variant: "DEFAULT"`, `accelerator: "NONE"`, optional `shape: "hm"`
  - `"L4"` -> `variant: "GPU"`, `accelerator: "L4"`, always omits `shape`
  - `"G4" | "T4" | "A100" | "H100"` -> `variant: "GPU"`, `accelerator: gpu`, optional `shape: "hm"`
  """
  @spec hardware_spec(String.t(), boolean()) ::
          {:ok, %{variant: String.t(), accelerator: String.t(), shape: String.t() | nil}}
          | {:error, :invalid_accelerator}
  def hardware_spec(gpu, high_mem \\ false)

  def hardware_spec("CPU", high_mem) when is_boolean(high_mem) do
    {:ok, %{variant: "DEFAULT", accelerator: "NONE", shape: if(high_mem, do: "hm", else: nil)}}
  end

  def hardware_spec(gpu, high_mem) when gpu in @gpu_accelerators and is_boolean(high_mem) do
    shape = if high_mem and gpu not in @high_mem_only_accelerators, do: "hm", else: nil
    {:ok, %{variant: "GPU", accelerator: gpu, shape: shape}}
  end

  def hardware_spec(_, _), do: {:error, :invalid_accelerator}

  @doc "Fetch account compute-unit balance and consumption info (`/tun/m/ccu-info`)."
  @spec ccu_info(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ccu_info(access_token, opts \\ []) when is_binary(access_token) and is_list(opts) do
    get_json(access_token, "/tun/m/ccu-info", [{"authuser", "0"}], opts)
  end

  @doc "List active VM assignments for the account (`/tun/m/assignments`)."
  @spec list_assignments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_assignments(access_token) when is_binary(access_token) do
    case get_json(access_token, "/tun/m/assignments", [{"authuser", "0"}]) do
      {:ok, []} ->
        {:ok, []}

      {:ok, map} when is_map(map) and map_size(map) == 0 ->
        {:ok, []}

      {:ok, %{"assignments" => list}} when is_list(list) ->
        if Enum.all?(list, &valid_assignment_item?/1),
          do: {:ok, list},
          else: {:error, :invalid_response}

      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &valid_assignment_item?/1),
          do: {:ok, list},
          else: {:error, :invalid_response}

      {:ok, _} ->
        {:error, :invalid_response}

      error ->
        error
    end
  end

  defp valid_assignment_item?(%{"endpoint" => ep}) when is_binary(ep) and ep != "", do: true
  defp valid_assignment_item?(_), do: false

  @doc "GET `/tun/m/assign` to probe an existing assignment or obtain an XSRF token."
  @spec assign_get(String.t(), String.t(), String.t(), String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def assign_get(access_token, nbh, variant, accelerator, high_mem \\ false, opts \\ [])
      when is_binary(access_token) and is_binary(nbh) and is_binary(variant) and
             is_binary(accelerator) and is_boolean(high_mem) and is_list(opts) do
    get_json(
      access_token,
      "/tun/m/assign",
      assign_query(nbh, variant, accelerator, high_mem),
      opts
    )
  end

  @doc "POST `/tun/m/assign` with `X-Goog-Colab-Token` to allocate a runtime."
  @spec assign_post(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          boolean(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def assign_post(
        access_token,
        xsrf_token,
        nbh,
        variant,
        accelerator,
        high_mem \\ false,
        opts \\ []
      )
      when is_binary(access_token) and is_binary(xsrf_token) and is_binary(nbh) and
             is_binary(variant) and is_binary(accelerator) and is_boolean(high_mem) and
             is_list(opts) do
    post_json(
      access_token,
      xsrf_token,
      "/tun/m/assign",
      assign_query(nbh, variant, accelerator, high_mem),
      opts
    )
  end

  @doc "Two-step GET -> POST `/tun/m/assign` allocation flow."
  @spec assign(String.t(), String.t(), String.t(), String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def assign(access_token, nbh, variant, accelerator, high_mem \\ false, opts \\ []) do
    with {:ok, %{} = first} <- assign_get(access_token, nbh, variant, accelerator, high_mem, opts) do
      cond do
        is_binary(first["endpoint"]) and first["endpoint"] != "" ->
          {:ok, first}

        is_binary(first["token"]) and first["token"] != "" ->
          assign_post(access_token, first["token"], nbh, variant, accelerator, high_mem, opts)

        true ->
          {:error, {:unexpected_response, first}}
      end
    end
  end

  @doc "Two-step GET -> POST `/tun/m/unassign/<endpoint>` to release a runtime."
  @spec unassign(String.t(), String.t(), keyword()) ::
          {:ok, map() | :not_found} | {:error, term()}
  def unassign(access_token, endpoint, opts \\ [])
      when is_binary(access_token) and is_binary(endpoint) and endpoint != "" and is_list(opts) do
    path = "/tun/m/unassign/" <> URI.encode_www_form(endpoint)

    case get_json(access_token, path, [{"authuser", "0"}], opts) do
      {:ok, %{"token" => xsrf_token}} when is_binary(xsrf_token) and xsrf_token != "" ->
        post_json(
          access_token,
          xsrf_token,
          path,
          [{"authuser", "0"}],
          Keyword.put(opts, :allow_empty, true)
        )

      {:error, {:http_error, 404, _}} ->
        {:ok, :not_found}

      {:ok, body} ->
        {:error, {:unexpected_response, body}}

      error ->
        error
    end
  end

  @doc """
  Refresh `runtimeProxyInfo` (`url` and `token`) for an existing `endpoint` via
  `GET /tun/m/assignments`. Returns `{:error, :vm_terminated_externally}` if the
  endpoint is no longer listed.
  """
  @spec refresh_proxy_info(String.t(), String.t()) ::
          {:ok, %{url: String.t(), token: String.t(), assignment: map()}} | {:error, term()}
  def refresh_proxy_info(access_token, endpoint)
      when is_binary(access_token) and is_binary(endpoint) and endpoint != "" do
    with {:ok, assignments} <- list_assignments(access_token) do
      case Enum.find(assignments, &(is_map(&1) and &1["endpoint"] == endpoint)) do
        nil ->
          {:error, :vm_terminated_externally}

        %{"runtimeProxyInfo" => %{"url" => url, "token" => token}} = assignment
        when is_binary(url) and url != "" and is_binary(token) and token != "" ->
          {:ok, %{url: url, token: token, assignment: assignment}}

        _ ->
          {:error, :invalid_proxy_info}
      end
    end
  end

  @doc """
  Validate a Colab runtime proxy URL against SSRF and domain allowlist rules:
  - `https` scheme only
  - port `443` (or `nil`)
  - empty `userinfo`
  - hostname in `colab.research.google.com`, `*.colab.research.google.com`,
    `*.prod.colab.googleusercontent.com`, `*.prod.colab.dev`, or
    `*.prod.r.colab.dev`
  - DNS resolution via `SalixAgent.Egress.Destination.resolve/2`

  When `:allow_private` (or `:colab_allow_private_endpoints` app env in tests) is
  `true`, private IPs, custom test ports, and non-Google test hostnames are
  permitted while `https` and empty `userinfo` remain enforced.
  """
  @spec validate_proxy_url(String.t(), keyword()) ::
          {:ok,
           %{uri: URI.t(), host: String.t(), port: pos_integer(), addresses: [:inet.ip_address()]}}
          | {:error, term()}
  def validate_proxy_url(url, opts \\ [])

  def validate_proxy_url(url, opts) when is_binary(url) and url != "" do
    allow_private =
      Keyword.get(
        opts,
        :allow_private,
        SystemsRuntime.get_env(:salix_agent, :colab_allow_private_endpoints, false)
      ) == true

    uri = URI.parse(url)

    host =
      if is_binary(uri.host), do: String.downcase(String.trim_trailing(uri.host, ".")), else: ""

    cond do
      not (uri.scheme == "https" or (allow_private and uri.scheme in ["http", "ws", "wss"])) ->
        {:error, :invalid_proxy_scheme}

      uri.userinfo not in [nil, ""] ->
        {:error, :invalid_proxy_userinfo}

      host == "" ->
        {:error, :invalid_proxy_host}

      not allow_private and uri.port not in [nil, 443] ->
        {:error, :invalid_proxy_port}

      not allow_private and not allowed_proxy_host?(host) ->
        {:error, :disallowed_proxy_host}

      true ->
        default_port = if uri.scheme in ["http", "ws"], do: 80, else: 443

        case Destination.resolve(host, allow_private: allow_private) do
          {:ok, addresses} ->
            {:ok, %{uri: uri, host: host, port: uri.port || default_port, addresses: addresses}}

          {:error, reason} ->
            {:error, {:blocked_proxy_destination, reason}}
        end
    end
  end

  def validate_proxy_url(_, _), do: {:error, :invalid_proxy_url}

  @doc "Strip Google's XSSI prefix `\")]}'\\n\"` if present and decode JSON."
  @spec decode_xssi_json(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode_xssi_json(body, opts \\ []) when is_binary(body) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    trimmed =
      case body do
        @xssi_prefix <> rest -> rest
        other -> other
      end

    case String.trim(trimmed) do
      "" ->
        if allow_empty, do: {:ok, %{}}, else: {:error, :invalid_response}

      json ->
        case Jason.decode(json) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_response}
        end
    end
  end

  # ---- Internal helpers ----

  defp allowed_proxy_host?(@allowed_proxy_exact), do: true

  defp allowed_proxy_host?(host) do
    Enum.any?(@allowed_proxy_suffixes, fn suffix ->
      if String.ends_with?(host, suffix) do
        prefix = binary_part(host, 0, byte_size(host) - byte_size(suffix))

        prefix != "" and not String.starts_with?(prefix, ".") and
          not String.contains?(prefix, "..")
      else
        false
      end
    end)
  end

  defp assign_query(nbh, variant, accelerator, high_mem) do
    base = [
      {"nbh", nbh},
      {"authuser", "0"},
      {"variant", variant},
      {"accelerator", accelerator}
    ]

    if high_mem and accelerator not in @high_mem_only_accelerators do
      base ++ [{"shape", "hm"}]
    else
      base
    end
  end

  defp get_json(access_token, path, query, opts \\ []) do
    url = build_url(path, query)
    extra_req = Keyword.take(opts, [:receive_timeout])

    case Req.get(
           url,
           req_options([headers: base_headers(access_token), decode_body: false] ++ extra_req)
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_body(body, opts)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  rescue
    error -> {:error, {:transport_error, error}}
  end

  defp post_json(access_token, xsrf_token, path, query, opts) do
    url = build_url(path, query)
    headers = [{"x-goog-colab-token", xsrf_token} | base_headers(access_token)]
    extra_req = Keyword.take(opts, [:receive_timeout])

    case Req.post(
           url,
           req_options([headers: headers, body: "", decode_body: false] ++ extra_req)
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_body(body, opts)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  rescue
    error -> {:error, {:transport_error, error}}
  end

  defp decode_body(body, opts) when is_binary(body), do: decode_xssi_json(body, opts)
  defp decode_body(body, _opts) when is_map(body) or is_list(body), do: {:ok, body}
  defp decode_body(_, _opts), do: {:error, :invalid_response}

  defp decode_error_body(body) when is_binary(body) do
    case decode_xssi_json(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp decode_error_body(body), do: body

  defp base_headers(access_token) do
    [
      {"authorization", "Bearer " <> access_token},
      {"accept", "application/json"},
      {"x-colab-client-agent", @client_agent}
    ]
  end

  defp build_url(path, query) do
    base = String.trim_trailing(base_url(), "/")
    base <> path <> "?" <> URI.encode_query(query)
  end

  defp req_options(opts) do
    [
      retry: false,
      redirect: false,
      receive_timeout: 25_000,
      # Colab's empty-body POST `/tun/m/assign` stalls under HTTP/2 with Finch/Mint;
      # force HTTP/1.1 to match `google-colab-cli` (python-requests).
      connect_options: [timeout: 5_000, protocols: [:http1]]
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(config()[:req_options] || [])
  end

  defp base_url, do: config()[:colab_base_url] || @default_base_url
  defp config, do: SystemsRuntime.get_env(:salix_agent, :colab_oauth, [])
end
