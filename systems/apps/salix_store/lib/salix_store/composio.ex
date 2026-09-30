defmodule SalixStore.Composio do
  @moduledoc """
  Minimal REST client for the Composio v3/v3.1 APIs (`backend.composio.dev`) — the
  agent-accessible integrations path that runs alongside the managed OAuth
  adapters. Composio has no Elixir SDK; this wraps the plain HTTP surface the
  `composio.*` agent tools need:

    * auth configs — list per toolkit, create a Composio-managed one on demand
      (`ensure_auth_config/2`), so a tenant never has to register provider
      OAuth apps to get started
    * connected accounts — hosted Connect Link creation, list/get/delete
    * tools — catalog search and direct execution
      (`POST /api/v3/tools/execute/{tool_slug}`), which returns provider data
      inline instead of going through a sandboxed VM
    * trigger types and instances, plus project webhook subscription configuration
    * authenticated proxy — create/delete a short-lived Tool Router session and
      execute a native provider HTTP request while preserving the provider's
      response status

  Handwritten-protocol justification (AGENTS.md · External Integrations):
  Composio ships official SDKs for Python and TypeScript only — there is no
  official or maintained community Elixir client. The surface here is kept
  narrow (the endpoints below, bounded connected-account pagination, no
  retry/webhook-signing logic), covered
  by integration-style tests against a mock server, and isolated behind this
  single module so it can be replaced if an Elixir SDK appears.

  Every function takes a `settings` map (`%{"api_key" => _, "base_url" => _}`,
  from `Salix.Control.ComposioSettings`) as its first argument; nothing is
  read from global state except the test seam.

  The base URL resolves through
  `Application.get_env(:salix_store, :composio_base_url_override)` first —
  the test seam, mirroring `:oauth_endpoint_overrides` — then the settings
  record's `"base_url"`, then the public default.

  Returns are `{:ok, map}` / `:ok` on 2xx and `{:error, message}` otherwise.
  Calendar enrollment can opt into redacted structured transport errors with
  `error_mode: :structured`, preserving retryability without parsing strings
  downstream. Provider-level tool failures (`"successful" => false`) are NOT
  errors — the caller surfaces them to the model verbatim.
  """

  @default_base_url "https://backend.composio.dev"

  # Composio connected-account lifecycle states (v3 API).
  @active_status "ACTIVE"
  @pending_statuses ["INITIALIZING", "INITIATED"]
  @connected_accounts_page_limit 100
  @connected_accounts_max_pages 10

  @doc "Connected-account status meaning the account is usable."
  def active_status, do: @active_status

  @doc "Connected-account statuses meaning the user has not finished the flow."
  def pending_statuses, do: @pending_statuses

  @doc """
  The auth config id to connect `toolkit` under: the first existing auth
  config for the toolkit, else a freshly created Composio-managed one. A
  tenant that configured its own (custom OAuth app) auth config in the
  Composio dashboard wins automatically; everyone else gets managed auth with
  zero provider setup.
  """
  def ensure_auth_config(settings, toolkit) do
    with {:ok, %{"items" => items}} when is_list(items) <-
           request(settings, :get, "/api/v3/auth_configs",
             params: [toolkit_slug: toolkit],
             label: "list auth configs"
           ) do
      case Enum.find(items, &usable_auth_config?/1) do
        %{"id" => id} -> {:ok, id}
        nil -> maybe_create_managed_auth_config(settings, toolkit)
      end
    else
      {:ok, _other} -> maybe_create_managed_auth_config(settings, toolkit)
      {:error, message} -> {:error, message}
    end
  end

  # Composio does not offer managed OAuth for Google Admin. An administrator
  # must first configure an OAuth app with read-only Directory scopes.
  defp maybe_create_managed_auth_config(_settings, "google_admin"),
    do: {:error, :google_admin_custom_oauth_required}

  defp maybe_create_managed_auth_config(settings, toolkit),
    do: create_managed_auth_config(settings, toolkit)

  defp usable_auth_config?(config) do
    is_binary(config["id"]) and config["id"] != "" and config["is_disabled"] != true and
      config["deprecated"] != true
  end

  defp create_managed_auth_config(settings, toolkit) do
    body = %{
      "toolkit" => %{"slug" => toolkit},
      "auth_config" => %{"type" => "use_composio_managed_auth"}
    }

    case request(settings, :post, "/api/v3/auth_configs",
           json: body,
           label: "create auth config"
         ) do
      {:ok, %{"auth_config" => %{"id" => id}}} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, %{"id" => id}} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, other} -> {:error, "create auth config: no id in response #{inspect(other)}"}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Create a hosted Connect Link session for `user_id` under `auth_config_id`.
  Returns the raw response — at least `"redirect_url"` (send the user there)
  and `"connected_account_id"` (poll it for ACTIVE). `opts`:
  `:callback_url` — where Composio sends the browser after the provider flow.
  """
  def create_connect_link(settings, auth_config_id, user_id, opts \\ []) do
    body =
      %{"auth_config_id" => auth_config_id, "user_id" => user_id}
      |> put_present("callback_url", opts[:callback_url])

    request(settings, :post, "/api/v3/connected_accounts/link",
      json: body,
      label: "create connect link"
    )
  end

  @doc "Connected accounts for `user_id`, newest first. Returns `{:ok, items}`."
  def list_connected_accounts(settings, user_id) do
    case request(settings, :get, "/api/v3/connected_accounts",
           params: [user_ids: user_id],
           label: "list connected accounts"
         ) do
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, _other} -> {:error, :invalid_connected_accounts_response}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  All connected accounts for `user_id` within an explicit finite page budget.

  Unlike `list_connected_accounts/2`, this follows `next_cursor`. It fails
  closed rather than returning an incomplete set when the provider advertises
  more pages than `:max_pages`. Options: `:page_limit` (default 100),
  `:max_pages` (default 10), and `:error_mode` (`:message` by default or
  `:structured` for redacted HTTP/transport tuples).
  """
  def list_connected_accounts_all(settings, user_id, opts \\ []) do
    page_limit = bounded_positive(opts[:page_limit], @connected_accounts_page_limit, 100)
    max_pages = bounded_positive(opts[:max_pages], @connected_accounts_max_pages, 20)

    list_connected_account_pages(
      settings,
      user_id,
      page_limit,
      max_pages,
      nil,
      [],
      MapSet.new(),
      opts[:error_mode] || :message
    )
  end

  defp list_connected_account_pages(
         _settings,
         _user_id,
         _page_limit,
         0,
         _cursor,
         _items,
         _seen,
         _error_mode
       ),
       do: {:error, :connected_accounts_page_limit_exceeded}

  defp list_connected_account_pages(
         settings,
         user_id,
         page_limit,
         pages_left,
         cursor,
         accumulated,
         seen,
         error_mode
       ) do
    params =
      [user_ids: user_id, limit: page_limit]
      |> put_param(:cursor, cursor)

    case request(settings, :get, "/api/v3/connected_accounts",
           params: params,
           label: "list connected accounts",
           error_mode: error_mode
         ) do
      {:ok, %{"items" => items} = page} when is_list(items) ->
        next_cursor = trim(page["next_cursor"])
        accumulated = accumulated ++ items

        cond do
          next_cursor == "" ->
            {:ok, Enum.uniq_by(accumulated, &trim(&1["id"]))}

          MapSet.member?(seen, next_cursor) ->
            {:error, :connected_accounts_cursor_cycle}

          true ->
            list_connected_account_pages(
              settings,
              user_id,
              page_limit,
              pages_left - 1,
              next_cursor,
              accumulated,
              MapSet.put(seen, next_cursor),
              error_mode
            )
        end

      {:ok, _other} ->
        {:error, :invalid_connected_accounts_page}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  One connected account by id. `{:error, :not_found}` on 404.

  `opts[:error_mode]` may be `:message` (the default) or `:structured` for
  redacted HTTP/transport tuples.
  """
  def get_connected_account(settings, connected_account_id, opts \\ []) do
    request(settings, :get, "/api/v3/connected_accounts/#{connected_account_id}",
      label: "get connected account",
      error_mode: opts[:error_mode] || :message
    )
  end

  @doc "Delete (disconnect) a connected account. `:ok` on success or 404."
  def delete_connected_account(settings, connected_account_id) do
    case request(settings, :delete, "/api/v3/connected_accounts/#{connected_account_id}",
           label: "delete connected account"
         ) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Search the toolkit catalog (the ~300 connectable services). `opts`:
  `:search` (full-text over name/slug), `:limit`. Returns `{:ok, items}` with
  the raw toolkit maps (`"slug"`, `"name"`, `"auth_schemes"`,
  `"meta"` → description/tools_count/categories, ...).
  """
  def list_toolkits(settings, opts \\ []) do
    params =
      []
      |> put_param(:search, opts[:search])
      |> put_param(:limit, opts[:limit])

    case request(settings, :get, "/api/v3/toolkits", params: params, label: "list toolkits") do
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, _other} -> {:ok, []}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Search the tool catalog. `opts`: `:toolkit` (slug filter), `:query`
  (full-text), `:tool_slugs` (comma-separated exact slugs), `:limit`.
  Returns `{:ok, items}` with the raw tool maps (`"slug"`, `"name"`,
  `"description"`, `"input_parameters"`, ...).
  """
  def list_tools(settings, opts \\ []) do
    params =
      []
      |> put_param(:toolkit_slug, opts[:toolkit])
      |> put_param(:query, opts[:query])
      |> put_param(:tool_slugs, opts[:tool_slugs])
      |> put_param(:limit, opts[:limit])

    case request(settings, :get, "/api/v3/tools", params: params, label: "list tools") do
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, _other} -> {:ok, []}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Execute `tool_slug` for `user_id` with `arguments` (a map matching the
  tool's `input_parameters`). `opts`: `:connected_account_id` to pin a
  specific account and `:error_mode` (`:message` by default or `:structured`
  for redacted HTTP/transport tuples). Returns the raw execution envelope
  (`"data"` / `"successful"` / `"error"` / `"log_id"`) — a provider-level
  failure is `{:ok, %{"successful" => false, ...}}`, not `{:error, _}`.
  """
  def execute_tool(settings, tool_slug, user_id, arguments, opts \\ []) do
    body =
      %{"user_id" => user_id, "arguments" => arguments}
      |> put_present("connected_account_id", opts[:connected_account_id])
      |> put_present("version", opts[:version])

    request(settings, :post, "/api/v3/tools/execute/#{tool_slug}",
      json: body,
      label: "execute tool #{tool_slug}",
      error_mode: opts[:error_mode] || :message
    )
  end

  @doc """
  Create a short-lived Tool Router session pinned to one connected account.

  The session enables only `toolkit` and disables the remote workbench and
  connection-management helpers. Native proxy calls still run through
  Composio's bearer authority; Comma never reads or stores the provider token.
  """
  def create_proxy_session(
        settings,
        user_id,
        connected_account_id,
        toolkit \\ "googlecalendar",
        opts \\ []
      ) do
    error_mode = opts[:error_mode] || :message

    body = %{
      "user_id" => user_id,
      "toolkits" => %{"enable" => [toolkit]},
      "connected_accounts" => %{toolkit => [connected_account_id]},
      "manage_connections" => %{"enable" => false},
      "workbench" => %{"enable" => false}
    }

    case request(settings, :post, "/api/v3.1/tool_router/session",
           json: body,
           label: "create proxy session",
           error_mode: error_mode
         ) do
      {:ok, %{"session_id" => session_id}} when is_binary(session_id) and session_id != "" ->
        {:ok, session_id}

      {:ok, _other} when error_mode == :structured ->
        {:error, :invalid_composio_proxy_session}

      {:ok, other} ->
        {:error, {:invalid_composio_proxy_session, other}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Execute a native provider request through a Tool Router session.

  A successful Composio request returns the raw proxy envelope, including its
  provider-level `"status"` (for example Google Calendar's 410). The caller,
  rather than this transport adapter, decides the domain meaning of that
  status.
  """
  def proxy_execute(settings, session_id, request_body, opts \\ []) when is_map(request_body) do
    request(
      settings,
      :post,
      "/api/v3.1/tool_router/session/#{URI.encode(session_id)}/proxy_execute",
      json: request_body,
      label: "execute proxy request",
      max_response_bytes: opts[:max_response_bytes],
      error_mode: opts[:error_mode] || :message
    )
  end

  @doc "Delete a Tool Router session. Repeated deletion is successful."
  def delete_proxy_session(settings, session_id) do
    case request(
           settings,
           :delete,
           "/api/v3.1/tool_router/session/#{URI.encode(session_id)}",
           label: "delete proxy session"
         ) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  # Trigger and subscription endpoints use the existing isolated REST adapter.
  # No maintained Elixir Composio SDK covers this surface. Requests are bounded,
  # have no transport retries, and are exercised against an HTTP test server.
  def list_trigger_types(settings, toolkit, cursor \\ nil) do
    request(settings, :get, "/api/v3.1/triggers_types",
      params: put_param([toolkit_slugs: toolkit, limit: 20], :cursor, cursor),
      label: "list trigger types",
      error_mode: :structured
    )
  end

  def get_trigger_type(settings, slug) do
    request(settings, :get, "/api/v3.1/triggers_types/#{segment(slug)}",
      label: "get trigger type",
      error_mode: :structured
    )
  end

  def list_triggers(settings, group_id, opts \\ []) do
    params =
      [user_ids: group_id, show_disabled: true, limit: 50]
      |> put_param(:cursor, opts[:cursor])
      |> put_param(:trigger_ids, opts[:trigger_id])

    request(settings, :get, "/api/v3.1/trigger_instances/active",
      params: params,
      label: "list triggers",
      error_mode: :structured
    )
  end

  def upsert_trigger(settings, group_id, account_id, slug, config) do
    request(settings, :post, "/api/v3.1/trigger_instances/#{segment(slug)}/upsert",
      json: %{
        user_id: group_id,
        connected_account_id: account_id,
        trigger_config: config,
        egress_url: nil
      },
      label: "upsert trigger",
      error_mode: :structured
    )
  end

  def manage_trigger(settings, group_id, id, action)
      when action in ["enable", "disable", "delete"] do
    method = if action == "delete", do: :delete, else: :patch
    opts = [label: "manage trigger", error_mode: :structured]

    opts =
      if action == "delete",
        do: opts,
        else: Keyword.put(opts, :json, %{status: action, user_id: group_id})

    request(settings, method, "/api/v3.1/trigger_instances/manage/#{segment(id)}", opts)
  end

  def list_webhook_subscriptions(settings) do
    request(settings, :get, "/api/v3.1/webhook_subscriptions",
      params: [limit: 2],
      label: "list webhook subscriptions",
      error_mode: :structured
    )
  end

  def set_webhook_subscription(settings, url, id \\ nil) do
    path = "/api/v3.1/webhook_subscriptions" <> if(id, do: "/" <> segment(id), else: "")

    request(settings, if(id, do: :patch, else: :post), path,
      json: %{webhook_url: url, enabled_events: ["composio.trigger.message"], version: "V3"},
      label: "set webhook subscription",
      error_mode: :structured
    )
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # ---- HTTP plumbing ----

  defp request(settings, method, path, opts) do
    label = Keyword.fetch!(opts, :label)
    error_mode = opts[:error_mode] || :message

    case api_key(settings) do
      "" ->
        composio_config_error(label, error_mode)

      api_key ->
        req_opts =
          [
            url: base_url(settings) <> path,
            method: method,
            headers: [{"x-api-key", api_key}, {"accept", "application/json"}]
          ]
          |> put_opt(:params, opts[:params])
          |> put_opt(:json, opts[:json])

        # Account management runs under the plugin attempt lock. Each HTTP call
        # gets one attempt and a finite transport wait. Tool execution keeps its
        # existing policy and its caller-owned collection budget.
        req_opts =
          if String.starts_with?(path, [
               "/api/v3/connected_accounts",
               "/api/v3/auth_configs",
               "/api/v3.1/trigger",
               "/api/v3.1/webhook_subscriptions"
             ]) do
            Keyword.merge(req_opts,
              receive_timeout: 8_000,
              connect_options: [timeout: 8_000],
              retry: false
            )
          else
            req_opts
          end

        req_opts
        |> bound_response(opts[:max_response_bytes])
        |> Req.request()
        |> handle_response(label, error_mode)
    end
  end

  defp bound_response(options, limit) when is_integer(limit) and limit > 0 do
    Keyword.merge(options,
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: 8_000,
      connect_options: [timeout: 8_000],
      into: fn {:data, data}, {req, resp} ->
        body = (resp.body || "") <> data

        if byte_size(body) > limit,
          do: {:halt, {req, %{resp | body: :response_too_large}}},
          else: {:cont, {req, %{resp | body: body}}}
      end
    )
  end

  defp bound_response(options, _), do: options

  defp handle_response({:ok, %Req.Response{body: :response_too_large}}, _label, _mode),
    do: {:error, :response_too_large}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, label, error_mode) do
    cond do
      status in 200..299 -> {:ok, decode_body(body)}
      status == 404 -> {:error, :not_found}
      error_mode == :structured -> {:error, {:http, status}}
      true -> {:error, "composio #{label}: HTTP #{status}: #{error_message(body)}"}
    end
  end

  defp handle_response({:error, err}, _label, :structured),
    do: {:error, {:transport, transport_reason(err)}}

  defp handle_response({:error, err}, label, _error_mode),
    do: {:error, "composio #{label} request: #{Exception.message(err)}"}

  defp composio_config_error(_label, :structured), do: {:error, :composio_not_configured}

  defp composio_config_error(label, _error_mode),
    do: {:error, "composio #{label}: api_key is not configured"}

  defp transport_reason(%Req.TransportError{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(_error), do: :unknown

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_body(_), do: %{}

  defp error_message(body) do
    body = decode_body(body)

    get_in(body, ["error", "message"]) || body["message"] ||
      (body == %{} && "no error detail") || Jason.encode!(body)
  end

  defp base_url(settings) do
    override = Application.get_env(:salix_store, :composio_base_url_override)
    configured = String.trim(to_string((is_map(settings) && settings["base_url"]) || ""))

    cond do
      is_binary(override) and override != "" -> override
      configured != "" -> configured
      true -> @default_base_url
    end
    |> String.trim_trailing("/")
  end

  defp api_key(settings) when is_map(settings),
    do: String.trim(to_string(settings["api_key"] || ""))

  defp api_key(_), do: ""

  defp put_present(map, _key, nil), do: map

  defp put_present(map, key, value) do
    if String.trim(to_string(value)) == "", do: map, else: Map.put(map, key, value)
  end

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: params ++ [{key, value}]

  defp bounded_positive(value, _default, maximum)
       when is_integer(value) and value > 0 and value <= maximum,
       do: value

  defp bounded_positive(_value, default, _maximum), do: default
  defp trim(value), do: value |> to_string() |> String.trim()

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, []), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
