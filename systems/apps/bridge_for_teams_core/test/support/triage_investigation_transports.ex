defmodule BridgeForTeams.TriageInvestigationTransports do
  @moduledoc """
  Local external transports for the isolated investigation composition fixture.

  `install!/1` accepts selected `:llm_base_urls`, an exact loopback
  `:slack_base_url`, an `:exa` callback, and an optional `:capture` callback.
  Exa receives `%{method: :post, path: path, json: body}` and returns a
  `Req.Response` or `{:error, reason}`. Capture receives only bounded routing
  metadata, never request headers, bodies, command arguments or credentials.
  A separate opt-in `:llm_request_observer` receives the selected LLM's encoded
  request body and final HTTP status in memory. It must retain only bounded
  source matches, never raw body/headers, and does not replace the adapter.

  An explicit `:live_exa_api_key` opts a local probe into the real read-only
  `/search` and `/contents` operations instead of the frozen Exa callback.
  The key is process-local and never included in captured metadata. Other
  destinations and write operations remain unavailable; this is not a replay
  of historical public-page bytes.

  Req defaults and the environment/MCP/Compute transport seams are global.
  Install after application startup, run serially, and retire fixture work
  before calling the returned cleanup function. Selected LLM requests retain
  the previous adapter and streaming callback; Slack retains its real loopback
  transport. Unseeded Exa operations and other destinations fail explicitly.

  This does not change ToolDisclosure, plugin policy, or role authorization.
  The caller owns the fresh local plugin inventory and absence of Compute
  environment/placement/grant authority. The Compute HTTP seam prevents host
  execution; it does not prevent local placement-operation records. This is not
  an OS egress sandbox: prebuilt Req requests, explicit adapters and transports
  outside these named seams are not intercepted.
  """

  @capture_key :triage_investigation_transport_capture
  @exa_base_url "https://api.exa.ai"
  @exa_body_limit 65_536
  @llm_paths ~w(/chat/completions /responses /responses/compact /v1/messages)
  @settings [
    {:req, :default_options},
    {:salix_agent, :exa_api_key},
    {:salix_agent, :exa_base_url},
    {:salix_agent, :env_dispatch},
    {:salix_agent, :mcp_provider_mod},
    {:salix_store, :agent_vmm_host_http_client},
    {:bridge_for_teams_core, @capture_key}
  ]

  defmodule UnavailableError do
    defexception [:message]
  end

  def install!(opts) do
    llm_targets =
      for base <- Keyword.fetch!(opts, :llm_base_urls), path <- @llm_paths, into: MapSet.new() do
        uri = base_uri!(base)
        {origin(uri), String.trim_trailing(uri.path || "", "/") <> path}
      end

    slack = opts |> Keyword.fetch!(:slack_base_url) |> base_uri!()

    unless slack.scheme == "http" and slack.host in ["127.0.0.1", "::1"] do
      raise ArgumentError, "Slack fixture must use an exact HTTP loopback listener"
    end

    exa = Keyword.fetch!(opts, :exa)
    live_exa_key = Keyword.get(opts, :live_exa_api_key)
    capture = Keyword.get(opts, :capture, fn _event -> :ok end)
    llm_observer = Keyword.get(opts, :llm_request_observer, fn _body, _status -> :ok end)

    unless is_function(exa, 1) and is_function(capture, 1) do
      raise ArgumentError, "exa and capture must be one-argument fixture callbacks"
    end

    unless is_nil(live_exa_key) or (is_binary(live_exa_key) and byte_size(live_exa_key) > 0) do
      raise ArgumentError, "live public-web reads require a non-empty process-local key"
    end

    previous =
      Enum.map(@settings, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)

    defaults = Req.default_options()
    adapter = Keyword.get(defaults, :adapter, &Req.Steps.run_finch/1)
    slack_origin = origin(slack)

    Req.default_options(
      Keyword.put(defaults, :adapter, fn request ->
        route(
          request,
          llm_targets,
          slack_origin,
          adapter,
          exa,
          capture,
          not is_nil(live_exa_key),
          llm_observer
        )
      end)
    )

    Application.put_env(:salix_agent, :exa_api_key, live_exa_key || "local-investigation-fixture")
    Application.put_env(:salix_agent, :exa_base_url, @exa_base_url)
    Application.put_env(:salix_agent, :env_dispatch, __MODULE__.EmptyEnvironment)
    Application.put_env(:salix_agent, :mcp_provider_mod, __MODULE__.EmptyMCP)

    Application.put_env(
      :salix_store,
      :agent_vmm_host_http_client,
      __MODULE__.UnavailableComputeHTTP
    )

    Application.put_env(:bridge_for_teams_core, @capture_key, capture)

    fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end
  end

  defp route(request, llm_targets, slack_origin, adapter, exa, capture, live_exa?, llm_observer) do
    request_origin = origin(request.url)

    cond do
      request_origin == {"https", "api.exa.ai", 443} and request.method == :post and
          request.url.path in ["/search", "/contents"] ->
        if live_exa? do
          capture.(http_event(request, :public_web_read))
          run_adapter(adapter, request)
        else
          capture.(http_event(request, :exa))
          exa_response(request, exa)
        end

      request_origin == slack_origin ->
        capture.(http_event(request, :passthrough))
        run_adapter(adapter, request)

      request.method == :post and MapSet.member?(llm_targets, {request_origin, request.url.path}) ->
        capture.(http_event(request, :passthrough))
        result = run_adapter(adapter, request)

        status =
          case result do
            {_request, %Req.Response{status: status}} -> status
            _ -> nil
          end

        llm_observer.(request.body, status)
        result

      true ->
        capture.(http_event(request, :unavailable))
        unavailable_response(request, "HTTP destination or operation is not seeded")
    end
  end

  defp exa_response(request, exa) do
    body = request.body || ""

    if (is_binary(body) or is_list(body)) and IO.iodata_length(body) <= @exa_body_limit do
      with {:ok, json} when is_map(json) <- Jason.decode(IO.iodata_to_binary(body)) do
        case exa.(%{method: request.method, path: request.url.path, json: json}) do
          %Req.Response{} = response -> {request, response}
          {:error, reason} -> unavailable_response(request, "Exa: #{inspect(reason, limit: 10)}")
          _ -> unavailable_response(request, "invalid Exa fixture response")
        end
      else
        _ -> unavailable_response(request, "Exa requires a bounded JSON object")
      end
    else
      unavailable_response(request, "Exa request exceeds the fixture body bound")
    end
  end

  defp unavailable_response(request, detail) do
    {request,
     __MODULE__.UnavailableError.exception(
       message: "test fixture unavailable: " <> String.slice(detail, 0, 300)
     )}
  end

  defp run_adapter(adapter, request) when is_function(adapter, 1), do: adapter.(request)

  defp run_adapter({module, function, args}, request),
    do: apply(module, function, [request | args])

  defp base_uri!(base) when is_binary(base) do
    uri = URI.parse(base)

    if origin(uri) != nil and uri.query == nil and uri.fragment == nil do
      uri
    else
      raise ArgumentError,
            "fixture base URLs must be HTTP(S) URLs without userinfo, query or fragment"
    end
  end

  defp origin(%URI{scheme: scheme, host: host, port: port, userinfo: nil})
       when scheme in ["http", "https"] and is_binary(host) and host != "" and
              is_integer(port) and port > 0 and port <= 65_535,
       do: {scheme, String.downcase(host), port}

  defp origin(_uri), do: nil

  defp http_event(request, disposition) do
    %{
      surface: :http,
      disposition: disposition,
      method: request.method,
      origin:
        request.url
        |> Map.take([:scheme, :host, :port])
        |> then(&struct(URI, &1))
        |> URI.to_string()
        |> String.slice(0, 300)
    }
  end

  @doc false
  def unavailable(surface, operation) do
    capture(surface, operation, :unavailable)
    {:error, {:test_fixture_unavailable, surface, operation}}
  end

  @doc false
  def inventory(surface, operation, value) do
    capture(surface, operation, :empty_inventory)
    {:ok, value}
  end

  defp capture(surface, operation, disposition) do
    callback = Application.get_env(:bridge_for_teams_core, @capture_key, fn _ -> :ok end)
    callback.(%{surface: surface, operation: operation, disposition: disposition})
  end

  defmodule EmptyEnvironment do
    @moduledoc false
    @behaviour SalixAgent.EnvDispatch
    alias BridgeForTeams.TriageInvestigationTransports, as: Transports

    @impl true
    def list_envs(_agent_id), do: Transports.inventory(:environment, :list_envs, [])

    @impl true
    def list_devices(_agent_id, _opts),
      do: Transports.inventory(:environment, :list_devices, %{devices: [], next_cursor: nil})

    for {operation, arity} <- [
          get_device: 2,
          create_device_install: 2,
          exec: 4,
          request: 4,
          computer_use: 3,
          android: 3,
          process_list: 2,
          process_write: 5,
          process_tail: 4,
          read_stream: 3,
          write_stream: 4
        ] do
      @impl true
      def unquote(operation)(unquote_splicing(List.duplicate({:_, [], nil}, arity))),
        do: Transports.unavailable(:environment, unquote(operation))
    end
  end

  defmodule EmptyMCP do
    @moduledoc false
    @behaviour SalixAgent.Tools.MCP
    alias BridgeForTeams.TriageInvestigationTransports, as: Transports

    @impl true
    def provider_state(_agent_id), do: Transports.inventory(:mcp, :provider_state, %{})
    @impl true
    def dynamic_disclosure_entries(_agent_id),
      do: Transports.inventory(:mcp, :dynamic_disclosure_entries, [])

    @impl true
    def list_definitions(_agent_id), do: Transports.inventory(:mcp, :list_definitions, [])
    @impl true
    def list_bindings(_agent_id), do: Transports.inventory(:mcp, :list_bindings, [])

    for {operation, arity} <- [
          create_definition: 2,
          create_binding: 2,
          update_binding: 3,
          set_binding_enabled: 3,
          refresh_binding: 2,
          authorize_binding: 3,
          call_tool: 5,
          cancel_tool_call: 5,
          list_resources: 2,
          read_resource: 3,
          list_prompts: 2,
          get_prompt: 4
        ] do
      @impl true
      def unquote(operation)(unquote_splicing(List.duplicate({:_, [], nil}, arity))),
        do: Transports.unavailable(:mcp, unquote(operation))
    end
  end

  defmodule UnavailableComputeHTTP do
    @moduledoc false
    alias BridgeForTeams.TriageInvestigationTransports, as: Transports

    def post(_url, _body), do: Transports.unavailable(:compute_host, :post)
    def post_import(_url, _headers), do: Transports.unavailable(:compute_host, :post_import)
  end
end
